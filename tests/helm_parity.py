#!/usr/bin/env python3
"""The chart against compose: per pair (compose service -> chart container) the same env
variable names, the same values (but the hosts, compose's service names against the chart's
<fullname>-..., and the secrets, which must come from the Secret where compose has a secret
of .env), the same command, and probes that check what compose's healthcheck checks with its
timings. The scripts the chart copies are byte-identical to compose's.

  helm_parity.py [case...]   cases: see CASES (default: all), each with the admin UI and
                             the backups on and off

Needs docker compose (config only: no daemon) and helm. The test .env is .env-example as
tests/e2e.sh writes it: its placeholders filled, a few values per case.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

import yaml

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)
CHART = os.path.join(REPO, "charts", "firefox-sync")
RELEASE = "test-release"
FULLNAME = f"{RELEASE}-firefox-sync"
DOMAIN = "example.test"
EXTDB = "extdb.example.test"

# chart-only, compose-only or different, by design: "<chart container>/<VAR>" (or /command,
# /<probe>) -> why. Every entry must be used by some case (a stale one fails)
ALLOWED_DIFFERENCES = {
    # admin UI
    "admin/ADMIN_DEPLOYMENT": "the commands the admin UI shows: kubectl and helm (kubernetes), not docker compose (compose)",
    "admin/ADMIN_K8S_RELEASE": "chart-only: the release name for the helm commands the admin UI shows",
    "admin/ADMIN_K8S_NAMESPACE": "chart-only: the namespace for the kubectl commands the admin UI shows",
    "admin/ADMIN_K8S_FULLNAME": "chart-only: the chart's object names (fullnameOverride), which the admin UI builds from it",
    "admin/ADMIN_K8S_SECRET": "chart-only: the Secret's name (existingSecret) for the commands the admin UI shows",
    "admin/ADMIN_EXPORT_PORT": "compose-only: the host port compose publishes the admin UI on; the chart has a Service (and an Ingress)",
    # the Sync server
    "syncstorage/SYNC_STATSD_HOST": "chart-only as a variable: compose exports it in syncstorage's entrypoint when ffs-admin resolves; "
    "the chart sets it while the admin UI is on (its value is still compared with the export)",
    "syncstorage/SYNC_STATSD_PORT": "as SYNC_STATSD_HOST",
    "syncstorage/command": "compose's entrypoint script only adds SYNC_STATSD_* (env here) before exec /app/bin/syncserver",
    "syncstorage/readinessProbe": "compose's healthcheck is the livenessProbe; ready sooner (every 10 s, 3 failures) "
    "so that the Service gets it at once",
    # the chart passes the passwords as their own variables (from the Secret) and builds the
    # database URLs with $(VAR): compose interpolates them into the URLs
    "migrate/STORAGE_DB_PASSWORD": "chart-only: the password of SYNC_SYNCSTORAGE__DATABASE_URL, $(STORAGE_DB_PASSWORD) there",
    "migrate/TOKENSERVER_DB_PASSWORD": "chart-only: the password of SYNC_TOKENSERVER__DATABASE_URL, $(TOKENSERVER_DB_PASSWORD) there",
    "migrate/POSTGRES_SYNC_PASSWORD": "chart-only: the password of the database URLs, $(POSTGRES_SYNC_PASSWORD) there",
    "migrate/POSTGRES_PASSWORD": "chart-only: the password of the database URLs with your own server (no Sync role), $(POSTGRES_PASSWORD) there",
    "syncstorage/STORAGE_DB_PASSWORD": "as migrate's",
    "syncstorage/TOKENSERVER_DB_PASSWORD": "as migrate's",
    "syncstorage/POSTGRES_SYNC_PASSWORD": "as migrate's",
    "syncstorage/POSTGRES_PASSWORD": "as migrate's",
    # the backups: a CronJob, not compose's loop
    "backup/command": "a CronJob runs backup.sh now at backup.schedule; compose's container runs backup.sh loop",
    "backup/MARIADB_TLS_VERIFY": "bundled MySQL: false (the chart's one value, the init container's) where compose's backup "
    "inherits true; no effect: the backup image is mysql:8.4, backup.sh reads it with the MariaDB client only",
    # the databases
    "db/MARIADB_RANDOM_ROOT_PASSWORD": "compose-only with MySQL: docker-compose.sync-mysql.yml keeps docker-compose.yml's MARIADB_*, "
    "the MySQL image ignores them",
    "db/MARIADB_DATABASE": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "db/MARIADB_USER": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "db/MARIADB_PASSWORD": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "db/MARIADB_AUTO_UPGRADE": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "db/startupProbe": "the first start (a new database, a long recovery) gets up to 30 minutes; compose's start_period "
    "only delays counting the failures",
    "db/livenessProbe": "restarted only after 5 minutes without an answer (every 30 s, 10 failures): compose never restarts "
    "an unhealthy database, and a restart in the middle of a recovery starts it over; readiness is compose's healthcheck",
    "admin/startupProbe": "the first start moves the tables of an older install: up to 10 minutes",
    "admin/readinessProbe": "compose's healthcheck is the livenessProbe; ready sooner (every 10 s) for the Service",
}

# containers of the chart that compose has no service for
CHART_ONLY_CONTAINERS = {
    "wait-db": "compose's depends_on service_healthy: waits for the database servers to answer, no credentials, no env",
    "bind": "binds the backups PVC at install (WaitForFirstConsumer storage classes), compose's volume needs nothing",
    "wait-sync": "compose's ffs-admin depends_on tokenserver_db_init: the admin UI starts once the Sync server serves "
    "(its init containers succeeded), no env",
}

# compose healthchecks the chart does as HTTP probes: the image has no shell
EQUIVALENT_CHECKS = {
    ("exec", "/ffs-admin", "healthcheck"): (
        ("http", "8080", "/healthz"),
        "admin/main.go: /ffs-admin healthcheck GETs http://127.0.0.1:<ADMIN_LISTEN, :8080>/healthz",
    ),
}

# compose's scripts the chart carries a copy of
IDENTICAL_FILES = {
    "charts/firefox-sync/files/backup.sh": "config/backup/backup.sh",
    "charts/firefox-sync/files/admin-user.sh": "db/mysql/admin-user.sh",
}

# compose service -> chart (workload kind, workload name, container, key prefix, init or one-shot)
PAIRS = [
    ("sync_role_init", "Deployment", f"{FULLNAME}-syncstorage", "sync-role", "sync-role", True),
    ("syncstorage_migrate", "Deployment", f"{FULLNAME}-syncstorage", "migrate", "migrate", True),
    ("tokenserver_db_init", "Deployment", f"{FULLNAME}-syncstorage", "db-init", "db-init", True),
    ("syncstorage", "Deployment", f"{FULLNAME}-syncstorage", "syncstorage", "syncstorage", False),
    ("ffs-admin", "Deployment", f"{FULLNAME}-admin", "admin", "admin", False),
    # compose's loop is a CronJob here: no probes to compare
    ("backup", "CronJob", f"{FULLNAME}-backup", "backup", "backup", True),
    ("tokenserver_db", "StatefulSet", f"{FULLNAME}-tokenserver-db", "db", "db", False),
    ("syncstorage_db", "StatefulSet", f"{FULLNAME}-storage-db", "db", "db", False),
    ("postgres_db", "StatefulSet", f"{FULLNAME}-postgres", "db", "db", False),
]

# the hosts: compose's service names, the chart's Services
HOSTS = {
    "tokenserver_db": f"{FULLNAME}-tokenserver-db",
    "syncstorage_db": f"{FULLNAME}-storage-db",
    "postgres_db": f"{FULLNAME}-postgres",
    "syncstorage": f"{FULLNAME}-syncstorage",
    "ffs-admin": f"{FULLNAME}-admin",
    EXTDB: EXTDB,
}

# case -> compose files, .env values, helm values
CASES = {
    "mariadb": (["docker-compose.yml"], {}, ["--set", "database.backend=mariadb"]),
    "mysql": (["docker-compose.yml", "docker-compose.sync-mysql.yml"], {"SYNC_DB": "mysql"}, ["--set", "database.backend=mysql"]),
    "postgres": (["docker-compose.sync-postgres.yml"], {"POSTGRES_SYNC_USER": "syncserver_app"}, ["--set", "database.backend=postgres"]),
    # your own server (DATABASES.md, prepare_environment.sh): no database containers, no TLS
    # check (MySQL's self-signed certificate); PostgreSQL without the Sync role
    "external-mariadb": (["docker-compose.yml"],
                         {"DB_CONTAINERS": "0", "MARIADB_TLS_VERIFY": "false", "MARIADB_TOKENSERVER_SERVER": EXTDB,
                          "MARIADB_SYNCSTORAGE_SERVER": EXTDB},
                         ["--set", "database.backend=mariadb"]),
    "external-mysql": (["docker-compose.yml"],
                       {"SYNC_DB": "mysql", "DB_CONTAINERS": "0", "MARIADB_TLS_VERIFY": "false",
                        "MARIADB_TOKENSERVER_SERVER": EXTDB, "MARIADB_SYNCSTORAGE_SERVER": EXTDB},
                       ["--set", "database.backend=mysql"]),
    "external-postgres": (["docker-compose.sync-postgres.yml"],
                          {"DB_CONTAINERS": "0", "POSTGRES_SERVER": EXTDB, "POSTGRES_SYNC_PASSWORD": ""},
                          ["--set", "database.backend=postgres"]),
}
EXTERNAL_HELM = ["--set", "database.bundled=false", "--set", f"database.external.host={EXTDB}", "--set", "existingSecret=mine"]

SECRET = re.compile(r"s3cr3t(\d+)x")
# a secret in a normalized value: <secret:token number> (compose), <secret:key> (chart)
PLACEHOLDER = re.compile(r"<secret:([^>]*)>")


class Failures(list):
    def add(self, where, what):
        self.append(f"{where}: {what}")


def run(cmd, env=None):
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        sys.exit(f"{' '.join(cmd)} failed:\n{p.stderr}")
    return p.stdout


# --- the test .env: .env-example filled as tests/e2e.sh does it ---------------------------

def set_line(lines, name, value):
    """NAME=value, also under the SYNC_ prefix compose's .env names may get"""
    pattern = re.compile(rf"^(?:SYNC_)?{re.escape(name)}=")
    hits = [i for i, line in enumerate(lines) if pattern.match(line)]
    for i in hits:
        lines[i] = lines[i].split("=", 1)[0] + "=" + value
    if not hits:
        lines.append(f"{name}={value}")


