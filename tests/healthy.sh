# Healthchecks of the stack, sourced by tests/e2e.sh, tests/e2e-fxa.sh and tests/podman.sh.
# Every container that keeps running has a healthcheck and passes it; the one-shot ones
# (restart: "no" in compose, Type=oneshot in the Quadlets) have none: their exit status counts.

# compose_healthy <seconds> <compose command...>: every service of the stack (of its profiles,
# not scaled to 0) has a container; those that keep running are running and healthy, the
# one-shot ones exited with 0. Waits that long for those still starting. Prints "all
# healthy", or each one that is not: service=state/health
compose_healthy() {
  local wait=$1 deadline expected seen bad
  shift
  deadline=$(($(date +%s) + wait))
  expected=$("$@" config --format json 2> /dev/null | jq -r '.services | to_entries[] | select((.value.deploy.replicas // 1) != 0) | .key' | LC_ALL=C sort)
  [ -n "${expected}" ] || { echo "no services in the compose config"; return; }
  while :; do
    # (docker run --rm containers: not the stack's)
    seen=$("$@" ps -a -q | xargs -r docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}} {{index .Config.Labels "com.docker.compose.oneoff"}} {{.HostConfig.RestartPolicy.Name}} {{.State.Status}} {{.State.ExitCode}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2> /dev/null |
      awk '$2 != "True"')
    bad=$( {
      echo "${seen}" | awk 'NF {
        oneshot = ($3 == "no" || $3 == "")
        if (oneshot && $4 == "exited" && $5 == 0) next
        if ($4 == "running" && $6 == "healthy") next
        print $1 "=" $4 "/" $6
      }'
      LC_ALL=C comm -23 <(echo "${expected}") <(echo "${seen}" | awk 'NF {print $1}' | LC_ALL=C sort -u) | sed 's/$/=missing/'
    } | LC_ALL=C sort | paste -sd' ')
    [ -z "${bad}" ] && { echo "all healthy"; return; }
    [ "$(date +%s)" -lt "${deadline}" ] || { echo "${bad}"; return; }
    sleep 5
  done
}

# quadlet_container <file>: the container name of a .container unit
quadlet_container() {
  local name
  name=$(sed -n 's/^ContainerName=//p' "$1" | tail -1)
  echo "${name:-systemd-$(basename "$1" .container)}"
}

# quadlets_healthy <seconds> [dir]: every installed unit that keeps running (not
# Type=oneshot) has a HealthCmd, its container runs and passes podman healthcheck run.
# Prints "all healthy", or each one that is not: container=state
quadlets_healthy() {
  local wait=$1 dir=${2:-${QUADLET_DIR}} deadline bad f name state
  deadline=$(($(date +%s) + wait))
  while :; do
    bad=""
    for f in "${dir}"/firefox-sync-*.container; do
      [ -f "${f}" ] || continue
      grep -qx 'Type=oneshot' "${f}" && continue
      name=$(quadlet_container "${f}")
      grep -q '^HealthCmd=' "${f}" || { bad="${bad} ${name}=no-HealthCmd"; continue; }
      state=$(podman inspect -f '{{.State.Status}}' "${name}" 2> /dev/null) || state=missing
      if [ "${state}" != running ]; then
        bad="${bad} ${name}=${state}"
      elif ! podman healthcheck run "${name}" > /dev/null 2>&1; then
        bad="${bad} ${name}=unhealthy"
      fi
    done
    [ -z "${bad}" ] && { echo "all healthy"; return; }
    [ "$(date +%s)" -lt "${deadline}" ] || { echo "${bad# }"; return; }
    sleep 5
  done
}

# a duration of compose or systemd (1m30s, 300s, 5m0s, 1h) in seconds, empty: $2
seconds() {
  [ -n "$1" ] || { echo "$2"; return; }
  echo "$1" | awk '{
    s = 0; d = $0
    while (match(d, /^[0-9.]+(h|ms|us|ns|m|s)/)) {
      part = substr(d, 1, RLENGTH); d = substr(d, RLENGTH + 1)
      n = part + 0; u = part; sub(/^[0-9.]+/, "", u)
      s += n * (u == "h" ? 3600 : u == "m" ? 60 : u == "s" ? 1 : 0)
    }
    if (d != "") { print "bad:" $0; exit }
    print int(s)
  }'
}

# a healthcheck command compared as words: no double quotes, single spaces
words() { tr -d '"' | tr -s ' ' | sed 's/^ //; s/ $//'; }

