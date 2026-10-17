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
- Postgres: $(POSTGRES_PASSWORD) for both tokenserver and storage (single database, single password)
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
{{- printf "postgres://%s:$(POSTGRES_PASSWORD)@%s:%s/%s" $user $host $port $name }}
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
The Secret key holding the password of the tokenserver or storage database user
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
Accepts a dict with "root", "name" (the env var) and "key" (the Secret key)
*/}}
{{- define "firefox-sync.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "firefox-sync.secretName" .root }}
      key: {{ .key }}
{{- end }}

{{/*
The env vars named like the Secret keys of the database passwords, referenced as $(VAR)
by firefox-sync.dbUrl: they must come before the URLs in every container
*/}}
{{- define "firefox-sync.dbPasswordEnv" -}}
{{- if eq .Values.database.backend "postgres" }}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "POSTGRES_PASSWORD" "key" "POSTGRES_PASSWORD") }}
{{- else }}
{{- include "firefox-sync.secretEnv" (dict "root" . "name" "TOKENSERVER_DB_PASSWORD" "key" "TOKENSERVER_DB_PASSWORD") }}
{{ include "firefox-sync.secretEnv" (dict "root" . "name" "STORAGE_DB_PASSWORD" "key" "STORAGE_DB_PASSWORD") }}
{{- end }}
{{- end }}

{{/*
The env of syncstorage-rs, as compose's x-syncstorage (docker-compose.yml and
docker-compose.postgres.yml), for the migrate init container and the server
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
The image of the bundled database, also the client of wait-db: as compose
*/}}
{{- define "firefox-sync.dbImage" -}}
{{- $backend := .Values.database.backend }}
{{- if eq $backend "postgres" }}
{{- print "postgres:18" }}
{{- else if eq $backend "mysql" }}
{{- print "mysql:8.4" }}
{{- else }}
{{- print "mariadb:lts" }}
{{- end }}
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
