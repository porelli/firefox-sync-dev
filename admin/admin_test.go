package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type fakeChecker struct {
	allowed map[string]bool
	err     error
	asked   []string
}

func (f *fakeChecker) SignupAllowed(ctx context.Context, email string) (bool, error) {
	f.asked = append(f.asked, email)
	return f.allowed[email], f.err
}

type seen struct {
	path, host, xff, body string
}

func gateWithUpstream(t *testing.T, checker SignupChecker) (http.Handler, *[]seen) {
	var requests []seen
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		requests = append(requests, seen{r.URL.RequestURI(), r.Host, r.Header.Get("X-Forwarded-For"), string(body)})
		w.Write([]byte(`{"uid":"x"}`))
	}))
	t.Cleanup(upstream.Close)
	u, _ := url.Parse(upstream.URL)
	return newGate(u, "https://accounts.example.com", checker, nil), &requests
}

func create(gate http.Handler, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "http://api.example.com"+path, strings.NewReader(body))
	req.Header.Set("X-Forwarded-For", "203.0.113.7")
	w := httptest.NewRecorder()
	gate.ServeHTTP(w, req)
	return w
}

func TestGateForwardsAllowedSignups(t *testing.T) {
	checker := &fakeChecker{allowed: map[string]bool{"alice@example.com": true}}
	gate, requests := gateWithUpstream(t, checker)
	body := `{"email":"alice@example.com","authPW":"x"}`
	w := create(gate, "/v1/account/create?keys=true", body)
	if w.Code != 200 || len(*requests) != 1 {
		t.Fatalf("not forwarded: %d %v", w.Code, *requests)
	}
	got := (*requests)[0]
	if got.path != "/v1/account/create?keys=true" || got.body != body || got.host != "api.example.com" {
		t.Errorf("changed on the way: %+v", got)
	}
	// the auth server reads the client address at a fixed depth: no extra hop
	if got.xff != "203.0.113.7" {
		t.Errorf("X-Forwarded-For = %q", got.xff)
	}
}

func TestGateRefusesSignups(t *testing.T) {
	checker := &fakeChecker{allowed: map[string]bool{}}
	gate, requests := gateWithUpstream(t, checker)
	for _, path := range []string{"/v1/account/create", "/v1//account/create", "/v1/account/create/", "/v1/account/./create"} {
		w := create(gate, path, `{"email":"mallory@example.org"}`)
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), `"errno":125`) {
			t.Errorf("%s: %d %s", path, w.Code, w.Body)
		}
	}
	if len(*requests) != 0 {
		t.Errorf("refused sign-ups reached the auth server: %v", *requests)
	}
}

func TestGateReadsTheEmailAsTheAuthServer(t *testing.T) {
	checker := &fakeChecker{allowed: map[string]bool{"alice@example.com": true}}
	gate, requests := gateWithUpstream(t, checker)
	// encoding/json would take the last key that case-folds to "email", the auth
	// server takes only "email" itself
	for _, body := range []string{
		`{"email":"mallory@example.org","Email":"alice@example.com"}`,
		`{"email":"mallory@example.org","EMAIL":"alice@example.com"}`,
		`{"email":"alice@example.com","email":"mallory@example.org"}`,
	} {
		if w := create(gate, "/v1/account/create", body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, forwarded", body, w.Code)
		}
	}
	if len(*requests) != 0 {
		t.Errorf("reached the auth server: %v", *requests)
	}
	// not the auth server's email: it refuses those itself
	if w := create(gate, "/v1/account/create", `{"Email":"mallory@example.org"}`); w.Code != 200 {
		t.Errorf("no email key: %d", w.Code)
	}
}

func TestGateRefusalReadableByTheAccountsPages(t *testing.T) {
	gate, _ := gateWithUpstream(t, &fakeChecker{})
	for origin, want := range map[string]string{"https://accounts.example.com": "https://accounts.example.com", "https://evil.example": ""} {
		req := httptest.NewRequest(http.MethodPost, "/v1/account/create", strings.NewReader(`{"email":"mallory@example.org"}`))
		req.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		gate.ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != want {
			t.Errorf("%s: Access-Control-Allow-Origin %q", origin, got)
		}
		// the pages send credentials: without this they cannot read the error either
		if creds := w.Header().Get("Access-Control-Allow-Credentials"); (creds == "true") != (want != "") {
			t.Errorf("%s: Access-Control-Allow-Credentials %q", origin, creds)
		}
	}
}

