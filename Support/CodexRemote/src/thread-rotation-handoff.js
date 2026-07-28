import fs from "node:fs";

const DEFAULT_MAX_BYTES = 16 * 1024 * 1024;
const DEFAULT_MAX_ENTRIES = 12;
const DEFAULT_MAX_CHARS = 6000;
const ENTRY_MAX_CHARS = 600;

export function buildThreadRotationHandoff({
  statePath = "",
  previousThreadId = "",
  maxBytes = DEFAULT_MAX_BYTES,
  maxEntries = DEFAULT_MAX_ENTRIES,
  maxChars = DEFAULT_MAX_CHARS,
  now = () => Date.now(),
} = {}) {
  const entries = recentConversationEntries({ statePath, maxBytes, maxEntries });
  if (entries.length === 0) return "";
  const lines = [
    "Thread continuation handoff",
    "",
    "This is an automatic Voice Relay Codex thread rotation. Treat this as carryover context, not as a new user request. Continue obeying the current configured authority sources and the latest real user message.",
    previousThreadId ? `Previous thread: ${previousThreadId}` : "",
    `Created at: ${new Date(now()).toISOString()}`,
    "",
    "Recent conversation carryover:",
    ...entries.map((entry) => `- ${entry.role}: ${entry.text}`),
    "",
    "Internal completion requirement: reply exactly HANDOFF_STORED.",
  ].filter(Boolean);
  return truncateText(lines.join("\n"), normalizePositiveNumber(maxChars, DEFAULT_MAX_CHARS));
}

export function recentConversationEntries({
  statePath = "",
  maxBytes = DEFAULT_MAX_BYTES,
  maxEntries = DEFAULT_MAX_ENTRIES,
} = {}) {
  const sessionFile = sessionFileFromRelayState(statePath);
  if (!sessionFile) return [];
  const text = readFileTail(sessionFile, normalizePositiveNumber(maxBytes, DEFAULT_MAX_BYTES));
  const entries = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    for (const conversationEntry of extractConversationEntries(entry)) {
      const last = entries.at(-1);
      if (last?.role === conversationEntry.role && last?.text === conversationEntry.text) {
        continue;
      }
      entries.push(conversationEntry);
    }
  }
  return selectRecentEntries(entries, normalizePositiveNumber(maxEntries, DEFAULT_MAX_ENTRIES));
}

function sessionFileFromRelayState(statePath) {
  try {
    if (!statePath || !fs.existsSync(statePath)) return "";
    const parsed = JSON.parse(fs.readFileSync(statePath, "utf8"));
    const sessionFile = typeof parsed?.sessionFile === "string" ? parsed.sessionFile : "";
    if (!sessionFile || !fs.existsSync(sessionFile)) return "";
    if (!fs.statSync(sessionFile).isFile()) return "";
    return sessionFile;
  } catch {
    return "";
  }
}

function readFileTail(filePath, maxBytes) {
  try {
    const stat = fs.statSync(filePath);
    const length = Math.min(stat.size, maxBytes);
    const start = stat.size - length;
    const buffer = Buffer.allocUnsafe(length);
    const fd = fs.openSync(filePath, "r");
    try {
      fs.readSync(fd, buffer, 0, length, start);
    } finally {
      fs.closeSync(fd);
    }
    let text = buffer.toString("utf8");
    if (start > 0) {
      const newline = text.search(/\r?\n/);
      text = newline >= 0 ? text.slice(newline + 1) : "";
    }
    return text;
  } catch {
    return "";
  }
}

function extractConversationEntries(entry) {
  if (entry?.type === "compacted" && Array.isArray(entry?.payload?.replacement_history)) {
    return entry.payload.replacement_history
      .map((message) => extractMessageConversationEntry(message))
      .filter(Boolean);
  }
  const conversationEntry = extractConversationEntry(entry);
  return conversationEntry ? [conversationEntry] : [];
}

function extractConversationEntry(entry) {
  const payload = entry?.payload;
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "user"
  ) {
    return extractMessageConversationEntry(payload);
  }
  if (entry?.type === "event_msg" && payload?.type === "user_message") {
    const text = normalizeConversationText(extractUserMessageText(payload.message));
    return text ? { role: "User", text } : null;
  }
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "assistant"
  ) {
    const phase = String(payload.phase || "assistant");
    if (!["assistant", "commentary", "final_answer"].includes(phase)) return null;
    return extractMessageConversationEntry(payload);
  }
  return null;
}

function extractMessageConversationEntry(message) {
  if (message?.type !== "message") return null;
  if (message?.role === "user") {
    const text = normalizeConversationText(extractUserMessageText(extractMessageText(message)));
    return text ? { role: "User", text } : null;
  }
  if (message?.role === "assistant") {
    const text = normalizeConversationText(extractMessageText(message));
    return text ? { role: "Assistant", text } : null;
  }
  return null;
}

function selectRecentEntries(entries, limit) {
  if (entries.length <= limit) return entries;
  const recent = entries.slice(-limit);
  if (recent.some((entry) => entry.role === "User")) return recent;
  const latestUser = entries.findLast((entry) => entry.role === "User");
  if (!latestUser) return recent;
  if (limit <= 1) return [latestUser];
  return [latestUser, ...entries.slice(-(limit - 1))];
}

function extractMessageText(payload) {
  if (typeof payload?.content === "string") return payload.content;
  if (Array.isArray(payload?.content)) {
    return payload.content
      .map((item) => item?.text || item?.output_text || item?.input_text || "")
      .join("\n")
      .trim();
  }
  if (typeof payload?.message === "string") return payload.message;
  return "";
}

function extractUserMessageText(value) {
  let text = String(value || "");
  const incomingMarker = text.lastIndexOf("# Incoming Message");
  if (incomingMarker >= 0) {
    const afterIncoming = text.slice(incomingMarker);
    const explicitBody = afterIncoming.match(
      /(?:^|\n)# Message Text\r?\n\r?\n([\s\S]*)$/,
    );
    const legacyBody = afterIncoming.match(
      /(?:^|\n)iMessage reply context:[^\n]*\r?\n\r?\n([\s\S]*)$/i,
    );
    if (explicitBody) text = explicitBody[1];
    else if (legacyBody) text = legacyBody[1];
    else {
      const blankLine = afterIncoming.search(/\r?\n\r?\n/);
      if (blankLine >= 0) text = afterIncoming.slice(blankLine).trim();
    }
  }
  return text;
}

function normalizeConversationText(value) {
  return truncateText(
    String(value || "")
      .replace(/<oai-mem-citation>[\s\S]*?<\/oai-mem-citation>/g, "")
      .replace(/\[voice_relay_request_id:\s*[^\]]+\]\s*/g, "")
      .replace(/\s+/g, " ")
      .trim(),
    ENTRY_MAX_CHARS,
  );
}

function truncateText(value, maxChars) {
  const text = String(value || "").trim();
  if (!text || text.length <= maxChars) return text;
  return `${text.slice(0, Math.max(0, maxChars - 1)).trim()}...`;
}

function normalizePositiveNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}
