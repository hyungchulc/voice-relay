import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const SESSIONS_DIR = path.join(os.homedir(), ".codex", "sessions");
const THREAD_SESSION_FILE_CACHE = new Map();
const DEFAULT_INITIAL_SCAN_BYTES = 16 * 1024 * 1024;
const INITIAL_SCAN_BYTES = Number(
  process.env.CODEX_SESSION_INITIAL_SCAN_BYTES || DEFAULT_INITIAL_SCAN_BYTES,
);
const FINAL_ANSWER_SETTLE_MS = Number(
  process.env.CODEX_FINAL_ANSWER_SETTLE_MS || 1500,
);
const TURN_ABORT_GRACE_MS = Number(
  process.env.CODEX_TURN_ABORT_GRACE_MS || 5000,
);
const SESSION_META_SCAN_BYTES = 256 * 1024;

export class AcceptedSteerResponseRevisionFence {
  constructor() {
    this.acceptedRevision = 0;
    this.acceptedOffset = null;
    this.requestToken = null;
    this.rootSessionId = null;
    this.turnId = null;
    this.sessionFile = null;
  }

  accept({
    acceptedOffset,
    requestToken = "",
    rootSessionId = "",
    turnId = "",
    sessionFile = "",
  } = {}) {
    const normalizedOffset = Number(acceptedOffset);
    const normalizedRootSessionId = normalizeSessionId(rootSessionId);
    const normalizedTurnId = normalizeSessionId(turnId);
    const normalizedSessionFile = normalizeSessionFile(sessionFile);
    if (!Number.isSafeInteger(normalizedOffset) || normalizedOffset < 0) {
      throw new Error("Accepted steer revision requires a stable session offset");
    }
    if (
      !normalizedRootSessionId ||
      !normalizedTurnId ||
      !normalizedSessionFile
    ) {
      throw new Error(
        "Accepted steer revision requires stable root, turn, and session-file scope",
      );
    }
    if (
      Number.isSafeInteger(this.acceptedOffset) &&
      normalizedOffset <= this.acceptedOffset
    ) {
      throw new Error("Accepted steer revisions must advance the session offset");
    }
    if (
      this.acceptedRevision > 0 &&
      (normalizedRootSessionId !== this.rootSessionId ||
        normalizedTurnId !== this.turnId ||
        normalizedSessionFile !== this.sessionFile)
    ) {
      throw new Error("Accepted steer revisions must remain in one response scope");
    }
    this.acceptedRevision += 1;
    this.acceptedOffset = normalizedOffset;
    this.requestToken = String(requestToken || "").trim() || null;
    this.rootSessionId = normalizedRootSessionId;
    this.turnId = normalizedTurnId;
    this.sessionFile = normalizedSessionFile;
    return this.snapshot();
  }

  snapshot() {
    return Object.freeze({
      acceptedRevision: this.acceptedRevision,
      acceptedOffset: this.acceptedOffset,
      requestToken: this.requestToken,
      rootSessionId: this.rootSessionId,
      turnId: this.turnId,
      sessionFile: this.sessionFile,
    });
  }
}

export async function waitForCodexReply({
  requestId,
  expectedRootSessionId = "",
  sinceMs,
  timeoutMs,
}) {
  const deadline = Date.now() + timeoutMs;
  const scanner = new SessionReplyScanner(requestId, { expectedRootSessionId });
  while (Date.now() < deadline) {
    const files = listRecentSessionFiles(sinceMs - 60_000);
    for (const file of files) {
      const hit = scanner.scanFile(file);
      if (hit) return hit;
    }
    await sleep(1000);
  }
  throw new Error(`Timed out waiting for Codex reply for ${requestId}`);
}

export async function waitForCodexReplies({
  requestId,
  expectedRootSessionId = "",
  sinceMs,
  timeoutMs,
}) {
  const deadline = Date.now() + timeoutMs;
  const scanner = new SessionReplyScanner(requestId, { expectedRootSessionId });
  while (Date.now() < deadline) {
    const files = listRecentSessionFiles(sinceMs - 60_000);
    for (const file of files) {
      const hit = scanner.scanFile(file);
      if (
        hit?.complete &&
        hit.pendingImageGenerationCount === 0 &&
        hit.messages.length > 0
      ) {
        return hit;
      }
    }
    await sleep(1000);
  }
  throw new Error(`Timed out waiting for Codex replies for ${requestId}`);
}

