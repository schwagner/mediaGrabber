# ============================================================
# status.sh — what this drive is doing, for the desktop to show
#
# Sourced by mediagrab, cdrip, dvdrip and datarip (not run). Each run keeps
# one file per drive, $MEDIAGRAB_STATUS/<drive>.json — one line of JSON,
# replaced atomically, world-readable — which the Noctalia plugin in
# noctalia/ reads:
#
#   drive     sr0
#   kind      cd | dvd | data | ""          (still detecting)
#   phase     detecting | waiting | ripping | shipping | done | failed | note
#   disc      what is in it: album, film, volume label
#   step      the human line under it: "track 3 of 12", "1.2G of 4.3G"
#   progress  0..1, or null when there is nothing to measure
#   message   the outcome, once the run has one (the notification's text)
#   since     epoch seconds the phase began; with progress, gives an ETA
#   pid boot  the unit's main process and the boot it ran in: a "ripping"
#             file whose pid is gone, or from another boot, was interrupted
#   started updated   epoch seconds
#
# The JSON is rendered from <drive>.env, key=value lines, under flock — the
# rip and its progress ticker both write, and neither may lose the other's
# keys. Nothing here may fail a rip: every write swallows its errors, and
# with MEDIAGRAB_STATUS unset (tests, a hand run without the module) it is
# all a no-op.
#
# PROGRESS is measured by a ticker: a background loop, started around the
# long step (cyanrip, one ffmpeg remux, the tar stream) and stopped after it,
# that calls the ripper's own tick function every 2 s. It is a subshell, so
# it sees the ripper's variables as they were when it started — which is why
# it is started per step, not once per run.
# ============================================================

status_dir=${MEDIAGRAB_STATUS-}
# The unit's main process. exec keeps a pid, and dvdrip's systemd-inhibit
# re-exec leaves the outer pid waiting on it, so the first one is right for
# the whole run.
export MEDIAGRAB_PID=${MEDIAGRAB_PID:-$$}
status_keys=(drive kind phase disc step progress message since pid boot started updated)

_status_json() {  # string escaped for JSON, quotes included
  local s=$1
  s=${s//\\/\\\\} s=${s//\"/\\\"} s=${s//$'\t'/ } s=${s//$'\r'/}
  printf '"%s"' "$s"
}

status() {  # status key=value... — merge into this drive's status
  [[ -n $status_dir && -n ${dev-} ]] || return 0
  mkdir -p "$status_dir" 2>/dev/null || return 0
  (
    local drive=${dev##*/} kv line k v first=1
    local -A s=()
    local env=$status_dir/$drive.env
    flock 9
    if [[ -r $env ]]; then
      while IFS= read -r line; do s[${line%%=*}]=${line#*=}; done < "$env"
    fi
    local now old=${s[phase]-}
    now=$(date +%s)
    for kv in "$@"; do
      v=${kv#*=}
      s[${kv%%=*}]=${v//$'\n'/ }
    done
    [[ ${s[phase]-} == "$old" && -n ${s[since]-} ]] || s[since]=$now
    s[updated]=$now
    for k in "${status_keys[@]}"; do printf '%s=%s\n' "$k" "${s[$k]-}"; done > "$env.tmp"
    {
      printf '{'
      for k in "${status_keys[@]}"; do
        v=${s[$k]-}
        (( first )) || printf ','
        first=0
        case $k in
          progress|since|pid|started|updated) printf '"%s":%s' "$k" "${v:-null}" ;;
          *) printf '"%s":%s' "$k" "$(_status_json "$v")" ;;
        esac
      done
      printf '}\n'
    } > "$status_dir/$drive.json.tmp"
    chmod 0644 "$env.tmp" "$status_dir/$drive.json.tmp"
    mv "$env.tmp" "$env"
    mv "$status_dir/$drive.json.tmp" "$status_dir/$drive.json"
  ) 9>>"$status_dir/${dev##*/}.lock" 2>/dev/null || true
}

status_new() {  # status_new [kind] — a fresh run on this drive
  [[ -n $status_dir && -n ${dev-} ]] || return 0
  # Exported, so the re-execs inside one run (cdrip's Retry, dvdrip's
  # answers and its inhibit wrapper) carry on the same record.
  export MEDIAGRAB_RUN=1
  rm -f "$status_dir/${dev##*/}.env" 2>/dev/null || true
  status drive="${dev##*/}" kind="${1-}" phase=detecting disc= step= progress= message= \
    pid="$MEDIAGRAB_PID" boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" started="$(date +%s)"
}

status_run() {  # status_run <kind> — join mediagrab's record, or start one by hand
  [[ -n ${MEDIAGRAB_RUN-} ]] || status_new "$1"
  status kind="$1"
}

status_end() {  # status_end <ok|fail|note> <message> — the outcome
  local phase=note
  case $1 in ok) phase=done ;; fail) phase=failed ;; esac
  tick_stop
  status phase="$phase" step= progress= message="$2"
}

status_waiting() {  # status_waiting <question> — a popup is up
  status phase=waiting step="$1" progress=
}

tick_start() {  # tick_start <function> — call it every 2 s until tick_stop
  tick_stop
  [[ -n $status_dir ]] || return 0
  local fn=$1 parent=$$
  ( while sleep 2; do kill -0 "$parent" 2>/dev/null || exit 0; "$fn" 2>/dev/null || true; done ) &
  _ticker=$!
}

tick_stop() {
  [[ -n ${_ticker-} ]] || return 0
  kill "$_ticker" 2>/dev/null || true
  wait "$_ticker" 2>/dev/null || true
  _ticker=""
}

fraction() {  # fraction <done> <total> — "0.4213", clamped to 0..1
  awk -v d="$1" -v t="$2" 'BEGIN { if (t <= 0) exit 1; f = d / t; if (f < 0) f = 0; if (f > 1) f = 1; printf "%.4f", f }'
}

status_asking() {  # status_asking <mediagrab-ask's arguments> — its question
  local q="" t=""
  while (( $# )); do
    case $1 in
      --title) t=$2; shift ;;
      --while|--timeout|--reply) shift ;;
      --*) ;;
      *) q=$1; break ;;
    esac
    shift
  done
  status_waiting "${t:+$t: }$q"
}
