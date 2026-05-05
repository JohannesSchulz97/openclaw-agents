import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const REGISTRY_PATH =
  process.env.TWENTY_ZOOM_OPTIN || path.join(process.env.HOME || "", ".openclaw", "twenty-zoom-optin.json");
const OPENCLAW_CONFIG_PATH = path.join(process.env.HOME || "", ".openclaw", "openclaw.json");
const SPOOL_ROOT = path.join(os.tmpdir(), "openclaw-twenty-zoom");
const dmChannelCache = new Map();

function asString(value) {
  if (typeof value === "string") {
    return value.trim();
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return "";
}

function asList(value) {
  if (Array.isArray(value)) {
    return value.flatMap((entry) => {
      if (typeof entry === "string") {
        return entry.split(",");
      }
      if (entry && typeof entry === "object") {
        return [
          entry.email,
          entry.userEmail,
          entry.primaryEmail,
          entry.value,
        ].filter(Boolean);
      }
      return [];
    });
  }
  if (typeof value === "string") {
    return value.split(",");
  }
  return [];
}

function normalizeEmail(value) {
  return asString(value).toLowerCase();
}

function uniq(values) {
  return [...new Set(values.filter(Boolean))];
}

function normalizeParticipantNames(value) {
  if (Array.isArray(value)) {
    return value
      .map((entry) => {
        if (typeof entry === "string") {
          return entry.trim();
        }
        if (!entry || typeof entry !== "object") {
          return "";
        }
        return (
          asString(entry.name) ||
          [asString(entry.firstName), asString(entry.lastName)].filter(Boolean).join(" ") ||
          asString(entry.email)
        );
      })
      .filter(Boolean)
      .join(", ");
  }
  return asString(value);
}

function normalizeRecord(payload) {
  const record =
    payload && typeof payload.record === "object" && payload.record !== null
      ? payload.record
      : payload && typeof payload.data === "object" && payload.data !== null
        ? payload.data
        : payload;

  const id =
    asString(record?.id) ||
    asString(record?.recordId) ||
    asString(record?.meetingId) ||
    asString(record?.callId);
  if (!id) {
    throw new Error("Twenty payload missing record id");
  }

  const hostEmail = normalizeEmail(record?.hostEmail);
  const participantEmails = uniq(
    [
      ...asList(record?.participantEmails).map(normalizeEmail),
      ...asList(record?.participants)
        .map((entry) => normalizeEmail(entry?.email || entry?.userEmail || entry?.primaryEmail || entry)),
      hostEmail,
    ].filter(Boolean),
  );

  return {
    id,
    event: asString(payload?.event) || asString(payload?.type) || "twenty.zoom.transcript",
    meeting_topic:
      asString(record?.meetingTopic) ||
      asString(record?.name) ||
      asString(record?.title) ||
      "Zoom Meeting",
    host_email: hostEmail,
    participant_emails: participantEmails,
    participant_names:
      normalizeParticipantNames(record?.participants) ||
      asString(record?.participantNames),
    started_at:
      asString(record?.meetingStartedAt) ||
      asString(record?.meetingStartTime) ||
      asString(record?.startedAt),
    ended_at:
      asString(record?.meetingEndedAt) ||
      asString(record?.meetingEndTime) ||
      asString(record?.endedAt),
    summary_en: asString(record?.summaryEng) || asString(record?.summaryEn),
    summary_de: asString(record?.zusammenfassung) || asString(record?.summaryDe),
    transcript_text:
      asString(record?.transcriptText) ||
      asString(record?.meetingText) ||
      asString(record?.transcript),
    raw_record: record,
  };
}

async function readRegistry() {
  try {
    const raw = await fs.readFile(REGISTRY_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}

function renderTranscript(normalized) {
  return [
    `Meeting: ${normalized.meeting_topic}`,
    `Host: ${normalized.host_email || "-"}`,
    `Start: ${normalized.started_at || "-"}`,
    `End: ${normalized.ended_at || "-"}`,
    `Participants: ${normalized.participant_names || normalized.participant_emails.join(", ") || "-"}`,
    "",
    normalized.transcript_text || "",
  ].join("\n");
}

function renderHeader(normalized) {
  return [
    "*Zoom meeting transcript*",
    `*${normalized.meeting_topic}*`,
    "",
    `Host: ${normalized.host_email || "-"}`,
    `Start: ${normalized.started_at || "-"}`,
    `End: ${normalized.ended_at || "-"}`,
    `Participants: ${normalized.participant_names || normalized.participant_emails.join(", ") || "-"}`,
    "",
    "Replies in this thread: summary plus full transcript file.",
  ].join("\n");
}

async function sendMessage(args) {
  const { stdout } = await execFileAsync("openclaw", ["message", "send", ...args], {
    maxBuffer: 10 * 1024 * 1024,
  });
  return stdout;
}

async function sendTopMessage(slackId, header) {
  const stdout = await sendMessage([
    "--channel",
    "slack",
    "--target",
    `user:${slackId}`,
    "--message",
    header,
    "--json",
  ]);
  const parsed = JSON.parse(stdout);
  const messageId = parsed?.payload?.result?.messageId || parsed?.payload?.messageId || "";
  if (!messageId || messageId === "unknown") {
    throw new Error(`Slack top message missing messageId for ${slackId}`);
  }
  return messageId;
}

async function sendThreadReply(slackId, replyTo, message) {
  await sendMessage([
    "--channel",
    "slack",
    "--target",
    `user:${slackId}`,
    "--reply-to",
    replyTo,
    "--message",
    message,
  ]);
}

async function sendTranscriptFile(slackId, replyTo, transcriptFile) {
  const slackToken = await getSlackBotToken();
  const channelId = await getSlackDmChannelId(slackToken, slackId);
  const content = await fs.readFile(transcriptFile);
  const filename = path.basename(transcriptFile);

  const uploadRequest = await slackJsonRequest(
    slackToken,
    "files.getUploadURLExternal",
    new URLSearchParams({
      filename,
      length: String(content.length),
    }),
    {
      contentType: "application/x-www-form-urlencoded",
    },
  );

  const uploadResponse = await fetch(uploadRequest.upload_url, {
    method: "POST",
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
    },
    body: content,
  });
  if (!uploadResponse.ok) {
    throw new Error(`Slack file upload failed (${uploadResponse.status})`);
  }

  await slackJsonRequest(
    slackToken,
    "files.completeUploadExternal",
    {
      files: [{ id: uploadRequest.file_id, title: filename }],
      channel_id: channelId,
      thread_ts: replyTo,
      initial_comment: "Full transcript",
    },
    {
      contentType: "application/json; charset=utf-8",
    },
  );
}

async function getSlackBotToken() {
  const raw = await fs.readFile(OPENCLAW_CONFIG_PATH, "utf8");
  const parsed = JSON.parse(raw);
  const token = asString(parsed?.channels?.slack?.botToken);
  if (!token) {
    throw new Error("Slack bot token missing from openclaw.json");
  }
  return token;
}

async function getSlackDmChannelId(slackToken, slackId) {
  const cached = dmChannelCache.get(slackId);
  if (cached) {
    return cached;
  }

  const response = await slackJsonRequest(
    slackToken,
    "conversations.open",
    { users: slackId },
    { contentType: "application/json; charset=utf-8" },
  );
  const channelId = asString(response?.channel?.id);
  if (!channelId) {
    throw new Error(`Slack DM channel resolution failed for ${slackId}`);
  }
  dmChannelCache.set(slackId, channelId);
  return channelId;
}

async function slackJsonRequest(slackToken, method, payload, { contentType }) {
  const body =
    contentType === "application/x-www-form-urlencoded"
      ? payload.toString()
      : JSON.stringify(payload);

  const response = await fetch(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${slackToken}`,
      "Content-Type": contentType,
    },
    body,
  });
  if (!response.ok) {
    throw new Error(`Slack API ${method} failed (${response.status})`);
  }

  const parsed = await response.json();
  if (!parsed?.ok) {
    throw new Error(`Slack API ${method} error: ${parsed?.error || "unknown_error"}`);
  }
  return parsed;
}

async function readJsonIfExists(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, "utf8"));
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

async function acquireRecipientState(deliveryRoot, email) {
  const key = crypto.createHash("sha256").update(email).digest("hex");
  const recipientDir = path.join(deliveryRoot, key);
  try {
    await fs.mkdir(recipientDir);
    return {
      recipientDir,
      state: {},
      completed: false,
    };
  } catch (error) {
    if (error && error.code === "EEXIST") {
      const completed = await readJsonIfExists(path.join(recipientDir, "delivery.json"));
      if (completed) {
        return {
          recipientDir,
          state: completed,
          completed: true,
        };
      }

      const inflight = await readJsonIfExists(path.join(recipientDir, "inflight.json"));
      return {
        recipientDir,
        state: inflight || {},
        completed: false,
      };
    }
    throw error;
  }
}

export default async function twentyZoomTransform(ctx) {
  const payload = ctx?.payload && typeof ctx.payload === "object" ? ctx.payload : {};
  const normalized = normalizeRecord(payload);

  await fs.mkdir(SPOOL_ROOT, { recursive: true });
  const recordsRoot = path.join(SPOOL_ROOT, "records");
  const deliveryRoot = path.join(SPOOL_ROOT, "deliveries", normalized.id);
  await fs.mkdir(recordsRoot, { recursive: true });
  await fs.mkdir(deliveryRoot, { recursive: true });

  const normalizedPath = path.join(recordsRoot, `${normalized.id}.json`);
  await fs.writeFile(`${normalizedPath}.tmp`, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
  await fs.rename(`${normalizedPath}.tmp`, normalizedPath);

  const transcriptDir = path.join(SPOOL_ROOT, "transcripts");
  await fs.mkdir(transcriptDir, { recursive: true });
  const transcriptTxtPath = path.join(transcriptDir, `${normalized.id}.txt`);
  await fs.writeFile(transcriptTxtPath, renderTranscript(normalized), "utf8");

  const registry = await readRegistry();
  const recipients = normalized.participant_emails
    .map((email) => ({ email, entry: registry[email] }))
    .filter(({ entry }) => entry && entry.opted_in && asString(entry.slack_id));

  if (recipients.length === 0) {
    return null;
  }

  const header = renderHeader(normalized);
  for (const { email, entry } of recipients) {
    const delivery = await acquireRecipientState(deliveryRoot, email);
    if (delivery.completed) {
      continue;
    }

    const slackId = asString(entry.slack_id);
    const language = asString(entry.summary_lang) || "both";
    const inflightPath = path.join(delivery.recipientDir, "inflight.json");
    const state = {
      email,
      slack_id: slackId,
      summary_lang: language,
      message_id: asString(delivery.state.message_id),
      de_sent: Boolean(delivery.state.de_sent),
      en_sent: Boolean(delivery.state.en_sent),
      file_sent: Boolean(delivery.state.file_sent),
    };

    if (!state.message_id) {
      state.message_id = await sendTopMessage(slackId, header);
      await fs.writeFile(inflightPath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
    }

    if (!state.de_sent && (language === "de" || language === "both") && normalized.summary_de) {
      await sendThreadReply(slackId, state.message_id, `*Zusammenfassung (DE)*\n${normalized.summary_de}`);
      state.de_sent = true;
      await fs.writeFile(inflightPath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
    }
    if (!state.en_sent && (language === "en" || language === "both") && normalized.summary_en) {
      await sendThreadReply(slackId, state.message_id, `*Summary (EN)*\n${normalized.summary_en}`);
      state.en_sent = true;
      await fs.writeFile(inflightPath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
    }

    if (!state.file_sent) {
      await sendTranscriptFile(slackId, state.message_id, transcriptTxtPath);
      state.file_sent = true;
      await fs.writeFile(inflightPath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
    }

    const completedState = {
      ...state,
      delivered_at: new Date().toISOString(),
      record_path: normalizedPath,
      transcript_txt_path: transcriptTxtPath,
      transcript_path: transcriptTxtPath,
    };
    await fs.writeFile(
      path.join(delivery.recipientDir, "delivery.json"),
      `${JSON.stringify(completedState, null, 2)}\n`,
      "utf8",
    );
  }

  return null;
}
