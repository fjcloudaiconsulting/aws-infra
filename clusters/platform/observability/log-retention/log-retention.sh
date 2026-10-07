#!/bin/sh
# Enforces "request logs are deleted after at most 7 days" (INFRA-130) on the node's container logs.
# kubelet rotates by size only, so a quiet container keeps old lines for weeks. Every CRI log line starts with an
# RFC3339 UTC timestamp and files are append-only, so the first line is the oldest. A file whose first line is older
# than the cutoff (6 days, hourly run: worst case 6d 1h) is emptied (live *.log, never unlinked: containerd holds it
# open O_APPEND) or deleted (kubelet-rotated *.log.<ts>[.gz]). An unparseable first line counts as expired.
# Env: LOG_ROOT (default /var/log/pods), NOW (epoch seconds), CUTOFF (YYYY-MM-DDTHH:MM:SS, derived from NOW),
# HEARTBEAT_URL (empty: no heartbeat). Symlinks are not followed (find -type f).
set -u
LOG_ROOT=${LOG_ROOT:-/var/log/pods}
NOW=${NOW:-$(date -u +%s)}
CUTOFF=${CUTOFF:-$(date -u -d "@$((NOW - 6 * 86400))" +%Y-%m-%dT%H:%M:%S)}
fail=0

expired() { # $1 = first 19 chars of the first line
  case $1 in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) return 0 ;;
  esac
  awk -v t="$1" -v c="$CUTOFF" 'BEGIN { exit !(t < c) }'
}

# kubelet removes its own *.tmp (gzip in progress) normally; one left behind for an hour is stale.
find "$LOG_ROOT" -type f -name '*.tmp' -mmin +60 -exec rm -f {} + || fail=1

find "$LOG_ROOT" -type f \( -name '*.log' -o -name '*.log.*' \) ! -name '*.tmp' > "${TMPDIR:-/tmp}/files" || fail=1
while IFS= read -r f; do
  [ -s "$f" ] || continue
  case $f in
    *.gz) first=$(gzip -dc "$f" 2>/dev/null | head -n 1 | head -c 19) ;;
    *) first=$(head -n 1 "$f" | head -c 19) ;;
  esac
  expired "$first" || continue
  case $f in
    *.log) truncate -s 0 "$f" || fail=1; echo "truncated $f" ;;
    *) rm -f "$f" || fail=1; echo "deleted $f" ;;
  esac
done < "${TMPDIR:-/tmp}/files"

[ "$fail" -eq 0 ] || { echo "log-retention: errors, no heartbeat" >&2; exit 1; }
if [ -n "${HEARTBEAT_URL:-}" ]; then
  ns=$((NOW * 1000000000))
  wget -q -O /dev/null --header 'Content-Type: application/json' --post-data \
    "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"log-retention\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"log_retention_last_success_timestamp_seconds\",\"gauge\":{\"dataPoints\":[{\"asDouble\":$NOW,\"timeUnixNano\":\"$ns\"}]}}]}]}]}" \
    "$HEARTBEAT_URL" || { echo "log-retention: heartbeat failed" >&2; exit 1; }
fi
