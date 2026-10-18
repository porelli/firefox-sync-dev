package main

import (
	"database/sql"
	"strings"
	"testing"
	"time"
)

// noStackCommands: the commands of compose and the Quadlets, which a Kubernetes install
// has none of
func noStackCommands(t *testing.T, what, text string) {
	t.Helper()
	for _, bad := range []string{"docker compose", "systemctl", "COMPOSE_PROFILES", "prepare_environment.sh", "Quadlets"} {
		if strings.Contains(text, bad) {
			t.Errorf("%s: %q with ADMIN_DEPLOYMENT=kubernetes: %s", what, bad, text)
		}
	}
}

func TestDeploymentKubernetesCommands(t *testing.T) {
	// the chart's names as it passes them: fullnameOverride=sync, existingSecret=my-secret
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_NAMESPACE", "ffs")
	t.Setenv("ADMIN_K8S_FULLNAME", "sync")
	t.Setenv("ADMIN_K8S_SECRET", "my-secret")
	d, err := loadDeployment()
	if err != nil {
		t.Fatal(err)
	}

	// the backups card of the overview, and its help
	var b strings.Builder
	data := map[string]any{"CSRF": "x", "Health": []Component{{Name: "Sync server", Up: true}},
		"Backup": map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": d.Quadlets(), "Kubernetes": d.Kubernetes()}}
	if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
		t.Fatal(err)
	}
	page := b.String()
	card := page[strings.Index(page, `id="backups-card"`):]
	card = card[:strings.Index(card, "</section>")]
	// (a new Job name for every run; html/template writes + as &#43;)
	if got := d.BackupNow(); got != "kubectl -n ffs create job --from=cronjob/sync-backup backup-now-$(date +%s)" {
		t.Errorf("BackupNow: %s", got)
	}
	for _, want := range []string{"<code>kubectl -n ffs create job --from=cronjob/sync-backup backup-now-$(date &#43;%s)</code>",
		"--set backup.enabled=true", "<code>sync-backups</code>", "the Secret <code>my-secret</code>"} {
		if !strings.Contains(card, want) {
			t.Errorf("backups card: no %q", want)
		}
	}
	noStackCommands(t, "backups card", card)

	// the setup checks and the alerts of the overview
	if c := nodeCheck(d, "https://sync.example.com", nil); !strings.Contains(c.Text, "kubectl -n ffs rollout restart deployment/sync-syncstorage") {
		t.Errorf("node check: %s", c.Text)
	} else {
		noStackCommands(t, "node check", c.Text)
	}
	c := ownDBCheck(&SyncDB{db: sql.OpenDB(&fakeFxa{})}, moveState{}, d)
	if !strings.Contains(c.Text, "ADMIN_DB_PASSWORD") || !strings.Contains(c.Text, "helm upgrade t ") {
		t.Errorf("own database check: %s", c.Text)
	}
	noStackCommands(t, "own database check", c.Text)
	noStackCommands(t, "the log line", ownDBHint(d))
	if c := ownDBCheck(&SyncDB{own: sql.OpenDB(&fakeFxa{}), ownName: "ffs_admin", postgres: true}, moveState{Superuser: "syncserver"}, d); !strings.Contains(c.Text, "DATABASES.md") {
		t.Errorf("superuser check: %s", c.Text)
	} else {
		noStackCommands(t, "superuser check", c.Text)
	}
	if got := d.restartSync(); !strings.Contains(got, "kubectl -n ffs rollout restart deployment/sync-syncstorage") {
		t.Errorf("restart: %s", got)
	}
	h := &Health{app: &App{deployment: d}}
	noStackCommands(t, "the metrics alert", h.deployment().restartSync())

	// the activity page, the sign-in page
	for name, data := range map[string]map[string]any{
		"activity.html": {"CSRF": "x", "Range": "24h", "Ranges": []string{"24h"}, "Kinds": eventKinds, "Received": time.Time{}, "Kubernetes": d.Kubernetes()},
		"login.html":    {"Password": true, "Kubernetes": d.Kubernetes()},
	} {
		var b strings.Builder
		if err := templates.ExecuteTemplate(&b, name, data); err != nil {
			t.Fatal(err)
		}
		noStackCommands(t, name, b.String())
		if name == "login.html" && !strings.Contains(b.String(), "kubectl -n ffs get secret my-secret") {
			t.Errorf("login: where the password is: %s", b.String())
		}
		if name == "activity.html" && !strings.Contains(b.String(), "rollout restart deployment/sync-syncstorage") {
			t.Errorf("activity: how to restart the Sync server")
		}
	}

	// the configuration page, with the chart's bundled MariaDB
	t.Setenv("TOKENSERVER_DB_HOST", "sync-tokenserver-db")
	page = configPage(t, false, func(app *App, _ *fakeFxa) { app.deployment = d })
	if got := configRowOf(page, "Runs with"); !strings.Contains(got, "Kubernetes") || !strings.Contains(got, "Helm release t") {
		t.Errorf("runs with: %q", got)
	}
	if got := configRowOf(page, "Published on"); !strings.Contains(got, "sync-admin") {
		t.Errorf("published on: %q", got)
	}
	if got := configRowOf(page, "Last runs"); !strings.Contains(got, "backup.enabled") {
		t.Errorf("backups: %q", got)
	}
	if got := configRowOf(page, "Databases"); !strings.Contains(got, "a container of the stack") {
		t.Errorf("the bundled databases: %q", got)
	}
	noStackCommands(t, "configuration page", page)
}

