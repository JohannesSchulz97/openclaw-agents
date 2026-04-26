#!/usr/bin/env bash
# cron-utils.sh — Shared library for cron job management in jobs-config.json.
# Sourced by create-agent.sh and remove-agent.sh.
#
# Functions:
#   check_dependencies   — verify jq is installed
#   generate_uuid        — produce a new UUID v4
#   add_cron_job         — append a job entry to the cron config (DEPRECATED)
#   add_cron_jobs        — add 3 check-in + 1 summary job to the cron config
#   remove_cron_job      — delete a job entry by agentId

set -euo pipefail

# --------------------------------------------------------------------------- #
# Source guard — prevent direct execution
# --------------------------------------------------------------------------- #
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: cron-utils.sh is a library and must be sourced, not executed directly." >&2
    echo "Usage: source \"\$(dirname \"\$0\")/lib/cron-utils.sh\"" >&2
    exit 1
fi

# Source schedule-utils for compute_checkin_times, build_cron_expr, validate_timezone
source "${BASH_SOURCE[0]%/*}/schedule-utils.sh"

# --------------------------------------------------------------------------- #
# check_dependencies — verify required tools are available
# --------------------------------------------------------------------------- #
check_dependencies() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed." >&2
        echo "Install it with:" >&2
        echo "  macOS:  brew install jq" >&2
        echo "  Ubuntu: sudo apt-get install jq" >&2
        echo "  Arch:   sudo pacman -S jq" >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
# generate_uuid — produce a UUID, using the best available method
# Note: The config id field is informational only. apply-cron.sh matches
# jobs by agentId, not by id. The gateway assigns and owns job IDs.
# --------------------------------------------------------------------------- #
generate_uuid() {
    # Prefer uuidgen (macOS, most Linux)
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return
    fi

    # Fallback: kernel random UUID (Linux)
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi

    # Last resort: construct from /dev/urandom
    local hex
    hex=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    # Format as 8-4-4-4-12 and set version 4 / variant bits
    printf '%s-%s-4%s-%s-%s\n' \
        "${hex:0:8}" \
        "${hex:8:4}" \
        "${hex:13:3}" \
        "$(printf '%02x' $(( 0x${hex:16:2} & 0x3f | 0x80 )))${hex:18:2}" \
        "${hex:20:12}"
}

