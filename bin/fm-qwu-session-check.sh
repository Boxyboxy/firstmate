#!/usr/bin/env bash
# Report whether the queue-workflow UAT's staging dashboard session is usable.
#
# Prints ONE line only when firstmate should wake and re-establish the session;
# prints nothing while the session is healthy. That is the watcher check-script
# contract (AGENTS.md section 7).
#
# Firstmate performs the actual refresh with its browser tool, because the
# sign-in is a real Microsoft identity-provider round trip in the captain's
# headed Chrome profile, not something a shell can drive. The captain authorized
# that refresh explicitly on 2026-08-06 before going away.
#
# This script never mints, stores, or renews a credential itself. It only reads
# the exported cookie header and asks the deployed API whether it still
# authenticates.
set -euo pipefail

FM_HOME="${FM_HOME:-/Users/eugene/code/firstmate}"
COOKIE="$FM_HOME/data/qwu-uat-staging/session.cookie"
BASE="https://staging.krewresearch.com"
STATE="$FM_HOME/state/qwu-cases-staging.status"

# Only matters while the UAT worker is still running. Once it has reported a
# terminal result, a dead session is expected and must not wake anyone.
if [ -f "$STATE" ] && tail -3 "$STATE" 2>/dev/null | grep -qE '^(done|failed):'; then
  exit 0
fi

if [ ! -s "$COOKIE" ]; then
  echo "qwu-uat staging session missing: no exported cookie; refresh via browser sign-in"
  exit 0
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Cookie: $(cat "$COOKIE")" "$BASE/api/auth/session" 2>/dev/null || echo 000)

if [ "$code" != "200" ]; then
  echo "qwu-uat staging session dead (http=$code): refresh via browser sign-in"
  exit 0
fi

user=$(curl -s --max-time 20 -H "Cookie: $(cat "$COOKIE")" "$BASE/api/auth/session" 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
u = (d or {}).get("user") or {}
print(u.get("email") or "")' 2>/dev/null || echo "")

if [ -z "$user" ]; then
  echo "qwu-uat staging session expired (empty user): refresh via browser sign-in"
  exit 0
fi

exit 0