func TestDeploymentFromEnv(t *testing.T) {
	for _, c := range []struct {
		kind, release, fullname, secret string
		ok, quadlets, kubernetes        bool
	}{
		{kind: "", ok: true}, {kind: "compose", ok: true}, {kind: "quadlets", ok: true, quadlets: true},
		{kind: "kubernetes", release: "t", fullname: "t-firefox-sync", secret: "t-firefox-sync", ok: true, kubernetes: true},
		// the names come from the chart, never derived from the release
		{kind: "kubernetes", release: "t", fullname: "x", secret: "mine", ok: true, kubernetes: true},
		{kind: "kubernetes"}, {kind: "kubernetes", release: "t"}, {kind: "kubernetes", release: "t", fullname: "x"},
		{kind: "Compose"}, {kind: "k8s", release: "t", fullname: "x", secret: "y"},
	} {
		t.Setenv("ADMIN_DEPLOYMENT", c.kind)
		t.Setenv("ADMIN_K8S_RELEASE", c.release)
		t.Setenv("ADMIN_K8S_NAMESPACE", "")
		t.Setenv("ADMIN_K8S_FULLNAME", c.fullname)
		t.Setenv("ADMIN_K8S_SECRET", c.secret)
		d, err := loadDeployment()
		if (err == nil) != c.ok {
			t.Errorf("%+v: %v", c, err)
			continue
		}
		if err != nil {
			continue
		}
		if d.Quadlets() != c.quadlets || d.Kubernetes() != nil != c.kubernetes {
			t.Errorf("%+v: %+v", c, d)
		}
		if c.kubernetes && (d.fullname() != c.fullname || d.Secret() != c.secret) {
			t.Errorf("%+v: fullname %q, secret %q", c, d.fullname(), d.Secret())
		}
	}
	// without a namespace: kubectl's own
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_FULLNAME", "t-firefox-sync")
	t.Setenv("ADMIN_K8S_SECRET", "t-firefox-sync")
	if d, _ := loadDeployment(); d.restartSync() != "restart it (kubectl rollout restart deployment/t-firefox-sync-syncstorage)" {
		t.Errorf("no namespace: %q", d.restartSync())
	}
	// the bundled databases by the chart's prefix, not your own server of a similar name
	d := deployment{kind: "kubernetes", release: "t", prefix: "sync", secret: "s"}
	if !d.stackHost("sync-tokenserver-db") || !d.stackHost("sync-postgres") || d.stackHost("t-firefox-sync-tokenserver-db") || d.stackHost("tokenserver_db") {
		t.Error("stack hosts of the chart")
	}
}

