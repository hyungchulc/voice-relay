import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  AcceptedSteerResponseRevisionFence,
  streamCodexReplies,
} from "../Support/CodexRemote/src/session-log.js";

const ROOT_SESSION_ID = "019fb137-bcc5-72f0-941b-93208c70afdb";
const TURN_ID = "019fb137-fence-7000-8000-000000000001";
const ROOT_REQUEST_ID = "voice-relay-revision-fence-root";

function jsonlEntry(type, payload, timestamp = "2026-07-30T22:07:30.000Z") {
  return JSON.stringify({ timestamp, type, payload });
}

function rootEntries() {
  return [
    jsonlEntry("session_meta", { id: ROOT_SESSION_ID }),
    jsonlEntry("turn_context", { turn_id: TURN_ID }),
    jsonlEntry("event_msg", {
      type: "user_message",
      message: `[voice_relay_request_id: ${ROOT_REQUEST_ID}]\nStart the request.`,
    }),
  ];
}

function assistantMessage(id, phase, text) {
  return jsonlEntry("response_item", {
    type: "message",
    id,
    role: "assistant",
    phase,
    content: [{ type: "output_text", text }],
  });
}

function taskComplete(text) {
  return jsonlEntry("event_msg", {
    type: "task_complete",
    turn_id: TURN_ID,
    last_agent_message: text,
    completed_at: "2026-07-30T22:07:45.000Z",
  });
}

function append(file, entries) {
  fs.appendFileSync(file, `${entries.join("\n")}\n`);
  return fs.statSync(file).size;
}

async function withSessionFile(run) {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "voice-relay-revision-fence."),
  );
  const file = path.join(directory, "session.jsonl");
  try {
    fs.writeFileSync(file, "");
    return await run(file);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function streamOptions({
  file,
  clock,
  onMessage,
  sleepFn,
  timeoutMs = 10_000,
  getAcceptedSteerRevision = null,
  signal = null,
}) {
  return {
    requestId: ROOT_REQUEST_ID,
    expectedRootSessionId: ROOT_SESSION_ID,
    sinceMs: 0,
    timeoutMs,
    finalAnswerSettleMs: 1_500,
    listFiles: () => [file],
    now: () => clock.now,
    sleepFn,
    onMessage,
    onAccepted: async () => {},
    getAcceptedSteerRevision,
    signal,
  };
}

await withSessionFile(async (file) => {
  append(file, [
    ...rootEntries(),
    assistantMessage("normal-final", "final_answer", "Normal final."),
  ]);
  const clock = { now: 0 };
  const messages = [];
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
      },
    }),
  );
  assert.equal(
    result.completedBy,
    "final_answer_settle",
    "a normal no-steer final must still settle through the bounded heuristic",
  );
  assert.deepEqual(
    messages.map((message) => message.text),
    ["Normal final."],
    "a no-steer final must be committed exactly once at terminal settlement",
  );
});

await withSessionFile(async (file) => {
  const obsoleteFinal = "Obsolete pre-steer final.";
  const revisedCommentary = "Applying the accepted correction.";
  const revisedFinalA = "Corrected final A.";
  const revisedFinalB = "Corrected final B.";
  append(file, [
    ...rootEntries(),
    assistantMessage("obsolete-final", "final_answer", obsoleteFinal),
  ]);
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      getAcceptedSteerRevision: () => fence.snapshot(),
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
        sleeps += 1;
        if (sleeps === 1) {
          const acceptedOffset = append(file, [
            jsonlEntry("event_msg", {
              type: "user_message",
              message:
                "[bridge_followup_request_id: race-steer]\nUse the corrected request.",
            }),
          ]);
          fence.accept({
            acceptedOffset,
            requestToken: "race-steer",
            rootSessionId: ROOT_SESSION_ID,
            turnId: TURN_ID,
            sessionFile: file,
          });
        } else if (sleeps === 2) {
          append(file, [
            assistantMessage(
              "revised-commentary-race",
              "commentary",
              revisedCommentary,
            ),
            assistantMessage(
              "revised-final-a-race",
              "final_answer",
              revisedFinalA,
            ),
            assistantMessage(
              "revised-final-b-race",
              "final_answer",
              revisedFinalB,
            ),
            taskComplete(revisedFinalB),
          ]);
        }
      },
    }),
  );
  assert.equal(
    result.completedBy,
    "task_complete",
    "the accepted correction must close only on authoritative completion",
  );
  assert.equal(
    result.completedResponseRevision,
    1,
    "the corrected response must resolve exactly one accepted revision",
  );
  assert.deepEqual(
    messages.map((message) => message.text),
    [revisedCommentary, `${revisedFinalA}\n\n${revisedFinalB}`],
    "a buffered final at or before the accepted offset must not cross the response boundary",
  );
  assert.ok(
    !messages.some((message) => message.text.includes(obsoleteFinal)),
    "the obsolete pre-steer final must never reach the relay callback",
  );
  assert.deepEqual(
    result.messages
      .filter((message) => message.phase === "final_answer")
      .map((message) => message.text),
    [`${revisedFinalA}\n\n${revisedFinalB}`],
    "the terminal result must contain only ordered finals from the accepted revision",
  );
});

