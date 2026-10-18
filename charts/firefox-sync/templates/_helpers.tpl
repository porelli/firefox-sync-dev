{{/*
Expand the name of the chart.
*/}}
{{- define "firefox-sync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "firefox-sync.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "firefox-sync.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "firefox-sync.labels" -}}
helm.sh/chart: {{ include "firefox-sync.chart" .root }}
{{ include "firefox-sync.selectorLabels" . }}
{{- if .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/*
Selector labels
Accepts a dict with "root" (the root context) and optional "component"
*/}}
{{- define "firefox-sync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "firefox-sync.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- if .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}

{{/*
Return the proper image name based on backend and component
Accepts a dict with "root" (the root context) and "name" (syncstorage|init|admin)
*/}}
{{- define "firefox-sync.image" -}}
{{- $root := .root }}
{{- $name := .name }}
{{- $backend := $root.Values.database.backend }}
{{- $repository := $root.Values.image.repository }}
{{- if eq $name "admin" }}
{{- printf "%s:admin-%s" $repository $root.Values.image.adminTag }}
{{- else if eq $name "syncstorage" }}
{{- if eq $backend "postgres" }}
{{- printf "%s:syncstorage-rs-postgres-%s" $repository $root.Values.image.syncstorageTag }}
{{- else }}
{{- printf "%s:syncstorage-rs-mysql-%s" $repository $root.Values.image.syncstorageTag }}
{{- end }}
{{- else if eq $name "init" }}
{{- if eq $backend "postgres" }}
{{- printf "%s:syncstorage-rs-postgres-init-%s" $repository $root.Values.image.initTag }}
{{- else }}
{{- printf "%s:syncstorage-rs-mysql-init-%s" $repository $root.Values.image.initTag }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database host for tokenserver or storage
Accepts a dict with "root" (the root context) and "db" (tokenserver|storage)
For bundled databases (the Services of databases.yaml):
  - mariadb/mysql: <fullname>-tokenserver-db and <fullname>-storage-db (separate databases)
  - postgres: <fullname>-postgres (shared database)
For external databases: use the configured host
*/}}
{{- define "firefox-sync.dbHost" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- $fullname := include "firefox-sync.fullname" $root }}
{{- if eq $backend "postgres" }}
{{- printf "%s-postgres" $fullname }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- printf "%s-tokenserver-db" $fullname }}
{{- else }}
{{- printf "%s-storage-db" $fullname }}
{{- end }}
{{- end }}
{{- else }}
{{- $root.Values.database.external.host }}
{{- end }}
{{- end }}

{{/*
Return the database port
*/}}
{{- define "firefox-sync.dbPort" -}}
{{- $root := .root }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- if eq $backend "postgres" }}
{{- print "5432" }}
{{- else }}
{{- print "3306" }}
{{- end }}
{{- else }}
{{- $root.Values.database.external.port }}
{{- end }}
{{- end }}

