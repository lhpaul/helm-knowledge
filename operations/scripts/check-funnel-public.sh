#!/usr/bin/env bash
# Pre-flight for Linear/GitHub webhooks → Mac Mini Tailscale Funnel.
# Uses public resolvers (what Linear sees), not MagiDNS / Tailscale 100.x.
#
# Usage:
#   ./check-funnel-public.sh              # one-shot
#   ./check-funnel-public.sh --watch 5    # dig+curl every 30s for N minutes
#   ./check-funnel-public.sh --watch 5 --interval 20
#
# Exit 0 only if DNS public + /health 200 + /api/webhooks/linear returns 401
# (handler reachable; unsigned body rejected). Non-zero → do not re-enable Linear.

set -euo pipefail

HOST="${FUNNEL_HOST:-mac-mini-de-luis.tailc0e5af.ts.net}"
BASE="https://${HOST}"
PUBLIC_RESOLVERS=(${FUNNEL_DNS_RESOLVERS:-8.8.8.8 1.1.1.1})
WATCH_MINUTES=0
INTERVAL_SEC=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      WATCH_MINUTES="${2:?}"
      shift 2
      ;;
    --interval)
      INTERVAL_SEC="${2:?}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

is_public_ip() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  # Tailscale CGNAT — fine on-tailnet, useless for Linear
  [[ "$ip" == 100.* ]] && return 1
  return 0
}

check_dns() {
  local resolver="$1"
  local answers
  answers="$(dig @"$resolver" +short +time=3 +tries=2 "$HOST" A 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -z "$answers" ]]; then
    echo "DNS @$resolver: EMPTY/NXDOMAIN"
    return 1
  fi
  local ok=0
  local ip
  for ip in $answers; do
    if is_public_ip "$ip"; then
      ok=1
      break
    fi
  done
  if [[ $ok -eq 0 ]]; then
    echo "DNS @$resolver: only non-public answers ($answers)"
    return 1
  fi
  echo "DNS @$resolver: $answers"
  return 0
}

check_once() {
  local ts fail=0
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "── $ts  host=$HOST"

  local r
  for r in "${PUBLIC_RESOLVERS[@]}"; do
    if ! check_dns "$r"; then
      fail=1
    fi
  done

  local health_code linear_code
  health_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 \
    "${BASE}/health" 2>/dev/null || echo '000')"
  linear_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 \
    -X POST "${BASE}/api/webhooks/linear" \
    -H 'content-type: application/json' -d '{}' 2>/dev/null || echo '000')"

  echo "GET  /health → HTTP ${health_code} (want 200)"
  echo "POST /api/webhooks/linear (unsigned) → HTTP ${linear_code} (want 401)"

  if [[ "$health_code" != "200" ]]; then
    fail=1
  fi
  if [[ "$linear_code" != "401" ]]; then
    fail=1
  fi

  if [[ $fail -eq 0 ]]; then
    echo "RESULT: OK — safe to consider re-enabling Linear webhook"
    return 0
  fi
  echo "RESULT: FAIL — do not re-enable Linear yet"
  return 1
}

if [[ "$WATCH_MINUTES" -le 0 ]]; then
  check_once
  exit $?
fi

echo "Watching ${WATCH_MINUTES}m every ${INTERVAL_SEC}s (public DNS + Funnel)"
end=$((SECONDS + WATCH_MINUTES * 60))
passes=0
fails=0
while (( SECONDS < end )); do
  if check_once; then
    passes=$((passes + 1))
  else
    fails=$((fails + 1))
  fi
  echo
  if (( SECONDS + INTERVAL_SEC >= end )); then
    break
  fi
  sleep "$INTERVAL_SEC"
done

echo "Summary: passes=$passes fails=$fails"
if [[ "$fails" -eq 0 && "$passes" -gt 0 ]]; then
  echo "Stable for this window — OK to re-enable Linear webhook"
  exit 0
fi
echo "Unstable or failed — keep Linear disabled; consider funnel reset or Cloudflare Tunnel"
exit 1