export async function streamCodexReplies({
  requestId,
  expectedRootSessionId = "",
  sinceMs,
  timeoutMs,
  onTaskStarted = null,
  onAccepted = null,
  onMessage,
  getAcceptedSteerRevision = null,
  signal = null,
  finalAnswerSettleMs = FINAL_ANSWER_SETTLE_MS,
  turnAbortGraceMs = TURN_ABORT_GRACE_MS,
  listFiles = listRecentSessionFiles,
  now = () => Date.now(),
  sleepFn = sleep,
}) {
  let deadline = now() + timeoutMs;
  const scanner = new SessionReplyScanner(requestId, {
    expectedRootSessionId,
    includeLifecycleEvents: true,
    includeTaskStartedEvents: typeof onTaskStarted === "function",
    includeRequestEvents: typeof onAccepted === "function",
    includeActivityEvents: true,
    sinceMs,
  });
  const sent = new Set();
  const pendingFinals = [];
  const lastActivityOffsets = new Map();
  let lastHit = null;
  let settleCandidate = null;
  let completedResponseRevision = 0;
  let appliedResponseRevision = 0;
  let taskStartedNotified = false;
  let acceptanceNotified = false;
  let pinnedSessionFile = null;

  const reconcileAcceptedResponseRevision = () => {
    const nextRevision = acceptedSteerRevisionSnapshot(
      getAcceptedSteerRevision,
    );
    if (nextRevision.acceptedRevision < appliedResponseRevision) {
      throw new Error("Accepted steer response revision regressed");
    }
    if (nextRevision.acceptedRevision > appliedResponseRevision) {
      rebasePendingFinalsForAcceptedRevision(pendingFinals, nextRevision);
      settleCandidate = null;
      appliedResponseRevision = nextRevision.acceptedRevision;
    }
    return nextRevision;
  };

  while (now() < deadline) {
    throwIfReplyStreamAborted(signal, requestId);
    const pinnedFileForPoll = pinnedSessionFile;
    const files = pinnedFileForPoll
      ? [pinnedFileForPoll]
      : listFiles(sinceMs - 60_000);
    let rediscoverSessionFile = false;
    for (const file of files) {
      let hit;
      try {
        hit = scanner.scanFile(file);
      } catch (error) {
        if (
          pinnedFileForPoll === file &&
          isSessionFileReadUnavailableError(error)
        ) {
          pinnedSessionFile = null;
          rediscoverSessionFile = true;
          break;
        }
        throw error;
      }
      if (!hit) continue;
      if (!pinnedSessionFile && shouldPinSessionFile(hit)) {
        pinnedSessionFile = file;
      }
      lastHit = hit;
      if (Number.isSafeInteger(hit.activityOffset)) {
        const previousOffset = lastActivityOffsets.get(file);
        if (previousOffset === undefined || hit.activityOffset > previousOffset) {
          lastActivityOffsets.set(file, hit.activityOffset);
          deadline = now() + timeoutMs;
        }
      }
      if (hit.abortedAfterRequest) {
        throw new Error(`Codex turn aborted before final reply for ${requestId}`);
      }
      if (
        hit.abortedBeforeRequest &&
        !hit.seenRequest &&
        hit.abortedAtMs !== null &&
        now() - hit.abortedAtMs >= turnAbortGraceMs
      ) {
        throw new Error(`Codex turn aborted before request was logged for ${requestId}`);
      }
      if (
        !taskStartedNotified &&
        hit.taskStartedTurnId &&
        Number.isSafeInteger(hit.taskStartedOffset)
      ) {
        taskStartedNotified = true;
        await onTaskStarted?.({
          source: "session_log_task_started",
          sessionFile: file,
          rootSessionId: hit.ownerSessionId,
          turnId: hit.taskStartedTurnId,
          requestToken: requestId,
          taskStartedOffset: hit.taskStartedOffset,
          taskStartedAt: hit.taskStartedAt,
        });
        deadline = now() + timeoutMs;
      }
      if (
        !acceptanceNotified &&
        hit.seenRequest &&
        hit.turnId &&
        Number.isSafeInteger(hit.acceptedOffset)
      ) {
        acceptanceNotified = true;
        await onAccepted?.({
          source: "session_log",
          sessionFile: file,
          rootSessionId: hit.ownerSessionId,
          turnId: hit.turnId,
          requestToken: requestId,
          acceptedOffset: hit.acceptedOffset,
        });
        deadline = now() + timeoutMs;
      }
      let responseRevision = reconcileAcceptedResponseRevision();
      for (const message of hit.messages) {
        const key = message.id || `${message.phase}:${message.text}`;
        if (message.phase === "final_answer") {
          responseRevision = reconcileAcceptedResponseRevision();
          if (
            finalDispositionForRevision(message, file, responseRevision) !==
            "current"
          ) {
            continue;
          }
          const normalizedText = normalizeFinalText(message.text);
          if (
            !normalizedText ||
            pendingFinals.some(
              (entry) =>
                entry.key === key || entry.normalizedText === normalizedText,
            )
          ) {
            continue;
          }
          const pendingFinal = {
            key,
            normalizedText,
            message: messageWithFile(message, file),
            seenAt: now(),
            finalOffset: Number.isSafeInteger(message.finalOffset)
              ? message.finalOffset
              : null,
            responseRevision: responseRevision.acceptedRevision,
          };
          pendingFinals.push(pendingFinal);
          settleCandidate = pendingFinal;
          continue;
        }
        if (sent.has(key)) continue;
        sent.add(key);
        await onMessage(messageWithFile(message, file));
        deadline = now() + timeoutMs;
      }
      responseRevision = reconcileAcceptedResponseRevision();
      const unresolvedResponseRevision =
        responseRevision.acceptedRevision > completedResponseRevision;
      if (
        hit.complete &&
        hit.pendingImageGenerationCount === 0 &&
        (!unresolvedResponseRevision ||
          authoritativeCompletionForRevision(hit, responseRevision))
      ) {
        if (unresolvedResponseRevision) {
          completedResponseRevision = responseRevision.acceptedRevision;
        }
        const terminalFinal = combinedPendingFinal(pendingFinals);
        if (terminalFinal && !sent.has(terminalFinal.key)) {
          sent.add(terminalFinal.key);
          await onMessage(terminalFinal.message);
        }
        return {
          ...hit,
          messages: terminalMessages(hit.messages, terminalFinal?.message),
          completedBy: "task_complete",
          completedResponseRevision,
        };
      }
      if (unresolvedResponseRevision) {
        settleCandidate = null;
        continue;
      }
      if (
        settleCandidate &&
        Number.isSafeInteger(hit.activityOffset) &&
        Number.isSafeInteger(settleCandidate.finalOffset) &&
        hit.activityOffset > settleCandidate.finalOffset
      ) {
        settleCandidate = null;
      }
    }
    if (rediscoverSessionFile) continue;
    if (lastHit) reconcileAcceptedResponseRevision();
    if (
      settleCandidate &&
      lastHit?.pendingImageGenerationCount === 0 &&
      now() - settleCandidate.seenAt >= finalAnswerSettleMs &&
      lastHit
    ) {
      const terminalFinal = combinedPendingFinal(pendingFinals);
      if (terminalFinal && !sent.has(terminalFinal.key)) {
        sent.add(terminalFinal.key);
        await onMessage(terminalFinal.message);
      }
      return {
        ...lastHit,
        messages: terminalMessages(lastHit.messages, terminalFinal?.message),
        complete: true,
        completedAt: lastHit.completedAt || new Date(now()).toISOString(),
        completedBy: "final_answer_settle",
        completedResponseRevision,
      };
    }
    await sleepFn(500);
  }

  throw new Error(
    lastHit
      ? `Timed out waiting for final Codex reply for ${requestId}`
      : `Timed out waiting for Codex replies for ${requestId}`,
  );
}

function acceptedSteerRevisionSnapshot(getAcceptedSteerRevision) {
  if (typeof getAcceptedSteerRevision !== "function") {
    return {
      acceptedRevision: 0,
      acceptedOffset: null,
      requestToken: null,
      rootSessionId: null,
      turnId: null,
      sessionFile: null,
    };
  }
  const snapshot = getAcceptedSteerRevision() || {};
  const acceptedRevision = Number(snapshot.acceptedRevision);
  const acceptedOffset = Number(snapshot.acceptedOffset);
  const normalizedRevision =
    Number.isSafeInteger(acceptedRevision) && acceptedRevision > 0
      ? acceptedRevision
      : 0;
  const revision = {
    acceptedRevision: normalizedRevision,
    acceptedOffset:
      Number.isSafeInteger(acceptedOffset) && acceptedOffset >= 0
        ? acceptedOffset
        : null,
    requestToken: String(snapshot.requestToken || "").trim() || null,
    rootSessionId: normalizeSessionId(snapshot.rootSessionId) || null,
    turnId: normalizeSessionId(snapshot.turnId) || null,
    sessionFile: normalizeSessionFile(snapshot.sessionFile),
  };
  if (
    normalizedRevision > 0 &&
    (!Number.isSafeInteger(revision.acceptedOffset) ||
      !revision.rootSessionId ||
      !revision.turnId ||
      !revision.sessionFile)
  ) {
    throw new Error("Accepted steer response revision has incomplete scope");
  }
  return revision;
}

function authoritativeCompletionForRevision(hit, responseRevision) {
  return (
    Number.isSafeInteger(responseRevision.acceptedOffset) &&
    Number.isSafeInteger(hit.completedOffset) &&
    hit.completedOffset > responseRevision.acceptedOffset &&
    hit.ownerSessionId === responseRevision.rootSessionId &&
    hit.turnId === responseRevision.turnId &&
    normalizeSessionFile(hit.file) === responseRevision.sessionFile
  );
}

function rebasePendingFinalsForAcceptedRevision(
  pendingFinals,
  responseRevision,
) {
  const retained = [];
  for (const entry of pendingFinals) {
    const disposition = finalDispositionForRevision(
      entry.message,
      entry.message.file,
      responseRevision,
    );
    if (disposition !== "current") continue;
    retained.push({
      ...entry,
      responseRevision: responseRevision.acceptedRevision,
    });
  }
  pendingFinals.splice(0, pendingFinals.length, ...retained);
}

function finalDispositionForRevision(message, file, responseRevision) {
  if (responseRevision.acceptedRevision === 0) return "current";
  if (
    message.ownerSessionId !== responseRevision.rootSessionId ||
    message.turnId !== responseRevision.turnId ||
    normalizeSessionFile(file) !== responseRevision.sessionFile ||
    !Number.isSafeInteger(message.finalOffset)
  ) {
    return "unbound";
  }
  return message.finalOffset <= responseRevision.acceptedOffset
    ? "prior"
    : "current";
}

