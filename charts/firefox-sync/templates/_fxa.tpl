{{/*
The self-hosted Mozilla accounts (fxa.enabled), compose's docker-compose.fxa.yml (and
docker-compose.fxa-mariadb.yml): their images, hosts, env blocks, security contexts and checks
*/}}

{{/*
The image of the accounts (name "fxa": compose's ${FXA_IMAGE}:${FXA_VERSION}, fxa.image.repository
empty: image.repository) or of the pairing server (name "pairing": FXA_PAIRING_IMAGE, empty:
<image.repository>:fxa-channelserver-latest). Accepts a dict with "root" and "name"
*/}}
{{- define "firefox-sync.fxaImage" -}}
{{- $v := .root.Values }}
{{- if eq .name "pairing" }}
{{- $v.fxa.pairing.image | default (printf "%s:fxa-channelserver-latest" $v.image.repository) }}
{{- else }}
{{- printf "%s:%s" ($v.fxa.image.repository | default $v.image.repository) ($v.fxa.image.tag | default "fxa-mono-latest") }}
{{- end }}
{{- end }}

{{/*
The accounts database (compose's FXA_MYSQL_HOST, _PORT, _USER): the bundled server
<fullname>-fxa-db:3306 as root (MYSQL_ROOT_PASSWORD is FXA_MYSQL_PASSWORD, as compose's), or
your own server's fxa.database.external.*
*/}}
{{- define "firefox-sync.fxaDbHost" -}}
{{- if .Values.fxa.database.bundled }}
{{- printf "%s-fxa-db" (include "firefox-sync.fullname" .) }}
{{- else }}
{{- .Values.fxa.database.external.host }}
{{- end }}
{{- end }}

{{- define "firefox-sync.fxaDbPort" -}}
{{- $port := "3306" }}
{{- if not .Values.fxa.database.bundled }}
{{- with include "firefox-sync.number" .Values.fxa.database.external.port }}
{{- $port = . }}
{{- end }}
{{- end }}
{{- $port }}
{{- end }}

{{- define "firefox-sync.fxaDbUser" -}}
{{- if .Values.fxa.database.bundled }}
{{- print "root" }}
{{- else }}
{{- .Values.fxa.database.external.user }}
{{- end }}
{{- end }}

{{/*
The image of the accounts database (fxa.database.image.<backend>), also the client of its
wait and of its backups
*/}}
{{- define "firefox-sync.fxaDbImage" -}}
{{- index .Values.fxa.database.image .Values.fxa.database.backend }}
{{- end }}

{{/*
The host of a URL, without its port: the host of an Ingress. Accepts a dict with "root" and "url"
*/}}
{{- define "firefox-sync.fxaHost" -}}
{{- regexReplaceAll ":[0-9]+$" (urlParse (.url | default "")).host "" }}
{{- end }}

{{/*
The Sync server's FXA_OAUTH_SERVER_URL and FXA_EMAIL_DOMAIN: with the self-hosted accounts their
auth server and the host of fxa.authUrl (FXA.md: the email domain must be the auth host, so
fxa.oauthServerUrl and fxa.emailDomain are ignored then), else Mozilla's of the values
*/}}
{{- define "firefox-sync.fxaOauthServerUrl" -}}
{{- if .Values.fxa.enabled }}
{{- printf "http://%s-fxa-auth:9000/v1" (include "firefox-sync.fullname" .) }}
{{- else }}
{{- .Values.fxa.oauthServerUrl }}
{{- end }}
{{- end }}

{{- define "firefox-sync.fxaEmailDomain" -}}
{{- if .Values.fxa.enabled }}
{{- include "firefox-sync.fxaHost" (dict "root" . "url" .Values.fxa.authUrl) }}
{{- else }}
{{- .Values.fxa.emailDomain }}
{{- end }}
{{- end }}

{{/*
FXA_SIGNUP_ALLOWLIST: fxa.signupAllowlist, a list joined by commas or a string as it is (the
value of the env var, not an env entry)
*/}}
{{- define "firefox-sync.fxaAllowlist" -}}
{{- $l := .Values.fxa.signupAllowlist }}
{{- if kindIs "slice" $l }}
{{- join "," $l }}
{{- else if $l }}
{{- $l | toString }}
{{- end }}
{{- end }}