func TestGateFailsClosed(t *testing.T) {
	gate, requests := gateWithUpstream(t, &fakeChecker{err: errors.New("db down")})
	if w := create(gate, "/v1/account/create", `{"email":"alice@example.com"}`); w.Code != http.StatusServiceUnavailable {
		t.Errorf("status %d", w.Code)
	}
	if len(*requests) != 0 {
		t.Error("forwarded without a policy decision")
	}
}

func TestGatePassesEverythingElse(t *testing.T) {
	checker := &fakeChecker{}
	gate, requests := gateWithUpstream(t, checker)
	create(gate, "/v1/account/login", `{"email":"mallory@example.org"}`)
	req := httptest.NewRequest(http.MethodGet, "/v1/account/create", nil)
	gate.ServeHTTP(httptest.NewRecorder(), req)
	if len(*requests) != 2 || len(checker.asked) != 0 {
		t.Errorf("requests %v, checked %v", *requests, checker.asked)
	}
}

func TestGateBodyLimit(t *testing.T) {
	gate, requests := gateWithUpstream(t, &fakeChecker{})
	w := create(gate, "/v1/account/create", `{"email":"`+strings.Repeat("a", maxCreateBody)+`"}`)
	if w.Code != http.StatusRequestEntityTooLarge || len(*requests) != 0 {
		t.Errorf("status %d, forwarded %d", w.Code, len(*requests))
	}
}

func TestParseAllowlist(t *testing.T) {
	got, err := ParseAllowlist("Alice@Example.com, example.org\n@example.net;alice@example.com")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"alice@example.com", "@example.org", "@example.net"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("got %v", got)
	}
	for _, bad := range []string{"alice", "@", "alice@", "a@b@example.com", "@localhost", "%' OR 1=1"} {
		if _, err := ParseAllowlist(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	if got, _ := ParseAllowlist(" \n "); len(got) != 0 {
		t.Errorf("empty list: %v", got)
	}
}

func TestParseMode(t *testing.T) {
	for _, m := range []string{"open", "Allowlist", " closed "} {
		if _, err := ParseMode(m); err != nil {
			t.Error(err)
		}
	}
	if _, err := ParseMode("invite"); err == nil {
		t.Error("accepted invite")
	}
}

func testApp() *App {
	return &App{auth: &authConfig{password: &testPassword}, sessions: map[string]*session{}}
}

func post(h http.Handler, path string, form url.Values, cookie *http.Cookie, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "https://admin.example.com"+path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

func TestLogin(t *testing.T) {
	app := testApp()
	h := app.routes()
	w := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil)
	cookies := w.Result().Cookies()
	if w.Code != http.StatusSeeOther || len(cookies) != 1 {
		t.Fatalf("login failed: %d", w.Code)
	}
	c := cookies[0]
	if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode {
		t.Errorf("cookie flags: %+v", c)
	}
	var s *session
	for _, s = range app.sessions {
	}

	// form posts need the CSRF token of the session, and the same origin
	logout := func(form url.Values, headers map[string]string) int {
		return post(h, "/logout", form, c, headers).Code
	}
	if code := logout(url.Values{}, nil); code != http.StatusForbidden {
		t.Errorf("no CSRF token: %d", code)
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, map[string]string{"Origin": "https://evil.example"}); code != http.StatusForbidden {
		t.Errorf("cross origin: %d", code)
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, map[string]string{"Sec-Fetch-Site": "cross-site"}); code != http.StatusForbidden {
		t.Errorf("cross site: %d", code)
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, map[string]string{"Origin": "https://admin.example.com"}); code != http.StatusSeeOther {
		t.Errorf("logout: %d", code)
	}
	if len(app.sessions) != 0 {
		t.Error("session kept after logout")
	}
	if code := logout(url.Values{"csrf": {s.csrf}}, nil); code != http.StatusUnauthorized {
		t.Errorf("after logout: %d", code)
	}
}

func TestLoginThrottle(t *testing.T) {
	app := testApp()
	h := app.routes()
	for i := 0; i < loginFailuresPerMinute; i++ {
		if w := post(h, "/login", url.Values{"password": {"guess"}}, nil, nil); len(w.Result().Cookies()) != 0 {
			t.Fatal("wrong password accepted")
		}
	}
	// even the right password waits once the failures add up
	if w := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil); w.Code != http.StatusTooManyRequests {
		t.Errorf("status %d", w.Code)
	}
}