{{/*
Return the database name for tokenserver or storage
Accepts a dict with "root" (the root context) and "db" (tokenserver|storage)
*/}}
{{- define "firefox-sync.dbName" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- if eq $backend "postgres" }}
{{- print "syncserver" }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- print "tokenserver" }}
{{- else }}
{{- print "syncstorage" }}
{{- end }}
{{- end }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- $root.Values.database.external.tokenserverDatabase }}
{{- else }}
{{- if eq $backend "postgres" }}
{{- $root.Values.database.external.tokenserverDatabase }}
{{- else }}
{{- $root.Values.database.external.storageDatabase }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database user for tokenserver or storage
*/}}
{{- define "firefox-sync.dbUser" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- if eq $backend "postgres" }}
{{- print "syncserver" }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- print "tokenserver" }}
{{- else }}
{{- print "syncstorage" }}
{{- end }}
{{- end }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- $root.Values.database.external.tokenserverUser }}
{{- else }}
{{- if eq $backend "postgres" }}
{{- $root.Values.database.external.tokenserverUser }}
{{- else }}
{{- $root.Values.database.external.storageUser }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the database URL for tokenserver or storage
Accepts a dict with "root" (the root context) and "db" (tokenserver|storage)
The password is read from the environment variable via Kubernetes dependent env, not inlined here:
- Postgres: the Sync server's own role, $(POSTGRES_SYNC_PASSWORD), for both tokenserver and storage
  (single database); without one (firefox-sync.postgresSyncUser empty) POSTGRES_USER, $(POSTGRES_PASSWORD)
- MySQL/MariaDB: $(TOKENSERVER_DB_PASSWORD) or $(STORAGE_DB_PASSWORD) (separate databases)
*/}}
{{- define "firefox-sync.dbUrl" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- $host := include "firefox-sync.dbHost" (dict "root" $root "db" $db) }}
{{- $port := include "firefox-sync.dbPort" (dict "root" $root) }}
{{- $name := include "firefox-sync.dbName" (dict "root" $root "db" $db) }}
{{- $user := include "firefox-sync.dbUser" (dict "root" $root "db" $db) }}
{{- if eq $backend "postgres" }}
{{- $syncUser := include "firefox-sync.postgresSyncUser" $root }}
{{- if $syncUser }}
{{- printf "postgres://%s:$(POSTGRES_SYNC_PASSWORD)@%s:%s/%s" $syncUser $host $port $name }}
{{- else }}
{{- printf "postgres://%s:$(POSTGRES_PASSWORD)@%s:%s/%s" $user $host $port $name }}
{{- end }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- printf "mysql://%s:$(TOKENSERVER_DB_PASSWORD)@%s:%s/%s" $user $host $port $name }}
{{- else }}
{{- printf "mysql://%s:$(STORAGE_DB_PASSWORD)@%s:%s/%s" $user $host $port $name }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the name of the secret containing database passwords
*/}}
{{- define "firefox-sync.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- include "firefox-sync.fullname" . }}
{{- end }}
{{- end }}

{{/*
maxUsers as compose's MAX_USERS: a string, also when given as a number (maxUsers: 5,
--set maxUsers=5); int64 first, so that a large number is not printed as a float (1e+06)
*/}}
{{- define "firefox-sync.maxUsers" -}}
{{- include "firefox-sync.number" .Values.maxUsers }}
{{- end }}

{{/*
A value as compose's string: a string as it is, a number of a values file (a float64 there)
as an integer, never 2e+06; empty for nil
*/}}
{{- define "firefox-sync.number" -}}
{{- if kindIs "string" . }}
{{- . }}
{{- else if not (kindIs "invalid" .) }}
{{- . | int64 | toString }}
{{- end }}
{{- end }}

{{/*
PostgreSQL: the Sync server's own role (compose's POSTGRES_SYNC_USER), no superuser, created by
the sync-role init container before the migrations; the name prepare_environment.sh gives it.
Empty (compose: an install from before it, or your own server): the Sync server is POSTGRES_USER
*/}}
{{- define "firefox-sync.postgresSyncUser" -}}
{{- if and (eq .Values.database.backend "postgres") .Values.database.bundled }}
{{- print "syncserver_app" }}
{{- end }}
{{- end }}

{{/*
The admin UI's own database and users (compose's ADMIN_DB_NAME, ADMIN_DB_USER,
ADMIN_DB_SYNC_USER, with their defaults), password ADMIN_DB_PASSWORD in the Secret
*/}}
{{- define "firefox-sync.adminDbName" -}}ffs_admin{{- end }}
{{- define "firefox-sync.adminDbUser" -}}ffs_admin_ui{{- end }}
{{- define "firefox-sync.adminDbSyncUser" -}}ffs_admin_sync{{- end }}

{{/*
The Secret key holding the password of the tokenserver or storage database user
(PostgreSQL: POSTGRES_USER, the superuser of the bundled server)
Accepts a dict with "root" and "db" (tokenserver|storage)
*/}}
{{- define "firefox-sync.dbPasswordKey" -}}
{{- if eq .root.Values.database.backend "postgres" }}
{{- print "POSTGRES_PASSWORD" }}
{{- else if eq .db "tokenserver" }}
{{- print "TOKENSERVER_DB_PASSWORD" }}
{{- else }}
{{- print "STORAGE_DB_PASSWORD" }}
{{- end }}
{{- end }}

{{/*
An env entry read from the chart's Secret
Accepts a dict with "root", "name" (the env var), "key" (the Secret key) and optional
"optional" (true: the key may be missing from an existingSecret, the variable is then unset)
*/}}
{{- define "firefox-sync.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "firefox-sync.secretName" .root }}
      key: {{ .key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end }}

{{/*
The env vars named like the Secret keys of the database passwords, referenced as $(VAR)
by firefox-sync.dbUrl: they must come before the URLs in every container
*/}}
{{- define "firefox-sync.dbPasswordEnv" -}}
{{- if include "firefox-sync.postgresSyncUser" . }}
{{- /* never POSTGRES_PASSWORD, the superuser's (compose: the Sync server never gets it) */ -}}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_SYNC_PASSWORD" "key" "POSTGRES_SYNC_PASSWORD") }}
{{- else if eq .Values.database.backend "postgres" }}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_PASSWORD" "key" "POSTGRES_PASSWORD") }}
{{- else }}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "TOKENSERVER_DB_PASSWORD" "key" "TOKENSERVER_DB_PASSWORD") }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "STORAGE_DB_PASSWORD" "key" "STORAGE_DB_PASSWORD") }}
{{- end }}
{{- end }}

