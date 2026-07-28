import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(
  testDirectory,
  "..",
  "Sources",
  "DirectRealtimeController.swift"
);
const source = fs.readFileSync(sourcePath, "utf8");
const scriptMatch = source.match(/    <script>\n([\s\S]*?)    <\/script>/);
assert.ok(scriptMatch, "embedded Realtime runtime script must be extractable");

const nativeMessages = [];
const window = {
  webkit: {
    messageHandlers: {
      voiceRelay: {
        postMessage(payload) {
          nativeMessages.push(payload);
        },
      },
    },
  },
};
const context = vm.createContext({
  window,
  console,
  setTimeout,
  clearTimeout,
});
vm.runInContext(scriptMatch[1], context, {
  filename: "DirectRealtimeController.runtime.js",
});

const runtime = window.VoiceRelayNativeVoice;
assert.ok(runtime, "embedded Realtime runtime must expose its native API");

function receive(event) {
  runtime.receiveRealtimeEvent({ generation: 1, event });
}

function realtimeEvents() {
  return nativeMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON));
}

function responseCreates() {
  return realtimeEvents().filter(event => event.type === "response.create");
}

function sessionUpdates() {
  return realtimeEvents().filter(event => event.type === "session.update");
}

function nativeEvents(type) {
  return nativeMessages.filter(message => message.type === type);
}

runtime.start({
  generation: 1,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 1 });
runtime.transportReady({ generation: 1 });
assert.match(
  sessionUpdates().at(-1)?.session?.instructions || "",
  /Any factual, current-state, personal-context, device-state, external-information, calculation, or verification request must use codex/,
  "substantive or context-dependent questions must stay outside direct Realtime chat",
);
assert.match(
  sessionUpdates().at(-1)?.session?.instructions || "",
  /could take more than about five seconds/,
  "Realtime must hand off work that cannot be answered immediately and reliably",
);
assert.match(
  sessionUpdates().at(-1)?.session?.instructions || "",
  /When in doubt, use codex/,
  "ambiguous routing must prefer the full Codex path",
);

receive({
  type: "conversation.item.input_audio_transcription.completed",
  transcript: "내일 날씨 확인해줘",
});
assert.equal(responseCreates().length, 1, "routing starts one response");

receive({
  type: "response.created",
  response: { id: "route-1", metadata: {} },
});
receive({
  type: "response.function_call_arguments.done",
  name: "route_voice_turn",
  call_id: "route-call-1",
  arguments: JSON.stringify({ kind: "codex" }),
});
assert.equal(
  responseCreates().length,
  1,
  "progress must wait until the routing response finishes"
);
assert.equal(
  nativeEvents("codexRequest").length,
  1,
  "Codex work starts immediately while progress speech waits"
);

receive({
  type: "response.done",
  response: {
    id: "route-1",
    output: [{ type: "function_call" }],
  },
});
assert.equal(responseCreates().length, 2, "progress starts after routing");
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "codex_progress"
);
assert.doesNotMatch(
  responseCreates().at(-1).response.instructions,
  /확인해볼게|잠시만|One moment, I'll check/,
  "progress instructions must not pin a stock spoken phrase"
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /Do not answer any part of the request/,
  "handoff speech must remain action-only and cannot pre-answer the request",
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /knowledge, uncertainty, inability, or missing information/,
  "handoff speech must not claim that the requested context is unknown",
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /Never ask a question or request information/,
  "handoff speech must never ask the user for location or other context",
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /Assume all configured private context is already attached/,
  "handoff speech must treat private context injection as complete",
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /Let me check/,
  "English handoff speech should have a natural Realtime example",
);

receive({
  type: "response.created",
  response: {
    id: "progress-1",
    metadata: { voice_relay_kind: "codex_progress" },
  },
});
runtime.speakCodexCommentary({
  generation: 1,
  messageId: "commentary-1",
  text: "관련 설정을 확인하고 있어.",
});
assert.equal(
  responseCreates().length,
  2,
  "commentary must queue behind active progress speech"
);

const assistantEventCountBeforeProgress =
  nativeEvents("assistantPartial").length
  + nativeEvents("assistantFinal").length;