{{/*
compose's <prefix>MYSQL_HOST, _PORT, _USERNAME and _PASSWORD (x-fxa-mysql, AUTH_MYSQL_*...):
env entries, the password FXA_MYSQL_PASSWORD of the Secret. Accepts a dict with "root" and
"prefix" ("", "AUTH_", "OAUTH_", "PROFILE_", "PUSHBOX_")
*/}}
{{- define "firefox-sync.fxaMysqlEnv" -}}
- name: {{ .prefix }}MYSQL_HOST
  value: {{ include "firefox-sync.fxaDbHost" .root | quote }}
- name: {{ .prefix }}MYSQL_PORT
  value: {{ include "firefox-sync.fxaDbPort" .root | quote }}
- name: {{ .prefix }}MYSQL_USERNAME
  value: {{ include "firefox-sync.fxaDbUser" .root | quote }}
{{ include "firefox-sync.secretEnv" (dict "root" .root "name" (printf "%sMYSQL_PASSWORD" .prefix) "key" "FXA_MYSQL_PASSWORD") }}
{{- end }}

{{/*
The accounts' containers: the image's user app (10001) by number (runAsNonRoot checks a uid),
no capability, no privilege escalation, seccomp RuntimeDefault (PodSecurity restricted). For
nindent under securityContext:
*/}}
{{- define "firefox-sync.fxaSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
The accounts' pods: 10001. Their volumes are made 10001's by the root init containers
(keys-owner, images-owner) with fxa.volumeOwnerInit, as compose's fxa-keys-owner; without
them (volumeOwnerInit false) by fsGroup 10001, where the StorageClass applies it. For
nindent under the pod's securityContext:
*/}}
{{- define "firefox-sync.fxaPodSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
{{- if not .Values.fxa.volumeOwnerInit }}
fsGroup: 10001
fsGroupChangePolicy: OnRootMismatch
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
The secrets of the accounts that the chart generates, as prepare_environment.sh does
(generate_random_string 32): kept in the Secret, also once fxa.enabled is off again
*/}}
{{- define "firefox-sync.fxaGeneratedKeys" -}}
FXA_MYSQL_PASSWORD FXA_ADMIN_DB_PASSWORD FXA_AUTH_SECRET FXA_OAUTH_SECRET FXA_PROFILE_SECRET FXA_FLOW_ID_KEY FXA_SESSION_TOKEN_HANDLE_KEY FXA_CONTENT_SESSION_SECRET
{{- end }}