# --------------------------------------------------------------------------- #
# DEPRECATED: Use add_cron_jobs (plural) instead. This function creates a single
# every-2h check-in job. Retained for backward compatibility during migration.
#
# add_cron_job — add a new job to the cron config file
#
# Usage: add_cron_job <cron_file> <agent_name> <display_name> <slack_id> <model>
#
# Arguments:
#   cron_file    — path to jobs-config.json
#   agent_name   — agent identifier (e.g. "dev1")
#   display_name — human-readable name (e.g. "dev1")
#   slack_id     — Slack user ID (e.g. "<slack-id>")
#   model        — model identifier (e.g. "glm-5")
# --------------------------------------------------------------------------- #
add_cron_job() {
    local cron_file="${1:?Usage: add_cron_job <cron_file> <agent_name> <display_name> <slack_id> <model>}"
    local agent_name="${2:?Missing agent_name}"
    local display_name="${3:?Missing display_name}"
    local slack_id="${4:?Missing slack_id}"
    local model="${5:?Missing model}"

    if [[ ! -f "$cron_file" ]]; then
        echo "Error: Cron file not found: $cron_file" >&2
        return 1
    fi

    local job_id
    job_id=$(generate_uuid)

    # Build the payload message with substituted values
    local message
    message="Run scripts/poll-check.sh. Parse the JSON output.\n\nIf data.due == 0, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.due == 1:\n1. Read USER.md to find the developer's name, context, and GitHub username(s) from the ## GitHub section. Also read IDENTITY.md to find your target Slack user ID.\n2. If one or more GitHub usernames are configured in USER.md, run scripts/github-activity.sh --user <github-usernames> --since 24 (comma-separated if multiple). Parse the output for recent PRs, commits, reviews, and issues. If no GitHub username is configured, or the script fails or returns no data, skip this step and proceed without it -- GitHub activity is enrichment, not a blocker.\nIMPORTANT: Only use GitHub activity data from the script output above. Do NOT independently query GitHub APIs, the Events API, or any other GitHub endpoints. Do NOT reference any repositories outside <your-org> organization. Personal repos are strictly off-limits.\n3. Review your conversation history and memory for recent context about what the developer has been working on.\n4. Compose a check-in message that:\n   a. References specific GitHub activity or recent conversation context\n   b. Asks what they have been working on since the last check-in\n   c. Explicitly asks them to share any work NOT visible in GitHub -- meetings, design discussions, code reviews, research, architecture planning, pairing sessions, mentoring, documentation, or any other contributions\n   d. Asks about current blockers or anything they need help with\n   e. Is warm and specific, not generic. Avoid canned phrases like 'just checking in'.\n5. Send the message using this exact command: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is the target user's Slack ID from your identity/config files.\n6. After sending, update memory/poll-state.json: set awaiting_response to true."

    # Build the job object and append it to the jobs array
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg id "$job_id" \
       --arg agentId "$agent_name" \
       --arg name "${display_name} Check-in" \
       --arg message "$message" \
       --arg sessionKey "agent:${agent_name}:cron:checkin" \
       '.jobs += [{
            id: $id,
            agentId: $agentId,
            name: $name,
            enabled: true,
            schedule: {
                kind: "every",
                everyMs: 7200000
            },
            sessionTarget: "session:main",
            wakeMode: "now",
            payload: {
                kind: "agentTurn",
                message: $message,
                timeoutSeconds: 300,
                thinking: "medium"
            },
            sessionKey: $sessionKey,
            delivery: {
                mode: "none"
            }
        }]' "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Added cron job '${display_name} Check-in' for agent '${agent_name}' (id: ${job_id})"
}