function normalizeSessionFile(value) {
  const normalized = String(value || "").trim();
  return normalized ? path.resolve(normalized) : null;
}

function normalizeFinalText(value) {
  return String(value || "")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .trim();
}

function combinedPendingFinal(pendingFinals) {
  if (!Array.isArray(pendingFinals) || pendingFinals.length === 0) return null;
  const latest = pendingFinals.at(-1);
  if (
    pendingFinals.some(
      (entry) => entry.responseRevision !== latest.responseRevision,
    )
  ) {
    throw new Error("Pending finals crossed an accepted response revision");
  }
  return {
    key: `combined_final:${pendingFinals.map((entry) => entry.key).join("|")}`,
    message: {
      ...latest.message,
      text: pendingFinals
        .map((entry) => normalizeFinalText(entry.message.text))
        .filter(Boolean)
        .join("\n\n"),
    },
  };
}

function terminalMessages(messages, terminalFinal) {
  const nonFinalMessages = (messages || []).filter(
    (message) => message.phase !== "final_answer",
  );
  return terminalFinal
    ? [...nonFinalMessages, terminalFinal]
    : nonFinalMessages;
}

function shouldPinSessionFile(hit) {
  if (!hit) return false;
  if (hit.seenRequest || hit.messages?.length > 0) return true;
  if (Number.isSafeInteger(hit.taskStartedOffset)) return true;
  return Boolean(hit.ownerSessionId && !hit.abortedBeforeRequest);
}

function isSessionFileReadUnavailableError(error) {
  return ["EACCES", "EIO", "ENOENT", "ENOTDIR", "EPERM", "ESTALE"].includes(
    error?.code,
  );
}

function throwIfReplyStreamAborted(signal, requestId) {
  if (!signal?.aborted) return;
  const error = new Error(`Codex reply stream aborted for ${requestId}`);
  error.code = "CODEX_REPLY_STREAM_ABORTED";
  throw error;
}

export function listRecentSessionFiles(sinceMs) {
  const files = [];
  walk(SESSIONS_DIR, files);
  return files
    .map((file) => {
      const stat = fs.statSync(file);
      return { file, mtimeMs: stat.mtimeMs };
    })
    .filter(({ mtimeMs }) => mtimeMs >= sinceMs)
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .map(({ file }) => file);
}

export function findSessionFileForThreadId(
  threadId,
  { sessionsDir = SESSIONS_DIR } = {},
) {
  const normalizedThreadId = normalizeSessionId(threadId);
  if (!normalizedThreadId || !/^[0-9a-f-]+$/i.test(normalizedThreadId)) return null;
  const cacheKey = `${sessionsDir}\0${normalizedThreadId}`;
  const cached = THREAD_SESSION_FILE_CACHE.get(cacheKey);
  if (cached && fs.existsSync(cached)) return cached;
  const matches = fs.globSync(
    path.join(sessionsDir, "**", `*-${normalizedThreadId}.jsonl`),
  );
  if (matches.length === 0) return null;
  const sessionFile = matches
    .map((file) => ({ file, mtimeMs: fs.statSync(file).mtimeMs }))
    .sort((a, b) => b.mtimeMs - a.mtimeMs)[0].file;
  THREAD_SESSION_FILE_CACHE.set(cacheKey, sessionFile);
  return sessionFile;
}

export function normalizeSessionId(value) {
  return String(value || "").trim().replace(/^local:/, "");
}

export function inspectSessionFileBinding(file) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    return null;
  }
  if (stat.size <= 0) return null;

  const length = Math.min(stat.size, SESSION_META_SCAN_BYTES);
  const buffer = Buffer.allocUnsafe(length);
  const fd = fs.openSync(file, "r");
  try {
    fs.readSync(fd, buffer, 0, length, 0);
  } finally {
    fs.closeSync(fd);
  }

  for (const line of buffer.toString("utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    const binding = sessionBindingFromEntry(entry);
    if (binding) return binding;
  }
  return null;
}

export function createSessionLogTaskScopedFollowupEvidence({
  sessionsDir = SESSIONS_DIR,
  pollMs = 100,
  now = () => Date.now(),
  sleepFn = sleep,
} = {}) {
  return {
    async capture({ rootSessionId, turnId = "" } = {}) {
      const captureStartedAt = now();
      const expectedRootSessionId = normalizeSessionId(rootSessionId);
      if (!expectedRootSessionId) return null;
      const sessionFile = findSessionFileForThreadId(expectedRootSessionId, {
        sessionsDir,
      });
      const sessionFileResolvedAt = now();
      if (!sessionFile) return null;
      const binding = inspectSessionFileBinding(sessionFile);
      const bindingInspectedAt = now();
      if (
        !binding ||
        binding.isSubagent ||
        binding.sessionId !== expectedRootSessionId
      ) {
        return null;
      }
      const offset = fs.statSync(sessionFile).size;
      const offsetReadAt = now();
      const turnState = latestTurnStateAtOffset(sessionFile, offset);
      const turnStateReadAt = now();
      const observedTurnId = turnState.turnId;
      const expectedTurnId = normalizeSessionId(turnId);
      if (!observedTurnId || (expectedTurnId && observedTurnId !== expectedTurnId)) {
        return null;
      }
      return {
        sessionFile,
        rootSessionId: binding.sessionId,
        turnId: observedTurnId,
        offset,
        isSubagent: false,
        turnOpen: turnState.open,
        turnStartOffset: turnState.startOffset,
        turnEndOffset: turnState.endOffset,
        turnStartedAt: turnState.startedAt,
        turnEndedAt: turnState.endedAt,
        captureTimingMs: {
          findSessionFile: Math.max(0, sessionFileResolvedAt - captureStartedAt),
          inspectBinding: Math.max(0, bindingInspectedAt - sessionFileResolvedAt),
          statSessionFile: Math.max(0, offsetReadAt - bindingInspectedAt),
          scanTurnState: Math.max(0, turnStateReadAt - offsetReadAt),
          total: Math.max(0, turnStateReadAt - captureStartedAt),
        },
      };
    },

    async waitForAcceptance({
      sessionFile = "",
      rootSessionId,
      turnId,
      afterOffset,
      requestToken,
      timeoutMs,
    } = {}) {
      const expectedRootSessionId = normalizeSessionId(rootSessionId);
      const expectedTurnId = normalizeSessionId(turnId);
      const token = String(requestToken || "").trim();
      const startOffset = Number(afterOffset);
      if (
        !expectedRootSessionId ||
        !expectedTurnId ||
        !token ||
        !Number.isFinite(startOffset) ||
        startOffset < 0
      ) {
        return null;
      }
      const file = sessionFile || findSessionFileForThreadId(expectedRootSessionId, {
        sessionsDir,
      });
      if (!file) return null;
      const deadline = now() + Math.max(1, Number(timeoutMs) || 1);
      let offset = startOffset;
      const parseState = { carry: "", carryOffset: null };
      let observedTurnId = expectedTurnId;
      const scanAvailable = () => {
        const binding = inspectSessionFileBinding(file);
        if (
          !binding ||
          binding.isSubagent ||
          binding.sessionId !== expectedRootSessionId
        ) {
          return { done: true, evidence: null };
        }
        const stat = fs.statSync(file);
        if (stat.size < offset) return { done: true, evidence: null };
        if (stat.size > offset) {
          const readStartOffset = offset;
          const text = readFileRange(file, offset, stat.size);
          offset = stat.size;
          let acceptedEvidence = null;
          let turnMismatch = false;
          consumeJsonlTextWithOffsets(
            parseState,
            text,
            readStartOffset,
            (line, lineEndOffset) => {
              if (acceptedEvidence || turnMismatch) return;
              if (!line.trim()) return;
              let entry;
              try {
                entry = JSON.parse(line);
              } catch {
                return;
              }
              if (entry?.type === "turn_context" && entry.payload?.turn_id) {
                observedTurnId = normalizeSessionId(entry.payload.turn_id);
                if (observedTurnId !== expectedTurnId) {
                  turnMismatch = true;
                  return;
                }
              }
              if (entryContainsUserRequest(entry, token)) {
                if (observedTurnId !== expectedTurnId) return;
                acceptedEvidence = {
                  rootSessionId: binding.sessionId,
                  turnId: observedTurnId,
                  offset: lineEndOffset,
                  isSubagent: false,
                  requestToken: token,
                  acceptedAt: String(entry?.timestamp || "").trim() || null,
                };
              }
            },
          );
          if (acceptedEvidence) return { done: true, evidence: acceptedEvidence };
          if (turnMismatch || observedTurnId !== expectedTurnId) {
            return { done: true, evidence: null };
          }
        }
        return { done: false, evidence: null };
      };
      while (now() < deadline) {
        const scan = scanAvailable();
        if (scan.done) return scan.evidence;
        await sleepFn(Math.min(pollMs, Math.max(1, deadline - now())));
      }
      return scanAvailable().evidence;
    },
  };
}