await withSessionFile(async (file) => {
  append(file, rootEntries());
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  const partialFinal = "Valid partial final A.";
  const revisedCommentary = "Working on the accepted revision.";
  const additiveFinal = "Additive final B.";
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      getAcceptedSteerRevision: () => fence.snapshot(),
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
        sleeps += 1;
        if (sleeps === 1) {
          const acceptedOffset = append(file, [
            jsonlEntry("event_msg", {
              type: "user_message",
              message:
                "[bridge_followup_request_id: accepted-steer]\nUse the newer request.",
            }),
          ]);
          fence.accept({
            acceptedOffset,
            requestToken: "accepted-steer",
            rootSessionId: ROOT_SESSION_ID,
            turnId: TURN_ID,
            sessionFile: file,
          });
        } else if (sleeps === 2) {
          append(file, [
            assistantMessage("partial-final", "final_answer", partialFinal),
          ]);
        } else if (sleeps === 6) {
          append(file, [
            assistantMessage(
              "revised-commentary",
              "commentary",
              revisedCommentary,
            ),
            assistantMessage("additive-final", "final_answer", additiveFinal),
            taskComplete(additiveFinal),
          ]);
        }
      },
    }),
  );
  assert.equal(
    result.completedBy,
    "task_complete",
    "an accepted response revision must close only on authoritative completion",
  );
  assert.equal(
    result.completedResponseRevision,
    1,
    "authoritative completion must resolve the accepted response revision",
  );
  assert.ok(
    sleeps >= 6,
    "an accepted-but-unincorporated revision must remain open past final settle",
  );
  assert.deepEqual(
    messages.map((message) => message.text),
    [revisedCommentary, `${partialFinal}\n\n${additiveFinal}`],
    "all distinct buffered finals must be delivered in chronological order",
  );
  assert.equal(
    messages.filter((message) => message.phase === "final_answer").length,
    1,
    "authoritative completion must commit one combined terminal final",
  );
  assert.deepEqual(
    result.messages
      .filter((message) => message.phase === "final_answer")
      .map((message) => message.text),
    [`${partialFinal}\n\n${additiveFinal}`],
    "the terminal result must expose the same single ordered combined final",
  );
});

await withSessionFile(async (file) => {
  const repeatedAcrossBoundary = "Same text in the authoritative revision.";
  append(file, [
    ...rootEntries(),
    assistantMessage(
      "same-text-before-steer",
      "final_answer",
      repeatedAcrossBoundary,
    ),
  ]);
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      getAcceptedSteerRevision: () => fence.snapshot(),
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
        sleeps += 1;
        if (sleeps === 1) {
          const acceptedOffset = append(file, [
            jsonlEntry("event_msg", {
              type: "user_message",
              message:
                "[bridge_followup_request_id: same-text-steer]\nRegenerate it.",
            }),
          ]);
          fence.accept({
            acceptedOffset,
            requestToken: "same-text-steer",
            rootSessionId: ROOT_SESSION_ID,
            turnId: TURN_ID,
            sessionFile: file,
          });
        } else if (sleeps === 2) {
          append(file, [
            assistantMessage(
              "same-text-after-steer",
              "final_answer",
              repeatedAcrossBoundary,
            ),
            taskComplete(repeatedAcrossBoundary),
          ]);
        }
      },
    }),
  );
  assert.equal(result.completedResponseRevision, 1);
  assert.deepEqual(
    messages
      .filter((message) => message.phase === "final_answer")
      .map((message) => message.text),
    [repeatedAcrossBoundary],
    "quarantining a prior revision must rebase exact-text deduplication",
  );
});