receive({
  type: "response.output_audio_transcript.delta",
  response_id: "progress-1",
  delta: "진행 멘트",
});
receive({
  type: "response.output_audio_transcript.done",
  response_id: "progress-1",
  transcript: "진행 멘트",
});
assert.equal(
  nativeEvents("assistantPartial").length
    + nativeEvents("assistantFinal").length,
  assistantEventCountBeforeProgress,
  "progress transcript must never enter final-answer state"
);
assert.equal(
  nativeEvents("assistantProgress").at(-1)?.text,
  "진행 멘트",
  "spoken Realtime handoff progress must remain visible"
);

receive({
  type: "response.done",
  response: {
    id: "progress-1",
    metadata: { voice_relay_kind: "codex_progress" },
    output: [],
  },
});
assert.equal(responseCreates().length, 3, "commentary follows progress");
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "codex_commentary"
);

receive({
  type: "response.created",
  response: {
    id: "commentary-1",
    metadata: { voice_relay_kind: "codex_commentary" },
  },
});
const assistantEventCountBeforeCommentary =
  nativeEvents("assistantPartial").length
  + nativeEvents("assistantFinal").length;
receive({
  type: "response.output_audio_transcript.delta",
  response_id: "commentary-1",
  delta: "관련 설정을 확인하고 있어.",
});
receive({
  type: "response.output_audio_transcript.done",
  response_id: "commentary-1",
  transcript: "관련 설정을 확인하고 있어.",
});
assert.equal(
  nativeEvents("assistantPartial").length
    + nativeEvents("assistantFinal").length,
  assistantEventCountBeforeCommentary,
  "commentary transcript must never enter final-answer state"
);
assert.equal(
  nativeEvents("assistantProgress").at(-1)?.text,
  "관련 설정을 확인하고 있어.",
  "spoken Codex commentary must remain visible"
);

runtime.resolveCodex({
  generation: 1,
  callId: "route-call-1",
  output: "내일은 맑을 예정이야.",
});
assert.equal(
  responseCreates().length,
  3,
  "final speech must wait behind active commentary"
);

receive({
  type: "response.done",
  response: {
    id: "commentary-1",
    metadata: { voice_relay_kind: "codex_commentary" },
    output: [],
  },
});
assert.equal(responseCreates().length, 4, "final follows commentary");
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "codex_final"
);

receive({
  type: "response.created",
  response: {
    id: "final-1",
    metadata: { voice_relay_kind: "codex_final" },
  },
});
receive({
  type: "response.output_audio_transcript.delta",
  response_id: "final-1",
  delta: "내일은 맑을 예정이야.",
});
receive({
  type: "response.output_audio_transcript.done",
  response_id: "final-1",
  transcript: "내일은 맑을 예정이야.",
});
assert.equal(
  nativeEvents("assistantFinal").at(-1)?.text,
  "내일은 맑을 예정이야.",
  "only the final Realtime response becomes the assistant answer"
);

const messagesBeforeDirect = nativeMessages.length;
runtime.start({
  generation: 2,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 2 });
runtime.transportReady({ generation: 2 });
runtime.receiveRealtimeEvent({
  generation: 2,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "오케이",
  },
});
runtime.receiveRealtimeEvent({
  generation: 2,
  event: {
    type: "response.created",
    response: { id: "route-2", metadata: {} },
  },
});
runtime.receiveRealtimeEvent({
  generation: 2,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "direct-call-2",
    arguments: JSON.stringify({ kind: "direct_chat" }),
  },
});
const generationTwoMessages = nativeMessages.slice(messagesBeforeDirect);
assert.equal(
  generationTwoMessages.filter(message => message.type === "codexRequest").length,
  0,
  "Realtime semantic direct_chat must not start a Codex turn"
);
const generationTwoCreates = generationTwoMessages
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .filter(event => event.type === "response.create");
assert.equal(
  generationTwoCreates.length,
  2,
  "Realtime semantic direct_chat must answer through the routed tool result only"
);
runtime.receiveRealtimeEvent({
  generation: 2,
  event: {
    type: "response.created",
    response: { id: "direct-2", metadata: {} },
  },
});
runtime.receiveRealtimeEvent({
  generation: 2,
  event: {
    type: "response.output_audio_transcript.delta",
    response_id: "direct-2",
    delta: "응.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 2,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "direct-2",
    transcript: "응.",
  },
});
assert.equal(
  nativeEvents("assistantFinal").at(-1)?.text,
  "응.",
  "a direct Realtime reply must remain visible while it is spoken",
);

console.log("Realtime response queue tests passed");