{{/*
The env of syncstorage-rs, as compose's x-syncstorage (docker-compose.yml and
docker-compose.sync-postgres.yml), for the migrate init container and the server
*/}}
{{- define "firefox-sync.syncstorageEnv" -}}
{{- include "firefox-sync.dbPasswordEnv" . }}
- name: SYNC_HOST
  value: 0.0.0.0
- name: SYNC_HUMAN_LOGS
  value: "1"
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "SYNC_MASTER_SECRET" "key" "SYNC_MASTER_SECRET") }}
- name: SYNC_SYNCSTORAGE__DATABASE_URL
  value: {{ include "firefox-sync.dbUrl" (dict "root" . "db" "storage") | quote }}
- name: SYNC_TOKENSERVER__ENABLED
  value: "true"
- name: SYNC_TOKENSERVER__RUN_MIGRATIONS
  value: "true"
- name: SYNC_TOKENSERVER__NODE_TYPE
  value: {{ ternary "postgres" "mysql" (eq .Values.database.backend "postgres") }}
- name: SYNC_TOKENSERVER__DATABASE_URL
  value: {{ include "firefox-sync.dbUrl" (dict "root" . "db" "tokenserver") | quote }}
- name: SYNC_TOKENSERVER__INIT_NODE_URL
  value: {{ .Values.syncDomain | quote }}
- name: SYNC_TOKENSERVER__FXA_EMAIL_DOMAIN
  value: {{ .Values.fxa.emailDomain | quote }}
- name: SYNC_TOKENSERVER__FXA_OAUTH_SERVER_URL
  value: {{ .Values.fxa.oauthServerUrl | quote }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "SYNC_TOKENSERVER__FXA_METRICS_HASH_SECRET" "key" "METRICS_HASH_SECRET") }}
- name: SYNC_TOKENSERVER__ADDITIONAL_BLOCKING_THREADS_FOR_FXA_REQUESTS
  value: "2"
- name: RUST_LOG
  value: info
{{- end }}

{{/*
The image of the bundled database, also the client of wait-db and of the backups: as compose
(database.image.<backend>, compose's POSTGRES_IMAGE for PostgreSQL)
*/}}
{{- define "firefox-sync.dbImage" -}}
{{- index .Values.database.image .Values.database.backend }}
{{- end }}

{{/*
MARIADB_TLS_VERIFY of the init container: the bundled MySQL's certificate is self-signed
(docker-compose.sync-mysql.yml sets false), the bundled MariaDB's is checked; your own
server: database.external.tlsVerify
*/}}
{{- define "firefox-sync.tlsVerify" -}}
{{- if not .Values.database.bundled }}
{{- .Values.database.external.tlsVerify | toString }}
{{- else if eq .Values.database.backend "mysql" }}
{{- print "false" }}
{{- else }}
{{- print "true" }}
{{- end }}
{{- end }}

