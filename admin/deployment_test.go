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
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_NAMESPACE", "ffs")
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
	for _, want := range []string{"<code>kubectl -n ffs create job --from=cronjob/t-firefox-sync-backup backup-now</code>",
		"--set backup.enabled=true", "<code>t-firefox-sync-backups</code>", "the Secret <code>t-firefox-sync</code>"} {
		if !strings.Contains(card, want) {
			t.Errorf("backups card: no %q", want)
		}
	}
	noStackCommands(t, "backups card", card)

	// the setup checks and the alerts of the overview
	if c := nodeCheck(d, "https://sync.example.com", nil); !strings.Contains(c.Text, "kubectl -n ffs rollout restart deployment/t-firefox-sync-syncstorage") {
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
	if got := d.restartSync(); !strings.Contains(got, "kubectl -n ffs rollout restart deployment/t-firefox-sync-syncstorage") {
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
		if name == "login.html" && !strings.Contains(b.String(), "kubectl -n ffs get secret t-firefox-sync") {
			t.Errorf("login: where the password is: %s", b.String())
		}
		if name == "activity.html" && !strings.Contains(b.String(), "rollout restart deployment/t-firefox-sync-syncstorage") {
			t.Errorf("activity: how to restart the Sync server")
		}
	}

	// the configuration page, with the chart's bundled MariaDB
	t.Setenv("TOKENSERVER_DB_HOST", "t-firefox-sync-tokenserver-db")
	page = configPage(t, false, func(app *App, _ *fakeFxa) { app.deployment = d })
	if got := configRowOf(page, "Runs with"); !strings.Contains(got, "Kubernetes") || !strings.Contains(got, "Helm release t") {
		t.Errorf("runs with: %q", got)
	}
	if got := configRowOf(page, "Published on"); !strings.Contains(got, "t-firefox-sync-admin") {
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
		kind, release, namespace string
		ok, quadlets, kubernetes bool
		fullname                 string
	}{
		{kind: "", ok: true}, {kind: "compose", ok: true}, {kind: "quadlets", ok: true, quadlets: true},
		{kind: "kubernetes", release: "t", ok: true, kubernetes: true, fullname: "t-firefox-sync"},
		// the chart's fullname: the release when it says firefox-sync already
		{kind: "kubernetes", release: "my-firefox-sync", namespace: "x", ok: true, kubernetes: true, fullname: "my-firefox-sync"},
		{kind: "kubernetes"}, {kind: "Compose"}, {kind: "k8s", release: "t"},
	} {
		t.Setenv("ADMIN_DEPLOYMENT", c.kind)
		t.Setenv("ADMIN_K8S_RELEASE", c.release)
		t.Setenv("ADMIN_K8S_NAMESPACE", c.namespace)
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
		if c.kubernetes && d.fullname() != c.fullname {
			t.Errorf("%+v: fullname %q", c, d.fullname())
		}
	}
	// without a namespace: kubectl's own
	t.Setenv("ADMIN_DEPLOYMENT", "kubernetes")
	t.Setenv("ADMIN_K8S_RELEASE", "t")
	t.Setenv("ADMIN_K8S_NAMESPACE", "")
	if d, _ := loadDeployment(); d.restartSync() != "restart it (kubectl rollout restart deployment/t-firefox-sync-syncstorage)" {
		t.Errorf("no namespace: %q", d.restartSync())
	}
}
