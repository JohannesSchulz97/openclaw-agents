#!/usr/bin/env bash
# trigger-bootstrap.sh — Trigger bootstrap for an agent using a two-step flow:
#   1. LLM composes a personalized Slack message (using agent context)
#   2. Script sends it deterministically via openclaw message send
#
# Use case: Proactively initiate bootstrap from the admin side when a new agent
# has been created but hasn't had its first interactive session yet.
#
# Usage: scripts/trigger-bootstrap.sh --agent <name> [OPTIONS]
#        scripts/trigger-bootstrap.sh --all [OPTIONS]
# Example: scripts/trigger-bootstrap.sh --agent dev10
#          scripts/trigger-bootstrap.sh --all --audit-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
AGENT_NAME=""
ALL_AGENTS=false
DRY_RUN=false
AUDIT_ONLY=false
COMPOSE_ONLY=false
CONTINUE_MODE=false  # kept for backward compatibility, ignored

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: scripts/trigger-bootstrap.sh --agent NAME [OPTIONS]
       scripts/trigger-bootstrap.sh --all [OPTIONS]

Required (one of):
  --agent NAME         Agent name, kebab-case (e.g., "dev10", "<your-org>")
  --all                Process all agents

Optional:
  --audit-only         Show bootstrap status for each agent without triggering
  --compose-only       Run LLM composition but don't send the message
  --continue           Kept for backward compatibility (ignored)
  --dry-run            Print what would be done without executing anything
  --help               Show this help message
EOF
  exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)        AGENT_NAME="$2"; shift 2 ;;
    --all)          ALL_AGENTS=true; shift ;;
    --audit-only)   AUDIT_ONLY=true; shift ;;
    --compose-only) COMPOSE_ONLY=true; shift ;;
    --continue)     CONTINUE_MODE=true; shift ;;  # ignored, backward compat
    --dry-run)      DRY_RUN=true; shift ;;
    --help)         usage 0 ;;
    *)              echo "Error: Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$AGENT_NAME" && "$ALL_AGENTS" != true ]]; then
  echo "Error: --agent or --all is required" >&2
  usage 1
fi