// no .env with the Helm chart: the values of the chart instead
func TestDeploymentKubernetesNoDotEnv(t *testing.T) {
	d := deployment{kind: "kubernetes", release: "t", namespace: "ffs", prefix: "t-firefox-sync", secret: "t-firefox-sync"}
	for _, editable := range []bool{true, false} {
		var b strings.Builder
		data := map[string]any{"CSRF": "x", "Health": []Component{{Name: "Sync server", Up: true}}, "MaxUsersEditable": editable,
			"Sync":       &SyncStatus{Users: 1, MaxUsers: 5, Nodes: []SyncNode{{Node: "https://sync.example.com", Users: 1}}},
			"Backup":     map[string]any{"Time": "03:00", "Local": "03:00", "Keep": 7, "Quadlets": false, "Kubernetes": d.Kubernetes()},
			"Kubernetes": d.Kubernetes()}
		if err := templates.ExecuteTemplate(&b, "dashboard.html", data); err != nil {
			t.Fatal(err)
		}
		page := b.String()
		if strings.Contains(page, ".env") {
			i := strings.Index(page, ".env")
			t.Errorf("dashboard (max users editable %v): .env: %s", editable, page[max(0, i-200):i+10])
		}
		for _, want := range []string{"<code>admin.alertEmail</code>", "<code>maxUsers"} {
			if !strings.Contains(page, want) {
				t.Errorf("dashboard (max users editable %v): no %q", editable, want)
			}
		}
	}
	if got := d.checkOAuth(); strings.Contains(got, ".env") || !strings.Contains(got, "fxa.oauthServerUrl") {
		t.Errorf("sign-in keys check: %s", got)
	}
	app := &App{deployment: d}
	if err := app.maxUsersReadOnly(); strings.Contains(err.Error(), ".env") || !strings.Contains(err.Error(), "maxUsers") {
		t.Errorf("max users read-only: %v", err)
	}
	// compose's as before
	if err := (&App{}).maxUsersReadOnly(); !strings.Contains(err.Error(), "MAX_USERS in .env") {
		t.Errorf("compose: %v", err)
	}
}

// the chart's address in the helm commands: the one the chart passes (ADMIN_K8S_CHART, where
// it was published), else the public repository's, never another repository's; in the
// release's chart version (ADMIN_K8S_CHART_VERSION): --reuse-values never moves to another one
func TestDeploymentChartAddress(t *testing.T) {
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_NAMESPACE", "ffs")
	t.Setenv("ADMIN_K8S_FULLNAME", "t-firefox-sync")
	t.Setenv("ADMIN_K8S_SECRET", "t-firefox-sync")
	for _, c := range []struct{ env, version, want string }{
		{"", "", "helm upgrade t oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync -n ffs --reuse-values --set backup.enabled=true"},
		{"", "0.1.0", "helm upgrade t oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync --version 0.1.0 -n ffs --reuse-values --set backup.enabled=true"},
		{"oci://ghcr.io/porelli/firefox-sync-dev/charts/firefox-sync", "0.1.0-dev.1",
			"helm upgrade t oci://ghcr.io/porelli/firefox-sync-dev/charts/firefox-sync --version 0.1.0-dev.1 -n ffs --reuse-values --set backup.enabled=true"},
	} {
		t.Setenv("ADMIN_K8S_CHART", c.env)
		t.Setenv("ADMIN_K8S_CHART_VERSION", c.version)
		d, err := loadDeployment()
		if err != nil {
			t.Fatal(err)
		}
		if got := d.BackupsOn(); got != c.want {
			t.Errorf("ADMIN_K8S_CHART=%q ADMIN_K8S_CHART_VERSION=%q: %s", c.env, c.version, got)
		}
	}
}

// the old names of .env: no setup check with the Helm chart (no .env there), also if
// FFS_OLD_ENV_NAMES came from somewhere
func TestDeploymentKubernetesNoOldNamesCheck(t *testing.T) {
	t.Setenv("FFS_OLD_ENV_NAMES", "MAX_USERS SYNCSTORAGE_DOMAIN")
	k8s := &App{deployment: deployment{kind: "kubernetes", release: "t", prefix: "t-firefox-sync", secret: "t-firefox-sync"}}
	for _, c := range k8s.setupChecks(t.Context(), nil, nil) {
		if strings.Contains(c.Name, "Old setting names") {
			t.Errorf("kubernetes: %+v", c)
		}
	}
	found := false
	for _, c := range (&App{}).setupChecks(t.Context(), nil, nil) {
		found = found || strings.Contains(c.Name, "Old setting names")
	}
	if !found {
		t.Error("compose: no check of the old names")
	}
	// the node check names the chart's value
	if c := nodeCheck(k8s.deployment, "https://sync.example.com", nil); !strings.Contains(c.Text, "syncDomain is https://sync.example.com") || strings.Contains(c.Text, "SYNC_PUBLIC_URL") {
		t.Errorf("node check, kubernetes: %s", c.Text)
	}
}
