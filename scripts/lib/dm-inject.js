#!/usr/bin/env node
// dm-inject.js — Append an assistant message to a target session JSONL.
//
// Replaces sessions_send for the DM-mirror use case. No agent turn is triggered,
// no ping-pong, no Slack delivery — pure transcript append.
//
// Usage:
//   node scripts/lib/dm-inject.js \
//     --session-key "agent:<name>:slack:direct:<slack-id>" \
//     --message "<text>" \
//     [--idempotency-key <key>]
//
// Exit 0: prints {"messageId":"<uuid>"}
// Exit 1: prints {"error":"<msg>"}
//
// JSONL shape matches OpenClaw's delivery-mirror path:
//   role=assistant, provider=openclaw, model=delivery-mirror, api=openai-responses

'use strict';

const { readFileSync, appendFileSync, existsSync, readdirSync, createReadStream } = require('node:fs');
const { homedir } = require('node:os');
const { join } = require('node:path');
const { randomUUID } = require('node:crypto');
const { createInterface } = require('node:readline');

function die(msg) {
  process.stdout.write(JSON.stringify({ error: msg }) + '\n');
  process.exit(1);
}

// Parse CLI args
const args = process.argv.slice(2);
let sessionKey = null;
let message = null;
let idempotencyKey = null;

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--session-key':     sessionKey     = args[++i]; break;
    case '--message':         message        = args[++i]; break;
    case '--idempotency-key': idempotencyKey = args[++i]; break;
    default:
      // allow unknown flags without dying
  }
}

if (!sessionKey) die('--session-key is required');
if (message === null || message === undefined) die('--message is required');

// Extract agent name from session key: "agent:<name>:..."
const keyMatch = sessionKey.match(/^agent:([^:]+):/);
if (!keyMatch) die(`Cannot extract agent name from session key: ${sessionKey}`);
const agentName = keyMatch[1];

// Resolve sessions dir
const sessionsDir = join(homedir(), '.openclaw', 'agents', agentName, 'sessions');
const sessionsFile = join(sessionsDir, 'sessions.json');

if (!existsSync(sessionsFile)) {
  die(`sessions.json not found: ${sessionsFile}`);
}

// Load sessions.json and find the session ID for this key
let sessionsIndex;
try {
  sessionsIndex = JSON.parse(readFileSync(sessionsFile, 'utf8'));
} catch (e) {
  die(`Failed to parse sessions.json: ${e.message}`);
}

const sessionMeta = sessionsIndex[sessionKey];
if (!sessionMeta) {
  die(`Session key not found in sessions.json: ${sessionKey}`);
}

const sessionId = sessionMeta.sessionId || sessionMeta.id;
if (!sessionId) {
  die(`No sessionId in metadata for key: ${sessionKey}`);
}

// Resolve session JSONL file — handles plain and topic-suffixed filenames
let sessionFile = null;
const plain = join(sessionsDir, `${sessionId}.jsonl`);
if (existsSync(plain)) {
  sessionFile = plain;
} else {
  const files = readdirSync(sessionsDir).filter(
    f => f.startsWith(`${sessionId}-`) && f.endsWith('.jsonl')
  );
  if (files.length > 0) {
    sessionFile = join(sessionsDir, files[0]);
  }
}

if (!sessionFile) {
  die(`Session JSONL file not found for sessionId: ${sessionId}`);
}

// Idempotency check: scan existing lines for matching idempotencyKey, then append
(async () => {
  if (idempotencyKey) {
    const rl = createInterface({
      input: createReadStream(sessionFile, { encoding: 'utf8' }),
      crlfDelay: Infinity,
    });
    for await (const line of rl) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj.idempotencyKey === idempotencyKey) {
          const existingId = obj.id || (obj.message && obj.message.id) || idempotencyKey;
          process.stdout.write(JSON.stringify({ messageId: existingId, cached: true }) + '\n');
          process.exit(0);
        }
      } catch {
        // skip malformed lines
      }
    }
  }

  // Build the JSONL line (delivery-mirror shape)
  const msgId = randomUUID();
  const entry = {
    type: 'message',
    id: msgId,
    timestamp: new Date().toISOString(),
    ...(idempotencyKey ? { idempotencyKey } : {}),
    message: {
      id: msgId,
      role: 'assistant',
      provider: 'openclaw',
      model: 'delivery-mirror',
      api: 'openai-responses',
      content: [{ type: 'text', text: message }],
    },
  };

  appendFileSync(sessionFile, JSON.stringify(entry) + '\n', { encoding: 'utf8' });
  process.stdout.write(JSON.stringify({ messageId: msgId }) + '\n');
})().catch(err => die(err.message));
