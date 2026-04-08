#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"github-activity","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

if ! command -v gh &>/dev/null; then
    json_error "github-activity" "MISSING_DEP" "gh CLI is not installed"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    json_error "github-activity" "AUTH_ERROR" "gh CLI not authenticated"
    exit 1
fi

# ── Args ─────────────────────────────────────
USER=""
SINCE_HOURS=24
ORG="<your-org>"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            USER="$2"
            shift 2
            ;;
        --since)
            SINCE_HOURS="$2"
            shift 2
            ;;
        --org)
            ORG="$2"
            shift 2
            ;;
        *)
            json_error "github-activity" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$USER" ]]; then
    json_error "github-activity" "MISSING_ARG" "--user USERNAME is required"
    exit 1
fi

# ── Time range ───────────────────────────────
NOW_EPOCH=$(date -u +%s)
SINCE_EPOCH=$(( NOW_EPOCH - SINCE_HOURS * 3600 ))

# macOS date vs GNU date
if date -u -r "$SINCE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' &>/dev/null; then
    SINCE_ISO=$(date -u -r "$SINCE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
    NOW_ISO=$(date -u -r "$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
    SINCE_DATE=$(date -u -r "$SINCE_EPOCH" '+%Y-%m-%d')
else
    SINCE_ISO=$(date -u -d "@$SINCE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
    NOW_ISO=$(date -u -d "@$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
    SINCE_DATE=$(date -u -d "@$SINCE_EPOCH" '+%Y-%m-%d')
fi

log "Fetching GitHub activity for $USER in $ORG since $SINCE_ISO"

# ── Fetch via Search API (supports comma-separated users) ──
IFS=',' read -ra USERS <<< "$USER"

ISSUES_RAW="[]"
COMMITS_RAW="[]"
COMMENTS_RAW="[]"

for u in "${USERS[@]}"; do
    u=$(echo "$u" | xargs)  # trim whitespace
    log "Fetching search results for user: $u"

    # 1. Issues and PRs created by user
    log "  Searching issues/PRs authored by $u"
    USER_ISSUES=$(gh api "search/issues?q=author:${u}+org:${ORG}+created:>=${SINCE_DATE}&per_page=100&sort=created&order=desc" \
        --jq '.items' 2>/dev/null) || {
        log "  Warning: Failed to fetch issues/PRs for $u, skipping"
        USER_ISSUES="[]"
    }
    ISSUES_RAW=$(echo "$ISSUES_RAW"$'\n'"$USER_ISSUES" | jq -s 'flatten')

    # 2. Commits by user
    log "  Searching commits by $u"
    USER_COMMITS=$(gh api "search/commits?q=author:${u}+org:${ORG}+committer-date:>=${SINCE_DATE}&per_page=100&sort=committer-date&order=desc" \
        -H "Accept: application/vnd.github.cloak-preview+json" \
        --jq '.items' 2>/dev/null) || {
        log "  Warning: Failed to fetch commits for $u, skipping"
        USER_COMMITS="[]"
    }
    COMMITS_RAW=$(echo "$COMMITS_RAW"$'\n'"$USER_COMMITS" | jq -s 'flatten')

    # 3. Issues where user commented
    log "  Searching issues commented by $u"
    USER_COMMENTS=$(gh api "search/issues?q=commenter:${u}+org:${ORG}+updated:>=${SINCE_DATE}&per_page=100" \
        --jq '.items' 2>/dev/null) || {
        log "  Warning: Failed to fetch comment activity for $u, skipping"
        USER_COMMENTS="[]"
    }
    COMMENTS_RAW=$(echo "$COMMENTS_RAW"$'\n'"$USER_COMMENTS" | jq -s 'flatten')
done

# ── Fetch comment bodies (parallel) ─────────
COMMENT_TMPDIR=$(mktemp -d)
trap 'rm -rf "$COMMENT_TMPDIR"' EXIT

# Build username list for filtering comment authors
USERNAMES_JSON=$(for u in "${USERS[@]}"; do echo "$u" | xargs; done | jq -R . | jq -s .)

# Extract unique (repo, number) pairs from comment search results
COMMENT_TARGETS=$(printf '%s' "$COMMENTS_RAW" | jq -r \
    '[.[] | {repo: (.repository_url | split("/")[-1]), number: .number}]
     | unique_by("\(.repo)/\(.number)")[]
     | "\(.repo) \(.number)"' 2>/dev/null || true)

COMMENT_BODIES="{}"
if [[ -n "$COMMENT_TARGETS" ]]; then
    BODY_PIDS=()
    MAX_BODY_CONCURRENT=5

    while IFS=' ' read -r repo_name issue_number; do
        [[ -z "$repo_name" ]] && continue

        (
            RAW=$(gh api "repos/${ORG}/${repo_name}/issues/${issue_number}/comments?per_page=100&since=${SINCE_ISO}" 2>/dev/null) || RAW="[]"
            printf '%s' "$RAW" | jq --argjson users "$USERNAMES_JSON" \
                '[.[] | select(.user.login as $l | $users | index($l)) | .body]' \
                > "$COMMENT_TMPDIR/${repo_name}_${issue_number}.json"
        ) &
        BODY_PIDS+=($!)

        if [[ ${#BODY_PIDS[@]} -ge $MAX_BODY_CONCURRENT ]]; then
            for pid in "${BODY_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
            BODY_PIDS=()
        fi
    done <<< "$COMMENT_TARGETS"

    for pid in "${BODY_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

    # Build lookup: { "repo/number": "joined body text" }
    for f in "$COMMENT_TMPDIR"/*.json; do
        [[ -f "$f" ]] || continue
        basename_f=$(basename "$f" .json)
        repo_name="${basename_f%_*}"
        issue_number="${basename_f##*_}"
        key="${repo_name}/${issue_number}"
        body=$(jq -r 'if length > 0 then join("\n---\n") else "" end' "$f" 2>/dev/null || echo "")
        if [[ -n "$body" ]]; then
            COMMENT_BODIES=$(printf '%s' "$COMMENT_BODIES" | jq --arg key "$key" --arg body "$body" '. + {($key): $body}')
        fi
    done
fi

log "Fetched comment bodies for $(printf '%s' "$COMMENT_BODIES" | jq 'length') issues"

# ── Transform and deduplicate ────────────────
RESULT=$(jq -n \
    --arg since "$SINCE_ISO" \
'
input as $issues | input as $commits | input as $comments | input as $bodies |

# Deduplicate issues/PRs by html_url
($issues | [group_by(.html_url)[] | .[0]]) as $uniq_issues |

# Build a set of issue URLs from the author search for excluding from comments
[$uniq_issues[].html_url] as $author_urls |

# Deduplicate comments by html_url, then exclude items already in author search
($comments
    | [group_by(.html_url)[] | .[0]]
    | map(select(.html_url as $url | $author_urls | index($url) | not))
) as $uniq_comments |

# Deduplicate commits by sha
($commits | [group_by(.sha)[] | .[0]]) as $uniq_commits |

# Transform issues/PRs into activity entries
[
    $uniq_issues[] |
    {
        has_pr: (has("pull_request") and .pull_request != null),
        state: .state,
        merged: (.pull_request.merged_at // null),
        repo: (.repository_url | split("/")[-1]),
        title: .title,
        number: .number,
        at: .created_at
    } |
    if .has_pr then
        if .merged != null then
            { type: "pr_merged", repo: .repo, title: .title, number: .number, at: .at }
        elif .state == "open" then
            { type: "pr_opened", repo: .repo, title: .title, number: .number, at: .at }
        else
            { type: "pr_closed", repo: .repo, title: .title, number: .number, at: .at }
        end
    else
        if .state == "open" then
            { type: "issue_opened", repo: .repo, title: .title, number: .number, at: .at }
        else
            { type: "issue_closed", repo: .repo, title: .title, number: .number, at: .at }
        end
    end
] as $issue_activity |

# Transform commits into activity entries
[
    $uniq_commits[] |
    {
        type: "commit",
        repo: (.repository.full_name | split("/")[-1]),
        message: .commit.message,
        sha: (.sha[:7]),
        at: .commit.committer.date
    }
] as $commit_activity |

# Transform comment items into activity entries (with bodies from Phase 2)
[
    $uniq_comments[] |
    (.repository_url | split("/")[-1]) as $repo |
    {
        type: "comment",
        repo: $repo,
        title: .title,
        number: .number,
        at: .updated_at,
        body: ($bodies["\($repo)/\(.number)"] // null)
    }
] as $comment_activity |

# Merge all activity and sort descending by time
($issue_activity + $commit_activity + $comment_activity)
    | sort_by(.at) | reverse
    | . as $activity |

# Build summary counts
{
    summary: {
        total_events: ($activity | length),
        commits: ([$activity[] | select(.type == "commit")] | length),
        prs_opened: ([$activity[] | select(.type == "pr_opened")] | length),
        prs_merged: ([$activity[] | select(.type == "pr_merged")] | length),
        prs_reviewed: 0,
        issues_opened: ([$activity[] | select(.type == "issue_opened")] | length),
        issues_closed: ([$activity[] | select(.type == "issue_closed")] | length),
        comments: ([$activity[] | select(.type == "comment")] | length)
    },
    activity: $activity
}
' <(printf '%s' "$ISSUES_RAW") <(printf '%s' "$COMMITS_RAW") <(printf '%s' "$COMMENTS_RAW") <(printf '%s' "$COMMENT_BODIES"))

# ── Build final output ───────────────────────
DATA=$(echo "$RESULT" | jq \
    --arg user "$USER" \
    --arg org "$ORG" \
    --argjson since_hours "$SINCE_HOURS" \
    --arg period "$SINCE_ISO to $NOW_ISO" \
    '{
        user: $user,
        org: $org,
        since_hours: $since_hours,
        period: $period,
        summary: .summary,
        activity: .activity
    }')

log "Found $(echo "$DATA" | jq '.summary.total_events') events for $USER in $ORG"

json_success "github-activity" "$DATA"
