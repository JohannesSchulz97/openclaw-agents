#!/usr/bin/env python3
"""dm-pollution-detector.py — Scan DM session JSONL files for transcript pollution.

Detects five pollution types introduced by sessions_send misuse:
  1. cron_injected_user   — user messages without a Slack DM envelope
  2. verbatim_leak        — assistant messages with thinking/retry artifacts
  3. narration_prefix     — assistant messages narrating the inject step
  4. control_token        — raw control tokens in assistant replies
  5. self_inject_loop     — user messages injected as array content (sessions_send trace)

Usage:
  python3 scripts/lib/dm-pollution-detector.py [--agent NAME] [--json]

Options:
  --agent NAME   Scan a single agent only (default: all agents)
  --json         Output raw JSON (default: human-readable summary)
  --help         Show this message

Exit 0: outputs report.
"""
from __future__ import annotations  # Path | None syntax on Python < 3.10

import json
import re
import sys
from pathlib import Path

OPENCLAW_DIR = Path.home() / '.openclaw' / 'agents'

CONTROL_TOKENS = {'NO_REPLY', 'ANNOUNCE_SKIP', 'REPLY_SKIP'}

NARRATION_PREFIXES = re.compile(
    r'^(injecting|inject\b|i am now inject|mechanically inject|step only:|mechanical step|'
    r'before sending.*inject|now inject|sending.*inject)',
    re.IGNORECASE,
)

THINKING_ARTIFACTS = re.compile(
    r'<thinking>|</thinking>|\[Retry after the previous|resolveFallbackRetryPrompt|'
    r'reasoning_content|<\|thinking\|>',
    re.IGNORECASE,
)


def find_dm_session_file(sessions_dir: Path, sessions_file: Path) -> Path | None:
    """Return the JSONL path for the most-recently-updated DM session."""
    try:
        index = json.loads(sessions_file.read_text(encoding='utf-8'))
    except Exception:
        return None

    best_id, best_ts = None, 0
    for key, meta in index.items():
        if 'slack:direct:' not in key:
            continue
        ts = meta.get('updatedAt', 0)
        if ts > best_ts:
            best_ts = ts
            best_id = meta.get('sessionId') or meta.get('id', '')

    if not best_id:
        return None

    plain = sessions_dir / f'{best_id}.jsonl'
    if plain.exists():
        return plain

    # Topic-suffixed variant
    for f in sessions_dir.iterdir():
        if f.name.startswith(f'{best_id}-') and f.suffix == '.jsonl':
            return f

    return None


def scan_session(jsonl_path: Path) -> dict:
    """Scan a JSONL session file and return pollution counts."""
    counts = {
        'cron_injected_user': 0,
        'verbatim_leak': 0,
        'narration_prefix': 0,
        'control_token': 0,
        'self_inject_loop': 0,
        'total_lines': 0,
        'examples': {},
    }

    try:
        lines = jsonl_path.read_text(encoding='utf-8', errors='replace').splitlines()
    except Exception as e:
        counts['error'] = str(e)
        return counts

    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            continue

        if obj.get('type') != 'message':
            continue

        counts['total_lines'] += 1
        msg = obj.get('message', {})
        if not isinstance(msg, dict):
            continue

        role = msg.get('role', '')
        content = msg.get('content', '')

        if role == 'user':
            if isinstance(content, list):
                # Array content = injected via sessions_send (not a real Slack DM)
                counts['self_inject_loop'] += 1
                if 'self_inject_loop' not in counts['examples']:
                    text_parts = [c.get('text', '') for c in content if isinstance(c, dict) and c.get('type') == 'text']
                    counts['examples']['self_inject_loop'] = ' '.join(text_parts)[:120]

            elif isinstance(content, str):
                # User string content that lacks a Slack DM envelope
                if not (content.startswith('Slack DM from') or content.startswith('[Queued messages')):
                    # Skip system messages
                    if not content.startswith('System:'):
                        counts['cron_injected_user'] += 1
                        if 'cron_injected_user' not in counts['examples']:
                            counts['examples']['cron_injected_user'] = content[:120]

        elif role == 'assistant':
            # Collect visible text
            text = ''
            if isinstance(content, list):
                parts = []
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'text':
                        parts.append(c.get('text', ''))
                text = ' '.join(parts)
            elif isinstance(content, str):
                text = content

            text = text.strip()
            if not text:
                continue

            # Strip [[reply_to_current]] prefix before checks
            if text.startswith('[[reply_to_current]]'):
                text = text[len('[[reply_to_current]]'):].strip()

            # Check control tokens
            if text in CONTROL_TOKENS or any(text.startswith(t) for t in CONTROL_TOKENS):
                counts['control_token'] += 1
                if 'control_token' not in counts['examples']:
                    counts['examples']['control_token'] = text[:120]
                continue

            # Check verbatim thinking leaks
            if THINKING_ARTIFACTS.search(text):
                counts['verbatim_leak'] += 1
                if 'verbatim_leak' not in counts['examples']:
                    counts['examples']['verbatim_leak'] = text[:120]
                continue

            # Check narration prefixes
            if NARRATION_PREFIXES.match(text):
                counts['narration_prefix'] += 1
                if 'narration_prefix' not in counts['examples']:
                    counts['examples']['narration_prefix'] = text[:120]

    return counts