func TestDashboardNeedsLogin(t *testing.T) {
	h := testApp().routes()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/login" {
		t.Errorf("status %d %s", w.Code, w.Header().Get("Location"))
	}
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Error("no CSP")
	}
}

func TestRedisRevoke(t *testing.T) {
	// a fake Redis that records the command and answers like EVAL
	server, client := net.Pipe()
	defer client.Close()
	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := server.Read(buf)
		got <- string(buf[:n])
		server.Write([]byte(":2\r\n"))
		server.Close()
	}()
	reply, err := redisCommand(client, "EVAL", revokeScript, "2", "at:abc", "fxa-auth-sessionabc")
	if err != nil || reply != int64(2) {
		t.Fatalf("reply %v, %v", reply, err)
	}
	if cmd := <-got; !strings.HasPrefix(cmd, "*5\r\n$4\r\nEVAL\r\n") || !strings.Contains(cmd, "$6\r\nat:abc\r\n") {
		t.Errorf("command %q", cmd)
	}
	for in, want := range map[string]any{"+OK\r\n": "OK", "$3\r\nabc\r\n": "abc", "*2\r\n:1\r\n$1\r\nx\r\n": []any{int64(1), "x"}} {
		v, err := readReply(bufio.NewReader(strings.NewReader(in)))
		if err != nil || fmt.Sprint(v) != fmt.Sprint(want) {
			t.Errorf("%q: %v %v", in, v, err)
		}
	}
	if _, err := readReply(bufio.NewReader(strings.NewReader("-ERR nope\r\n"))); err == nil {
		t.Error("error reply accepted")
	}
}

func TestStatsd(t *testing.T) {
	r := &Recorder{current: map[string]*metric{}}
	r.parseStatsd("syncstorage.request.get_collections:1|c|#tokenserver_origin:rust\n" +
		"syncstorage.request.get_collections:2|c|@0.5\n" +
		"syncstorage.token_creation:12|ms|#token_type:OAuth\nsyncstorage.token_creation:8|ms\n" +
		"bad name:1|c\nnovalue|c\nsyncstorage.x:abc|c\nsyncstorage.gauge:3|g")
	if m := r.current["syncstorage.request.get_collections"]; m == nil || m.count != 5 {
		t.Errorf("counter %+v", m)
	}
	if m := r.current["syncstorage.token_creation"]; m == nil || m.count != 2 || m.total != 20 {
		t.Errorf("timer %+v", m)
	}
	if len(r.current) != 3 {
		t.Errorf("kept %v", r.current)
	}
	// a sender cannot make it keep unlimited names
	for i := 0; i < 2*maxMetricNames; i++ {
		r.parseStatsd(fmt.Sprintf("flood.%d:1|c", i))
	}
	if len(r.current) != maxMetricNames {
		t.Errorf("%d names", len(r.current))
	}
}

func TestBarChart(t *testing.T) {
	svg := string(barChart([]int64{0, 5, 10}))
	if !strings.HasPrefix(svg, "<svg") || strings.Count(svg, "<rect") != 3 || !strings.Contains(svg, `height="78.0"`) {
		t.Errorf("%s", svg)
	}
	if humanBytes(1536) != "1.5 KB" || humanBytes(10) != "10 B" {
		t.Error(humanBytes(1536))
	}
}

func TestParseRateLimitKey(t *testing.T) {
	kind, on, value, action, max, window, ok := parseRateLimitKey("rate-limit:block:ip_email=172.18.0.16_invited@example.net:accountLogin:5-900-900")
	if !ok || kind != "block" || on != "ip_email" || value != "172.18.0.16_invited@example.net" || action != "accountLogin" || max != 5 || window.Seconds() != 900 {
		t.Errorf("%v %v %v %v %v %v", kind, on, value, action, max, window)
	}
	_, on, value, action, _, _, ok = parseRateLimitKey("rate-limit:attempts:ip=2001:db8::1:accountLogin:100-86400-900")
	if !ok || on != "ip" || value != "2001:db8::1" || action != "accountLogin" {
		t.Errorf("IPv6: %v %v %v", on, value, action)
	}
	for _, bad := range []string{"at:abc", "rate-limit:block:nothing", "rate-limit:block:ip=1:accountLogin:5-900"} {
		if _, _, _, _, _, _, ok := parseRateLimitKey(bad); ok {
			t.Errorf("accepted %q", bad)
		}
	}
	// only blocks can be lifted: Unblock refuses anything else before touching Redis
	if err := (&FxaDB{}).Unblock(context.Background(), "fxa-auth-session123"); err == nil {
		t.Error("unblocked a non-block key")
	}
}