# --------------------------------------------------------------------------- #
# add_cron_jobs — add the full dev-pa cron bundle for an agent.
#
# Creates five jobs:
#   - morning check-in       (cron: start_hour:00 in <timezone>)
#   - midday check-in        (cron: midpoint of work window in <timezone>)
#   - evening check-in       (cron: end_hour-1:30 in <timezone>)
#   - evening work report    (cron: 19:00 daily in <timezone> — runs every day
#                             regardless of <works_weekends> so ad-hoc weekend
#                             work is captured; the script self-suppresses the
#                             DM on zero-activity days, issue #310)
#   - daily summary          (cron: 22:00 in <timezone>, weekdays unless
#                             <works_weekends> is true)
#
# Usage: add_cron_jobs <cron_file> <agent_name> <display_name> <model> <start_hour> <end_hour> <timezone> <works_weekends> <slack_id>
# --------------------------------------------------------------------------- #
add_cron_jobs() {
    local cron_file="$1" agent_name="$2" display_name="$3" model="$4"
    local start_hour="${5:-9}" end_hour="${6:-18}" timezone="${7:-UTC}" works_weekends="${8:-false}"
    local slack_id="${9:-}"

    # Use isolated sessions to prevent cron output from polluting DM sessions (#276)
    local session_target="isolated"

    if [[ ! -f "$cron_file" ]]; then
        echo "Error: Cron file not found: $cron_file" >&2
        return 1
    fi

    # Validate timezone
    if ! validate_timezone "$timezone"; then
        echo "Error: Invalid timezone: $timezone" >&2
        return 1
    fi

    # Compute check-in times
    compute_checkin_times "$start_hour" "$end_hour"

    # Build cron expressions
    local morning_cron midday_cron evening_cron
    morning_cron=$(build_cron_expr "$MORNING_HOUR" "$MORNING_MIN" "$works_weekends")
    midday_cron=$(build_cron_expr "$MIDDAY_HOUR" "$MIDDAY_MIN" "$works_weekends")
    evening_cron=$(build_cron_expr "$EVENING_HOUR" "$EVENING_MIN" "$works_weekends")

    # Bootstrap preamble — shared across all check-in types
    local bootstrap_preamble
    bootstrap_preamble="Run scripts/bootstrap-check.sh prepare. If data.bootstrap_complete == false, read IDENTITY.md for your Slack user ID, ask the developer for the missing fields in data.missing_required via openclaw message send, then stop.\n\n"

    # Build dm-inject instruction with agent-specific DM session key (#366).
    local slack_id_lower
    slack_id_lower=$(echo "$slack_id" | tr '[:upper:]' '[:lower:]')
    local sessions_send_instruction=""
    if [[ -n "$slack_id" ]]; then
        sessions_send_instruction="\\n\\nBefore sending, inject the message into the DM session:\\nnode scripts/lib/dm-inject.js --session-key \"agent:${agent_name}:slack:direct:${slack_id_lower}\" --message \"<your composed message>\"\\n\\n"
    fi

    # Create 3 jobs with type-specific payloads
    for type in morning midday evening; do
        local job_id
        job_id=$(generate_uuid)
        local cron_expr name_suffix checkin_message message

        case $type in
            morning)
                cron_expr="$morning_cron"
                name_suffix="Morning Check-in"
                checkin_message="Read IDENTITY.md for your Slack user ID. Run scripts/lib/dm-digest.sh and parse the JSON for recent conversation context. Send a context-aware morning check-in following the Cron Job Responses guidance in AGENTS.md. ${sessions_send_instruction}Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\""
                ;;
            midday)
                cron_expr="$midday_cron"
                name_suffix="Midday Check-in"
                checkin_message="Read IDENTITY.md for your Slack user ID. Run scripts/lib/dm-digest.sh and parse the JSON for recent conversation context. Send a context-aware midday check-in following the Cron Job Responses guidance in AGENTS.md. ${sessions_send_instruction}Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\""
                ;;
            evening)
                cron_expr="$evening_cron"
                name_suffix="Evening Check-in"
                checkin_message="Read IDENTITY.md for your Slack user ID. Run scripts/lib/dm-digest.sh and parse the JSON for recent conversation context. Send a context-aware evening check-in following the Cron Job Responses guidance in AGENTS.md. ${sessions_send_instruction}Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\""
                ;;
        esac

        # Combine bootstrap preamble with type-specific check-in
        message="${bootstrap_preamble}${checkin_message}"

        # Append to jobs-config.json using jq
        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN

        jq --arg id "$job_id" \
           --arg agentId "$agent_name" \
           --arg name "${display_name} ${name_suffix}" \
           --arg message "$message" \
           --arg cronExpr "$cron_expr" \
           --arg tz "$timezone" \
           --arg sessionKey "agent:${agent_name}:cron:${type}" \
           --arg sessionTarget "$session_target" \
           '.jobs += [{
                id: $id,
                agentId: $agentId,
                name: $name,
                enabled: true,
                schedule: {
                    kind: "cron",
                    cronExpr: $cronExpr,
                    tz: $tz
                },
                sessionTarget: $sessionTarget,
                wakeMode: "now",
                payload: {
                    kind: "agentTurn",
                    message: $message,
                    timeoutSeconds: 300,
                    thinking: "medium"
                },
                sessionKey: $sessionKey,
                delivery: {
                    mode: "none"
                }
            }]' "$cron_file" > "$tmp_file"

        mv "$tmp_file" "$cron_file"
        echo "Added cron job '${display_name} ${name_suffix}' for agent '${agent_name}' (id: ${job_id})"
    done

    # Add daily summary job — runs at 20:00 CET (after evening check-in, before tech-manager report)
    local summary_id summary_message
    summary_id=$(generate_uuid)
    summary_message="Run scripts/daily-summary.sh prepare and parse the JSON. If success is false, stop.\n\nIf data.no_activity is true, stop here. Do NOT write a file, do NOT call finalize. Output only 'NO_ACTIVITY'.\n\n1. Summarize today's conversations using data.conversation_digest (messages since data.last_summary_epoch; 0 means full day). Follow data.template for section format.\n2. Write to data.output_file. Stay factual — use the developer's own words, do not fabricate.\n3. Run scripts/daily-summary.sh finalize.\n\nDo not modify any state files yourself."

    local summary_cron_expr
    summary_cron_expr="0 22 * * *"

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg id "$summary_id" \
       --arg agentId "$agent_name" \
       --arg name "${display_name} Daily Summary" \
       --arg message "$summary_message" \
       --arg cronExpr "$summary_cron_expr" \
       --arg tz "$timezone" \
       --arg sessionKey "agent:${agent_name}:cron:summary" \
       --arg sessionTarget "$session_target" \
       '.jobs += [{
            id: $id,
            agentId: $agentId,
            name: $name,
            enabled: true,
            schedule: {
                kind: "cron",
                cronExpr: $cronExpr,
                tz: $tz
            },
            sessionTarget: $sessionTarget,
            wakeMode: "now",
            payload: {
                kind: "agentTurn",
                message: $message,
                timeoutSeconds: 300,
                thinking: "medium"
            },
            sessionKey: $sessionKey,
            delivery: {
                mode: "none"
            }
        }]' "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Added cron job '${display_name} Daily Summary' for agent '${agent_name}' (id: ${summary_id})"

    # ═════════════════════════════════════════════════════════════════════
    # Evening Work Report — runs 19:00 daily in agent's timezone.
    #
    # Daily regardless of works_weekends (#310): developers occasionally do
    # ad-hoc weekend work and we don't want to lose it. The script detects
    # "no activity" via work-report.sh and tells the model to exit early
    # without writing a file or DM, so idle weekends stay silent.
    # ═════════════════════════════════════════════════════════════════════
    local report_id
    report_id=$(generate_uuid)
    local report_slack_id_lower
    report_slack_id_lower=$(echo "$slack_id" | tr '[:upper:]' '[:lower:]')

    local report_sessions_send_line=""
    if [[ -n "$slack_id" ]]; then
        report_sessions_send_line="\\n\\nBefore sending, inject the report into the DM session:\\nnode scripts/lib/dm-inject.js --session-key \"agent:${agent_name}:slack:direct:${report_slack_id_lower}\" --message \"<report>\"\\n\\n"
    fi

    local report_message
    report_message="Run scripts/work-report.sh prepare and parse the JSON output.\\nIf success is false, stop and output the error.\\n\\nIf data.no_activity is true, stop here. Do NOT compose a report, do NOT write a file, do NOT call finalize, do NOT send a DM. The prepare step already recorded that the cron fired (report-state.last_run_epoch). Output only 'NO_ACTIVITY'.\\n\\nOtherwise, compose an end-of-day work report using data.github_activity and data.conversation_digest. Format richly using bold, italic, \`backticks\` for technical terms (script names, config keys, file paths), and linked PR/issue references.\\n\\nUse these sections:\\n\\n## Work Report — <data.date>\\n\\n### ✅ What was accomplished\\nEach distinct item (feature, fix, investigation, review, discussion) gets its OWN bullet with a detailed explanation of what and why. NEVER combine multiple PRs or features into a single bullet point. Include both GitHub activity and work from data.conversation_digest. Link PRs and issues using full markdown links to <your-org> org.\\n\\nExample bullet:\\n- **Preserved LCM plugin config** across \`plugins install --force\` — added two-layer save/restore in \`update-openclaw.sh\` to back up \`openclaw.json\` and launchd plist env vars before reinstall ([#257](https://github.com/<your-org>/openclaw-agents/pull/257), fixes [#256](https://github.com/<your-org>/openclaw-agents/issues/256))\\n\\n### ⚠️ Challenges\\nBlockers, complexity, dependencies, things that need attention. Write \\\"None\\\" if clear.\\n\\n### 📋 Next steps\\nOpen PRs, carry-over items, plans for the next working day. Only write \\\"Not discussed\\\" if there is genuinely no indication of what comes next.\\n\\nRules:\\n- One bullet per distinct item. Each PR or piece of work is separate.\\n- Each bullet should explain what was done and why — the reader should understand the change without looking up the PR.\\n- Be factual. Do NOT fabricate PR titles, issue numbers, or feature names.\\n- If data.file_exists is true, mention \\\"Updated report\\\" in the DM.\\n\\nSave the report to data.output_file.\\nRun scripts/work-report.sh finalize.\\n\\nIf data.dm is true, send the report to your developer via Slack DM.${report_sessions_send_line}Convert the markdown formatting to Slack equivalents — keep all rich formatting (bold, italic, inline code, emojis, links) but use Slack syntax:\\n\\nSTEP 3 — POST INDIVIDUAL REPORTS AS THREAD REPLIES\\n\\nFor each developer with report_status == \\\"active\\\" ONLY (skip idle and cron_missed developers):\\n- Post one short top-level marker message to data.work_reports_channel_id with the form: `EOD report <data.date> <@SLACK_ID>`\\n- Capture the returned Slack message id from that parent message (the ts / Message ID)\\n- Post the full report EXACTLY as written in data.report as a reply to that parent using `--reply-to <message_id>`\\n- Prefix the thread reply body with <@SLACK_ID>\\n\\nopenclaw message send --channel slack --target channel:{data.work_reports_channel_id} --message \\\"EOD report <data.date> <@SLACK_ID>\\\"\\nopenclaw message send --channel slack --target channel:{data.work_reports_channel_id} --reply-to <message_id> --message \\\"<@SLACK_ID>\\n<report>\\\"\\n\\nBrief pause (1-2 seconds) between developers to avoid Slack rate limiting.\\n\\nNOTE: To re-run during testing, add --force: bash scripts/evening-report.sh --force\\nTo target a different channel for testing: bash scripts/evening-report.sh --force --channel <CHANNEL_ID> --work-reports-channel <CHANNEL_ID>\\n\\nopenclaw message send --channel slack --target user:<data.slack_user_id> --message \\\"<report>\\\"\\nIf data.dm is false, skip the DM — only write the report to data.output_file."

    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg id "$report_id" \
       --arg agentId "$agent_name" \
       --arg name "${display_name} Evening Work Report" \
       --arg message "$report_message" \
       --arg tz "$timezone" \
       --arg sessionKey "agent:${agent_name}:cron:report" \
       --arg sessionTarget "$session_target" \
       '.jobs += [{
            id: $id,
            agentId: $agentId,
            name: $name,
            enabled: true,
            schedule: {
                kind: "cron",
                cronExpr: "0 19 * * *",
                tz: $tz
            },
            sessionTarget: $sessionTarget,
            wakeMode: "now",
            payload: {
                kind: "agentTurn",
                message: $message,
                timeoutSeconds: 300,
                thinking: "medium",
                model: "google/gemini-3.1-pro-preview"
            },
            sessionKey: $sessionKey,
            delivery: {
                mode: "none"
            }
        }]' "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Added cron job '${display_name} Evening Work Report' for agent '${agent_name}' (id: ${report_id})"
}

# --------------------------------------------------------------------------- #
# remove_cron_job — remove a job by agentId from the cron config file
#
# Usage: remove_cron_job <cron_file> <agent_name>
# --------------------------------------------------------------------------- #
remove_cron_job() {
    local cron_file="${1:?Usage: remove_cron_job <cron_file> <agent_name>}"
    local agent_name="${2:?Missing agent_name}"

    if [[ ! -f "$cron_file" ]]; then
        echo "Error: Cron file not found: $cron_file" >&2
        return 1
    fi

    # Check if a matching job exists
    local count
    count=$(jq --arg agentId "$agent_name" '[.jobs[] | select(.agentId == $agentId)] | length' "$cron_file")

    if [[ "$count" -eq 0 ]]; then
        echo "Warning: No cron job found for agent '${agent_name}'" >&2
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg agentId "$agent_name" \
       '.jobs = [.jobs[] | select(.agentId != $agentId)]' \
       "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Removed ${count} cron job(s) for agent '${agent_name}'"
}