def scan_agent(agent_dir: Path) -> dict | None:
    """Scan one agent's DM session. Returns None if no DM session found."""
    sessions_dir = agent_dir / 'sessions'
    sessions_file = sessions_dir / 'sessions.json'

    if not sessions_file.exists():
        return None

    jsonl_path = find_dm_session_file(sessions_dir, sessions_file)
    if not jsonl_path:
        return None

    counts = scan_session(jsonl_path)
    counts['session_file'] = str(jsonl_path.name)
    return counts


def total_pollution(counts: dict) -> int:
    return (
        counts.get('cron_injected_user', 0)
        + counts.get('verbatim_leak', 0)
        + counts.get('narration_prefix', 0)
        + counts.get('control_token', 0)
        + counts.get('self_inject_loop', 0)
    )


def main():
    args = sys.argv[1:]
    target_agent = None
    output_json = False

    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            target_agent = args[i + 1]
            i += 2
        elif args[i] == '--json':
            output_json = True
            i += 1
        elif args[i] in ('--help', '-h'):
            print(__doc__)
            sys.exit(0)
        else:
            i += 1

    if not OPENCLAW_DIR.exists():
        print(json.dumps({'error': f'Agents dir not found: {OPENCLAW_DIR}'}))
        sys.exit(1)

    results = {}
    agent_dirs = sorted(OPENCLAW_DIR.iterdir()) if not target_agent else [OPENCLAW_DIR / target_agent]

    for agent_dir in agent_dirs:
        if not agent_dir.is_dir():
            continue
        agent_name = agent_dir.name
        counts = scan_agent(agent_dir)
        if counts is None:
            continue
        results[agent_name] = counts

    # Summary stats
    polluted = [a for a, c in results.items() if total_pollution(c) > 0]
    summary = {
        'agents_scanned': len(results),
        'agents_polluted': len(polluted),
        'totals': {
            'cron_injected_user': sum(c.get('cron_injected_user', 0) for c in results.values()),
            'verbatim_leak': sum(c.get('verbatim_leak', 0) for c in results.values()),
            'narration_prefix': sum(c.get('narration_prefix', 0) for c in results.values()),
            'control_token': sum(c.get('control_token', 0) for c in results.values()),
            'self_inject_loop': sum(c.get('self_inject_loop', 0) for c in results.values()),
        },
        'per_agent': results,
    }

    if output_json:
        print(json.dumps(summary, indent=2))
        return

    # Human-readable output
    print(f'Agents scanned : {summary["agents_scanned"]}')
    print(f'Agents polluted: {summary["agents_polluted"]}')
    print()
    t = summary['totals']
    print(f'  cron_injected_user : {t["cron_injected_user"]}')
    print(f'  verbatim_leak      : {t["verbatim_leak"]}')
    print(f'  narration_prefix   : {t["narration_prefix"]}')
    print(f'  control_token      : {t["control_token"]}')
    print(f'  self_inject_loop   : {t["self_inject_loop"]}')
    print()
    if polluted:
        print('Polluted agents (worst first):')
        for agent in sorted(polluted, key=lambda a: total_pollution(results[a]), reverse=True):
            c = results[agent]
            print(f'  {agent:20s}  total={total_pollution(c):4d}  '
                  f'cron={c.get("cron_injected_user", 0)}  '
                  f'leak={c.get("verbatim_leak", 0)}  '
                  f'narr={c.get("narration_prefix", 0)}  '
                  f'ctrl={c.get("control_token", 0)}  '
                  f'loop={c.get("self_inject_loop", 0)}')
    else:
        print('No pollution detected.')


if __name__ == '__main__':
    main()