function latestTurnStateAtOffset(file, endOffset) {
  const end = Math.max(0, Number(endOffset) || 0);
  if (end === 0) return emptyTurnState();
  const configuredWindow = Number.isFinite(INITIAL_SCAN_BYTES)
    ? INITIAL_SCAN_BYTES
    : DEFAULT_INITIAL_SCAN_BYTES;
  let scanBytes = Math.max(SESSION_META_SCAN_BYTES, configuredWindow);

  while (true) {
    const start = Math.max(0, end - scanBytes);
    const state = turnStateInRange(file, start, end);
    if (start === 0 || (state.turnId && state.turnSequenceCount >= 2)) {
      return withoutTurnSequenceCount(state);
    }
    const nextScanBytes = Math.min(
      end,
      Math.max(scanBytes + SESSION_META_SCAN_BYTES, scanBytes * 2),
    );
    if (nextScanBytes <= scanBytes) return withoutTurnSequenceCount(state);
    scanBytes = nextScanBytes;
  }
}

function turnStateInRange(file, rangeStartOffset, rangeEndOffset) {
  const buffer = readFileRangeBuffer(file, rangeStartOffset, rangeEndOffset);
  let cursor = 0;
  if (rangeStartOffset > 0) {
    const firstNewline = buffer.indexOf(0x0a);
    if (firstNewline < 0) return { ...emptyTurnState(), turnSequenceCount: 0 };
    cursor = firstNewline + 1;
  }
  let turnId = "";
  let open = false;
  let startOffset = null;
  let endOffset = null;
  let startedAt = null;
  let endedAt = null;
  let turnSequenceCount = 0;

  while (cursor < buffer.length) {
    const lineStart = cursor;
    const newline = buffer.indexOf(0x0a, cursor);
    const lineEnd = newline < 0 ? buffer.length : newline;
    const nextCursor = newline < 0 ? buffer.length : newline + 1;
    const contentEnd = lineEnd > lineStart && buffer[lineEnd - 1] === 0x0d
      ? lineEnd - 1
      : lineEnd;
    const line = buffer.subarray(lineStart, contentEnd).toString("utf8");
    const absoluteLineStart = rangeStartOffset + lineStart;
    const absoluteLineEnd = rangeStartOffset + nextCursor;
    cursor = nextCursor;
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry?.type === "turn_context" && entry.payload?.turn_id) {
        const observedTurnId = normalizeSessionId(entry.payload.turn_id);
        if (observedTurnId && observedTurnId !== turnId) {
          turnId = observedTurnId;
          open = true;
          startOffset = absoluteLineStart;
          endOffset = null;
          startedAt = normalizedTimestamp(entry.timestamp);
          endedAt = null;
          turnSequenceCount += 1;
        }
        continue;
      }
      if (!turnId) continue;
      const lifecycleTurnId = normalizeSessionId(entry?.payload?.turn_id);
      const appliesToCurrentTurn = !lifecycleTurnId || lifecycleTurnId === turnId;
      if (
        appliesToCurrentTurn &&
        ((entry?.type === "event_msg" && entry.payload?.type === "task_complete") ||
          entryIsTurnAbort(entry))
      ) {
        open = false;
        if (endOffset === null) {
          endOffset = absoluteLineEnd;
          endedAt = normalizedTimestamp(
            entry.timestamp || entry?.payload?.completed_at || entry?.payload?.aborted_at,
          );
        }
      }
    } catch {}
  }
  return {
    turnId,
    open,
    startOffset,
    endOffset,
    startedAt,
    endedAt,
    turnSequenceCount,
  };
}

function emptyTurnState() {
  return {
    turnId: "",
    open: false,
    startOffset: null,
    endOffset: null,
    startedAt: null,
    endedAt: null,
  };
}

function withoutTurnSequenceCount(state) {
  const { turnSequenceCount: _turnSequenceCount, ...turnState } = state;
  return turnState;
}

function normalizedTimestamp(value) {
  return String(value || "").trim() || null;
}

function readFileRange(file, startOffset, endOffset) {
  return readFileRangeBuffer(file, startOffset, endOffset).toString("utf8");
}

function readFileRangeBuffer(file, startOffset, endOffset) {
  const start = Math.max(0, Number(startOffset) || 0);
  const end = Math.max(start, Number(endOffset) || 0);
  const length = end - start;
  if (length === 0) return Buffer.alloc(0);
  const buffer = Buffer.allocUnsafe(length);
  const fd = fs.openSync(file, "r");
  try {
    fs.readSync(fd, buffer, 0, length, start);
  } finally {
    fs.closeSync(fd);
  }
  return buffer;
}


function parseReplyFromFile(file, requestId) {
  const scanner = new SessionReplyScanner(requestId, { initialScanBytes: Infinity });
  const hit = scanner.scanFile(file);
  if (!hit || hit.messages.length === 0) return null;
  return {
    file,
    text: hit.messages.at(-1).text,
    completedAt: hit.completedAt,
  };
}

export class SessionReplyScanner {
  constructor(
    requestId,
    {
      initialScanBytes = INITIAL_SCAN_BYTES,
      expectedRootSessionId = "",
      includeLifecycleEvents = false,
      includeTaskStartedEvents = false,
      includeRequestEvents = false,
      includeActivityEvents = false,
      sinceMs = null,
    } = {},
  ) {
    this.requestId = requestId;
    this.initialScanBytes = initialScanBytes;
    this.expectedRootSessionId = normalizeSessionId(expectedRootSessionId);
    this.includeLifecycleEvents = includeLifecycleEvents;
    this.includeTaskStartedEvents = includeTaskStartedEvents;
    this.includeRequestEvents = includeRequestEvents;
    this.includeActivityEvents = includeActivityEvents;
    this.sinceMs = Number.isFinite(Number(sinceMs)) ? Number(sinceMs) : null;
    this.files = new Map();
  }

  scanFile(file) {
    const state = this.stateForFile(file);
    const { text, startOffset } = this.readNewText(file, state);
    if (!text) return state.messages.length > 0 ? this.hit(file, state) : null;

    consumeJsonlTextWithOffsets(
      state,
      text,
      startOffset,
      (line, lineEndOffset) => this.parseLine(state, line, lineEndOffset),
    );
    return this.hasHit(state) ? this.hit(file, state) : null;
  }

