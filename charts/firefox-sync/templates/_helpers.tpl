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
For bundled databases:
  - mariadb/mysql: tokenserver_db and syncstorage_db (separate databases)
  - postgres: postgres_db (shared database)
For external databases: use the configured host
*/}}
{{- define "firefox-sync.dbHost" -}}
{{- $root := .root }}
{{- $db := .db }}
{{- $backend := $root.Values.database.backend }}
{{- if $root.Values.database.bundled }}
{{- $fullname := include "firefox-sync.fullname" $root }}
{{- if eq $backend "postgres" }}
{{- printf "%s-postgres-db" $fullname }}
{{- else }}
{{- if eq $db "tokenserver" }}
{{- printf "%s-tokenserver-db" $fullname }}
{{- else }}
{{- printf "%s-syncstorage-db" $fullname }}
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
