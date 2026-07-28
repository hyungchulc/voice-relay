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
assert.deepEqual(
  Array.from(responseCreates().at(-1).response.output_modalities),
  ["text"],
  "the route classifier must never create an audio response",
);
assert.equal(
  responseCreates().at(-1).response.tool_choice,
  "required",
  "every accepted turn must mechanically require the routing tool",
);
assert.equal(
  responseCreates().at(-1).response.parallel_tool_calls,
  false,
  "the route classifier must produce exactly one route decision",
);
assert.equal(
  responseCreates().at(-1).response.tools.length,
  1,
  "the route classifier must expose only one tool",
);
assert.equal(
  responseCreates().at(-1).response.tools[0].name,
  "route_voice_turn",
  "the required route tool must be route_voice_turn",
);
assert.deepEqual(
  Array.from(responseCreates().at(-1).response.tools[0].parameters.required),
  ["kind", "social_origin"],
  "the route tool must require a fail-closed social-origin classification",
);
assert.deepEqual(
  Array.from(
    responseCreates().at(-1).response.tools[0]
      .parameters.properties.social_origin.enum,
  ),
  [
    "user_reply",
    "assistant_like_playback",
    "independent",
    "not_applicable",
  ],
  "social-origin classification must distinguish real replies from playback",
);
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "route_classifier",
  "route responses must remain distinguishable from spoken replies",
);

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
  type: "response.function_call_arguments.done",
  name: "route_voice_turn",
  call_id: "duplicate-route-call",
  arguments: JSON.stringify({ kind: "codex" }),
});
assert.equal(
  nativeEvents("codexRequest").length,
  1,
  "duplicate route completions must not start duplicate Codex work",
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
const progressInstructions =
  responseCreates().at(-1).response.instructions;
assert.doesNotMatch(
  progressInstructions,
  /확인해볼게|잠시만|One moment, I'll check/,
  "progress instructions must not pin a stock spoken phrase"
);
assert.match(
  progressInstructions,
  /Speak exactly this acknowledgement, with no additions or omissions/,
  "handoff speech must request one exact locally selected acknowledgement",
);
assert.doesNotMatch(
  progressInstructions,
  /내일 날씨 확인해줘/,
  "handoff speech must never receive the original user request",
);
assert.match(
  progressInstructions,
  /알겠어, 바로 살펴볼게/,
  "the first Korean handoff must use the local rotating whitelist",
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
  nativeEvents("assistantProgress").filter(
    event => event.kind === "codex_commentary"
  ).length,
  0,
  "raw Codex commentary must not be replaced by a second generated transcript"
);

runtime.speakCodexCommentary({
  generation: 1,
  messageId: "commentary-2",
  text: "관련 설정을 확인하고 있어. 로그를 대조했어.",
});
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
assert.equal(responseCreates().length, 4, "cumulative commentary follows");
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "codex_commentary"
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /로그를 대조했어/,
  "only the new suffix of cumulative commentary should be spoken"
);
assert.doesNotMatch(
  responseCreates().at(-1).response.instructions,
  /관련 설정을 확인하고 있어/,
  "already spoken commentary must not be repeated"
);

receive({
  type: "response.created",
  response: {
    id: "commentary-2",
    metadata: { voice_relay_kind: "codex_commentary" },
  },
});
receive({
  type: "response.done",
  response: {
    id: "commentary-2",
    metadata: { voice_relay_kind: "codex_commentary" },
    output: [],
  },
});
assert.equal(responseCreates().length, 5, "final follows all commentary");
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

const messagesBeforeRouteFailure = nativeMessages.length;
runtime.start({
  generation: 3,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 3 });