  stateForFile(file) {
    let state = this.files.get(file);
    if (state) return state;
    const binding = inspectSessionFileBinding(file);
    state = {
      offset: null,
      carry: "",
      carryOffset: null,
      seenRequest: false,
      complete: false,
      completedAt: null,
      sessionId: binding?.sessionId || null,
      sessionBinding: binding,
      sessionBindingLocked: Boolean(binding),
      bindingAccepted: this.acceptsSessionBinding(binding),
      abortedBeforeRequest: false,
      abortedAfterRequest: false,
      abortedAt: null,
      abortedAtMs: null,
      taskStartedTurnId: null,
      taskStartedOffset: null,
      taskStartedAt: null,
      messages: [],
      seenMessageKeys: new Set(),
      pendingImageGenerationCalls: new Set(),
      currentTurnId: null,
      currentRequestToken: null,
      acceptedOffset: null,
      acceptedTurnId: null,
      activityOffset: null,
      latestBridgeRequestOffset: null,
      completedOffset: null,
    };
    this.files.set(file, state);
    return state;
  }

  acceptsSessionBinding(binding) {
    if (binding?.isSubagent) return false;
    if (!this.expectedRootSessionId) return true;
    return binding?.sessionId === this.expectedRootSessionId;
  }

  readNewText(file, state) {
    const stat = fs.statSync(file);
    let startedMidFile = false;
    let readOffset = state.offset;
    let resetReadState = false;
    if (readOffset === null || stat.size < readOffset) {
      const windowSize = Number.isFinite(this.initialScanBytes)
        ? Math.max(0, Math.min(stat.size, this.initialScanBytes))
        : stat.size;
      readOffset = stat.size - windowSize;
      resetReadState = true;
      startedMidFile = readOffset > 0;
    }
    const startOffset = readOffset;
    if (stat.size <= readOffset) {
      state.offset = readOffset;
      if (resetReadState) state.carry = "";
      return { text: "", startOffset };
    }

    const length = stat.size - readOffset;
    const buffer = Buffer.allocUnsafe(length);
    const fd = fs.openSync(file, "r");
    try {
      fs.readSync(fd, buffer, 0, length, readOffset);
    } finally {
      fs.closeSync(fd);
    }
    if (resetReadState) state.carry = "";
    state.offset = stat.size;
    const text = buffer.toString("utf8");
    if (!startedMidFile) return { text, startOffset };
    const newline = text.search(/\r?\n/);
    if (newline < 0) return { text: "", startOffset: stat.size };
    const newlineLength = text[newline] === "\r" && text[newline + 1] === "\n" ? 2 : 1;
    const consumed = text.slice(0, newline + newlineLength);
    return {
      text: text.slice(newline + newlineLength),
      startOffset: startOffset + Buffer.byteLength(consumed, "utf8"),
    };
  }

  parseLine(state, line, lineEndOffset) {
    if (!line.trim()) return;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      return;
    }
    const sessionBinding = sessionBindingFromEntry(entry);
    if (sessionBinding) {
      if (state.sessionBindingLocked) return;
      state.sessionBindingLocked = true;
      state.sessionId = sessionBinding.sessionId;
      state.sessionBinding = sessionBinding;
      state.bindingAccepted = this.acceptsSessionBinding(sessionBinding);
      if (!state.bindingAccepted) {
        state.seenRequest = false;
        state.taskStartedTurnId = null;
        state.taskStartedOffset = null;
        state.taskStartedAt = null;
        state.acceptedOffset = null;
        state.acceptedTurnId = null;
        state.activityOffset = null;
        state.latestBridgeRequestOffset = null;
        state.completedOffset = null;
        state.complete = false;
        state.completedAt = null;
        state.messages = [];
        state.seenMessageKeys.clear();
        state.pendingImageGenerationCalls.clear();
      }
      return;
    }
    if (!state.bindingAccepted) return;

    const payload = entry.payload;
    if (entry?.type === "turn_context" && payload?.turn_id) {
      state.currentTurnId = normalizeSessionId(payload.turn_id) || null;
    }

    if (
      this.includeTaskStartedEvents &&
      entry?.type === "event_msg" &&
      payload?.type === "task_started"
    ) {
      const taskStartedAtMs = entryTimestampMs(entry);
      const taskStartedTurnId = normalizeSessionId(payload.turn_id);
      if (
        taskStartedTurnId &&
        (this.sinceMs === null ||
          taskStartedAtMs === null ||
          taskStartedAtMs >= this.sinceMs)
      ) {
        state.taskStartedTurnId = taskStartedTurnId;
        state.taskStartedOffset = lineEndOffset;
        state.taskStartedAt = String(entry.timestamp || "").trim() || null;
      }
    }

    if (this.includeLifecycleEvents && entryIsTurnAbort(entry)) {
      const abortedAtMs = entryTimestampMs(entry);
      if (this.sinceMs === null || abortedAtMs === null || abortedAtMs >= this.sinceMs) {
        state.abortedAt = entry.timestamp || null;
        state.abortedAtMs = abortedAtMs;
        if (state.seenRequest) {
          state.abortedAfterRequest = true;
        } else {
          state.abortedBeforeRequest = true;
        }
      }
    }

    if (entryContainsUserRequest(entry, this.requestId)) {
      state.seenRequest = true;
      state.currentRequestToken = this.requestId;
      state.acceptedOffset = lineEndOffset;
      state.acceptedTurnId = state.currentTurnId;
      state.activityOffset = lineEndOffset;
      state.latestBridgeRequestOffset = lineEndOffset;
    } else if (state.seenRequest && entryIsUserMessage(entry)) {
      state.currentRequestToken = bridgeFollowupRequestTokenFromEntry(entry);
      if (
        bridgeRequestTokenFromEntry(entry) &&
        state.acceptedTurnId &&
        state.currentTurnId === state.acceptedTurnId
      ) {
        state.latestBridgeRequestOffset = lineEndOffset;
      }
    }
    if (!state.seenRequest) return;
    if (
      state.acceptedTurnId &&
      state.currentTurnId === state.acceptedTurnId &&
      lineEndOffset > state.activityOffset
    ) {
      state.activityOffset = lineEndOffset;
    }

    const imageGeneration = observeImageGenerationEntry(
      state,
      entry,
      lineEndOffset,
    );
    if (imageGeneration.ended && imageGeneration.matched) {
      const attachment = imageAttachmentFromGenerationEnd({
        sessionId: state.sessionId,
        payload,
      });
      if (attachment) {
        const key = payload.call_id || `${attachment.filePath}:${attachment.name}`;
        if (!state.seenMessageKeys.has(key)) {
          state.seenMessageKeys.add(key);
          state.messages.push(attachThreadRelayEvidence({
            id: payload.call_id || null,
            phase: "attachment",
            text: "",
            attachments: [attachment],
          }, state, lineEndOffset, lineEndOffset));
        }
      }
    }