# ------------------------------------------------------------------------------
# Extract a markdown field value, handling multiline format:
#   - **Field:** value        (same-line)
#   - **Field:**
#     value                   (next-line)
# Returns empty string for template defaults like _(hint text)_ or <placeholder>
# ------------------------------------------------------------------------------
extract_md_field() {
  local file="$1" field="$2"
  local line_num value next_line

  line_num=$(grep -n "^\- \*\*${field}:\*\*" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  [[ -z "$line_num" ]] && echo "" && return

  value=$(sed -n "${line_num}p" "$file" | sed "s/^- \*\*${field}:\*\*[[:space:]]*//" | xargs)

  # If same-line value is empty, check next line
  if [[ -z "$value" ]]; then
    local next_num=$((line_num + 1))
    next_line=$(sed -n "${next_num}p" "$file" | xargs)
    # Accept next line if it's not another field marker or heading
    if [[ -n "$next_line" && "$next_line" != "- **"* && "$next_line" != "#"* ]]; then
      value="$next_line"
    fi
  fi

  # Treat template defaults as empty
  # Patterns: _(hint text)_, <placeholder>
  if [[ "$value" =~ ^_\(.+\)_$ ]] || [[ "$value" =~ ^\<.+\>$ ]]; then
    value=""
  fi

  echo "$value"
}

# ------------------------------------------------------------------------------
# Gap detection: determine what bootstrap info is missing for an agent
# Returns: NOT_STARTED | MINIMAL | PARTIAL | COMPLETE
# Prints missing items to stdout (one per line) before the status line.
# ------------------------------------------------------------------------------
audit_agent() {
  local agent_name="$1"
  local agent_dir="$HOME/.openclaw/agents/$agent_name"
  local missing=()

  # Skip non-agent directories (e.g., tech-manager, main)
  if [[ ! -f "$agent_dir/BOOTSTRAP.md" ]]; then
    echo "SKIP"
    return
  fi

  # Already bootstrapped?
  if [[ -f "$agent_dir/.BOOTSTRAP.md.done" ]]; then
    echo "COMPLETE"
    return
  fi

  # Check IDENTITY.md fields individually
  local id_name id_creature id_vibe id_emoji
  id_name=$(extract_md_field "$agent_dir/IDENTITY.md" "Name")
  id_creature=$(extract_md_field "$agent_dir/IDENTITY.md" "Creature")
  id_vibe=$(extract_md_field "$agent_dir/IDENTITY.md" "Vibe")
  id_emoji=$(extract_md_field "$agent_dir/IDENTITY.md" "Emoji")

  local id_missing=()
  [[ -z "$id_name" ]] && id_missing+=("name")
  [[ -z "$id_creature" ]] && id_missing+=("creature")
  [[ -z "$id_vibe" ]] && id_missing+=("vibe")
  [[ -z "$id_emoji" ]] && id_missing+=("emoji")

  if [[ ${#id_missing[@]} -gt 0 ]]; then
    missing+=("identity (${id_missing[*]})")
  fi

  # Check USER.md fields individually
  local u_name u_call u_tz
  u_name=$(extract_md_field "$agent_dir/USER.md" "Name")
  u_call=$(extract_md_field "$agent_dir/USER.md" "What to call them")
  u_tz=$(extract_md_field "$agent_dir/USER.md" "Timezone")

  local user_missing=()
  [[ -z "$u_name" ]] && user_missing+=("name")
  [[ -z "$u_call" ]] && user_missing+=("what to call them")
  [[ -z "$u_tz" ]] && user_missing+=("timezone")

  if [[ ${#user_missing[@]} -gt 0 ]]; then
    missing+=("user info (${user_missing[*]})")
  fi

  # Check work schedule
  local has_schedule=false
  if [[ -f "$agent_dir/memory/work-schedule.json" ]] || [[ -f "$agent_dir/work-schedule.json" ]]; then
    has_schedule=true
  fi
  if [[ "$has_schedule" != true ]]; then
    missing+=("work schedule (timezone, working hours)")
  fi

  # Determine status
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "COMPLETE"
  elif [[ ${#missing[@]} -ge 2 && " ${missing[*]} " == *"identity"* ]]; then
    for item in "${missing[@]}"; do echo "  - $item"; done
    echo "NOT_STARTED"
  elif [[ ${#missing[@]} -ge 2 ]]; then
    for item in "${missing[@]}"; do echo "  - $item"; done
    echo "MINIMAL"
  else
    for item in "${missing[@]}"; do echo "  - $item"; done
    echo "PARTIAL"
  fi
}

# ------------------------------------------------------------------------------
# Build compose prompt based on bootstrap gap status
# ------------------------------------------------------------------------------
build_compose_prompt() {
  local status="$1"
  local missing_items="$2"

  case "$status" in
    NOT_STARTED)
      echo "You are about to message your developer on Slack for the first time. Read your IDENTITY.md and BOOTSTRAP.md. Compose a warm, casual introductory message. Keep it short — just introduce yourself and start a conversation. Output ONLY the message text, nothing else. No markdown formatting, no code blocks, no explanation."
      ;;
    MINIMAL)
      echo "You need to collect some missing information from your developer. You're missing: ${missing_items}. Compose a friendly Slack message asking for these things. Keep it conversational and short. Output ONLY the message text, nothing else. No markdown formatting, no code blocks, no explanation."
      ;;
    PARTIAL)
      echo "You need to collect some remaining information from your developer. You're missing: ${missing_items}. Compose a short, friendly Slack message asking for these specific things. Keep it conversational. Output ONLY the message text, nothing else. No markdown formatting, no code blocks, no explanation."
      ;;
    *)
      echo ""
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Process a single agent: audit, compose, send
# ------------------------------------------------------------------------------
process_agent() {
  local agent_name="$1"
  local agent_dir="$HOME/.openclaw/agents/$agent_name"

  # Validate agent exists
  if [[ ! -d "$agent_dir" ]]; then
    echo "[$agent_name] Error: Agent directory not found: $agent_dir" >&2
    return 1
  fi

  # Run audit
  local audit_output
  audit_output=$(audit_agent "$agent_name")
  local status
  status=$(echo "$audit_output" | tail -1)
  local total_lines
  total_lines=$(echo "$audit_output" | wc -l | tr -d ' ')
  local missing_lines=""
  if [[ "$total_lines" -gt 1 ]]; then
    missing_lines=$(echo "$audit_output" | sed '$d')
  fi
  local missing_flat=""
  if [[ -n "$missing_lines" ]]; then
    missing_flat=$(echo "$missing_lines" | sed 's/^  - //' | paste -sd', ' -)
  fi

  # Audit-only mode: just print status
  if [[ "$AUDIT_ONLY" == true ]]; then
    echo "[$agent_name] Status: $status"
    if [[ -n "$missing_lines" ]]; then
      echo "$missing_lines"
    fi
    return 0
  fi

  # Skip agents that don't need bootstrap
  if [[ "$status" == "SKIP" ]]; then
    echo "[$agent_name] Skipping (not a bootstrappable agent)"
    return 0
  fi
  if [[ "$status" == "COMPLETE" ]]; then
    echo "[$agent_name] Already bootstrapped, skipping."
    return 0
  fi

  # Build compose prompt
  local compose_prompt
  compose_prompt=$(build_compose_prompt "$status" "$missing_flat")

  if [[ -z "$compose_prompt" ]]; then
    echo "[$agent_name] Error: Could not determine compose prompt for status '$status'" >&2
    return 1
  fi

  # Get Slack ID
  local slack_id
  slack_id=$(grep "Slack User ID:" "$agent_dir/IDENTITY.md" | sed 's/.*Slack User ID:[* ]*//' | tr -d '[:space:]')
  if [[ -z "$slack_id" ]]; then
    echo "[$agent_name] Error: Could not find Slack User ID in IDENTITY.md" >&2
    return 1
  fi

  # Dry-run mode
  if [[ "$DRY_RUN" == true ]]; then
    echo "[$agent_name] Status: $status"
    echo "[$agent_name] Would compose with prompt: \"${compose_prompt:0:80}...\""
    echo "[$agent_name] Would send to $slack_id"
    return 0
  fi

  # Step 1: LLM composes the message
  echo "[$agent_name] Composing message..."
  local result
  result=$(openclaw agent \
    --agent "$agent_name" \
    --session-id "agent:${agent_name}:main" \
    --message "$compose_prompt" \
    --json \
    --timeout 120 \
    2>/dev/null) || true

  local composed_msg
  composed_msg=$(echo "$result" | jq -r '.result.payloads[0].text // empty' 2>/dev/null)

  if [[ -z "$composed_msg" ]]; then
    echo "[$agent_name] Error: LLM returned empty response. Skipping." >&2
    return 1
  fi

  echo "[$agent_name] Composed: \"${composed_msg:0:80}...\""

  # Compose-only mode: stop here
  if [[ "$COMPOSE_ONLY" == true ]]; then
    echo "[$agent_name] Full message:"
    echo "$composed_msg"
    return 0
  fi

  # Step 2: Send deterministically
  echo "[$agent_name] Sending to $slack_id..."
  if openclaw message send \
    --channel slack \
    --target "user:${slack_id}" \
    --message "$composed_msg" \
    --agent "$agent_name"; then
    echo "[$agent_name] Sent successfully."
  else
    echo "[$agent_name] Error: Failed to send message." >&2
    return 1
  fi

  # Step 3: Inject context into main session so agent knows what happened
  echo "[$agent_name] Injecting follow-up context into main session..."
  openclaw agent \
    --agent "$agent_name" \
    --session-id "agent:${agent_name}:main" \
    --message "SYSTEM NOTE: You just sent a Slack DM to your developer (${slack_id}) asking about: ${missing_flat}. When they reply, update the appropriate files: IDENTITY.md for identity info, USER.md for developer info, memory/work-schedule.json for work schedule. Do NOT send another message — just wait for their reply." \
    --json \
    --timeout 60 \
    2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
if [[ "$ALL_AGENTS" == true ]]; then
  for agent_dir in "$HOME/.openclaw/agents"/*/; do
    agent_name=$(basename "$agent_dir")
    process_agent "$agent_name" || true
  done
else
  process_agent "$AGENT_NAME"
fi