func TestNewerVersion(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"0.23.4", "0.23.3", true}, {"0.23.3", "0.23.3", false}, {"v1.348.0", "v1.347.1", true}, {"0.24.0", "0.23.10", true}, {"0.23.3", "0.24.0", false}, {"latest", "0.23.3", false}} {
		if got := newerVersion(c.a, c.b); got != c.want {
			t.Errorf("newerVersion(%q, %q) = %v", c.a, c.b, got)
		}
	}
	if senderAddress(`"Mozilla accounts" <no-reply@example.com>`) != "no-reply@example.com" || senderAddress("a@b.c") != "a@b.c" {
		t.Error("senderAddress")
	}
}

func TestPrometheusNeedsToken(t *testing.T) {
	h := testApp().routes()
	for _, auth := range []string{"", "Bearer wrong"} {
		req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != http.StatusNotFound {
			t.Errorf("%q: %d", auth, w.Code)
		}
	}
}

func TestMaxUsersFitsTheTriggers(t *testing.T) {
	app := testApp()
	app.maxUsersEditable = true
	h := app.routes()
	c := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil).Result().Cookies()[0]
	var s *session
	for _, s = range app.sessions {
	}
	// refused before the database (there is none here)
	for _, n := range []string{"-1", "2147483648", "3000000000", "lots"} {
		if w := post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {n}}, c, nil); w.Code != http.StatusSeeOther {
			t.Fatalf("%s: status %d", n, w.Code)
		}
		if !strings.Contains(s.failed, "from 0 to 2147483647") {
			t.Errorf("%s: %q", n, s.failed)
		}
	}
	if err := (&SyncDB{}).SetMaxUsers(context.Background(), 1<<31); err == nil {
		t.Error("SetMaxUsers accepted 2^31")
	}
}

func TestMaxUsersEditable(t *testing.T) {
	for v, want := range map[string]bool{
		"initial:5": true, " initial:5 ": true, "initial:0": true,
		// set again by the init container on every start
		"5": false, "fixed:5": false,
		// not given: read-only, the safe side
		"": false,
		// the init container refuses these
		"lots": false, "Initial:5": false, "-1": false,
	} {
		if got := maxUsersEditable(v); got != want {
			t.Errorf("%q: %v", v, got)
		}
	}
}

func TestMaxUsersReadOnly(t *testing.T) {
	app := testApp() // MAX_USERS not initial:N
	h := app.routes()
	c := post(h, "/login", url.Values{"password": {"correct horse battery"}}, nil, nil).Result().Cookies()[0]
	var s *session
	for _, s = range app.sessions {
	}
	// refused before the database: there is none here, SetMaxUsers would panic
	w := post(h, "/sync/max-users", url.Values{"csrf": {s.csrf}, "max_users": {"5"}}, c, nil)
	if w.Code != http.StatusSeeOther || !strings.Contains(s.failed, "managed by MAX_USERS in .env") || s.message != "" {
		t.Errorf("status %d, failed %q, message %q", w.Code, s.failed, s.message)
	}

	render := func(editable bool) string {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "Sync": &SyncStatus{Users: 1, MaxUsers: 5}, "MaxUsersEditable": editable}
		if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
			t.Fatal(err)
		}
		return b.String()
	}
	page := render(false)
	for _, want := range []string{`value="5" required disabled>`, `<button type="submit" disabled>Save</button>`, "managed by MAX_USERS in .env; set MAX_USERS=initial:5 to manage it here"} {
		if !strings.Contains(page, want) {
			t.Errorf("read-only page without %q", want)
		}
	}
	page = render(true)
	if strings.Contains(page, "disabled>") || strings.Contains(page, "set MAX_USERS=initial:5") {
		t.Error("editable page has a disabled form")
	}
}

func TestServeChecksIntervals(t *testing.T) {
	t.Setenv("ADMIN_PASSWORD", "correct horse battery")
	for _, name := range []string{"HEALTH_CHECK_SECONDS", "METRICS_FLUSH_SECONDS", "ALERT_INTERVAL_SECONDS"} {
		t.Setenv(name, "0")
		// before any database: a ticker of 0 panics in the background
		if err := serve(context.Background()); err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("%s=0: %v", name, err)
		}
		t.Setenv(name, "5")
	}
}