def env_file(overrides, profiles):
    with open(os.path.join(REPO, ".env-example")) as f:
        lines = f.read().splitlines()
    out = []
    n = 0
    for line in lines:
        if re.match(r"^\s*#?\s*COMPOSE_FILE=", line):
            continue
        if re.match(r"^#\s*COMPOSE_PROFILES=", line):
            line = "COMPOSE_PROFILES=" + ",".join(profiles)
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if m:
            name, value = m.groups()
            # every secret of .env, the optional ones too (the chart has them in its Secret):
            # one of its own each, recognizable in the values
            if "<REPLACE_WITH_SOMETHING_SECURE>" in value or (value == "" and re.search(r"(PASS|PASSWORD|SECRET|TOKEN|NOTIFY)$", name)):
                n += 1
                value = value.replace("<REPLACE_WITH_SOMETHING_SECURE>", f"s3cr3t{n}x") if value else f"s3cr3t{n}x"
            # what else is yours (the SMTP server and its sender...): unset, as the chart's
            # defaults (the Sync server's domain below)
            if "<REPLACE_WITH_" in value:
                value = ""
            line = f"{name}={value}"
        out.append(line)
    for name, value in dict(SYNCSTORAGE_DOMAIN=f"https://{DOMAIN}", **overrides).items():
        set_line(out, name, value)
    return "\n".join(out) + "\n"