await withSessionFile(async (file) => {
  const originalFinal = "Revision zero final.";
  const firstRevisionFinal = "Revision one final.";
  const secondRevisionFinalA = "Revision two final A.";
  const secondRevisionFinalB = "Revision two final B.";
  append(file, [
    ...rootEntries(),
    assistantMessage("revision-zero-final", "final_answer", originalFinal),
  ]);
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      getAcceptedSteerRevision: () => fence.snapshot(),
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
        sleeps += 1;
        if (sleeps === 1) {
          const acceptedOffset = append(file, [
            jsonlEntry("event_msg", {
              type: "user_message",
              message:
                "[bridge_followup_request_id: revision-one-steer]\nFirst update.",
            }),
          ]);
          fence.accept({
            acceptedOffset,
            requestToken: "revision-one-steer",
            rootSessionId: ROOT_SESSION_ID,
            turnId: TURN_ID,
            sessionFile: file,
          });
        } else if (sleeps === 2) {
          append(file, [
            assistantMessage(
              "revision-one-final",
              "final_answer",
              firstRevisionFinal,
            ),
          ]);
        } else if (sleeps === 3) {
          const acceptedOffset = append(file, [
            jsonlEntry("event_msg", {
              type: "user_message",
              message:
                "[bridge_followup_request_id: revision-two-steer]\nSecond update.",
            }),
          ]);
          fence.accept({
            acceptedOffset,
            requestToken: "revision-two-steer",
            rootSessionId: ROOT_SESSION_ID,
            turnId: TURN_ID,
            sessionFile: file,
          });
        } else if (sleeps === 4) {
          append(file, [
            assistantMessage(
              "revision-two-final-a",
              "final_answer",
              secondRevisionFinalA,
            ),
            assistantMessage(
              "revision-two-final-b",
              "final_answer",
              secondRevisionFinalB,
            ),
            taskComplete(secondRevisionFinalB),
          ]);
        }
      },
    }),
  );
  assert.equal(
    result.completedResponseRevision,
    2,
    "successive accepted steers must resolve the newest response revision",
  );
  assert.deepEqual(
    messages
      .filter((message) => message.phase === "final_answer")
      .map((message) => message.text),
    [`${secondRevisionFinalA}\n\n${secondRevisionFinalB}`],
    "a later accepted response revision must quarantine every earlier pending revision",
  );
  assert.ok(
    !messages.some(
      (message) =>
        message.text.includes(originalFinal) ||
        message.text.includes(firstRevisionFinal),
    ),
    "no pending final may cross either accepted response boundary",
  );
});

await withSessionFile(async (file) => {
  append(file, [
    ...rootEntries(),
    assistantMessage("candidate-final", "final_answer", "Candidate final."),
  ]);
  const clock = { now: 0 };
  const messages = [];
  let sleeps = 0;
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
        sleeps += 1;
        if (sleeps === 1) {
          append(file, [
            assistantMessage(
              "later-commentary",
              "commentary",
              "Additional activity.",
            ),
          ]);
        } else if (sleeps === 4) {
          append(file, [
            assistantMessage(
              "replacement-final",
              "final_answer",
              "Replacement final.",
            ),
          ]);
        }
      },
    }),
  );
  assert.equal(
    result.completedBy,
    "final_answer_settle",
    "the replacement candidate must retain ordinary bounded settlement",
  );
  assert.deepEqual(
    messages.map((message) => message.text),
    [
      "Additional activity.",
      "Candidate final.\n\nReplacement final.",
    ],
    "later activity must delay settlement without discarding an earlier distinct final",
  );
});

await withSessionFile(async (file) => {
  append(file, rootEntries());
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  const repeatedFinal = "The same final answer.";
  const result = await streamCodexReplies(
    streamOptions({
      file,
      clock,
      getAcceptedSteerRevision: () => fence.snapshot(),
      onMessage: async (message) => messages.push(message),
      sleepFn: async (milliseconds) => {
        clock.now += milliseconds;
        sleeps += 1;
        if (sleeps === 1) {
          const acceptedOffset = append(file, [
            jsonlEntry("event_msg", {
              type: "user_message",
              message:
                "[bridge_followup_request_id: duplicate-steer]\nKeep the answer.",
            }),
          ]);
          fence.accept({
            acceptedOffset,
            requestToken: "duplicate-steer",
            rootSessionId: ROOT_SESSION_ID,
            turnId: TURN_ID,
            sessionFile: file,
          });
        } else if (sleeps === 2) {
          append(file, [
            assistantMessage(
              "duplicate-final-one",
              "final_answer",
              repeatedFinal,
            ),
            assistantMessage(
              "duplicate-final-two",
              "final_answer",
              `  ${repeatedFinal}\r\n`,
            ),
            taskComplete(repeatedFinal),
          ]);
        }
      },
    }),
  );
  assert.equal(
    result.completedBy,
    "task_complete",
    "a duplicate replay after accepted steer must still close authoritatively",
  );
  assert.deepEqual(
    messages
      .filter((message) => message.phase === "final_answer")
      .map((message) => message.text),
    [repeatedFinal],
    "different IDs with exactly normalized duplicate text must emit once",
  );
  assert.deepEqual(
    result.messages
      .filter((message) => message.phase === "final_answer")
      .map((message) => message.text),
    [repeatedFinal],
    "the terminal result must also contain one deduplicated final",
  );
});

