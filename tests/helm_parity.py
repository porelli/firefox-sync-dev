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

MYSQL_SERVERS = "mariadb,mysql,external-mariadb,external-mysql"
BUNDLED = "mariadb,mysql,postgres"

# chart-only, compose-only or different, by design: "<cases>:<chart container>/<VAR>" -> why.
# <cases>: * or the cases (comma-separated) the reason holds for; every case of an entry must
# use it (with the admin UI and the backups on or off), else it is stale and fails
ALLOWED_DIFFERENCES = {
    # admin UI
    "*:admin/ADMIN_DEPLOYMENT": "the commands the admin UI shows: kubectl and helm (kubernetes), not docker compose (compose)",
    "*:admin/ADMIN_K8S_RELEASE": "chart-only: the release name for the helm commands the admin UI shows",
    "*:admin/ADMIN_K8S_NAMESPACE": "chart-only: the namespace for the kubectl commands the admin UI shows",
    "*:admin/ADMIN_K8S_FULLNAME": "chart-only: the chart's object names (fullnameOverride), which the admin UI builds from it",
    "*:admin/ADMIN_K8S_SECRET": "chart-only: the Secret's name (existingSecret) for the commands the admin UI shows",
    "*:admin/ADMIN_K8S_CHART": "chart-only: where the chart was published, for the helm upgrade commands the admin UI shows",
    "*:admin/ADMIN_K8S_CHART_VERSION": "chart-only: the release's chart version, the --version of the helm upgrade commands the admin UI shows",
    "*:admin/ADMIN_EXPORT_PORT": "compose-only: the host port compose publishes the admin UI on; the chart has a Service (and an Ingress)",
    # the old names of .env (MIGRATING.md#renamed-settings): compose tells its containers which
    # are still set, or set with their new ones; the chart has no .env
    "*:migrate/FFS_BOTH_ENV_NAMES": "compose-only: the old .env names set with their new ones; the chart has no .env",
    "*:syncstorage/FFS_BOTH_ENV_NAMES": "as migrate's",
    "*:db-init/FFS_BOTH_ENV_NAMES": "as migrate's",
    "postgres,external-postgres:sync-role/FFS_BOTH_ENV_NAMES": "as migrate's",
    "*:db-init/FFS_OLD_ENV_NAMES": "compose-only: the old .env names still set, for the init container's warning; no .env here",
    "*:admin/FFS_OLD_ENV_NAMES": "compose-only: the old .env names still set, for the admin UI's setup check; no .env here",
    # the Sync server
    "*:syncstorage/SYNC_STATSD_HOST": "chart-only as a variable: compose exports it in syncstorage's entrypoint when ffs-admin resolves; "
    "the chart sets it while the admin UI is on (its value is still compared with the export)",
    "*:syncstorage/SYNC_STATSD_PORT": "as SYNC_STATSD_HOST",
    # the chart passes the passwords as their own variables (from the Secret) and builds the
    # database URLs with $(VAR): compose interpolates them into the URLs (and a $(VAR) must use them)
    f"{MYSQL_SERVERS}:migrate/STORAGE_DB_PASSWORD": "chart-only: the password of SYNC_SYNCSTORAGE__DATABASE_URL, $(STORAGE_DB_PASSWORD) there",
    f"{MYSQL_SERVERS}:migrate/TOKENSERVER_DB_PASSWORD": "chart-only: the password of SYNC_TOKENSERVER__DATABASE_URL, $(TOKENSERVER_DB_PASSWORD) there",
    "postgres:migrate/POSTGRES_SYNC_PASSWORD": "chart-only: the password of the database URLs (the Sync role), $(POSTGRES_SYNC_PASSWORD) there",
    "external-postgres:migrate/POSTGRES_PASSWORD": "chart-only: the password of the database URLs with your own server (no Sync role), "
    "$(POSTGRES_PASSWORD) there",
    f"{MYSQL_SERVERS}:syncstorage/STORAGE_DB_PASSWORD": "as migrate's",
    f"{MYSQL_SERVERS}:syncstorage/TOKENSERVER_DB_PASSWORD": "as migrate's",
    "postgres:syncstorage/POSTGRES_SYNC_PASSWORD": "as migrate's",
    "external-postgres:syncstorage/POSTGRES_PASSWORD": "as migrate's",
    # the backups
    "mysql:backup/MARIADB_TLS_VERIFY": "bundled MySQL: false (the chart's one value, the init container's) where compose's backup "
    "inherits true; no effect: the backup image is MySQL's, backup.sh reads it with the MariaDB client only",
    "mysql:db/FFS_MYSQL_IMAGE": "compose-only: SYNC_MYSQL_IMAGE as set in .env (empty: the compose file's default), for "
    "db/mysql/keep-major.sh; the chart's image is always database.image.mysql, chosen in the values (HELM.md#upgrades)",
    "mysql:db/FFS_MYSQL_SETTING": "as FFS_MYSQL_IMAGE",
    # the databases
    "mysql:db/MARIADB_RANDOM_ROOT_PASSWORD": "compose-only with MySQL: docker-compose.sync-mysql.yml keeps docker-compose.yml's MARIADB_*, "
    "the MySQL image ignores them",
    "mysql:db/MARIADB_DATABASE": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "mysql:db/MARIADB_USER": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "mysql:db/MARIADB_PASSWORD": "as MARIADB_RANDOM_ROOT_PASSWORD",
    "mysql:db/MARIADB_AUTO_UPGRADE": "as MARIADB_RANDOM_ROOT_PASSWORD",
}