def compose_config(files, overrides, profiles):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "test.env")
        with open(path, "w") as f:
            f.write(env_file(overrides, profiles))
        # nothing of this shell: .env alone (the shell wins over --env-file)
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONFIG", "XDG_RUNTIME_DIR")}
        cmd = ["docker", "compose", "--project-directory", REPO, "-p", "ffs-parity", "--env-file", path]
        for f_ in files:
            cmd += ["-f", os.path.join(REPO, f_)]
        return json.loads(run(cmd + ["config", "--format", "json"], env=env))["services"]


def helm_template(args):
    out = run(["helm", "template", RELEASE, CHART, "--set", f"syncDomain=https://{DOMAIN}"] + args)
    return [d for d in yaml.safe_load_all(out) if d]


# --- normalization ------------------------------------------------------------------------

def hosts(name, value, names):
    """the hosts of a value (all of it for a host's variable, or of its URLs) as <host:compose service>"""
    if re.search(r"(_HOST|_SERVER)$", name) and value in names:
        return f"<host:{names[value]}>"
    return re.sub(r"(://(?:[^/@\s]*@)?)([A-Za-z0-9_.-]+)",
                  lambda m: m.group(1) + (f"<host:{names[m.group(2)]}>" if m.group(2) in names else m.group(2)), value)


