#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"check-updates","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ─────────────────────────────────────
parse_quiet_flag "$@"
set -- ${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}

# ── Helper: truncate string ──────────────────
truncate() {
    local text="$1" max="${2:-2000}"
    if [[ ${#text} -gt $max ]]; then
        printf '%s...' "${text:0:$max}"
    else
        printf '%s' "$text"
    fi
}

# ── Helper: check a single component ─────────
# Args: name display_name current_cmd latest_cmd notes_cmd
# Outputs a JSON object for the component
check_component() {
    local name="$1" display_name="$2"
    local current latest release_notes="" update_available="false"

    # Get current version
    current=$(eval "$3" 2>/dev/null) || current=""
    if [[ -z "$current" ]]; then
        current="unknown"
    fi

    # Get latest version
    latest=$(eval "$4" 2>/dev/null) || latest=""
    if [[ -z "$latest" ]]; then
        latest="unknown"
    fi

    # Determine if update is available
    if [[ "$current" != "unknown" && "$latest" != "unknown" && "$current" != "$latest" ]]; then
        update_available="true"
        # Fetch release notes
        release_notes=$(eval "$5" 2>/dev/null) || release_notes=""
        release_notes=$(truncate "$release_notes" 2000)
    fi

    # Note errors
    if [[ "$current" == "unknown" || "$latest" == "unknown" ]]; then
        release_notes="Error: could not determine ${current:+latest}${latest:+current} version"
        if [[ "$current" == "unknown" && "$latest" == "unknown" ]]; then
            release_notes="Error: could not determine current or latest version"
        fi
    fi

    jq -n \
        --arg name "$name" \
        --arg display_name "$display_name" \
        --arg current "$current" \
        --arg latest "$latest" \
        --argjson update_available "$update_available" \
        --arg release_notes "$release_notes" \
        '{
            name: $name,
            display_name: $display_name,
            current: $current,
            latest: $latest,
            update_available: $update_available,
            release_notes: $release_notes
        }'
}

# ── Check components ─────────────────────────
[[ "$QUIET" != "true" ]] && log "Checking OpenClaw version..."
OPENCLAW_JSON=$(check_component \
    "openclaw" \
    "OpenClaw" \
    "openclaw --version | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+'" \
    "npm view openclaw version" \
    "gh release view \"v\$(npm view openclaw version)\" --repo anthropics/openclaw --json body --jq .body 2>/dev/null"
)

[[ "$QUIET" != "true" ]] && log "Checking lossless-claw version..."
LOSSLESS_JSON=$(check_component \
    "lossless-claw" \
    "Lossless Claw" \
    "openclaw plugins inspect lossless-claw 2>/dev/null | grep -E '^Version:' | awk '{print \$2}'" \
    "npm view @martian-engineering/lossless-claw version" \
    "npm info @martian-engineering/lossless-claw --json 2>/dev/null | jq -r '.description // .readme // \"No release notes available\"'"
)

[[ "$QUIET" != "true" ]] && log "Checking QMD version..."
QMD_JSON=$(check_component \
    "qmd" \
    "QMD" \
    "qmd --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'" \
    "npm view @tobilu/qmd version" \
    "gh release view \"v\$(npm view @tobilu/qmd version)\" --repo tobi/qmd --json body --jq .body 2>/dev/null"
)

# ── Build output ─────────────────────────────
COMPONENTS=$(jq -n \
    --argjson oc "$OPENCLAW_JSON" \
    --argjson lc "$LOSSLESS_JSON" \
    --argjson qmd "$QMD_JSON" \
    '[$oc, $lc, $qmd]'
)

UPDATES_COUNT=$(echo "$COMPONENTS" | jq '[.[] | select(.update_available == true)] | length')

DATA=$(jq -n \
    --argjson components "$COMPONENTS" \
    --argjson updates_available "$UPDATES_COUNT" \
    '{
        components: $components,
        updates_available: $updates_available
    }'
)

[[ "$QUIET" != "true" ]] && log "Update check complete: $UPDATES_COUNT update(s) available"

json_success "check-updates" "$DATA"