    if (
      entry.type === "response_item" &&
      payload?.type === "message" &&
      payload?.role === "assistant"
    ) {
      const text = extractMessageText(payload);
      if (text) {
        const key = payload.id || `${payload.phase || "assistant"}:${text}`;
        if (!state.seenMessageKeys.has(key)) {
          state.seenMessageKeys.add(key);
          state.messages.push(attachThreadRelayEvidence({
            id: payload.id || null,
            phase: payload.phase || "assistant",
            text,
          }, state, lineEndOffset, lineEndOffset));
        }
      }
    }
    if (entry.type === "response_item" && payload?.type === "image_generation_call") {
      const attachment = imageAttachmentFromCall({ sessionId: state.sessionId, payload });
      if (attachment) {
        const key = payload.id || `${attachment.filePath}:${attachment.name}`;
        if (!state.seenMessageKeys.has(key)) {
          state.seenMessageKeys.add(key);
          state.messages.push(attachThreadRelayEvidence({
            id: payload.id || null,
            phase: "attachment",
            text: "",
            attachments: [attachment],
          }, state, lineEndOffset, lineEndOffset));
        }
      }
    }
    if (entry.type === "event_msg" && payload?.type === "task_complete") {
      state.complete = true;
      state.completedAt = payload.completed_at || null;
      state.completedOffset = lineEndOffset;
      const finalAnswer = payload.last_agent_message || null;
      if (finalAnswer) {
        const hasMatchingFinalAnswer = state.messages.some(
          (message) =>
            message.phase === "final_answer" &&
            message.text === finalAnswer,
        );
        if (!hasMatchingFinalAnswer) {
          state.messages.push(attachThreadRelayEvidence({
            id: `task_complete:${lineEndOffset}`,
            phase: "final_answer",
            text: finalAnswer,
          }, state, lineEndOffset, lineEndOffset));
        }
      }
    }
  }

  hit(file, state) {
    const hit = {
      file,
      messages: state.messages,
      complete: state.complete,
      completedAt: state.completedAt,
      pendingImageGenerationCount: state.pendingImageGenerationCalls.size,
      seenRequest: state.seenRequest,
      abortedBeforeRequest: state.abortedBeforeRequest,
      abortedAfterRequest: state.abortedAfterRequest,
      abortedAt: state.abortedAt,
      abortedAtMs: state.abortedAtMs,
    };
    if (this.includeRequestEvents) {
      Object.defineProperties(hit, {
        ownerSessionId: {
          enumerable: false,
          value: state.sessionId || null,
        },
        turnId: {
          enumerable: false,
          value: state.currentTurnId || null,
        },
        acceptedOffset: {
          enumerable: false,
          value: Number.isSafeInteger(state.acceptedOffset)
            ? state.acceptedOffset
            : null,
        },
      });
    }
    if (this.includeTaskStartedEvents) {
      if (!this.includeRequestEvents) {
        Object.defineProperty(hit, "ownerSessionId", {
          enumerable: false,
          value: state.sessionId || null,
        });
      }
      Object.defineProperties(hit, {
        taskStartedTurnId: {
          enumerable: false,
          value: state.taskStartedTurnId || null,
        },
        taskStartedOffset: {
          enumerable: false,
          value: Number.isSafeInteger(state.taskStartedOffset)
            ? state.taskStartedOffset
            : null,
        },
        taskStartedAt: {
          enumerable: false,
          value: state.taskStartedAt || null,
        },
      });
    }
    if (this.includeActivityEvents) {
      Object.defineProperties(hit, {
        activityOffset: {
          enumerable: false,
          value: Number.isSafeInteger(state.activityOffset) ? state.activityOffset : null,
        },
        latestBridgeRequestOffset: {
          enumerable: false,
          value: Number.isSafeInteger(state.latestBridgeRequestOffset)
            ? state.latestBridgeRequestOffset
            : null,
        },
        completedOffset: {
          enumerable: false,
          value: Number.isSafeInteger(state.completedOffset)
            ? state.completedOffset
            : null,
        },
      });
    }
    return hit;
  }

  hasHit(state) {
    return (
      state.messages.length > 0 ||
      (this.includeTaskStartedEvents &&
        Number.isSafeInteger(state.taskStartedOffset)) ||
      (this.includeRequestEvents && state.seenRequest) ||
      (this.includeActivityEvents && Number.isSafeInteger(state.activityOffset)) ||
      (this.includeLifecycleEvents &&
        (state.abortedBeforeRequest || state.abortedAfterRequest))
    );
  }
}

export class SessionThreadTailScanner {
  constructor({ offset = null, contextLookbackBytes = 512 * 1024 } = {}) {
    this.initialOffset = Number.isFinite(Number(offset)) ? Number(offset) : null;
    this.contextLookbackBytes = contextLookbackBytes;
    this.files = new Map();
  }

  scanFile(file) {
    const state = this.stateForFile(file);
    this.primeOriginFromLookback(file, state);
    const { text, startOffset } = this.readNewText(file, state);
    const messages = [];
    if (text) {
      consumeJsonlTextWithOffsets(
        state,
        text,
        startOffset,
        (line, lineEndOffset) => this.parseLine(state, line, messages, lineEndOffset),
      );
    }
    return {
      file,
      messages,
      offset: state.offset,
      complete: state.complete,
      completedAt: state.completedAt,
      voiceOrigin: state.currentChannel === "voice",
    };
  }

  stateForFile(file) {
    let state = this.files.get(file);
    if (state) return state;
    const binding = inspectSessionFileBinding(file);
    state = {
      offset: this.initialOffset,
      carry: "",
      carryOffset: null,
      complete: false,
      completedAt: null,
      sessionId: binding?.sessionId || null,
      sessionBindingLocked: Boolean(binding),
      seenMessageKeys: new Set(),
      pendingFinalAnswer: null,
      pendingImageGenerationCalls: new Set(),
      currentChannel: null,
      currentTurnId: null,
      currentRequestToken: null,
      originPrimed: false,
    };
    this.files.set(file, state);
    return state;
  }

  primeOriginFromLookback(file, state) {
    if (state.originPrimed) return;
    state.originPrimed = true;
    if (state.offset === null || state.offset <= 0 || this.contextLookbackBytes <= 0) return;

    const stat = fs.statSync(file);
    const end = Math.min(state.offset, stat.size);
    if (end <= 0) return;
    const length = Math.min(end, this.contextLookbackBytes);
    const start = end - length;
    const buffer = Buffer.allocUnsafe(length);
    const fd = fs.openSync(file, "r");
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
    for (const line of text.split(/\r?\n/)) {
      this.primeOriginLine(state, line);
    }
  }