COMPOSE_HOSTS = {k: k for k in HOSTS}
CHART_HOSTS = {v: k for k, v in HOSTS.items()}


def compose_env(service):
    env = {}
    for name, value in (service.get("environment") or {}).items():
        value = "" if value is None else str(value)
        env[name] = SECRET.sub(lambda m: f"<secret:{m.group(1)}>", hosts(name, value, COMPOSE_HOSTS))
    return env


def chart_env(container, where, failures):
    """name -> value, a secretKeyRef as <secret:key>, $(VAR) of an earlier variable expanded
    as Kubernetes does"""
    env = {}
    for e in container.get("env") or []:
        name = e["name"]
        if "value" in e or "valueFrom" not in e:
            value = hosts(name, str(e.get("value", "")), CHART_HOSTS)

            def ref(m):
                if m.group(0) == "$$":
                    return "$$"
                var = m.group(1)
                if var not in env:
                    failures.add(where, f"{name}: $({var}) before {var} is defined (Kubernetes leaves it as it is)")
                    return m.group(0)
                return env[var]
            env[name] = re.sub(r"\$\$|\$\(([A-Za-z_][A-Za-z0-9_]*)\)", ref, value)
        elif "secretKeyRef" in e["valueFrom"]:
            env[name] = f"<secret:{e['valueFrom']['secretKeyRef']['key']}>"
        else:
            env[name] = "<from:" + json.dumps(e["valueFrom"], sort_keys=True) + ">"
    return env


class Secrets:
    """compose's secrets (token numbers) against the chart's (keys of the Secret): one key per
    secret of .env and the other way round"""

    def __init__(self):
        self.key_of, self.token_of = {}, {}

    def same(self, compose, chart, where, failures):
        """compose and chart values equal, but for their secrets, which must pair up"""
        cparts, hparts = PLACEHOLDER.split(compose), PLACEHOLDER.split(chart)
        # literal, secret, literal, secret...
        if len(cparts) != len(hparts) or cparts[0::2] != hparts[0::2]:
            return False
        for token, key in zip(cparts[1::2], hparts[1::2]):
            if self.key_of.setdefault(token, key) != key:
                failures.add(where, f"compose's secret {token} is the Secret's {key} here, {self.key_of[token]} elsewhere")
            if self.token_of.setdefault(key, token) != token:
                failures.add(where, f"the Secret's {key} is compose's secret {token} here, {self.token_of[key]} elsewhere")
        return True


def duration(s):
    if not s:
        return 0
    total = 0.0
    for num, unit in re.findall(r"([\d.]+)(h|ms|m|s|us|ns)", s):
        total += float(num) * {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9}[unit]
    return total


def expand(s, env):
    """${VAR} and $VAR of a shell command, from the container's env"""
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)",
                  lambda m: env.get(m.group(1) or m.group(2), m.group(0)), s)


def check_of_exec(command, env):
    command = list(command)
    if len(command) == 3 and command[0] in ("sh", "/bin/sh") and command[1] == "-c":
        return ("exec",) + tuple(shlex.split(expand(command[2], env)))
    return ("exec",) + tuple(command)


def compose_check(hc, env):
    test = hc.get("test") or []
    if not test or test[0] == "NONE" or hc.get("disable"):
        return None
    if test[0] == "CMD-SHELL":
        check = check_of_exec(["sh", "-c", test[1].replace("$$", "$")], env)
    else:
        args = [a.replace("$$", "$") for a in test[1:]]
        m = re.match(r"^https?://(?:localhost|127\.0\.0\.1):(\d+)(/.*)$", args[-1]) if args and args[0] == "curl" else None
        check = ("http", m.group(1), m.group(2)) if m else check_of_exec(args, env)
    if check in EQUIVALENT_CHECKS:
        check = EQUIVALENT_CHECKS[check][0]
    return check