# commands other than compose's, the chart's exactly: "<cases>:<container>" -> ([command, args], why)
ALLOWED_COMMANDS = {
    "*:syncstorage": ([["/app/bin/syncserver"], None],
                      "compose's entrypoint script only adds SYNC_STATSD_* (env here) before exec /app/bin/syncserver"),
    "*:backup": ([["sh", "/ffs-backup/backup.sh"], ["now"]],
                 "a CronJob runs backup.sh now at backup.schedule; compose's container runs backup.sh loop"),
    "mysql:db": ([None, ["sh", "/ffs-db/admin-user.sh", "mysqld", "--disable-log-bin"]],
                 "compose starts it through db/mysql/keep-major.sh (no upgrade of the data to another major with "
                 "SYNC_MYSQL_IMAGE unset in .env); the chart has no unset: database.image.mysql"),
}

# probes with other timings than compose's healthcheck, the chart's exactly:
# "<cases>:<container>/<probe>" -> ((periodSeconds, timeoutSeconds, failureThreshold), why)
ALLOWED_PROBE_TIMINGS = {
    "*:syncstorage/readinessProbe": ((10, 10, 3), "compose's healthcheck is the livenessProbe; ready sooner (every 10 s, 3 failures) "
                                     "so that the Service gets it at once"),
    "*:admin/startupProbe": ((5, 5, 120), "the first start moves the tables of an older install: up to 10 minutes"),
    "*:admin/readinessProbe": ((10, 5, 3), "compose's healthcheck is the livenessProbe; ready sooner (every 10 s) for the Service"),
    f"{BUNDLED}:db/startupProbe": ((10, 5, 180), "the first start (a new database, a long recovery) gets up to 30 minutes; "
                                  "compose's start_period only delays counting the failures"),
    f"{BUNDLED}:db/livenessProbe": ((30, 10, 10), "restarted only after 5 minutes without an answer: compose never restarts an "
                                    "unhealthy database, and a restart in the middle of a recovery starts it over; readiness "
                                    "is compose's healthcheck"),
}

# containers of the chart that compose has no service for, without env (no credentials):
# "<cases>:<kind>/<workload name, a regex>/<container>" -> why
CHART_ONLY_CONTAINERS = {
    f"*:Deployment/{FULLNAME}-syncstorage/wait-db": "compose's depends_on service_healthy: waits for the database servers to answer",
    f"*:Deployment/{FULLNAME}-admin/wait-sync": "compose's ffs-admin depends_on tokenserver_db_init: the admin UI starts once the "
    "Sync server serves (its init containers succeeded)",
    f"*:Job/{FULLNAME}-backup-volume-[0-9a-f]{{8}}/bind": "binds the backups PVC at install (WaitForFirstConsumer storage "
    "classes), compose's volume needs nothing",
}


def in_scope(key, case):
    """the entry's cases hold the case: (True, the rest of the key) or (False, None)"""
    scope, rest = key.split(":", 1)
    return (scope == "*" or case in scope.split(",")), rest


def entry(table, case, rest):
    """the key of the table for the case and the rest of a key, or None"""
    for key in table:
        ok, r = in_scope(key, case)
        if ok and r == rest:
            return key
    return None


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