runtime.transportReady({ generation: 3 });
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "스톡홀름 날씨 알려줘",
  },
});
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "response.created",
    response: {
      id: "route-failure-1",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
const assistantEventsBeforeInvalidRoute =
  nativeEvents("assistantPartial").length
  + nativeEvents("assistantFinal").length;
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "response.output_audio_transcript.delta",
    response_id: "route-failure-1",
    delta: "확인할 수 없어요.",
  },
});
assert.equal(
  nativeEvents("assistantPartial").length
    + nativeEvents("assistantFinal").length,
  assistantEventsBeforeInvalidRoute,
  "a route-classifier answer must never escape into assistant output",
);
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "response.function_call_arguments.done",
    name: "unexpected_route_tool",
    call_id: "unexpected-route-call",
    arguments: JSON.stringify({ kind: "direct_chat" }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "response.done",
    response: {
      id: "route-failure-1",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call", name: "unexpected_route_tool" }],
    },
  },
});
const routeFailureMessages = nativeMessages.slice(messagesBeforeRouteFailure);
const routeFailureCreates = routeFailureMessages
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .filter(event => event.type === "response.create");
assert.equal(
  routeFailureCreates.length,
  2,
  "a wrong or missing route tool call must retry the classifier exactly once",
);
assert.equal(
  routeFailureCreates.at(-1).response.tool_choice,
  "required",
  "the retry must preserve the fail-closed tool requirement",
);
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "response.created",
    response: {
      id: "route-failure-2",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 3,
  event: {
    type: "response.done",
    response: {
      id: "route-failure-2",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [],
    },
  },
});
assert.equal(
  nativeEvents("turnError").at(-1)?.code,
  "route_classifier_failed",
  "a second missing tool call must fail closed without killing the session",
);
assert.equal(
  nativeEvents("codexRequest").filter(event => event.generation === 3).length,
  0,
  "the fail-closed route must not invent a Codex call without a tool result",
);

const messagesBeforeEchoBargeIn = nativeMessages.length;
runtime.start({
  generation: 4,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 4 });
runtime.transportReady({ generation: 4 });
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "안녕",
  },
});
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "response.created",
    response: {
      id: "route-echo-4",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "route-echo-call-4",
    arguments: JSON.stringify({ kind: "direct_chat" }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "response.done",
    response: {
      id: "route-echo-4",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "response.created",
    response: { id: "direct-echo-4", metadata: {} },
  },
});
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "response.output_audio.delta",
    response_id: "direct-echo-4",
  },
});
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "direct-echo-4",
    transcript: "반가워, 무엇을 도와줄까?",
  },
});
const echoCheckStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "반가워 무엇을 도와줄까",
  },
});
const echoMessages = nativeMessages.slice(echoCheckStart);
assert.equal(
  echoMessages.filter(message => message.type === "playbackResume").length,
  1,
  "assistant playback echo must resume provisionally paused audio",
);
assert.equal(
  echoMessages.filter(message => message.type === "playbackInterrupt").length,
  0,
  "assistant playback echo must never interrupt its own response",
);
assert.equal(
  echoMessages.filter(message => message.type === "codexRequest").length,
  0,
  "assistant playback echo must never become a Codex request",
);

const humanBargeInStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "아니, 내일 날씨부터 확인해줘",
  },
});
const humanBargeInMessages = nativeMessages.slice(humanBargeInStart);
assert.equal(
  humanBargeInMessages
    .filter(message => message.type === "playbackInterrupt").length,
  1,
  "a distinct human barge-in must stop buffered playback exactly once",
);
const humanCancellation = humanBargeInMessages
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .find(event => event.type === "response.cancel");
assert.equal(
  humanCancellation?.response_id,
  "direct-echo-4",
  "human barge-in must cancel the response that was actually playing",
);
assert.equal(
  humanBargeInMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event => event.type === "response.create").length,
  0,
  "the replacement turn must wait for correlated cancellation completion",
);
runtime.receiveRealtimeEvent({
  generation: 4,
  event: {
    type: "error",
    error: {
      event_id: humanCancellation.event_id,
      code: "invalid_request_error",
    },
  },
});
const postCancellationMessages =
  nativeMessages.slice(messagesBeforeEchoBargeIn);
assert.equal(
  postCancellationMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind === "route_classifier"
    ).length,
  2,
  "the replacement human turn must start once after cancellation resolves",
);

const messagesBeforeResponseDoneEcho = nativeMessages.length;
runtime.start({
  generation: 5,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 5 });