# health_parity <quadlet dir> <compose command...>: each service of compose that keeps
# running has a healthcheck, and its Quadlet the same one: the command (compose's after the
# container's environment, the Quadlet's as rendered from .env), interval, timeout, retries
# and start period (the defaults of both when not set: 30s, 30s, 3, 0s). Every Quadlet that
# keeps running has one too. Prints "same", or each difference
health_parity() {
  local dir=$1 json out="" s restart test interval timeout retries start unit q qtest
  shift
  json=$("$@" config --format json 2> /dev/null) || { echo "compose config failed"; return; }
  while IFS='|' read -r s restart test interval timeout retries start; do
    [ "${restart}" = no ] && continue
    [ -n "${test}" ] || { out="${out}; ${s}: no healthcheck in compose"; continue; }
    case "${s}" in ffs-admin) unit=firefox-sync-admin ;; *) unit=firefox-sync-${s//_/-} ;; esac
    q=${dir}/${unit}.container
    if [ ! -f "${q}" ]; then
      # the pairing server has no Quadlet (docs/install/podman.md)
      [ "${s}" = fxa-pairing ] || out="${out}; ${s}: no ${unit}.container"
      continue
    fi
    if grep -qx 'Type=oneshot' "${q}"; then
      # the backups: one-shot units of firefox-sync-backup.timer, instead of compose's loop
      case "${s}" in backup|backup-fxa) ;; *) out="${out}; ${s}: ${unit} is a one-shot unit" ;; esac
      continue
    fi
    qtest=$(sed -n 's/^HealthCmd=//p' "${q}" | tail -1)
    case "${qtest}" in \[*) qtest=$(echo "${qtest}" | jq -r 'join(" ")') ;; esac
    # systemd's escapes of the rendered values; then, as compose's, the $NAME of the
    # container's shell with the unit's Environment=
    qtest=$(echo "${qtest}" | sed 's/%%/%/g; s/\$\$/$/g')
    qtest=$(Q=${qtest} awk '
      /^Environment=/ { l = substr($0, 13); if (l ~ /^".*"$/) l = substr(l, 2, length(l) - 2)
        k = l; sub(/=.*/, "", k); v = substr(l, length(k) + 2); gsub(/%%/, "%", v); env[k] = v }
      END { c = ENVIRON["Q"]; out = ""
        while (match(c, /[$]([{][A-Za-z_][A-Za-z0-9_]*[}]|[A-Za-z_][A-Za-z0-9_]*)/)) {
          n = substr(c, RSTART + 1, RLENGTH - 1); gsub(/[{}]/, "", n)
          out = out substr(c, 1, RSTART - 1) env[n]; c = substr(c, RSTART + RLENGTH) }
        print out c }' "${q}" | words)
    test=$(echo "${test}" | words)
    [ "${test}" = "${qtest}" ] || out="${out}; ${s}: command [${test}] in compose, [${qtest}] in ${unit}"
    local key c v
    for key in Interval:"${interval}":30s Timeout:"${timeout}":30s Retries:"${retries}":3 StartPeriod:"${start}":0s; do
      IFS=: read -r key c v <<< "${key}"
      local qv
      qv=$(sed -n "s/^Health${key}=//p" "${q}" | tail -1)
      if [ "${key}" = Retries ]; then
        c=${c:-${v}} qv=${qv:-${v}}
      else
        c=$(seconds "${c}" 0) qv=$(seconds "${qv}" "$(seconds "${v}")")
        [ -n "${c}" ] && [ "${c}" != 0 ] || c=$(seconds "${v}")
      fi
      [ "${c}" = "${qv}" ] || out="${out}; ${s}: ${key} ${c} in compose, ${qv} in ${unit}"
    done
  done < <(echo "${json}" | jq -r '.services | to_entries[] | .key as $s | .value as $v | ($v.environment // {}) as $e |
    ($v.healthcheck // {}) as $h |
    (if ($h.disable // false) then [] else ($h.test // []) end) as $t |
    (if ($t | length) == 0 then ""
     elif $t[0] == "CMD" then $t[1:] | join(" ")
     elif $t[0] == "CMD-SHELL" then $t[1]
     else "" end
     | gsub("\\$\\$"; "$")
     | gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($e[.v] // ""))
     | gsub("\\$(?<v>[A-Za-z_][A-Za-z0-9_]*)"; ($e[.v] // ""))) as $cmd |
    [$s, ($v.restart // "no"), $cmd, ($h.interval // ""), ($h.timeout // ""), (($h.retries // "") | tostring), ($h.start_period // "")] | join("|")')
  # the Quadlets that keep running, with or without a compose service
  local f
  for f in "${dir}"/firefox-sync-*.container; do
    [ -f "${f}" ] || continue
    grep -qx 'Type=oneshot' "${f}" && continue
    grep -q '^HealthCmd=' "${f}" || out="${out}; $(basename "${f}"): no HealthCmd"
  done
  echo "${out:+${out#; }}" | grep . || echo same
}
