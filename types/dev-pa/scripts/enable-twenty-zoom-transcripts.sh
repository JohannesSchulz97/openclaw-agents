#!/usr/bin/env bash
# Add or remove a developer in the Twenty Zoom transcript opt-in registry.
# Registry is a single host-local JSON file shared by all agents.
#
# Usage:
#   enable-twenty-zoom-transcripts.sh --agent NAME --email EMAIL --slack-id ID [--lang en|de|both]
#   enable-twenty-zoom-transcripts.sh --email EMAIL --unenroll

set -euo pipefail

REGISTRY="${TWENTY_ZOOM_OPTIN:-$HOME/.openclaw/twenty-zoom-optin.json}"

usage() {
  cat >&2 <<EOF
Usage:
  $0 --agent NAME --email EMAIL --slack-id ID [--lang en|de|both]
  $0 --email EMAIL --unenroll
EOF
  exit 1
}

AGENT=""
EMAIL=""
SLACK_ID=""
LANG="both"
UNENROLL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)    AGENT="$2"; shift 2 ;;
    --email)    EMAIL="$2"; shift 2 ;;
    --slack-id) SLACK_ID="$2"; shift 2 ;;
    --lang)     LANG="$2"; shift 2 ;;
    --unenroll) UNENROLL=1; shift ;;
    -h|--help)  usage ;;
    *)          usage ;;
  esac
done

[[ -z "$EMAIL" ]] && usage
[[ "$LANG" =~ ^(en|de|both)$ ]] || { echo "ERR: --lang must be en, de, or both" >&2; exit 1; }
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "ERR: --email must look like an email address" >&2; exit 1; }

mkdir -p "$(dirname "$REGISTRY")"
[[ -f "$REGISTRY" ]] || echo "{}" > "$REGISTRY"

if (( UNENROLL )); then
  python3 - "$REGISTRY" "$EMAIL" <<'PY'
import json, sys
p, email = sys.argv[1], sys.argv[2].lower()
r = json.load(open(p))
if email in r:
    r.pop(email)
    json.dump(r, open(p, 'w'), indent=2, sort_keys=True)
    open(p, 'a').write("\n")
    print(f"Unenrolled {email}")
else:
    print(f"{email} was not enrolled (no-op)")
PY
  exit 0
fi

[[ -z "$AGENT" || -z "$SLACK_ID" ]] && usage

python3 - "$REGISTRY" "$EMAIL" "$AGENT" "$SLACK_ID" "$LANG" <<'PY'
import json, sys, datetime
p, email, agent, slack_id, lang = sys.argv[1:]
email = email.lower()
r = json.load(open(p))
r[email] = {
    "agent": agent,
    "slack_id": slack_id,
    "summary_lang": lang,
    "opted_in": True,
    "opted_in_at": datetime.datetime.utcnow().isoformat() + "Z",
}
json.dump(r, open(p, 'w'), indent=2, sort_keys=True)
open(p, 'a').write("\n")
print(f"Enrolled {email} -> agent={agent} slack={slack_id} lang={lang}")
PY