  primeOriginLine(state, line) {
    if (!line.trim()) return;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      return;
    }
    if (entry?.type === "turn_context" && entry.payload?.turn_id) {
      state.currentTurnId = normalizeSessionId(entry.payload.turn_id) || null;
    }
    if (entryIsUserMessage(entry)) {
      state.currentChannel = entryUserMessageChannel(entry);
      state.currentRequestToken = bridgeFollowupRequestTokenFromEntry(entry);
    }
    observeImageGenerationEntry(state, entry);
  }

  readNewText(file, state) {
    const stat = fs.statSync(file);
    if (state.offset === null || stat.size < state.offset) {
      state.offset = stat.size;
      state.carry = "";
      state.carryOffset = null;
    }
    const startOffset = state.offset;
    if (stat.size <= state.offset) return { text: "", startOffset };

    const length = stat.size - state.offset;
    const buffer = Buffer.allocUnsafe(length);
    const fd = fs.openSync(file, "r");
    try {
      fs.readSync(fd, buffer, 0, length, state.offset);
    } finally {
      fs.closeSync(fd);
    }
    state.offset = stat.size;
    return { text: buffer.toString("utf8"), startOffset };
  }

  parseLine(state, line, messages, lineEndOffset) {
    if (!line.trim()) return;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      return;
    }
    const sessionBinding = sessionBindingFromEntry(entry);
    if (sessionBinding) {
      if (!state.sessionBindingLocked) {
        state.sessionBindingLocked = true;
        state.sessionId = sessionBinding.sessionId;
      }
      return;
    }

    const payload = entry.payload;
    if (entry?.type === "turn_context" && payload?.turn_id) {
      state.currentTurnId = normalizeSessionId(payload.turn_id) || null;
    }
    if (entryIsUserMessage(entry)) {
      state.currentChannel = entryUserMessageChannel(entry);
      state.currentRequestToken = bridgeFollowupRequestTokenFromEntry(entry);
    }

    const imageGeneration = observeImageGenerationEntry(
      state,
      entry,
      lineEndOffset,
    );
    if (imageGeneration.ended && imageGeneration.matched) {
      const attachment = imageAttachmentFromGenerationEnd({
        sessionId: state.sessionId,
        payload,
      });
      if (!attachment) return;
      const key = payload.call_id || `${attachment.filePath}:${attachment.name}`;
      if (state.seenMessageKeys.has(key)) return;
      state.seenMessageKeys.add(key);
      messages.push(attachThreadRelayEvidence({
        id: payload.call_id || null,
        phase: "attachment",
        text: "",
        attachments: [attachment],
        ...originFields(state),
      }, state, lineEndOffset, lineEndOffset));
      return;
    }

    if (
      entry.type === "response_item" &&
      payload?.type === "message" &&
      payload?.role === "assistant"
    ) {
      const text = extractMessageText(payload);
      if (!text) return;
      if (payload.phase === "final_answer") {
        state.pendingFinalAnswer = attachThreadRelayEvidence({
          id: payload.id || null,
          phase: "final_answer",
          text,
          ...originFields(state),
        }, state, lineEndOffset);
        return;
      }
      const key = payload.id || `${payload.phase || "assistant"}:${text}`;
      if (state.seenMessageKeys.has(key)) return;
      state.seenMessageKeys.add(key);
      const message = {
        id: payload.id || null,
        phase: payload.phase || "assistant",
        text,
        ...originFields(state),
      };
      messages.push(attachThreadRelayEvidence(message, state, lineEndOffset, lineEndOffset));
      return;
    }

    if (entry.type === "response_item" && payload?.type === "image_generation_call") {
      const attachment = imageAttachmentFromCall({ sessionId: state.sessionId, payload });
      if (!attachment) return;
      const key = payload.id || `${attachment.filePath}:${attachment.name}`;
      if (state.seenMessageKeys.has(key)) return;
      state.seenMessageKeys.add(key);
      messages.push(attachThreadRelayEvidence({
        id: payload.id || null,
        phase: "attachment",
        text: "",
        attachments: [attachment],
        ...originFields(state),
      }, state, lineEndOffset, lineEndOffset));
      return;
    }

    if (entry.type === "event_msg" && payload?.type === "task_complete") {
      state.complete = true;
      state.completedAt = payload.completed_at || null;
      const finalAnswer = payload.last_agent_message || state.pendingFinalAnswer?.text || null;
      if (!finalAnswer) return;
      const key = `task_complete:${lineEndOffset}`;
      if (state.seenMessageKeys.has(key)) return;
      state.seenMessageKeys.add(key);
      const pendingFinal = state.pendingFinalAnswer || null;
      const finalMessage = attachThreadRelayEvidence({
        ...(pendingFinal || {}),
        id: "task_complete",
        phase: "final_answer",
        text: finalAnswer,
        ...(!pendingFinal ? originFields(state) : {}),
      }, pendingFinal || state, pendingFinal?.finalOffset ?? lineEndOffset, lineEndOffset);
      state.pendingFinalAnswer = null;
      messages.push(finalMessage);
    }
  }
}

function consumeJsonlTextWithOffsets(state, text, startOffset, parseLine) {
  const hasCarry = Boolean(state.carry);
  const combined = `${state.carry}${text}`;
  const combinedStart = hasCarry && Number.isFinite(state.carryOffset)
    ? state.carryOffset
    : startOffset;
  let cursor = 0;
  const newlinePattern = /\r?\n/g;
  let match;
  while ((match = newlinePattern.exec(combined))) {
    const line = combined.slice(cursor, match.index);
    const consumedEnd = match.index + match[0].length;
    parseLine(
      line,
      combinedStart + Buffer.byteLength(combined.slice(0, consumedEnd), "utf8"),
    );
    cursor = consumedEnd;
  }
  state.carry = combined.slice(cursor);
  state.carryOffset = combinedStart + Buffer.byteLength(combined.slice(0, cursor), "utf8");
  if (!state.carry || !isCompleteJsonLine(state.carry)) return;
  const line = state.carry;
  const lineEndOffset = state.carryOffset + Buffer.byteLength(line, "utf8");
  state.carry = "";
  state.carryOffset = lineEndOffset;
  parseLine(line, lineEndOffset);
}

function attachThreadRelayEvidence(message, state, finalOffset, relayOffset = finalOffset) {
  Object.defineProperties(message, {
    ownerSessionId: {
      enumerable: false,
      value: state.sessionId || state.ownerSessionId || null,
    },
    turnId: {
      enumerable: false,
      value: state.currentTurnId || state.turnId || null,
    },
    requestToken: {
      enumerable: false,
      value: state.currentRequestToken || state.requestToken || null,
    },
    finalOffset: {
      enumerable: false,
      value: Number.isFinite(finalOffset) ? finalOffset : null,
    },
    relayOffset: {
      enumerable: false,
      value: Number.isFinite(relayOffset) ? relayOffset : null,
    },
  });
  return message;
}

function messageWithFile(message, file) {
  const clone = Object.create(
    Object.getPrototypeOf(message),
    Object.getOwnPropertyDescriptors(message),
  );
  Object.defineProperty(clone, "file", {
    enumerable: true,
    configurable: true,
    writable: true,
    value: file,
  });
  return clone;
}

function bridgeFollowupRequestTokenFromEntry(entry) {
  if (!entryIsUserMessage(entry)) return null;
  const payload = entry?.payload;
  const text = entry?.type === "event_msg"
    ? String(payload?.message || "")
    : String(extractMessageText(payload) || "");
  const match = text.match(/\[bridge_followup_request_id:\s*([^\]\r\n]+)\]/i);
  return match?.[1]?.trim() || null;
}

function bridgeRequestTokenFromEntry(entry) {
  if (!entryIsUserMessage(entry)) return null;
  const payload = entry?.payload;
  const text = entry?.type === "event_msg"
    ? String(payload?.message || "")
    : String(extractMessageText(payload) || "");
  const match = text.match(
    /\[(?:voice_relay_request_id|voice_relay_followup_request_id):\s*([^\]\r\n]+)\]/i,
  );
  return match?.[1]?.trim() || null;
}

function consumeJsonlText(state, text, parseLine) {
  const lines = `${state.carry}${text}`.split(/\r?\n/);
  state.carry = lines.pop() || "";
  for (const line of lines) {
    parseLine(line);
  }
  flushCompleteCarry(state, parseLine);
}

function flushCompleteCarry(state, parseLine) {
  if (!state.carry) return;
  if (!state.carry.trim()) {
    state.carry = "";
    return;
  }
  if (!isCompleteJsonLine(state.carry)) return;
  const line = state.carry;
  state.carry = "";
  parseLine(line);
}

function isCompleteJsonLine(line) {
  try {
    JSON.parse(line);
    return true;
  } catch {
    return false;
  }
}

function extractMessageText(payload) {
  if (typeof payload?.content === "string") return payload.content;
  if (Array.isArray(payload?.content)) {
    return payload.content
      .map((item) => item.text || item.output_text || "")
      .join("")
      .trim();
  }
  return null;
}

