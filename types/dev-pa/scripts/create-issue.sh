#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
if ! command -v gh &>/dev/null; then
    json_error "create-issue" "MISSING_DEP" "gh CLI is not installed"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    json_error "create-issue" "AUTH_ERROR" "gh CLI not authenticated"
    exit 1
fi

# ── Constants ────────────────────────────────
ORG="<your-org>"

# ── Args ─────────────────────────────────────
REPO=""
TITLE=""
BODY=""
LABELS=""

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --repo <repo-name> --title <title> [--body <body>] [--label <label>]

Create a GitHub issue in the $ORG organization.

Options:
  --repo   REPO    Repository name (without org prefix, e.g. "tob-app")
  --title  TITLE   Issue title (required)
  --body   BODY    Issue body/description (optional)
  --label  LABEL   Label to add (can be repeated)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --title)
            TITLE="$2"
            shift 2
            ;;
        --body)
            BODY="$2"
            shift 2
            ;;
        --label)
            LABELS="${LABELS:+$LABELS,}$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            json_error "create-issue" "INVALID_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ── Validation ───────────────────────────────
if [[ -z "$REPO" ]]; then
    json_error "create-issue" "MISSING_ARG" "--repo is required"
    exit 1
fi

if [[ -z "$TITLE" ]]; then
    json_error "create-issue" "MISSING_ARG" "--title is required"
    exit 1
fi

# Block repos outside the org (prevent injection via slashes)
if [[ "$REPO" == */* ]]; then
    json_error "create-issue" "ORG_VIOLATION" "Repo must be a plain name (no slashes). Only $ORG repos are allowed."
    exit 1
fi

FULL_REPO="$ORG/$REPO"

# Verify the repo exists and is accessible
if ! gh repo view "$FULL_REPO" --json name &>/dev/null; then
    json_error "create-issue" "REPO_NOT_FOUND" "Repository $FULL_REPO not found or not accessible"
    exit 1
fi

# ── Create issue ─────────────────────────────
GH_ARGS=(issue create --repo "$FULL_REPO" --title "$TITLE")

if [[ -n "$BODY" ]]; then
    GH_ARGS+=(--body "$BODY")
fi

if [[ -n "$LABELS" ]]; then
    GH_ARGS+=(--label "$LABELS")
fi

RESULT=$(gh "${GH_ARGS[@]}" 2>&1) || {
    json_error "create-issue" "GH_ERROR" "Failed to create issue" "$RESULT"
    exit 1
}

# Extract issue number and URL from gh output (URL like https://github.com/org/repo/issues/123)
ISSUE_URL="$RESULT"
ISSUE_NUMBER=$(echo "$ISSUE_URL" | sed 's|.*/||')

json_success "create-issue" "$(jq -n \
    --arg url "$ISSUE_URL" \
    --arg number "$ISSUE_NUMBER" \
    --arg repo "$FULL_REPO" \
    --arg title "$TITLE" \
    '{url: $url, number: ($number | tonumber), repo: $repo, title: $title}')"