{{/*
The env of db/mysql/admin-user.sh in the MariaDB and MySQL containers, as compose's
tokenserver_db and syncstorage_db. Accepts a dict with "root" and "role" (tokenserver|storage)
*/}}
{{- define "firefox-sync.adminUserEnv" -}}
- name: ADMIN_DB_ROLE
  value: {{ .role }}
{{- if eq .role "tokenserver" }}
- name: ADMIN_DB_USER
  value: {{ include "firefox-sync.adminDbUser" .root }}
{{- end }}
- name: ADMIN_DB_SYNC_USER
  value: {{ include "firefox-sync.adminDbSyncUser" .root }}
{{ include "firefox-sync.secretEnv" (dict "root" .root "name" "ADMIN_DB_PASSWORD" "key" "ADMIN_DB_PASSWORD") }}
{{- if eq .role "tokenserver" }}
- name: ADMIN_DB_NAME
  value: {{ include "firefox-sync.adminDbName" .root }}
{{- end }}
{{- end }}

{{/*
compose's POSTGRES_SYNC_USER and POSTGRES_SYNC_PASSWORD of sync_role_init and the init
container (empty without the Sync server's own role, as compose's ${...:-})
*/}}
{{- define "firefox-sync.postgresSyncEnv" -}}
{{- $syncUser := include "firefox-sync.postgresSyncUser" . }}
- name: POSTGRES_SYNC_USER
  value: {{ $syncUser | quote }}
{{- if $syncUser }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_SYNC_PASSWORD" "key" "POSTGRES_SYNC_PASSWORD") }}
{{- else }}
- name: POSTGRES_SYNC_PASSWORD
  value: ""
{{- end }}
{{- end }}

{{/*
compose's cap_drop: [NET_RAW] of the Sync server and its migrations: no raw sockets
*/}}
{{- define "firefox-sync.syncstorageSecurityContext" -}}
securityContext:
  capabilities:
    drop: ["NET_RAW"]
{{- end }}

{{/*
The admin UI's Service: its http port and the statsd port the Sync server sends to
*/}}
{{- define "firefox-sync.adminService" -}}
{{- printf "%s-admin" (include "firefox-sync.fullname" .) }}
{{- end }}

{{/*
The data of the chart's Secret (see secret.yaml) as JSON: read back from the cluster, the
missing secrets generated, the admin UI's of the values. Computed once per render and kept
on the root context, so that secret.yaml and the checksum of admin.yaml see the same
generated values
*/}}
{{- define "firefox-sync.secretData" -}}
{{- if not (hasKey $ "ffsSecretData") }}
{{- $name := include "firefox-sync.fullname" . }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name }}
{{- $data := dict }}
{{- if $existing }}
{{- $data = deepCopy ($existing.data | default dict) }}
{{- end }}
{{- /* ADMIN_DB_PASSWORD: the admin UI's own database users, also created by the bundled
databases and the init container (compose's ADMIN_DB_PASSWORD, prepare_environment.sh
generates it); POSTGRES_SYNC_PASSWORD: the Sync server's own role, POSTGRES_PASSWORD
the superuser's */ -}}
{{- $keys := list "SYNC_MASTER_SECRET" "METRICS_HASH_SECRET" "ADMIN_PASSWORD" "ADMIN_DB_PASSWORD" }}
{{- if eq .Values.database.backend "postgres" }}
{{- $keys = concat $keys (list "POSTGRES_PASSWORD" "POSTGRES_SYNC_PASSWORD") }}
{{- else }}
{{- $keys = concat $keys (list "TOKENSERVER_DB_PASSWORD" "STORAGE_DB_PASSWORD") }}
{{- end }}
{{- range $keys }}
{{- if not (hasKey $data .) }}
{{- $_ := set $data . (randAlphaNum 32 | b64enc) }}
{{- end }}
{{- end }}
{{- /* the admin UI's password when given (otherwise the generated one, kept) */ -}}
{{- with .Values.admin.password }}
{{- $_ := set $data "ADMIN_PASSWORD" (. | toString | b64enc) }}
{{- end }}
{{- /* its optional secrets (.env's names) are the values', never the cluster's: empty
there is empty here, the feature off (existingSecret to manage them out of band) */ -}}
{{- $_ := set $data "FXA_SMTP_PASS" (.Values.admin.smtp.password | toString | b64enc) }}
{{- $_ := set $data "ADMIN_OIDC_CLIENT_SECRET" (.Values.admin.oidc.clientSecret | toString | b64enc) }}
{{- $_ := set $data "ADMIN_METRICS_TOKEN" (.Values.admin.metricsToken | toString | b64enc) }}
{{- $_ := set $data "ADMIN_NOTIFY" (include "firefox-sync.adminNotify" . | b64enc) }}
{{- $_ := set $ "ffsSecretData" $data }}
{{- end }}
{{- toJson (get $ "ffsSecretData") }}
{{- end }}