runtime.transportReady({ generation: 5 });
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "안녕",
  },
});
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "response.created",
    response: {
      id: "route-response-done-echo-5",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "route-response-done-echo-call-5",
    arguments: JSON.stringify({ kind: "direct_chat" }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "response.done",
    response: {
      id: "route-response-done-echo-5",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "response.created",
    response: { id: "direct-response-done-echo-5", metadata: {} },
  },
});
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "response.output_audio.delta",
    response_id: "direct-response-done-echo-5",
  },
});
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "response.done",
    response: {
      id: "direct-response-done-echo-5",
      output: [{
        type: "message",
        phase: "final_answer",
        content: [{
          type: "output_audio",
          transcript: "안녕",
        }],
      }],
    },
  },
});
const responseDoneEchoStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 5,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "안녕",
  },
});
const responseDoneEchoMessages =
  nativeMessages.slice(responseDoneEchoStart);
assert.equal(
  responseDoneEchoMessages
    .filter(message => message.type === "playbackResume").length,
  1,
  "response.done text must suppress playback echo when transcript events are absent",
);
assert.equal(
  responseDoneEchoMessages
    .filter(message => message.type === "playbackInterrupt").length,
  0,
  "response.done playback echo must not interrupt its own response",
);
assert.equal(
  responseDoneEchoMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind === "route_classifier"
    ).length,
  0,
  "response.done playback echo must not create a duplicate routed turn",
);

const messagesBeforeVariedHandoff = nativeMessages.length;
runtime.start({
  generation: 6,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 6 });
