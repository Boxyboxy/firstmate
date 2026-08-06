#!/usr/bin/env bash
# Wake firstmate when GitHub Actions recovers from the outage that cancelled the
# queue-workflow Lambda deploy and PR 924's test jobs.
#
# Prints ONE line only when there is something to do; prints nothing otherwise.
# That is the watcher check-script contract (AGENTS.md section 7).
#
# Two conditions must BOTH hold before it speaks:
#   1. githubstatus reports the Actions component operational again.
#   2. The staging upload-function alias is still behind the fix commit, so the
#      deploy genuinely still needs rerunning.
#
# Condition 2 matters: without it this would keep waking firstmate after the
# deploy has already landed. It also means a captain who deploys by hand
# silences this automatically.
#
# Read-only. It never dispatches a workflow or touches AWS state.
set -euo pipefail

FM_HOME="${FM_HOME:-/Users/eugene/code/firstmate}"
MARKER="$FM_HOME/state/.gh-actions-recovery-notified"

# Already told firstmate this episode? Stay quiet until the marker is cleared.
[ -f "$MARKER" ] && exit 0

status=$(curl -s --max-time 20 https://www.githubstatus.com/api/v2/components.json 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown")
    sys.exit(0)
for c in d.get("components", []):
    if c.get("name") == "Actions":
        print(c.get("status") or "unknown")
        sys.exit(0)
print("unknown")' 2>/dev/null || echo unknown)

# Anything other than a clean recovery means keep waiting. An unreadable status
# page is not evidence of recovery.
[ "$status" = "operational" ] || exit 0

# Confirm the deploy is still outstanding before waking anyone.
alias_version=$(AWS_PROFILE=krew-admin AWS_REGION=us-east-1 \
  aws lambda get-alias --function-name krew-edge-upload-crm-staging --name live \
  --query FunctionVersion --output text 2>/dev/null || echo "")

case "$alias_version" in
  ''|*[!0-9]*)
    # Cannot read the alias - say so rather than silently assuming either way.
    : > "$MARKER"
    echo "GitHub Actions recovered; upload-function alias unreadable, check the deploy by hand"
    exit 0
    ;;
esac

if [ "$alias_version" -le 18 ]; then
  : > "$MARKER"
  echo "GitHub Actions recovered (alias still v$alias_version): rerun the Lambda deploy at cd604f1d8 and PR 924's cancelled tests and lambda-typecheck jobs"
fi

exit 0