{{/*
What the accounts need of the values, or the render fails saying so (fail closed); called by
firefox-sync.checkValues
*/}}
{{- define "firefox-sync.checkFxaValues" -}}
{{- $f := .Values.fxa }}
{{- if $f.enabled }}
{{- if not (and $f.contentUrl $f.authUrl $f.profileUrl) }}
{{- fail "firefox-sync: fxa.enabled needs fxa.contentUrl, fxa.authUrl and fxa.profileUrl, the public URLs of the accounts' pages, API and profiles, each on a host of its own (FXA.md)" }}
{{- end }}
{{- if not $f.database.bundled }}
{{- if not $f.database.external.host }}
{{- fail "firefox-sync: fxa.database.bundled=false needs fxa.database.external.host, your accounts database server (DATABASES.md)" }}
{{- end }}
{{- if not .Values.existingSecret }}
{{- fail "firefox-sync: fxa.database.bundled=false needs existingSecret, with FXA_MYSQL_PASSWORD and FXA_MYSQL_POLICY_PASSWORD, the passwords of fxa.database.external.user and policyUser on your server, and the accounts' secrets: the chart cannot generate passwords your server knows" }}
{{- end }}
{{- end }}
{{- $port := include "firefox-sync.number" $f.database.external.port }}
{{- if and $port (or (lt (atoi $port) 1) (gt (atoi $port) 65535)) }}
{{- fail (printf "firefox-sync: fxa.database.external.port %s is no port: 1 to 65535, or empty for 3306" $port) }}
{{- end }}
{{- if and $f.pairing.enabled (not $f.pairing.url) }}
{{- fail "firefox-sync: fxa.pairing.enabled needs fxa.pairing.url, the public wss:// URL of the pairing server" }}
{{- end }}
{{- /* every public host of its own (an Ingress each): host names case-insensitive, a
trailing dot the same host, the port ignored; the Sync server's two (syncDomain's, ingress.host)
may be the same */ -}}
{{- $hosts := list (list "syncDomain" .Values.syncDomain) }}
{{- if and .Values.ingress.enabled .Values.ingress.host }}
{{- $hosts = append $hosts (list "ingress.host" (printf "https://%s" .Values.ingress.host)) }}
{{- end }}
{{- $hosts = concat $hosts (list (list "fxa.contentUrl" $f.contentUrl) (list "fxa.authUrl" $f.authUrl) (list "fxa.profileUrl" $f.profileUrl)) }}
{{- if $f.pairing.enabled }}
{{- $hosts = append $hosts (list "fxa.pairing.url" $f.pairing.url) }}
{{- end }}
{{- if and .Values.admin.enabled .Values.admin.ingress.enabled }}
{{- $hosts = append $hosts (list "admin.ingress.host" (printf "https://%s" .Values.admin.ingress.host)) }}
{{- end }}
{{- $seen := dict }}
{{- $sync := list "syncDomain" "ingress.host" }}
{{- range $hosts }}
{{- $label := index . 0 }}
{{- $host := include "firefox-sync.fxaHost" (dict "root" $ "url" (index . 1)) | lower | trimSuffix "." }}
{{- if $host }}
{{- $other := get $seen $host }}
{{- if and $other (not (and (has $other $sync) (has $label $sync))) }}
{{- fail (printf "firefox-sync: %s has the host %s of %s: the accounts' URLs need a host each (an Ingress each), none of the Sync server's or the admin UI's" $label $host $other) }}
{{- end }}
{{- $_ := set $seen $host $label }}
{{- end }}
{{- end }}
{{- include "firefox-sync.checkExistingSecret" . }}
{{- end }}
{{- end }}

{{/*
An existingSecret must have the accounts' keys, or the pods would end in
CreateContainerConfigError: read with lookup on install and upgrade, the render then fails
naming the missing ones (the release stays at its revision). Nothing to check where lookup
returns nothing (helm template, a GitOps render, the Secret not created yet)
*/}}
{{- define "firefox-sync.checkExistingSecret" -}}
{{- if and .Values.existingSecret .Values.fxa.enabled }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.existingSecret }}
{{- if $existing }}
{{- include "firefox-sync.checkSecretKeys" (dict "root" . "name" .Values.existingSecret "data" ($existing.data | default dict)) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
The keys the accounts need in a Secret's data, missing or empty ones refused: the generated
ones, and with your own accounts server its policy user's password (FXA_MYSQL_POLICY_PASSWORD,
when fxa.database.external.policyUser is set). Accepts a dict with "root", "name" (the
Secret) and "data" (its data)
*/}}
{{- define "firefox-sync.checkSecretKeys" -}}
{{- $v := .root.Values }}
{{- if $v.fxa.enabled }}
{{- $required := splitList " " (include "firefox-sync.fxaGeneratedKeys" .root) }}
{{- if and (not $v.fxa.database.bundled) $v.fxa.database.external.policyUser }}
{{- $required = append $required "FXA_MYSQL_POLICY_PASSWORD" }}
{{- end }}
{{- $missing := list }}
{{- range $required }}
{{- if not (get $.data .) }}
{{- $missing = append $missing . }}
{{- end }}
{{- end }}
{{- if $missing }}
{{- fail (printf "firefox-sync: existingSecret %s lacks %s, which the self-hosted accounts need (HELM.md): add them, then helm upgrade again" .name (sortAlpha $missing | join ", ")) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
smtp.*, compose's FXA_SMTP_* of the accounts and the admin UI, as compose's strings (JSON):
host, port, user, secure, sender (the password is FXA_SMTP_PASS of the Secret)
*/}}
{{- define "firefox-sync.smtp" -}}
{{- $s := merge (deepCopy (.Values.smtp | default dict)) (dict "host" "" "port" 587 "user" "" "secure" false "sender" "") }}
{{- toJson (dict "host" ($s.host | default "" | toString) "port" (include "firefox-sync.number" $s.port) "user" ($s.user | default "" | toString) "secure" ($s.secure | toString) "sender" ($s.sender | default "" | toString)) }}
{{- end }}