function entryContainsUserRequest(entry, requestId) {
  if (!requestId) return false;
  const payload = entry?.payload;
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "user"
  ) {
    return extractMessageText(payload).includes(requestId);
  }
  if (entry?.type === "event_msg" && payload?.type === "user_message") {
    return String(payload.message || "").includes(requestId);
  }
  return false;
}

function sessionBindingFromEntry(entry) {
  if (entry?.type !== "session_meta" || !entry.payload?.id) return null;
  const payload = entry.payload;
  const sessionId = normalizeSessionId(payload.id);
  const declaredSessionId = normalizeSessionId(payload.session_id);
  const threadSpawn = payload?.source?.subagent?.thread_spawn || null;
  const parentSessionId = [
    threadSpawn?.parent_thread_id,
    payload.parent_thread_id,
    payload.forked_from_thread_id,
    payload.forked_from_id,
  ]
    .map(normalizeSessionId)
    .find(Boolean) || null;
  return {
    sessionId,
    isSubagent: Boolean(
      threadSpawn ||
      parentSessionId ||
      (declaredSessionId && declaredSessionId !== sessionId)
    ),
    parentSessionId,
  };
}

function entryIsUserMessage(entry) {
  const payload = entry?.payload;
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "user"
  ) {
    return true;
  }
  return entry?.type === "event_msg" && payload?.type === "user_message";
}

function entryUserMessageChannel(entry) {
  const payload = entry?.payload;
  let text = "";
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "user"
  ) {
    text = extractMessageText(payload) || "";
  } else if (entry?.type === "event_msg" && payload?.type === "user_message") {
    text = String(payload.message || "");
  }
  if (!text) return null;
  const match = text.match(/(?:^|\n)Channel:\s*([^\r\n]+)/i);
  if (match) {
    const channel = match[1].trim().toLowerCase();
    if (channel === "voice") return "voice";
    if (channel === "imessage") return "iMessage";
    if (channel === "local") {
      return "local";
    }
  }
  if (
    /\bvoice_relay_local_request_id\b/i.test(text) ||
    /\bVoice Relay local operating boundary\b/i.test(text)
  ) {
    return "local";
  }
  if (/\bvoice_relay_request_id\b/i.test(text)) {
    return "iMessage";
  }
  return null;
}

function originFields(state) {
  if (state.currentChannel === "voice") {
    return { voiceOrigin: true };
  }
  if (state.currentChannel === "local") {
    return { originChannel: "local", localOnly: true };
  }
  return {};
}

function entryIsTurnAbort(entry) {
  const payload = entry?.payload;
  if (entry?.type === "event_msg" && payload?.type === "turn_aborted") {
    return true;
  }
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "user"
  ) {
    return extractMessageText(payload).includes("<turn_aborted>");
  }
  return false;
}

function entryTimestampMs(entry) {
  const parsed = Date.parse(entry?.timestamp || "");
  return Number.isFinite(parsed) ? parsed : null;
}

function imageAttachmentFromCall({ sessionId, payload }) {
  const imageId = safeGeneratedImageId(payload?.id);
  if (!imageId || !payload?.result) return null;

  const generatedPath = sessionId
    ? path.join(
        os.homedir(),
        ".codex",
        "generated_images",
        sessionId,
        `${imageId}.png`,
      )
    : null;
  if (generatedPath && fs.existsSync(generatedPath)) {
    return {
      type: "image",
      filePath: generatedPath,
      name: `${imageId}.png`,
      mimeType: "image/png",
    };
  }

  if (typeof payload.result !== "string") return null;
  const fallbackRoot = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Voice Relay",
    "Generated Images",
  );
  const fallbackPath = sessionId
    ? path.join(fallbackRoot, sessionId, `${imageId}.png`)
    : path.join(fallbackRoot, `${imageId}.png`);
  fs.mkdirSync(path.dirname(fallbackPath), { recursive: true });
  if (!fs.existsSync(fallbackPath)) {
    fs.writeFileSync(fallbackPath, Buffer.from(payload.result, "base64"));
  }
  return {
    type: "image",
    filePath: fallbackPath,
    name: `${imageId}.png`,
    mimeType: "image/png",
  };
}

function imageAttachmentFromGenerationEnd({ sessionId, payload }) {
  if (payload?.status !== "completed") return null;
  const imageId = safeGeneratedImageId(payload?.call_id);
  if (!imageId) return null;

  const savedPath = String(payload?.saved_path || "").trim();
  if (
    savedPath &&
    isExactGeneratedImagePath({ sessionId, imageId, filePath: savedPath })
  ) {
    return {
      type: "image",
      filePath: fs.realpathSync(savedPath),
      name: `${imageId}.png`,
      mimeType: "image/png",
    };
  }

  return imageAttachmentFromCall({
    sessionId,
    payload: { id: imageId, result: payload?.result },
  });
}

function observeImageGenerationEntry(state, entry, lineEndOffset = null) {
  const payload = entry?.payload;
  const startKey = imageGenerationStartKey(entry, lineEndOffset);
  if (startKey) {
    state.pendingImageGenerationCalls.add(startKey);
    return { started: true, ended: false, matched: false };
  }

  if (
    entry?.type === "response_item" &&
    payload?.type === "custom_tool_call_output"
  ) {
    const callId = String(payload.call_id || "").trim();
    if (
      callId &&
      state.pendingImageGenerationCalls.has(callId) &&
      !/Script running with cell ID/iu.test(String(payload.output || ""))
    ) {
      state.pendingImageGenerationCalls.delete(callId);
    }
    return { started: false, ended: false, matched: false };
  }

  if (entry?.type !== "event_msg" || payload?.type !== "image_generation_end") {
    return { started: false, ended: false, matched: false };
  }

  const pending = state.pendingImageGenerationCalls.values().next();
  if (pending.done) {
    return { started: false, ended: true, matched: false };
  }
  state.pendingImageGenerationCalls.delete(pending.value);
  return { started: false, ended: true, matched: true };
}

function imageGenerationStartKey(entry, lineEndOffset) {
  const payload = entry?.payload;
  if (
    entry?.type !== "response_item" ||
    !["custom_tool_call", "function_call"].includes(payload?.type)
  ) {
    return null;
  }
  const input =
    typeof payload.input === "string"
      ? payload.input
      : typeof payload.arguments === "string"
        ? payload.arguments
        : "";
  const signature = `${payload.name || ""}\n${input}`;
  if (!/image_gen(?:__|\.)imagegen/iu.test(signature)) return null;
  return String(
    payload.call_id || payload.id || `image-generation:${lineEndOffset ?? "unknown"}`,
  );
}

function safeGeneratedImageId(value) {
  const imageId = String(value || "").trim();
  return /^[A-Za-z0-9._-]+$/u.test(imageId) ? imageId : null;
}

function isExactGeneratedImagePath({ sessionId, imageId, filePath }) {
  if (!sessionId || !imageId || !filePath) return false;
  const expectedRoot = path.join(
    os.homedir(),
    ".codex",
    "generated_images",
    sessionId,
  );
  try {
    const realRoot = fs.realpathSync(expectedRoot);
    const realFile = fs.realpathSync(filePath);
    const relative = path.relative(realRoot, realFile);
    return (
      relative === `${imageId}.png` &&
      !path.isAbsolute(relative) &&
      fs.statSync(realFile).isFile()
    );
  } catch {
    return false;
  }
}

function walk(dir, out) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(fullPath, out);
    } else if (entry.isFile() && entry.name.startsWith("rollout-")) {
      out.push(fullPath);
    }
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