# compose service -> chart (workload kind, workload name, container, key prefix, init or one-shot);
# a compose service of the case missing here fails
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
    "postgres": (["docker-compose.sync-postgres.yml"], {"SYNC_POSTGRES_APP_USER": "syncserver_app"}, ["--set", "database.backend=postgres"]),
    # your own server (DATABASES.md, prepare_environment.sh): no database containers, no TLS
    # check (MySQL's self-signed certificate); PostgreSQL without the Sync role
    "external-mariadb": (["docker-compose.yml"],
                         {"SYNC_DB_CONTAINERS": "0", "SYNC_DB_TLS_VERIFY": "false", "SYNC_TOKENSERVER_DB_HOST": EXTDB,
                          "SYNC_STORAGE_DB_HOST": EXTDB},
                         ["--set", "database.backend=mariadb"]),
    "external-mysql": (["docker-compose.yml"],
                       {"SYNC_DB": "mysql", "SYNC_DB_CONTAINERS": "0", "SYNC_DB_TLS_VERIFY": "false",
                        "SYNC_TOKENSERVER_DB_HOST": EXTDB, "SYNC_STORAGE_DB_HOST": EXTDB},
                       ["--set", "database.backend=mysql"]),
    "external-postgres": (["docker-compose.sync-postgres.yml"],
                          {"SYNC_DB_CONTAINERS": "0", "SYNC_POSTGRES_HOST": EXTDB, "SYNC_POSTGRES_APP_PASSWORD": ""},
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
    """NAME=value of .env-example's names (the SYNC_ ones, MIGRATING.md#renamed-settings)"""
    pattern = re.compile(rf"^{re.escape(name)}=")
    hits = [i for i, line in enumerate(lines) if pattern.match(line)]
    if not hits:
        # appended, an old name compose reads only as a fallback: the case would test nothing
        sys.exit(f".env-example has no {name}: update helm_parity.py's CASES")
    for i in hits:
        lines[i] = lines[i].split("=", 1)[0] + "=" + value


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
    for name, value in dict(SYNC_PUBLIC_URL=f"https://{DOMAIN}", **overrides).items():
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


def compare(case, label, services, docs, used, failures):
    """case: the key of CASES, label: it with the admin UI and backups on or off"""
    containers = workloads(docs)
    secrets = Secrets()
    paired = set()
    paired_services = set()

    def allowed(prefix, what, table=ALLOWED_DIFFERENCES):
        key = entry(table, case, f"{prefix}/{what}" if what else prefix)
        if key:
            used.add((key, case))
        return key

    for service_name, kind, workload, cname, prefix, one_shot in PAIRS:
        service = services.get(service_name)
        if service is not None and (service.get("deploy") or {}).get("replicas") == 0:
            service = None
        found = containers.get((kind, workload, cname))
        where = f"{label}: {service_name} -> {kind} {workload}/{cname}"
        if service is None and found is None:
            continue
        if service is not None:
            paired_services.add(service_name)
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
        if want != got:
            key = allowed(prefix, None, ALLOWED_COMMANDS)
            if not key:
                failures.add(where, f"command: compose {json.dumps(want)}, chart {json.dumps(got)}")
            elif got != ALLOWED_COMMANDS[key][0]:
                failures.add(where, f"command: {json.dumps(got)}, not {json.dumps(ALLOWED_COMMANDS[key][0])} ({key})")

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
            key = allowed(prefix, kind_, ALLOWED_PROBE_TIMINGS)
            if key:
                if got_t != ALLOWED_PROBE_TIMINGS[key][0]:
                    failures.add(where, f"{kind_} every {got_t[0]} s, timeout {got_t[1]} s, {got_t[2]} failures; "
                                        f"not {ALLOWED_PROBE_TIMINGS[key][0]} ({key})")
            elif got_t == timings:
                matching.append(kind_)
            else:
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
        where = f"{label}: {key[0]} {key[1]}/{key[2]}"
        match = None
        for k in CHART_ONLY_CONTAINERS:
            ok, rest = in_scope(k, case)
            kind, workload, cname = rest.split("/")
            if ok and kind == key[0] and cname == key[2] and re.fullmatch(workload, key[1]):
                match = k
        if not match:
            failures.add(where, "no compose service for this container")
            continue
        used.add((match, case))
        if container.get("env") or container.get("envFrom"):
            failures.add(where, f"env in a chart-only container ({match}): {[e['name'] for e in container.get('env') or []]}")

    # every compose service is a chart container (but the database containers of your own server)
    for name, service in services.items():
        if name not in paired_services and (service.get("deploy") or {}).get("replicas") != 0:
            failures.add(f"{label}: {name}", "a compose service the chart has no container for")


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
                compare(case, name, services, docs, used, failures)
                print(("✓ " if len(failures) == before else "✗ ") + name)
    # each entry used by every case it is for
    for table in ("ALLOWED_DIFFERENCES", "ALLOWED_COMMANDS", "ALLOWED_PROBE_TIMINGS", "CHART_ONLY_CONTAINERS"):
        for key in globals()[table]:
            unused = [c for c in cases if in_scope(key, c)[0] and (key, c) not in used]
            if unused:
                failures.add(table, f"{key} is used by no render of {', '.join(unused)}: narrow it or drop it")
    for f in failures:
        print("✗ " + f)
    if failures:
        return 1
    print(f"✓ the chart's env, commands and probes match compose's ({', '.join(cases)}; admin UI and backups on and off); "
          f"{', '.join(IDENTICAL_FILES)} identical to compose's")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