await withSessionFile(async (file) => {
  append(file, rootEntries());
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  await assert.rejects(
    streamCodexReplies(
      streamOptions({
        file,
        clock,
        timeoutMs: 2_000,
        getAcceptedSteerRevision: () => fence.snapshot(),
        onMessage: async (message) => messages.push(message),
        sleepFn: async (milliseconds) => {
          clock.now += milliseconds;
          sleeps += 1;
          if (sleeps === 1) {
            const acceptedOffset = append(file, [
              jsonlEntry("event_msg", {
                type: "user_message",
                message:
                  "[bridge_followup_request_id: timeout-steer]\nKeep waiting.",
              }),
            ]);
            fence.accept({
              acceptedOffset,
              requestToken: "timeout-steer",
              rootSessionId: ROOT_SESSION_ID,
              turnId: TURN_ID,
              sessionFile: file,
            });
            append(file, [
              assistantMessage(
                "timeout-stale-final",
                "final_answer",
                "Never commit this.",
              ),
            ]);
          }
        },
      }),
    ),
    /Timed out waiting for final Codex reply/,
    "an unresolved accepted revision must fail closed on timeout",
  );
  assert.deepEqual(
    messages,
    [],
    "timeout must not leak a quarantined final",
  );
});

await withSessionFile(async (file) => {
  append(file, [
    ...rootEntries(),
    assistantMessage(
      "abort-pre-steer-final",
      "final_answer",
      "Quarantine this before abort.",
    ),
  ]);
  const controller = new AbortController();
  const clock = { now: 0 };
  const fence = new AcceptedSteerResponseRevisionFence();
  const messages = [];
  let sleeps = 0;
  await assert.rejects(
    streamCodexReplies(
      streamOptions({
        file,
        clock,
        signal: controller.signal,
        getAcceptedSteerRevision: () => fence.snapshot(),
        onMessage: async (message) => messages.push(message),
        sleepFn: async (milliseconds) => {
          clock.now += milliseconds;
          sleeps += 1;
          if (sleeps === 1) {
            const acceptedOffset = append(file, [
              jsonlEntry("event_msg", {
                type: "user_message",
                message:
                  "[bridge_followup_request_id: abort-steer]\nStop this stream.",
              }),
            ]);
            fence.accept({
              acceptedOffset,
              requestToken: "abort-steer",
              rootSessionId: ROOT_SESSION_ID,
              turnId: TURN_ID,
              sessionFile: file,
            });
            controller.abort();
          }
        },
      }),
    ),
    (error) => error?.code === "CODEX_REPLY_STREAM_ABORTED",
    "an aborted response stream must remain fail-closed",
  );
  assert.deepEqual(
    messages,
    [],
    "abort after accepted steer must not leak a prior-revision final",
  );
});

{
  const fence = new AcceptedSteerResponseRevisionFence();
  const sessionFile = "/tmp/voice-relay-revision-fence.jsonl";
  assert.deepEqual(
    fence.accept({
      acceptedOffset: 10,
      requestToken: "revision-one",
      rootSessionId: ROOT_SESSION_ID,
      turnId: TURN_ID,
      sessionFile,
    }),
    {
      acceptedRevision: 1,
      acceptedOffset: 10,
      requestToken: "revision-one",
      rootSessionId: ROOT_SESSION_ID,
      turnId: TURN_ID,
      sessionFile,
    },
    "the first accepted steer must create response revision one",
  );
  await assert.rejects(
    async () =>
      fence.accept({
        acceptedOffset: 10,
        requestToken: "duplicate-offset",
        rootSessionId: ROOT_SESSION_ID,
        turnId: TURN_ID,
        sessionFile,
      }),
    /must advance/,
    "duplicate or regressive acceptance evidence must fail closed",
  );
  await assert.rejects(
    async () =>
      fence.accept({
        acceptedOffset: 20,
        requestToken: "foreign-turn",
        rootSessionId: ROOT_SESSION_ID,
        turnId: "019fb137-fence-7000-8000-000000000002",
        sessionFile,
      }),
    /must remain in one response scope/,
    "successive revisions must not cross root, turn, or session-file scope",
  );
  assert.equal(
    fence.accept({
      acceptedOffset: 20,
      requestToken: "revision-two",
      rootSessionId: ROOT_SESSION_ID,
      turnId: TURN_ID,
      sessionFile,
    }).acceptedRevision,
    2,
    "successive accepted steers must advance one durable response revision",
  );
}

console.log("Codex reply revision fence tests passed.");