def chart_check(probe, container, env):
    if "exec" in probe:
        return check_of_exec(probe["exec"]["command"], env)
    if "httpGet" in probe:
        port = probe["httpGet"]["port"]
        for p in container.get("ports") or []:
            if p.get("name") == port:
                port = p["containerPort"]
        return ("http", str(port), probe["httpGet"].get("path", "/"))
    return ("other", json.dumps(probe, sort_keys=True))


# --- the comparison -----------------------------------------------------------------------

def workloads(docs):
    """(kind, name, container name) -> (container, is init)"""
    out = {}
    for d in docs:
        kind = d.get("kind")
        if kind not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"):
            continue
        spec = (d["spec"].get("jobTemplate") or {}).get("spec", d["spec"])["template"]["spec"]
        for init, key in ((True, "initContainers"), (False, "containers")):
            for c in spec.get(key) or []:
                out[(kind, d["metadata"]["name"], c["name"])] = (c, init)
    return out


def compare(case, services, docs, used, failures):
    containers = workloads(docs)
    secrets = Secrets()
    paired = set()

    def allowed(prefix, what):
        key = f"{prefix}/{what}"
        if key in ALLOWED_DIFFERENCES:
            used.add(key)
            return True
        return False

    for service_name, kind, workload, cname, prefix, one_shot in PAIRS:
        service = services.get(service_name)
        if service is not None and (service.get("deploy") or {}).get("replicas") == 0:
            service = None
        found = containers.get((kind, workload, cname))
        where = f"{case}: {service_name} -> {kind} {workload}/{cname}"
        if service is None and found is None:
            continue
        if service is None or found is None:
            failures.add(where, "in compose only" if found is None else "in the chart only")
            continue
        paired.add((kind, workload, cname))
        container, init = found
        if one_shot != init and kind != "CronJob":
            failures.add(where, f"{'an init' if init else 'a long-running'} container for a compose service that {'runs once' if one_shot else 'keeps running'}")

        # the variables: compose's entrypoint exports (syncstorage's SYNC_STATSD_*) count as
        # compose's where the chart has the variable
        cenv = compose_env(service)
        script = "\n".join((service.get("entrypoint") or []) + (service.get("command") or []))
        exports = {}
        for line in script.splitlines():
            m = re.match(r"^\s*export\s+(.*)$", line)
            if m:
                for assign in shlex.split(m.group(1)):
                    if "=" in assign:
                        k, v = assign.split("=", 1)
                        exports[k] = hosts(k, v, COMPOSE_HOSTS)
        henv = chart_env(container, where, failures)
        for name in sorted(set(cenv) | set(henv)):
            if name not in henv:
                if not allowed(prefix, name):
                    failures.add(where, f"{name} in compose only")
                continue
            if name not in cenv:
                if name in exports:
                    if not secrets.same(exports[name], henv[name], where, failures):
                        failures.add(where, f"{name}: compose's entrypoint exports {exports[name]!r}, the chart has {henv[name]!r}")
                    if not allowed(prefix, name):
                        failures.add(where, f"{name} in compose's entrypoint script only")
                    continue
                # a password the chart passes on its own for a $(VAR) of another variable
                if not allowed(prefix, name):
                    failures.add(where, f"{name} in the chart only")
                continue
            if not secrets.same(cenv[name], henv[name], where, failures) and not allowed(prefix, name):
                failures.add(where, f"{name}: compose {cenv[name]!r}, chart {henv[name]!r}")
        # the chart-only variables allowed as passwords for $(VAR) must be used so
        for name in set(henv) - set(cenv) - set(exports):
            if name.endswith("PASSWORD") and not any(f"$({name})" in str(e.get("value", "")) for e in container.get("env") or []):
                failures.add(where, f"{name} in the chart only, and no $({name}) uses it")

        # the command: compose's entrypoint and command, the chart's command and args
        want = [service.get("entrypoint"), service.get("command")]
        got = [container.get("command"), container.get("args")]
        if want != got and not allowed(prefix, "command"):
            failures.add(where, f"command: compose {json.dumps(want)}, chart {json.dumps(got)}")

        # the probes: compose's check in every one of them; its timings in each, but those
        # allowed to differ (and in one at least)
        if one_shot:
            continue
        hc = service.get("healthcheck") or {}
        want_check = compose_check(hc, cenv)
        probes = {k: container[k] for k in ("startupProbe", "readinessProbe", "livenessProbe") if k in container}
        if want_check is None:
            if probes:
                failures.add(where, f"probes {sorted(probes)}, compose has no healthcheck")
            continue
        if "readinessProbe" not in probes or "livenessProbe" not in probes:
            failures.add(where, f"a readinessProbe and a livenessProbe needed, it has {sorted(probes)}")
        timings = (duration(hc.get("interval") or "30s"), duration(hc.get("timeout") or "30s"), hc.get("retries", 3))
        start = duration(hc.get("start_period"))
        matching = []
        for kind_, probe in probes.items():
            got_check = chart_check(probe, container, henv)
            want_s, got_s = json.dumps(want_check), json.dumps(got_check)
            if not secrets.same(want_s, got_s, where, failures):
                failures.add(where, f"{kind_} checks {got_check}, compose's healthcheck {want_check}")
            got_t = (probe.get("periodSeconds", 10), probe.get("timeoutSeconds", 1), probe.get("failureThreshold", 3))
            if got_t == timings:
                matching.append(kind_)
            elif not allowed(prefix, kind_):
                failures.add(where, f"{kind_} every {got_t[0]} s, timeout {got_t[1]} s, {got_t[2]} failures; "
                                    f"compose's healthcheck every {timings[0]:g} s, timeout {timings[1]:g} s, {timings[2]} retries")
        if not matching:
            failures.add(where, f"no probe with compose's healthcheck timings {timings}")
        # compose's start_period: within the startupProbe's time, or before the first check
        if start:
            window = 0
            if "startupProbe" in probes:
                p = probes["startupProbe"]
                window = p.get("initialDelaySeconds", 0) + p.get("periodSeconds", 10) * p.get("failureThreshold", 3)
            window = max([window] + [probes[k].get("initialDelaySeconds", 0) for k in matching])
            if window < start:
                failures.add(where, f"compose's start_period {start:g} s, the chart's probes count failures after {window} s")

    for key, (container, init) in containers.items():
        if key in paired:
            continue
        if key[2] in CHART_ONLY_CONTAINERS:
            used.add("container:" + key[2])
        else:
            failures.add(f"{case}: {key[0]} {key[1]}/{key[2]}", "no compose service for this container")


