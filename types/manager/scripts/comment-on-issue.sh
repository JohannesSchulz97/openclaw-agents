#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
if ! command -v gh &>/dev/null; then
    json_error "comment-on-issue" "MISSING_DEP" "gh CLI is not installed"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    json_error "comment-on-issue" "AUTH_ERROR" "gh CLI not authenticated"
    exit 1
fi

# ── Constants ────────────────────────────────
ORG="<your-org>"

# ── Args ─────────────────────────────────────
REPO=""
ISSUE_NUMBER=""
BODY=""
AUTHOR=""

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --repo <repo-name> --issue <number> --body <comment> [--author <github-username>]

Add a comment to a GitHub issue in the $ORG organization.

Options:
  --repo   REPO    Repository name (without org prefix, e.g. "tob-app")
  --issue  NUMBER  Issue number (required)
  --body   BODY    Comment text (required)
  --author USER    GitHub username of the person on whose behalf this comment is made
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --issue)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --body)
            BODY="$2"
            shift 2
            ;;
        --author)
            AUTHOR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            json_error "comment-on-issue" "INVALID_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ── Validation ───────────────────────────────
if [[ -z "$REPO" ]]; then
    json_error "comment-on-issue" "MISSING_ARG" "--repo is required"
    exit 1
fi

if [[ -z "$ISSUE_NUMBER" ]]; then
    json_error "comment-on-issue" "MISSING_ARG" "--issue is required"
    exit 1
fi

if [[ -z "$BODY" ]]; then
    json_error "comment-on-issue" "MISSING_ARG" "--body is required"
    exit 1
fi

# Validate issue number is numeric
if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
    json_error "comment-on-issue" "INVALID_ARG" "--issue must be a number"
    exit 1
fi

# Block repos outside the org (prevent injection via slashes)
if [[ "$REPO" == */* ]]; then
    json_error "comment-on-issue" "ORG_VIOLATION" "Repo must be a plain name (no slashes). Only $ORG repos are allowed."
    exit 1
fi

FULL_REPO="$ORG/$REPO"

# Verify the repo exists and is accessible
if ! gh repo view "$FULL_REPO" --json name &>/dev/null; then
    json_error "comment-on-issue" "REPO_NOT_FOUND" "Repository $FULL_REPO not found or not accessible"
    exit 1
fi

# ── Author attribution ──────────────────────────
if [[ -n "$AUTHOR" ]]; then
    BODY="🙋 **On behalf of @${AUTHOR}**

---

${BODY}"
fi

# ── Add comment ─────────────────────────────
RESULT=$(gh issue comment "$ISSUE_NUMBER" --repo "$FULL_REPO" --body "$BODY" 2>&1) || {
    json_error "comment-on-issue" "GH_ERROR" "Failed to comment on issue" "$RESULT"
    exit 1
}

# gh issue comment outputs the comment URL
COMMENT_URL="$RESULT"

json_success "comment-on-issue" "$(jq -n \
    --arg url "$COMMENT_URL" \
    --arg issue "$ISSUE_NUMBER" \
    --arg repo "$FULL_REPO" \
    '{url: $url, issue: ($issue | tonumber), repo: $repo}')"