runtime.transportReady({ generation: 6 });
runtime.receiveRealtimeEvent({
  generation: 6,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    transcript: "오늘 일정 확인해줘",
  },
});
runtime.receiveRealtimeEvent({
  generation: 6,
  event: {
    type: "response.created",
    response: {
      id: "route-handoff-5",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 6,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "route-handoff-call-5",
    arguments: JSON.stringify({ kind: "codex" }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 6,
  event: {
    type: "response.done",
    response: {
      id: "route-handoff-5",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
const variedHandoffRequest = nativeMessages
  .slice(messagesBeforeVariedHandoff)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .find(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_progress"
  );
assert.doesNotMatch(
  variedHandoffRequest?.response?.instructions || "",
  /진행 멘트/,
  "a later handoff prompt must not receive a prior generated transcript",
);
assert.match(
  variedHandoffRequest?.response?.instructions || "",
  /좋아, 맡겨줘/,
  "a later handoff must advance to the next local acknowledgement",
);

const wakeAcknowledgementStart = nativeMessages.length;
runtime.start({
  generation: 7,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: true,
});
runtime.transportOpened({ generation: 7 });
runtime.transportReady({ generation: 7 });
const wakeAcknowledgement = nativeMessages
  .slice(wakeAcknowledgementStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .find(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind
      === "wake_acknowledgement"
  );
assert.ok(
  wakeAcknowledgement,
  "a wake-only activation must create one Realtime acknowledgement",
);
assert.match(
  wakeAcknowledgement.response.instructions,
  /fresh wording freely instead of using a fixed stock phrase/,
  "wake acknowledgement wording must not be fixed",
);

const earlyBargeInStart = nativeMessages.length;
runtime.start({
  generation: 8,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: true,
});
runtime.transportOpened({ generation: 8 });
runtime.transportReady({ generation: 8 });
runtime.receiveRealtimeEvent({
  generation: 8,
  event: {
    type: "response.created",
    response: {
      id: "wake-ack-before-audio",
      metadata: { voice_relay_kind: "wake_acknowledgement" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 8,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 8,
  event: { type: "input_audio_buffer.speech_started" },
});
const earlyBargeInEvents = nativeMessages
  .slice(earlyBargeInStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
assert.equal(
  earlyBargeInEvents.filter(event =>
    event.type === "response.cancel"
      && event.response_id === "wake-ack-before-audio"
  ).length,
  1,
  "admitted speech must cancel a still-generating response exactly once before its first audio delta",
);

const replayedTurnStart = nativeMessages.length;
runtime.start({
  generation: 9,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Aria",
  wakePhrases: ["Hey Aria"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 9 });
runtime.transportReady({ generation: 9 });
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "weather-user-item-1",
    transcript: "Can you check the weather near my home now?",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.created",
    response: {
      id: "weather-route-1",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "weather-route-call-1",
    arguments: JSON.stringify({ kind: "codex" }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.done",
    response: {
      id: "weather-route-1",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "weather-user-item-before-playback",
    transcript: "Can you check the weather near my home now?",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.created",
    response: {
      id: "weather-progress-speech-1",
      metadata: { voice_relay_kind: "codex_progress" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.output_audio.delta",
    response_id: "weather-progress-speech-1",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "weather-progress-speech-1",
    transcript: "I’ll check that.",
  },
});
const weatherProgressDoneStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.done",
    response: {
      id: "weather-progress-speech-1",
      status: "completed",
      metadata: { voice_relay_kind: "codex_progress" },
      output: [],
    },
  },
});
assert.equal(
  nativeMessages.slice(weatherProgressDoneStart).filter(message =>
    message.type === "state"
    && message.phase === "thinking"
  ).length,
  0,
  "completed transient generation must remain speaking until native playback drains",
);
runtime.playbackDrained({
  generation: 9,
  responseId: "weather-progress-speech-1",
});
assert.equal(
  nativeMessages.slice(weatherProgressDoneStart).filter(message =>
    message.type === "state"
    && message.phase === "thinking"
  ).length,
  1,
  "transient playback drain must return the live Codex turn to thinking once",
);
runtime.resolveCodex({
  generation: 9,
  callId: "weather-route-call-1",
  output: "It is clear and 19 degrees.",
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.created",
    response: {
      id: "weather-final-speech-1",
      metadata: { voice_relay_kind: "codex_final" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.output_audio.delta",
    response_id: "weather-final-speech-1",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "weather-user-item-2",
    transcript: "Can you check the weather near my home now?",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "weather-user-item-1",
    transcript: "Can you check the weather near my home now?",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "weather-final-speech-1",
    transcript: "It is clear and 19 degrees.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "response.done",
    response: {
      id: "weather-final-speech-1",
      status: "completed",
      metadata: { voice_relay_kind: "codex_final" },
      output: [],
    },
  },
});
runtime.playbackDrained({
  generation: 9,
  responseId: "weather-final-speech-1",
});
runtime.receiveRealtimeEvent({
  generation: 9,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "weather-user-item-after-playback",
    transcript: "Can you check the weather near my home now?",
  },
});
const replayedTurnMessages = nativeMessages.slice(replayedTurnStart);
assert.equal(
  replayedTurnMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "replayed_user_turn_suppressed"
  ).length,
  3,
  "an accepted request retranscribed during work, playback, or the post-answer echo tail must be suppressed even under a new item id",
);
assert.equal(
  replayedTurnMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "duplicate_user_audio_item_suppressed"
  ).length,
  1,
  "a completed Realtime audio item must be handled exactly once",
);
assert.equal(
  replayedTurnMessages.filter(message =>
    message.type === "codexRequest"
  ).length,
  1,
  "looped or repeated transcription events must not create a second Codex request",
);

const postFinalEchoStart = nativeMessages.length;
runtime.start({
  generation: 10,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Aria",
  wakePhrases: ["Hey Aria"],
  shouldGreet: false,
  activationReason: "wake_with_command",
});
runtime.transportOpened({ generation: 10 });
runtime.transportReady({ generation: 10 });
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "post-final-user-1",
    transcript: "Check the weather near me.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.created",
    response: {
      id: "post-final-route-1",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "post-final-call-1",
    arguments: JSON.stringify({ kind: "codex" }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.done",
    response: {
      id: "post-final-route-1",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.created",
    response: {
      id: "post-final-progress-1",
      metadata: { voice_relay_kind: "codex_progress" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.done",
    response: {
      id: "post-final-progress-1",
      status: "completed",
      metadata: { voice_relay_kind: "codex_progress" },
      output: [],
    },
  },
});
runtime.resolveCodex({
  generation: 10,
  callId: "post-final-call-1",
  output: "The current weather is clear.",
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.created",
    response: {
      id: "post-final-speech-1",
      metadata: { voice_relay_kind: "codex_final" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.output_audio.delta",
    response_id: "post-final-speech-1",
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "post-final-speech-1",
    transcript: "The current weather is clear.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.done",
    response: {
      id: "post-final-speech-1",
      status: "completed",
      metadata: { voice_relay_kind: "codex_final" },
      output: [],
    },
  },
});
runtime.playbackDrained({
  generation: 10,
  responseId: "post-final-speech-1",
});
const exactRecentEchoStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "post-final-exact-echo-item",
    transcript: "The current weather is clear.",
  },
});
const exactRecentEchoMessages =
  nativeMessages.slice(exactRecentEchoStart);
assert.equal(
  exactRecentEchoMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "playback_echo_transcript_suppressed"
  ).length,
  1,
  "an exact post-drain playback echo must be rejected before semantic routing",
);
assert.equal(
  exactRecentEchoMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event => event.type === "response.create").length,
  0,
  "an exact post-drain playback echo must not create a route classifier",
);
assert.equal(
  exactRecentEchoMessages.filter(message =>
    message.type === "userTranscript"
  ).length,
  0,
  "an exact post-drain playback echo must not become a visible user turn",
);
const novelPlaybackEchoStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "post-final-echo-item",
    transcript: "I will check that now.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.created",
    response: {
      id: "post-final-echo-route",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "post-final-echo-call",
    arguments: JSON.stringify({
      kind: "direct_chat",
      social_origin: "assistant_like_playback",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.done",
    response: {
      id: "post-final-echo-route",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
const novelPlaybackEchoMessages =
  nativeMessages.slice(novelPlaybackEchoStart);
assert.equal(
  novelPlaybackEchoMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "playback_contended_social_turn_suppressed"
  ).length,
  1,
  "a novel self-echo after Codex final playback must be suppressed after semantic routing",
);
assert.equal(
  novelPlaybackEchoMessages.filter(message =>
    message.type === "userTranscript"
  ).length,
  0,
  "a suppressed post-final playback echo must never appear as a user turn",
);
assert.equal(
  novelPlaybackEchoMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind !== "route_classifier"
    ).length,
  0,
  "a suppressed post-final playback echo must never create a second spoken reply",
);
assert.equal(
  nativeMessages
    .slice(postFinalEchoStart)
    .filter(message => message.type === "codexRequest").length,
  1,
  "a post-final playback echo must never create a second Codex request",
);

const postFinalReplyStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "post-final-thanks-item",
    transcript: "Thanks.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.created",
    response: {
      id: "post-final-thanks-route",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 10,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "post-final-thanks-call",
    arguments: JSON.stringify({
      kind: "direct_chat",
      social_origin: "user_reply",
    }),
  },
});
const postFinalReplyMessages = nativeMessages.slice(postFinalReplyStart);
assert.equal(
  postFinalReplyMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "playback_contended_user_reply_admitted"
  ).length,
  1,
  "a real post-final social reply must pass the playback-tail backstop",
);
assert.equal(
  postFinalReplyMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "playback_contended_social_turn_suppressed"
  ).length,
  0,
  "a real post-final social reply must not be suppressed as playback",
);
assert.equal(
  postFinalReplyMessages.filter(message =>
    message.type === "userTranscript"
    && message.text === "Thanks."
  ).length,
  1,
  "an admitted post-final social reply must remain visible as a user turn",
);
assert.equal(
  postFinalReplyMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind !== "route_classifier"
    ).length,
  1,
  "an admitted post-final social reply must create exactly one spoken reply",
);
assert.equal(
  postFinalReplyMessages.filter(message =>
    message.type === "codexRequest"
  ).length,
  0,
  "a post-final conversational receipt must stay on the direct Realtime path",
);

console.log("Realtime response queue tests passed");
