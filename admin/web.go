package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"html/template"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed templates/*.html static/*
var assets embed.FS

var templates = template.Must(template.New("").Funcs(template.FuncMap{
	"date":  func(t time.Time) string { return t.UTC().Format("2006-01-02 15:04") },
	"when":  when,
	"bytes": humanBytes,
}).ParseFS(assets, "templates/*.html"))

const (
	sessionCookie   = "ffs_admin"
	sessionLifetime = 12 * time.Hour
	// failed password sign-ins allowed per minute, for everybody: the password is
	// the only secret
	loginFailuresPerMinute = 5
)

type session struct {
	csrf    string
	expires time.Time
	// who signed in (the email, "" with the password) and how: password, oidc, header
	user, method string
	// result of the last change, shown once on the dashboard
	message, failed string
}

type App struct {
	sync    *SyncDB
	storage *StorageDB // nil if the storage database is not configured
	fxa     *FxaDB     // nil without self-hosted accounts
	rec     *Recorder
	health  *Health
	alerter *Alerter // nil without ALERT_EMAIL and SMTP_HOST
	auth    *authConfig
	// ADMIN_STALE_DAYS, ADMIN_UNCONFIRMED_HOURS
	staleDays, unconfirmedHours int
	// MAX_USERS=initial:N: max users is set on the dashboard, otherwise by .env
	maxUsersEditable bool

	mu       sync.Mutex
	sessions map[string]*session
	failures []time.Time
}

func serve(ctx context.Context) error {
	auth, err := loadAuth()
	if err != nil {
		return err
	}
	// checked here, not on the first page load or in a background ticker
	for _, name := range []string{"HEALTH_CHECK_SECONDS", "METRICS_FLUSH_SECONDS", "ALERT_INTERVAL_SECONDS"} {
		if envInt(name, 1) < 1 {
			return fmt.Errorf("%s must be 1 or more", name)
		}
	}
	staleDays, unconfirmedHours := envInt("ADMIN_STALE_DAYS", 90), envInt("ADMIN_UNCONFIRMED_HOURS", 72)
	syncDB, err := openSyncDB()
	if err != nil {
		return err
	}
	fxaDB, err := openFxaDB()
	if err != nil {
		return err
	}
	storageDB, err := openStorageDB(syncDB)
	if err != nil {
		return err
	}
	rec, err := newRecorder(ctx, syncDB)
	if err != nil {
		return fmt.Errorf("metrics and event tables in the tokenserver database: %w", err)
	}
	go rec.run(ctx)
	go func() {
		if err := rec.listen(ctx, env("METRICS_LISTEN", ":8125")); err != nil {
			log.Printf("metrics: %v", err)
		}
	}()
	app := &App{sync: syncDB, storage: storageDB, fxa: fxaDB, rec: rec, auth: auth, sessions: map[string]*session{},
		staleDays: staleDays, unconfirmedHours: unconfirmedHours, maxUsersEditable: maxUsersEditable(os.Getenv("MAX_USERS"))}
	app.alerter = newAlerter()
	if app.alerter != nil {
		go app.alerter.run(ctx)
	}
	app.health = newHealth(app)
	go app.health.run(ctx)

	servers := []*http.Server{{
		Addr:              env("ADMIN_LISTEN", ":8080"),
		Handler:           app.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
	}}
	if fxaDB != nil {
		upstream, err := url.Parse(env("FXA_AUTH_UPSTREAM", "http://fxa-auth:9000"))
		if err != nil {
			return fmt.Errorf("FXA_AUTH_UPSTREAM: %w", err)
		}
		servers = append(servers, &http.Server{
			Addr:              env("GATE_LISTEN", ":8081"),
			Handler:           newGate(upstream, env("FXA_CONTENT_URL", ""), fxaDB, app.event),
			ReadHeaderTimeout: 10 * time.Second,
		})
	}

	errs := make(chan error, len(servers))
	for _, s := range servers {
		log.Printf("listening on %s", s.Addr)
		go func() { errs <- s.ListenAndServe() }()
	}
	select {
	case err := <-errs:
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for _, s := range servers {
			s.Shutdown(shutdown)
		}
		return nil
	}
}

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.Handle("GET /static/", http.FileServerFS(assets))
	mux.HandleFunc("GET /login", a.loginPage)
	mux.HandleFunc("POST /login", a.login)
	mux.HandleFunc("GET /auth/login", a.oidcLogin)
	mux.HandleFunc("GET "+callbackPath, a.oidcCallback)
	mux.HandleFunc("POST /logout", a.authenticated(a.logout))
	mux.HandleFunc("GET /{$}", a.authenticated(a.dashboard))
	mux.HandleFunc("GET /users/{uid}", a.authenticated(a.userPage))
	mux.HandleFunc("GET /activity", a.authenticated(a.activityPage))
	mux.HandleFunc("GET /security", a.authenticated(a.securityPage))
	mux.HandleFunc("POST /security/unblock", a.authenticated(a.unblock))
	mux.HandleFunc("POST /users/{uid}/devices/{id}/sign-out", a.authenticated(a.signOutDevice))
	mux.HandleFunc("POST /users/{uid}/sessions/{ref}/sign-out", a.authenticated(a.signOutSession))
	mux.HandleFunc("GET /metrics", a.prometheus)
	mux.HandleFunc("POST /sync/max-users", a.authenticated(a.setMaxUsers))
	mux.HandleFunc("POST /accounts/signups", a.authenticated(a.setSignups))
	mux.HandleFunc("POST /accounts/{uid}/disable", a.authenticated(a.setDisabled(true)))
	mux.HandleFunc("POST /accounts/{uid}/enable", a.authenticated(a.setDisabled(false)))
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func randomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// equal compares secrets in constant time
func equal(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// sameOrigin refuses cross-site form posts (on top of the CSRF token and the
// SameSite=Strict cookie)
func sameOrigin(r *http.Request) bool {
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
		return false
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != "null" {
		u, err := url.Parse(origin)
		if err != nil || u.Host != r.Host {
			return false
		}
	}
	return true
}

func (a *App) render(w http.ResponseWriter, name string, data any) {
	if err := templates.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("rendering %s: %v", name, err)
	}
}

// event records in the activity log, when there is one (not in the unit tests), and
// sends an alert for what is worth one
func (a *App) event(kind, detail string) {
	if a.rec != nil {
		a.rec.Event(kind, detail)
	}
	if alertKinds[kind] || kind == "admin" && strings.HasPrefix(detail, "signed in") {
		a.alert(kind, detail)
	}
}

type accountRow struct {
	UID       string
	Email     string
	Verified  bool
	CreatedAt time.Time
	Disabled  bool
	Sync      bool
	Usage     Usage
	// not synced for ADMIN_STALE_DAYS, never confirmed the email after 3 days
	Stale, Unconfirmed bool
}

type syncUserRow struct {
	SyncUser
	Usage Usage
	Stale bool
}

// usage of the current storage of each account (by FxA uid)
func (a *App) usage(ctx context.Context, users []SyncUser) (map[string]Usage, error) {
	usage := map[string]Usage{}
	if a.storage == nil {
		return usage, nil
	}
	totals, err := a.storage.Totals(ctx)
	if err != nil {
		return usage, err
	}
	for _, u := range users {
		usage[u.UID] = totals[u.StorageID]
	}
	return usage, nil
}

func (a *App) dashboard(w http.ResponseWriter, r *http.Request, s *session) {
	ctx := r.Context()
	data := a.base(s)
	var errs []string

	status, err := a.sync.Status(ctx)
	if err != nil {
		errs = append(errs, "Sync database: "+err.Error())
	}
	data["Sync"], data["MaxUsersEditable"] = status, a.maxUsersEditable
	if a.health != nil {
		data["Health"], data["Sizes"] = a.health.Components(), a.health.Sizes()
	}
	staleBefore := time.Now().AddDate(0, 0, -a.staleDays)
	data["StaleDays"] = a.staleDays
	syncUsers, err := a.sync.Users(ctx)
	if err != nil {
		errs = append(errs, "Sync users: "+err.Error())
	}
	inSync := map[string]bool{}
	for _, u := range syncUsers {
		inSync[u.UID] = true
	}
	usage, err := a.usage(ctx, syncUsers)
	if err != nil {
		errs = append(errs, "Sync storage: "+err.Error())
	}

	if a.fxa != nil {
		if policy, err := a.fxa.Policy(ctx); err != nil {
			errs = append(errs, "Sign-up policy: "+err.Error())
		} else {
			data["Policy"] = policy
			data["Allowlist"] = strings.Join(policy.Allowlist, "\n")
		}
		accounts, err := a.fxa.Accounts(ctx)
		if err != nil {
			errs = append(errs, "Accounts: "+err.Error())
		}
		rows := make([]accountRow, 0, len(accounts))
		var stale, unconfirmed int
		for _, acc := range accounts {
			row := accountRow{UID: acc.UID, Email: acc.Email, Verified: acc.Verified, CreatedAt: acc.CreatedAt, Disabled: acc.Disabled, Sync: inSync[acc.UID], Usage: usage[acc.UID]}
			row.Stale = row.Sync && row.Usage.LastModified.Before(staleBefore) && row.CreatedAt.Before(staleBefore)
			row.Unconfirmed = !acc.Verified && acc.CreatedAt.Before(time.Now().Add(-time.Duration(a.unconfirmedHours)*time.Hour))
			if row.Stale {
				stale++
			}
			if row.Unconfirmed {
				unconfirmed++
			}
			rows = append(rows, row)
		}
		data["Accounts"], data["StaleCount"], data["UnconfirmedCount"] = rows, stale, unconfirmed
	} else {
		// Mozilla's accounts: the tokenserver only knows the account ids
		rows := make([]syncUserRow, 0, len(syncUsers))
		for _, u := range syncUsers {
			stale := usage[u.UID].LastModified.Before(staleBefore) && u.CreatedAt.Before(staleBefore)
			rows = append(rows, syncUserRow{u, usage[u.UID], stale})
		}
		data["SyncUsers"] = rows
	}
	data["Errors"] = errs
	a.render(w, "dashboard.html", data)
}

func (a *App) done(w http.ResponseWriter, r *http.Request, s *session, message string, err error) {
	a.doneTo(w, r, s, "/", message, err)
}

// base is the data of every page: the form token, whether there are self-hosted
// accounts, and the result of the last change (shown once)
func (a *App) base(s *session) map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	data := map[string]any{"CSRF": s.csrf, "FxA": a.fxa != nil, "User": s.user, "Message": s.message, "Failed": s.failed}
	s.message, s.failed = "", ""
	return data
}

func (a *App) doneTo(w http.ResponseWriter, r *http.Request, s *session, to, message string, err error) {
	a.mu.Lock()
	if err != nil {
		log.Printf("%s: %v", r.URL.Path, err)
		s.message, s.failed = "", err.Error()
	} else {
		log.Printf("%s: %s", r.URL.Path, message)
		s.message, s.failed = message, ""
		go a.event("admin", message)
	}
	a.mu.Unlock()
	http.Redirect(w, r, to, http.StatusSeeOther)
}

var errMaxUsersReadOnly = errors.New("max users is managed by MAX_USERS in .env: set MAX_USERS=initial:N there to manage it here")

func (a *App) setMaxUsers(w http.ResponseWriter, r *http.Request, s *session) {
	if !a.maxUsersEditable {
		// the init container sets MAX_USERS again on its next start
		a.done(w, r, s, "", errMaxUsersReadOnly)
		return
	}
	n, err := strconv.Atoi(strings.TrimSpace(r.PostFormValue("max_users")))
	// the tokenserver triggers keep it in an INT
	if err != nil || n < 0 || n > math.MaxInt32 {
		a.done(w, r, s, "", fmt.Errorf("max users must be a number from 0 to %d", math.MaxInt32))
		return
	}
	err = a.sync.SetMaxUsers(r.Context(), n)
	a.done(w, r, s, fmt.Sprintf("Max users set to %d", n), err)
}

func (a *App) setSignups(w http.ResponseWriter, r *http.Request, s *session) {
	if a.fxa == nil {
		http.NotFound(w, r)
		return
	}
	mode, err := ParseMode(r.PostFormValue("mode"))
	if err != nil {
		a.done(w, r, s, "", err)
		return
	}
	allowlist, err := ParseAllowlist(r.PostFormValue("allowlist"))
	if err != nil {
		a.done(w, r, s, "", err)
		return
	}
	p := &SignupPolicy{Mode: mode, Allowlist: allowlist}
	err = a.fxa.SetPolicy(r.Context(), p)
	a.done(w, r, s, "Sign-ups: "+describePolicy(p), err)
}

func (a *App) setDisabled(disabled bool) handler {
	return func(w http.ResponseWriter, r *http.Request, s *session) {
		if a.fxa == nil {
			http.NotFound(w, r)
			return
		}
		uid := r.PathValue("uid")
		err := a.fxa.SetDisabled(r.Context(), uid, disabled)
		verb := "Enabled"
		if disabled {
			verb = "Disabled"
		}
		a.done(w, r, s, fmt.Sprintf("%s account %s", verb, uid), err)
	}
}

// listenPort is the port of an ADMIN_LISTEN like :8080 or 0.0.0.0:8080
func listenPort(addr string) string {
	if _, port, err := net.SplitHostPort(addr); err == nil {
		return port
	}
	return addr
}