def main(argv):
    cases = argv or list(CASES)
    failures = Failures()
    used = set()
    for path, original in IDENTICAL_FILES.items():
        with open(os.path.join(REPO, path), "rb") as a, open(os.path.join(REPO, original), "rb") as b:
            if a.read() != b.read():
                failures.add(path, f"differs from {original}")
    for case in cases:
        if case not in CASES:
            sys.exit(f"unknown case {case}: {' '.join(CASES)}")
        files, overrides, helm_args = CASES[case]
        if case.startswith("external-"):
            helm_args = helm_args + EXTERNAL_HELM
        for admin in (True, False):
            for backup in (True, False):
                profiles = [p for p, on in (("admin", admin), ("backup", backup)) if on]
                name = f"{case} ({'+'.join(profiles) or 'no admin, no backup'})"
                services = compose_config(files, overrides, profiles)
                docs = helm_template(helm_args + ["--set", f"admin.enabled={str(admin).lower()}", "--set", f"backup.enabled={str(backup).lower()}"])
                before = len(failures)
                compare(name, services, docs, used, failures)
                print(("✓ " if len(failures) == before else "✗ ") + name)
    if not argv:
        stale = sorted(set(ALLOWED_DIFFERENCES) - used) + sorted(
            c for c in CHART_ONLY_CONTAINERS if "container:" + c not in used)
        for key in stale:
            failures.add("ALLOWED_DIFFERENCES", f"{key} is used by no case: drop it")
    for f in failures:
        print("✗ " + f)
    if failures:
        return 1
    print(f"✓ the chart's env, commands and probes match compose's ({', '.join(cases)}; admin UI and backups on and off); "
          f"{', '.join(IDENTICAL_FILES)} identical to compose's")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
