package main

import (
	"errors"
	"fmt"
	"strings"
)

// deployment: how the stack runs (ADMIN_DEPLOYMENT), for the commands the pages show:
// compose (the default), quadlets, or kubernetes, the Helm chart, which also passes its
// release (ADMIN_K8S_RELEASE) and namespace (ADMIN_K8S_NAMESPACE). The admin UI names the
// chart's objects from the release as the chart does (firefox-sync.fullname)
type deployment struct {
	// compose, quadlets or kubernetes ("": compose)
	kind string
	// kubernetes: the Helm release and its namespace ("": kubectl's current one)
	release, namespace string
}

// loadDeployment reads ADMIN_DEPLOYMENT: an unknown one stops the start, rather than
// showing the commands of another stack
func loadDeployment() (deployment, error) {
	d := deployment{kind: env("ADMIN_DEPLOYMENT", "compose")}
	switch d.kind {
	case "compose", "quadlets":
	case "kubernetes":
		d.release, d.namespace = env("ADMIN_K8S_RELEASE", ""), env("ADMIN_K8S_NAMESPACE", "")
		if d.release == "" {
			return d, errors.New("ADMIN_DEPLOYMENT=kubernetes needs ADMIN_K8S_RELEASE, the Helm release (the chart sets it)")
		}
	default:
		return d, fmt.Errorf("ADMIN_DEPLOYMENT must be compose, quadlets or kubernetes, not %q", d.kind)
	}
	return d, nil
}

// Quadlets: the Podman Quadlets
func (d deployment) Quadlets() bool { return d.kind == "quadlets" }

// Kubernetes: the deployment with the Helm chart, nil otherwise (for {{with}} in the
// templates)
func (d deployment) Kubernetes() *deployment {
	if d.kind != "kubernetes" {
		return nil
	}
	return &d
}

// fullname: the prefix of the chart's objects, as its firefox-sync.fullname helper makes
// it from the release (no fullnameOverride)
func (d deployment) fullname() string {
	name := d.release
	if !strings.Contains(name, "firefox-sync") {
		name += "-firefox-sync"
	}
	if len(name) > 63 {
		name = name[:63]
	}
	return strings.TrimSuffix(name, "-")
}

// Release: the Helm release
func (d deployment) Release() string { return d.release }

// Kubectl: kubectl in the release's namespace
func (d deployment) Kubectl() string {
	if d.namespace == "" {
		return "kubectl"
	}
	return "kubectl -n " + d.namespace
}

// helmUpgrade: helm upgrade of the release with the values it has, plus those given
func (d deployment) helmUpgrade(set string) string {
	ns := ""
	if d.namespace != "" {
		ns = " -n " + d.namespace
	}
	return strings.TrimSpace("helm upgrade " + d.release + " oci://ghcr.io/porelli/charts/firefox-sync" + ns + " --reuse-values " + set)
}

// the chart's objects
func (d deployment) Secret() string         { return d.fullname() }
func (d deployment) BackupVolume() string   { return d.fullname() + "-backups" }
func (d deployment) AdminService() string   { return d.fullname() + "-admin" }
func (d deployment) syncDeployment() string { return "deployment/" + d.fullname() + "-syncstorage" }

// BackupNow: a run of the backup CronJob now
func (d deployment) BackupNow() string {
	return d.Kubectl() + " create job --from=cronjob/" + d.fullname() + "-backup backup-now"
}

// BackupsOn: the chart's backup CronJob turned on
func (d deployment) BackupsOn() string { return d.helmUpgrade("--set backup.enabled=true") }

// RestartSync: a new pod of the Sync server (its init containers first)
func (d deployment) RestartSync() string {
	return d.Kubectl() + " rollout restart " + d.syncDeployment()
}

// restartSync: how to restart the Sync server, for the missing metrics
func (d deployment) restartSync() string {
	if d.Kubernetes() != nil {
		return "restart it (" + d.RestartSync() + ")"
	}
	return "restart it (docker compose restart syncstorage, or systemctl --user restart firefox-sync-syncstorage.service)"
}

// startInit: how the init container runs again (it sets the Sync node)
func (d deployment) startInit() string {
	if d.Kubernetes() != nil {
		return d.RestartSync()
	}
	return "docker compose up -d (or restart the Quadlets)"
}

// name: what the configuration page says it runs with
func (d deployment) name() string {
	switch d.kind {
	case "quadlets":
		return "Podman Quadlets"
	case "kubernetes":
		name := "Kubernetes, Helm release " + d.release
		if d.namespace != "" {
			name += " in the namespace " + d.namespace
		}
		return name
	}
	return "docker compose"
}

// stackHost: a database of the stack, not your own server: the containers of compose and
// the Quadlets, the bundled databases of the chart
func (d deployment) stackHost(host string) bool {
	if d.Kubernetes() != nil {
		full := d.fullname()
		return host == full+"-tokenserver-db" || host == full+"-storage-db" || host == full+"-postgres"
	}
	return stackHosts[host]
}