{{/*
admin.notify as compose's ADMIN_NOTIFY: a list of URLs joined by commas, or a string as it is
*/}}
{{- define "firefox-sync.adminNotify" -}}
{{- $n := .Values.admin.notify }}
{{- if kindIs "slice" $n }}
{{- join "," $n }}
{{- else if $n }}
{{- $n | toString }}
{{- end }}
{{- end }}

{{/*
compose's BACKUP_TIME (HH:MM, UTC) of backup.schedule when it is a daily "M H * * *" (the
CronJob runs in UTC), for the admin UI's help and backup.sh; empty for any other schedule:
the admin UI then says its default, 03:00
*/}}
{{- define "firefox-sync.backupTime" -}}
{{- $s := .Values.backup.schedule | toString | trim }}
{{- if regexMatch "^([0-5]?[0-9]) ([01]?[0-9]|2[0-3]) \\* \\* \\*$" $s }}
{{- $f := splitList " " $s }}
{{- printf "%02d:%02d" (index $f 1 | atoi) (index $f 0 | atoi) }}
{{- end }}
{{- end }}

{{/*
The backup's pods (the CronJob's and the PVC's binding Job): root, as compose (the dumps are
root's, 0600), without any capability: root owns what it writes into the PVC and /tmp, the
dumps and their clients need none (the e2e dumps and restores so)
*/}}
{{- define "firefox-sync.backupPodSecurityContext" -}}
seccompProfile:
  type: RuntimeDefault
{{- end }}
{{- define "firefox-sync.backupSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end }}

{{/*
The names of the chart's objects within Kubernetes' limits, or the render fails saying so:
none is truncated, the admin UI builds them from ADMIN_K8S_FULLNAME (the CronJob, the Sync
server's Deployment, the databases' hosts). A CronJob at most 52 (its Jobs get 11 more), a
StatefulSet 52 (its pods' controller-revision-hash label is <name>-<hash of up to 10>), a
Service 63 (a DNS label)
*/}}
{{- define "firefox-sync.checkNames" -}}
{{- $fullname := include "firefox-sync.fullname" . }}
{{- $names := list (list "syncstorage" "Service" 63) }}
{{- if .Values.admin.enabled }}
{{- $names = append $names (list "admin" "Service" 63) }}
{{- end }}
{{- if .Values.backup.enabled }}
{{- $names = append $names (list "backup" "CronJob" 52) }}
{{- end }}
{{- if .Values.database.bundled }}
{{- if eq .Values.database.backend "postgres" }}
{{- $names = append $names (list "postgres" "StatefulSet" 52) }}
{{- else }}
{{- $names = concat $names (list (list "tokenserver-db" "StatefulSet" 52) (list "storage-db" "StatefulSet" 52)) }}
{{- end }}
{{- end }}
{{- range $names }}
{{- $name := printf "%s-%s" $fullname (index . 0) }}
{{- if gt (len $name) (index . 2) }}
{{- fail (printf "firefox-sync: set a shorter fullnameOverride or a shorter release name: the %s %s name %s is %d characters, at most %d (the fullname %s is %d)" (index . 0) (index . 1) $name (len $name) (index . 2) $fullname (len $fullname)) }}
{{- end }}
{{- end }}
{{- end }}
