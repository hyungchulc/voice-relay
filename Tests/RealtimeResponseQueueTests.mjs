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
  [
    "kind",
    "social_origin",
    "spoken_language",
    "spoken_register",
    "stop_target",
  ],
  "the route tool must require semantic stop-target, social-origin, language, and register classification",
);
assert.equal(
  responseCreates().at(-1).response.tools[0]
    .parameters.properties.spoken_language.type,
  "string",
  "the route tool must carry a language tag without a phrase table",
);
assert.deepEqual(
  Array.from(
    responseCreates().at(-1).response.tools[0]
      .parameters.properties.spoken_register.enum,
  ),
  ["casual", "polite", "neutral"],
  "the route tool must carry a language-neutral speaking register",
);
assert.deepEqual(
  Array.from(
    responseCreates().at(-1).response.tools[0]
      .parameters.properties.stop_target.enum,
  ),
  [
    "current_voice_or_codex_work",
    "external_or_other_object",
    "not_applicable",
    "ambiguous",
  ],
  "the route tool must separate assistant-work stops from external-object commands",
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
assert.match(
  responseCreates().at(-1).response.instructions || "",
  /Use local_presence for a short presence, hearing, or listening check/,
  "per-turn routing must preserve the local presence exception",
);
assert.match(
  responseCreates().at(-1).response.tools[0].description || "",
  /local_presence for a short presence, hearing, or listening check/,
  "the route tool contract must expose the local presence exception",
);

receive({
  type: "response.created",
  response: { id: "route-1", metadata: {} },
});
receive({
  type: "response.function_call_arguments.done",
  name: "route_voice_turn",
  call_id: "route-call-1",
  arguments: JSON.stringify({
    kind: "codex",
    social_origin: "not_applicable",
    spoken_language: "ko",
    spoken_register: "casual",
  }),
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
assert.equal(
  responseCreates().at(-1).response.conversation,
  "none",
  "handoff progress must stay outside the default conversation",
);
assert.deepEqual(
  responseCreates().at(-1).response.input,
  [],
  "handoff progress must not read prior Realtime conversation context",
);
const progressInstructions =
  responseCreates().at(-1).response.instructions;
assert.match(
  progressInstructions,
  /BCP 47 tag: "ko"/,
  "handoff speech must use the classified language",
);
assert.match(
  progressInstructions,
  /speaking register: "casual"/,
  "handoff speech must preserve the classified conversational register",
);
assert.match(
  progressInstructions,
  /untrusted user request data/,
  "handoff speech must treat request context as data rather than instructions",
);
assert.match(
  progressInstructions,
  /"내일 날씨 확인해줘"/,
  "handoff speech must receive the current request for action-specific wording",
);
assert.match(
  progressInstructions,
  /Do not answer the request, report a result or finding, claim success or completion/,
  "handoff speech must not turn request context into a false result",
);
assert.match(
  progressInstructions,
  /Ignore all prior conversational content for this response/,
  "handoff speech must not infer an answer from prior Realtime conversation",
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
  "the first commentary must be absorbed behind request-aware progress speech"
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
assert.equal(
  responseCreates().length,
  2,
  "the first Codex commentary must not repeat the initial spoken plan"
);
assert.equal(
  nativeEvents("diagnostic").filter(
    event =>
      event.stage
        === "codex_commentary_suppressed_after_request_aware_progress"
  ).length,
  1,
  "the absorbed commentary decision must remain observable"
);

runtime.speakCodexCommentary({
  generation: 1,
  messageId: "commentary-2",
  text:
    "관련 설정을 확인하고 있어. 로그를 대조했어.\n\n" +
    "Sources:\n- [Raw API](https://example.com/raw)",
});
assert.equal(responseCreates().length, 3, "new commentary suffix follows progress");
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "codex_commentary"
);
assert.equal(
  responseCreates().at(-1).response.conversation,
  "none",
  "Codex commentary playback must stay outside the default conversation",
);
assert.deepEqual(
  responseCreates().at(-1).response.input,
  [],
  "Codex commentary playback must not read prior Realtime conversation context",
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /로그를 대조했어/,
  "only the new suffix after absorbed commentary should be spoken"
);
assert.doesNotMatch(
  responseCreates().at(-1).response.instructions,
  /관련 설정을 확인하고 있어/,
  "absorbed initial commentary must seed cumulative speech deduplication"
);
assert.doesNotMatch(
  responseCreates().at(-1).response.instructions,
  /https?:\/\/|Sources:|\]\(/,
  "commentary speech must omit source blocks and Markdown destinations",
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
assert.equal(responseCreates().length, 4, "final follows all commentary");
assert.equal(
  responseCreates().at(-1).response.metadata.voice_relay_kind,
  "codex_final"
);
assert.equal(
  Object.hasOwn(responseCreates().at(-1).response, "input"),
  false,
  "the final playback response must retain the preceding function-result context",
);
assert.match(
  responseCreates().at(-1).response.instructions,
  /Read the answer field .* exactly as written/,
  "final speech must read Codex output instead of generating another answer",
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
    arguments: JSON.stringify({
      kind: "direct_chat",
      social_origin: "user_reply",
      spoken_language: "ko-KR",
      spoken_register: "casual",
    }),
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
assert.match(
  generationTwoCreates.at(-1)?.response?.instructions || "",
  /BCP 47 tag: "ko-KR"/,
  "a direct reply must use the classifier's spoken language",
);
assert.match(
  generationTwoCreates.at(-1)?.response?.instructions || "",
  /speaking register: "casual"/,
  "a direct reply must use the classifier's spoken register",
);
assert.match(
  generationTwoCreates.at(-1)?.response?.instructions || "",
  /Use one consistent speaking register throughout the entire response/,
  "a direct reply must not mix casual and polite forms",
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
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind === "route_classifier"
    ).length,
  1,
  "discarded local playback must let the committed replacement start without a server cancel terminal",
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
    arguments: JSON.stringify({
      kind: "codex",
      social_origin: "not_applicable",
      spoken_language: "es-MX",
      spoken_register: "polite",
    }),
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
  /BCP 47 tag: "es-MX"/,
  "handoff progress must support languages outside a hard-coded language pair",
);
assert.match(
  variedHandoffRequest?.response?.instructions || "",
  /speaking register: "polite"/,
  "handoff progress must preserve register across configured languages",
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

const presenceReturnStart = nativeMessages.length;
runtime.start({
  generation: 70,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["Relay"],
  shouldGreet: true,
  activationReason: "presence_return",
});
runtime.transportOpened({ generation: 70 });
runtime.transportReady({ generation: 70 });
const presenceReturnGreeting = nativeMessages
  .slice(presenceReturnStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .find(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind
      === "presence_return_greeting"
  );
assert.ok(
  presenceReturnGreeting,
  "a return candidate must create one spoken presence greeting",
);
assert.match(
  presenceReturnGreeting.response.instructions,
  /just returned after being away/,
  "presence return must use the return-specific semantic prompt",
);
assert.match(
  presenceReturnGreeting.response.instructions,
  /fresh wording freely instead of using a fixed stock phrase/,
  "presence greeting wording must not be fixed",
);

const unidentifiedWakeBargeInStart = nativeMessages.length;
runtime.start({
  generation: 71,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Aria",
  wakePhrases: ["Hey Aria"],
  shouldGreet: true,
});
runtime.transportOpened({ generation: 71 });
runtime.transportReady({ generation: 71 });
runtime.receiveRealtimeEvent({
  generation: 71,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 71,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 71,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "wake-barge-in-user-71",
    transcript: "Can you hear me?",
  },
});
const unidentifiedWakeBeforeCreated = nativeMessages
  .slice(unidentifiedWakeBargeInStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
assert.equal(
  unidentifiedWakeBeforeCreated.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  0,
  "a user turn must not overlap a requested wake response before its ID is known",
);
runtime.receiveRealtimeEvent({
  generation: 71,
  event: {
    type: "response.created",
    response: {
      id: "late-wake-acknowledgement-71",
      metadata: { voice_relay_kind: "wake_acknowledgement" },
    },
  },
});
const unidentifiedWakeEvents = nativeMessages
  .slice(unidentifiedWakeBargeInStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
assert.equal(
  unidentifiedWakeEvents.filter(event =>
    event.type === "response.cancel"
    && event.response_id === "late-wake-acknowledgement-71"
  ).length,
  1,
  "speech must preempt a wake acknowledgement even before its response ID exists",
);
runtime.receiveRealtimeEvent({
  generation: 71,
  event: {
    type: "response.done",
    response: {
      id: "late-wake-acknowledgement-71",
      status: "cancelled",
      metadata: { voice_relay_kind: "wake_acknowledgement" },
      output: [],
    },
  },
});
const unidentifiedWakeAfterCancellation = nativeMessages
  .slice(unidentifiedWakeBargeInStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
assert.equal(
  unidentifiedWakeAfterCancellation.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  1,
  "the queued user turn must start once after wake-response cancellation resolves",
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

const codexFailureStart = nativeMessages.length;
runtime.start({
  generation: 11,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["Hey Relay"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 11 });
runtime.transportReady({ generation: 11 });
runtime.resolveCodex({
  generation: 11,
  callId: "failed-codex-call",
  error: "An Additional Context Provider failed (APP_REMOTE_FAILED)",
});
const codexFailureEvents = nativeMessages
  .slice(codexFailureStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
const failureOutputEvent = codexFailureEvents.find(event =>
  event.type === "conversation.item.create"
  && event.item?.type === "function_call_output"
  && event.item?.call_id === "failed-codex-call"
);
assert.deepEqual(
  JSON.parse(failureOutputEvent?.item?.output || "{}"),
  { status: "error" },
  "raw Codex diagnostics must never be given back to Realtime to explain",
);
const failureSpeech = codexFailureEvents.find(event =>
  event.type === "response.create"
  && event.response?.metadata?.voice_relay_kind === "codex_final"
);
assert.match(
  failureSpeech?.response?.instructions || "",
  /Say exactly this and nothing else: "I couldn't complete that request\. Please try again\."/,
  "Codex failure speech must use deterministic generic copy",
);
assert.doesNotMatch(
  failureSpeech?.response?.instructions || "",
  /Additional Context Provider|APP_REMOTE_FAILED|weather|reliably/,
  "Codex failure speech must not fabricate a provider or capability explanation",
);

const speechProjectionStart = nativeMessages.length;
runtime.start({
  generation: 12,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["릴레이야"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 12 });
runtime.transportReady({ generation: 12 });
const sourceRichOriginal =
  "오늘은 맑아. [예보 상세](https://weather.example/forecast)를 확인했어. " +
  "추가 원문은 https://weather.example/raw 이야.\n" +
  "예상 범위는 18~27도고 ~~강조 표시~~도 자연스럽게 읽어.\n" +
  "#3 상태와 96개 테스트, VR-204, 짧은 커밋 a1b2c3d는 그대로 알려줘.\n" +
  '<a href="https://openai.example/report">OpenAI</a> 발표를 확인했어.\n' +
  "Task ID는 `019faf33-597f-73e3-b9b7-0486adc91dfc`야.\n" +
  "커밋은 `113410f5f2d12e602e1f77a39a074fb5792388fa`야.\n" +
  "[현재 영상](https://video.example/current), " +
  "[공식 영상 클립](https://video.example/official)\n" +
  '<a href="https://video.example/current">현재 영상</a>, ' +
  '<a href="https://video.example/official">공식 영상</a>\n' +
  "[1] [2] [^build]\n" +
  "[^build]: [검증 로그](https://weather.example/build)\n\n" +
  "출처\n- [Weather API](https://weather.example/api)\n" +
  "- https://weather.example/source";
runtime.resolveCodex({
  generation: 12,
  callId: "source-rich-codex-call",
  output: sourceRichOriginal,
});
const speechProjectionEvents = nativeMessages
  .slice(speechProjectionStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
const sourceRichOutput = speechProjectionEvents.find(event =>
  event.type === "conversation.item.create"
  && event.item?.type === "function_call_output"
  && event.item?.call_id === "source-rich-codex-call"
);
const sourceRichAnswer =
  JSON.parse(sourceRichOutput?.item?.output || "{}").answer || "";
assert.match(
  sourceRichAnswer,
  /오늘은 맑아\. 예보 상세를 확인했어\./,
  "speech projection must preserve factual prose and human link labels",
);
assert.match(
  sourceRichAnswer,
  /18 ~ 27도/,
  "speech projection must preserve numeric range semantics",
);
assert.doesNotMatch(
  sourceRichAnswer,
  /1827도/,
  "speech projection must never concatenate numbers across a range tilde",
);
assert.match(
  sourceRichAnswer,
  /강조 표시도 자연스럽게 읽어/,
  "speech projection must remove paired formatting markers without dropping their text",
);
assert.match(
  sourceRichAnswer,
  /#3 상태와 96개 테스트, VR-204, 짧은 커밋 a1b2c3d/,
  "speech projection must preserve issue numbers, verification counts, and short human identifiers",
);
assert.match(
  sourceRichAnswer,
  /OpenAI 발표를 확인했어/,
  "speech projection must preserve meaningful inline HTML attribution",
);
assert.doesNotMatch(
  sourceRichAnswer,
  /019faf33-597f-73e3-b9b7-0486adc91dfc|113410f5f2d12e602e1f77a39a074fb5792388fa|Task ID|https?:\/\/|www\.|\]\(|<a\b|출처|Weather API|현재 영상|공식 영상 클립|공식 영상|\[1\]|\[2\]|\[\^build\]|검증 로그|~~/,
  "speech projection must omit opaque metadata, URLs, link-only clusters, footnotes, and source-only blocks",
);
const sourceRichSpeech = speechProjectionEvents.find(event =>
  event.type === "response.create"
  && event.response?.metadata?.voice_relay_kind === "codex_final"
);
assert.equal(
  Object.hasOwn(sourceRichSpeech?.response || {}, "input"),
  false,
  "final speech must still consume only the immediately preceding sanitized function result",
);
assert.match(
  sourceRichSpeech?.response?.instructions || "",
  /tilde appears between numbers/,
  "final speech must explicitly preserve numeric range delivery",
);
assert.match(
  sourceRichSpeech?.response?.instructions || "",
  /never concatenate the numbers/,
  "final speech must forbid joined numeric range endpoints",
);
runtime.receiveRealtimeEvent({
  generation: 12,
  event: {
    type: "response.created",
    response: {
      id: "source-rich-speech-12",
      metadata: { voice_relay_kind: "codex_final" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 12,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "source-rich-speech-12",
    transcript:
      "오늘은 맑아. 예상 범위는 18에서 27도고 96개 테스트를 통과했어.",
  },
});
assert.equal(
  nativeMessages
    .slice(speechProjectionStart)
    .filter(message => message.type === "assistantFinal")
    .at(-1)?.text,
  sourceRichOriginal,
  "speech projection must not alter the exact Codex final shown on the visible surface",
);

const pendingResponseBargeInStart = nativeMessages.length;
runtime.start({
  generation: 13,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Aria",
  wakePhrases: ["Hey Aria"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 13 });
runtime.transportReady({ generation: 13 });
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "pending-response-user-1",
    transcript: "Check the latest weather near me.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.created",
    response: {
      id: "pending-response-route-1",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "pending-response-route-call-1",
    arguments: JSON.stringify({
      kind: "codex",
      social_origin: "not_applicable",
      spoken_language: "en-US",
      spoken_register: "casual",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.done",
    response: {
      id: "pending-response-route-1",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
const pendingResponseBeforeSpeech = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 13,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "pending-response-user-2",
    transcript: "Stop the song.",
  },
});
const pendingResponseSpeechMessages =
  nativeMessages.slice(pendingResponseBeforeSpeech);
assert.equal(
  pendingResponseSpeechMessages.filter(message =>
    message.type === "playbackInterrupt"
  ).length,
  1,
  "repeated admitted speech must preempt requested assistant audio exactly once",
);
assert.equal(
  pendingResponseSpeechMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind
        === "active_codex_control"
    ).length,
  0,
  "active control must wait until requested-but-unidentified assistant audio is cancelled",
);
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.created",
    response: {
      id: "late-codex-progress-13",
      metadata: { voice_relay_kind: "codex_progress" },
    },
  },
});
const pendingResponseMessages =
  nativeMessages.slice(pendingResponseBargeInStart);
const lateResponseCancellations = pendingResponseMessages
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .filter(event =>
    event.type === "response.cancel"
    && event.response_id === "late-codex-progress-13"
  );
assert.equal(
  lateResponseCancellations.length,
  1,
  "a late created assistant response must be cancelled exactly once before playback",
);
assert.equal(
  pendingResponseMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind
        === "active_codex_control"
    ).length,
  1,
  "a committed active-control turn must start after the late-created response is cancelled locally",
);
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.done",
    response: {
      id: "late-codex-progress-13",
      status: "cancelled",
      metadata: { voice_relay_kind: "codex_progress" },
      output: [],
    },
  },
});
const activeControlRequests = nativeMessages
  .slice(pendingResponseBargeInStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "active_codex_control"
  );
assert.equal(
  activeControlRequests.length,
  1,
  "a late cancellation terminal must not start the queued user control turn twice",
);
assert.match(
  activeControlRequests[0].response.instructions,
  /stop_session only when stop, cancel, or end targets this assistant's current voice or Codex work/,
  "active control routing must scope session stops to the assistant's current work",
);
assert.match(
  activeControlRequests[0].response.instructions,
  /command targeting another object or process.*substantive work/,
  "active control routing must keep object-scoped stop commands on the work path",
);
assert.match(
  activeControlRequests[0].response.instructions,
  /target or action is ambiguous, use steer_active_codex/,
  "ambiguous active follow-ups must default to steering instead of clarification",
);
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.created",
    response: {
      id: "active-control-external-stop-13",
      metadata: { voice_relay_kind: "active_codex_control" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_active_codex_turn",
    arguments: JSON.stringify({
      action: "stop_session",
      spoken_language: "en-US",
      spoken_register: "casual",
      stop_target: "external_or_other_object",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 13,
  event: {
    type: "response.done",
    response: {
      id: "active-control-external-stop-13",
      metadata: { voice_relay_kind: "active_codex_control" },
      output: [{ type: "function_call" }],
    },
  },
});
const externalStopControlMessages = nativeMessages
  .slice(pendingResponseBargeInStart);
assert.equal(
  externalStopControlMessages.filter(message =>
    message.type === "stopIntent"
  ).length,
  0,
  "an object-scoped stop command must not stop Voice Relay or the active Codex task",
);
assert.equal(
  externalStopControlMessages.filter(message =>
    message.type === "codexSteer"
    && message.text === "Stop the song."
  ).length,
  1,
  "an object-scoped stop command must steer the active Codex task exactly once",
);
const externalStopAcknowledgement = externalStopControlMessages
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .find(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_steer"
  );
assert.match(
  externalStopAcknowledgement?.response?.instructions || "",
  /additional request will be applied/,
  "an object-scoped stop command must receive the normal steer acknowledgement",
);
assert.doesNotMatch(
  externalStopAcknowledgement?.response?.instructions || "",
  /whether I should stop|additional instruction/,
  "active follow-up handling must never ask the old stop-versus-add clarification",
);

const textControlPriorityStart = nativeMessages.length;
runtime.start({
  generation: 14,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Aria",
  wakePhrases: ["Hey Aria"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 14 });
runtime.transportReady({ generation: 14 });
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "text-control-primary-14",
    transcript: "Check my calendar.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.created",
    response: {
      id: "text-control-route-14",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "text-control-route-call-14",
    arguments: JSON.stringify({
      kind: "codex",
      social_origin: "not_applicable",
      spoken_language: "en-US",
      spoken_register: "casual",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.done",
    response: {
      id: "text-control-route-14",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.created",
    response: {
      id: "text-control-progress-14",
      metadata: { voice_relay_kind: "codex_progress" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.done",
    response: {
      id: "text-control-progress-14",
      status: "cancelled",
      metadata: { voice_relay_kind: "codex_progress" },
      output: [],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "text-control-first-14",
    transcript: "Also include tomorrow.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.created",
    response: {
      id: "text-control-active-14",
      metadata: { voice_relay_kind: "active_codex_control" },
    },
  },
});
const secondTextControlStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 14,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "text-control-second-14",
    transcript: "And include Friday.",
  },
});
const secondTextControlBeforeDone = nativeMessages
  .slice(secondTextControlStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
assert.equal(
  secondTextControlBeforeDone.filter(event =>
    event.type === "response.cancel"
    && event.response_id === "text-control-active-14"
  ).length,
  0,
  "user speech must not cancel the active text-only control classifier",
);
assert.equal(
  secondTextControlBeforeDone.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "active_codex_control"
  ).length,
  0,
  "a second control utterance must queue behind the active text classifier",
);
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_active_codex_turn",
    arguments: JSON.stringify({
      action: "steer_active_codex",
      spoken_language: "en-US",
      spoken_register: "casual",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 14,
  event: {
    type: "response.done",
    response: {
      id: "text-control-active-14",
      metadata: { voice_relay_kind: "active_codex_control" },
      output: [{ type: "function_call" }],
    },
  },
});
const secondTextControlAfterDone = nativeMessages
  .slice(secondTextControlStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON));
assert.equal(
  secondTextControlAfterDone.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "active_codex_control"
  ).length,
  1,
  "the queued second control utterance must start exactly once after the first classifier completes",
);

const completedFinalBargeInStart = nativeMessages.length;
runtime.start({
  generation: 15,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["Hey Relay"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 15 });
runtime.transportReady({ generation: 15 });
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "completed-final-primary-15",
    transcript: "Check the current weather.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.created",
    response: {
      id: "completed-final-route-15",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "completed-final-call-15",
    arguments: JSON.stringify({
      kind: "codex",
      social_origin: "not_applicable",
      spoken_language: "en-US",
      spoken_register: "casual",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.done",
    response: {
      id: "completed-final-route-15",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.created",
    response: {
      id: "completed-final-progress-15",
      metadata: { voice_relay_kind: "codex_progress" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.done",
    response: {
      id: "completed-final-progress-15",
      status: "cancelled",
      metadata: { voice_relay_kind: "codex_progress" },
      output: [],
    },
  },
});
runtime.resolveCodex({
  generation: 15,
  callId: "completed-final-call-15",
  output: "The current weather is clear.",
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.created",
    response: {
      id: "completed-final-speech-15",
      metadata: { voice_relay_kind: "codex_final" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.output_audio.delta",
    response_id: "completed-final-speech-15",
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "completed-final-speech-15",
    transcript: "The current weather is clear.",
  },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "response.done",
    response: {
      id: "completed-final-speech-15",
      status: "completed",
      metadata: { voice_relay_kind: "codex_final" },
      output: [],
    },
  },
});
const completedFinalReplacementStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: 15,
  event: { type: "input_audio_buffer.speech_started" },
});
runtime.receiveRealtimeEvent({
  generation: 15,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "completed-final-replacement-15",
    transcript: "Check tomorrow instead.",
  },
});
const completedFinalReplacementMessages =
  nativeMessages.slice(completedFinalReplacementStart);
assert.equal(
  completedFinalReplacementMessages.filter(message =>
    message.type === "playbackInterrupt"
  ).length,
  1,
  "user speech must interrupt completed final playback exactly once",
);
assert.equal(
  completedFinalReplacementMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event => event.type === "response.cancel").length,
  0,
  "completed final playback must not wait for cancellation of a finished response",
);
assert.equal(
  completedFinalReplacementMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind === "route_classifier"
    ).length,
  1,
  "a user turn replacing completed final playback must start immediately",
);
assert.equal(
  completedFinalReplacementMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "user_turn_queued"
  ).length,
  1,
  "a user turn replacing completed final playback must be queued exactly once",
);
assert.equal(
  completedFinalReplacementMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "user_turn_started"
  ).length,
  1,
  "a user turn replacing completed final playback must start exactly once",
);
runtime.playbackDrained({
  generation: 15,
  responseId: "completed-final-speech-15",
});
const completedFinalLateDrainMessages =
  nativeMessages.slice(completedFinalReplacementStart);
assert.equal(
  completedFinalLateDrainMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind === "route_classifier"
    ).length,
  1,
  "a late playback-drained callback must not restart the replacement turn",
);
assert.equal(
  completedFinalLateDrainMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "user_turn_started"
  ).length,
  1,
  "a late playback-drained callback must not start the replacement turn twice",
);

const localPresenceStart = nativeMessages.length;
runtime.start({
  generation: 16,
  language: "en-US",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Relay",
  wakePhrases: ["Hey Relay"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: 16 });
runtime.transportReady({ generation: 16 });
runtime.receiveRealtimeEvent({
  generation: 16,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "local-presence-user-16",
    transcript: "Can you hear me?",
  },
});
runtime.receiveRealtimeEvent({
  generation: 16,
  event: {
    type: "response.created",
    response: {
      id: "local-presence-route-16",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 16,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: "local-presence-call-16",
    arguments: JSON.stringify({
      kind: "local_presence",
      social_origin: "not_applicable",
      spoken_language: "en-US",
      spoken_register: "casual",
    }),
  },
});
const localPresenceMessages = nativeMessages.slice(localPresenceStart);
assert.equal(
  localPresenceMessages.filter(message =>
    message.type === "codexRequest"
  ).length,
  0,
  "an active-session hearing check must stay on the local Realtime path",
);
assert.equal(
  localPresenceMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind !== "route_classifier"
    ).length,
  1,
  "a local presence check must create one direct spoken reply",
);

function runInterruptedCommentaryCancelSettlementRegression(
  generation,
  lateEventOrder,
) {
  const scenarioStart = nativeMessages.length;
  const suffix = String(generation);
  const originalText = "Check the latest weather near me.";
  const replacementText = "Check tomorrow instead.";
  const originalCallId = `missing-terminal-call-${suffix}`;
  const commentaryResponseId = `missing-terminal-commentary-${suffix}`;
  const replacementRouteId = `missing-terminal-replacement-route-${suffix}`;

  runtime.start({
    generation,
    language: "en-US",
    additionalLanguages: [],
    productName: "Voice Relay",
    assistantName: "Relay",
    wakePhrases: ["Hey Relay"],
    shouldGreet: false,
  });
  runtime.transportOpened({ generation });
  runtime.transportReady({ generation });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: `missing-terminal-original-${suffix}`,
      transcript: originalText,
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: `missing-terminal-route-${suffix}`,
        metadata: { voice_relay_kind: "route_classifier" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.function_call_arguments.done",
      name: "route_voice_turn",
      call_id: originalCallId,
      arguments: JSON.stringify({
        kind: "codex",
        social_origin: "not_applicable",
        spoken_language: "en-US",
        spoken_register: "casual",
      }),
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: `missing-terminal-route-${suffix}`,
        metadata: { voice_relay_kind: "route_classifier" },
        output: [{ type: "function_call" }],
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: `missing-terminal-progress-${suffix}`,
        metadata: { voice_relay_kind: "codex_progress" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: `missing-terminal-progress-${suffix}`,
        status: "cancelled",
        metadata: { voice_relay_kind: "codex_progress" },
        output: [],
      },
    },
  });
  runtime.speakCodexCommentary({
    generation,
    messageId: `missing-terminal-commentary-message-${suffix}`,
    text: "I am checking that now.",
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: commentaryResponseId,
        metadata: { voice_relay_kind: "codex_commentary" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.output_audio.delta",
      response_id: commentaryResponseId,
    },
  });
  runtime.resolveCodex({
    generation,
    callId: originalCallId,
    output: "The current weather is clear.",
  });

  const preemptionStart = nativeMessages.length;
  runtime.receiveRealtimeEvent({
    generation,
    event: { type: "input_audio_buffer.speech_started" },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: `missing-terminal-nonmeaningful-${suffix}`,
      transcript: "...",
    },
  });
  const beforeReplacement = nativeMessages.slice(preemptionStart);
  assert.equal(
    beforeReplacement
      .filter(message => message.type === "realtimeSend")
      .map(message => JSON.parse(message.eventJSON))
      .filter(event =>
        event.type === "response.create"
        && event.response?.metadata?.voice_relay_kind === "route_classifier"
      ).length,
    0,
    "a nonmeaningful transcript must not settle a pending response cancellation",
  );
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: `missing-terminal-replacement-${suffix}`,
      transcript: replacementText,
    },
  });

  const settledMessages = nativeMessages.slice(preemptionStart);
  const cancellationEvents = settledMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.cancel"
      && event.response_id === commentaryResponseId
    );
  assert.equal(
    cancellationEvents.length,
    1,
    "an interrupted commentary response must be cancelled exactly once",
  );
  assert.equal(
    settledMessages
      .filter(message => message.type === "realtimeSend")
      .map(message => JSON.parse(message.eventJSON))
      .filter(event =>
        event.type === "response.create"
        && event.response?.metadata?.voice_relay_kind === "route_classifier"
      ).length,
    1,
    "a committed replacement turn must start without a server cancel terminal",
  );
  assert.equal(
    settledMessages
      .filter(message => message.type === "realtimeSend")
      .map(message => JSON.parse(message.eventJSON))
      .filter(event =>
        event.type === "response.create"
        && event.response?.metadata?.voice_relay_kind === "codex_final"
      ).length,
    0,
    "user voice priority must discard the queued stale Codex final",
  );
  assert.equal(
    settledMessages.filter(message =>
      message.type === "diagnostic"
      && message.stage === "response_cancel_settled"
    ).length,
    1,
    "the interrupted response must settle locally exactly once",
  );
  assert.equal(
    settledMessages.filter(message =>
      message.type === "diagnostic"
      && message.stage === "user_turn_started"
      && message.text === replacementText
    ).length,
    1,
    "the replacement turn must start exactly once",
  );

  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: replacementRouteId,
        metadata: { voice_relay_kind: "route_classifier" },
      },
    },
  });
  const lateDone = () => runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: commentaryResponseId,
        status: "cancelled",
        metadata: { voice_relay_kind: "codex_commentary" },
        output: [],
      },
    },
  });
  const lateError = () => runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "error",
      error: {
        event_id: cancellationEvents[0].event_id,
        code: "invalid_request_error",
      },
    },
  });
  if (lateEventOrder === "error_first") {
    lateError();
    lateDone();
  } else {
    lateDone();
    lateError();
  }
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: commentaryResponseId,
        metadata: { voice_relay_kind: "codex_commentary" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.output_audio.delta",
      response_id: commentaryResponseId,
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.output_audio_transcript.done",
      response_id: commentaryResponseId,
      transcript: "A stale late transcript.",
    },
  });
  runtime.playbackDrained({
    generation,
    responseId: commentaryResponseId,
  });

  const afterLateEvents = nativeMessages.slice(preemptionStart);
  assert.equal(
    afterLateEvents
      .filter(message => message.type === "realtimeSend")
      .map(message => JSON.parse(message.eventJSON))
      .filter(event =>
        event.type === "response.create"
        && event.response?.metadata?.voice_relay_kind === "route_classifier"
      ).length,
    1,
    "late cancellation events must not duplicate the replacement route",
  );
  assert.equal(
    afterLateEvents.filter(message =>
      message.type === "diagnostic"
      && message.stage === "user_turn_started"
      && message.text === replacementText
    ).length,
    1,
    "late cancellation events must not start the replacement turn twice",
  );

  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.function_call_arguments.done",
      name: "route_voice_turn",
      call_id: `missing-terminal-replacement-call-${suffix}`,
      arguments: JSON.stringify({
        kind: "codex",
        social_origin: "not_applicable",
        spoken_language: "en-US",
        spoken_register: "casual",
      }),
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: replacementRouteId,
        metadata: { voice_relay_kind: "route_classifier" },
        output: [{ type: "function_call" }],
      },
    },
  });
  const scenarioMessages = nativeMessages.slice(scenarioStart);
  assert.equal(
    scenarioMessages.filter(message =>
      message.type === "codexRequest"
      && message.text === replacementText
    ).length,
    1,
    "late old-response events must not corrupt the replacement route owner",
  );
  assert.equal(
    scenarioMessages
      .filter(message => message.type === "realtimeSend")
      .map(message => JSON.parse(message.eventJSON))
      .filter(event =>
        event.type === "response.create"
        && event.response?.metadata?.voice_relay_kind === "codex_final"
      ).length,
    0,
    "the stale queued final must remain suppressed after late-event delivery",
  );
}

runInterruptedCommentaryCancelSettlementRegression(17, "done_first");
runInterruptedCommentaryCancelSettlementRegression(18, "error_first");

function runActiveStopTargetRegression(
  generation,
  followUpText,
  action,
  stopTarget,
) {
  const scenarioStart = nativeMessages.length;
  const routeResponseId = `stop-target-route-${generation}`;
  const routeCallId = `stop-target-call-${generation}`;
  const controlResponseId = `stop-target-control-${generation}`;

  runtime.start({
    generation,
    language: "ko-KR",
    additionalLanguages: [],
    productName: "Voice Relay",
    assistantName: "Aria",
    wakePhrases: ["configured wake"],
    shouldGreet: false,
  });
  runtime.transportOpened({ generation });
  runtime.transportReady({ generation });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: `stop-target-primary-${generation}`,
      transcript: "먼저 현재 작업을 실행해줘.",
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: routeResponseId,
        metadata: { voice_relay_kind: "route_classifier" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.function_call_arguments.done",
      name: "route_voice_turn",
      call_id: routeCallId,
      arguments: JSON.stringify({
        kind: "codex",
        social_origin: "not_applicable",
        spoken_language: "ko-KR",
        spoken_register: "casual",
        stop_target: "not_applicable",
      }),
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: routeResponseId,
        metadata: { voice_relay_kind: "route_classifier" },
        output: [{ type: "function_call" }],
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: `stop-target-progress-${generation}`,
        metadata: { voice_relay_kind: "codex_progress" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: `stop-target-progress-${generation}`,
        status: "cancelled",
        metadata: { voice_relay_kind: "codex_progress" },
        output: [],
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: `stop-target-follow-up-${generation}`,
      transcript: followUpText,
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: controlResponseId,
        metadata: { voice_relay_kind: "active_codex_control" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.function_call_arguments.done",
      name: "route_active_codex_turn",
      arguments: JSON.stringify({
        action,
        spoken_language: "ko-KR",
        spoken_register: "casual",
        stop_target: stopTarget,
      }),
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: controlResponseId,
        metadata: { voice_relay_kind: "active_codex_control" },
        output: [{ type: "function_call" }],
      },
    },
  });
  return nativeMessages.slice(scenarioStart);
}

for (const [generation, text] of [
  [19, "노래 멈춰."],
  [20, "영상 멈춰."],
  [21, "다운로드 멈춰."],
  [22, "멈추라는 말은 하지 않았어."],
  [23, "그 사람이 멈춰라고 말했어."],
]) {
  const messages = runActiveStopTargetRegression(
    generation,
    text,
    "stop_session",
    generation <= 21 ? "external_or_other_object" : "not_applicable",
  );
  assert.equal(
    messages.filter(message => message.type === "stopIntent").length,
    0,
    "external-object, negated, and quoted stop language must not stop the active Voice or Codex session",
  );
  assert.equal(
    messages.filter(message =>
      message.type === "codexSteer"
      && message.text === text
    ).length,
    1,
    `non-session stop language must remain substantive active-turn steering: ${text}`,
  );
}

for (const [generation, text] of [
  [24, "설명은 멈춰."],
  [25, "지금 하던 거 전부 멈춰."],
]) {
  const messages = runActiveStopTargetRegression(
    generation,
    text,
    "stop_session",
    "current_voice_or_codex_work",
  );
  assert.equal(
    messages.filter(message =>
      message.type === "stopIntent"
      && message.text === text
    ).length,
    1,
    "a stop explicitly targeting current assistant output or work must stop the session",
  );
  assert.equal(
    messages.filter(message => message.type === "codexSteer").length,
    0,
    "a verified current-work stop must not be forwarded as steering",
  );
}

const ambiguousFollowUpMessages = runActiveStopTargetRegression(
  26,
  "추가 지시를 하지.",
  "clarify",
  "ambiguous",
);
assert.equal(
  ambiguousFollowUpMessages.filter(message =>
    message.type === "codexSteer"
    && message.text === "추가 지시를 하지."
  ).length,
  1,
  "ambiguous or legacy active-control output must fail safely to steering",
);
assert.equal(
  ambiguousFollowUpMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && /whether I should stop|additional instruction/.test(
        event.response?.instructions || "",
      )
    ).length,
  0,
  "active follow-up handling must not ask the user to choose stop versus add",
);

const visibleStopAckStart = nativeMessages.length;
runActiveStopTargetRegression(
  28,
  "지금 하던 거 전부 멈춰.",
  "stop_session",
  "current_voice_or_codex_work",
);
runtime.receiveRealtimeEvent({
  generation: 28,
  event: {
    type: "response.created",
    response: {
      id: "visible-stop-ack-28",
      metadata: { voice_relay_kind: "semantic_stop" },
    },
  },
});
for (let index = 0; index < 2; index += 1) {
  runtime.receiveRealtimeEvent({
    generation: 28,
    event: {
      type: "response.output_audio_transcript.done",
      response_id: "visible-stop-ack-28",
      transcript: "지금 다 멈췄어.",
    },
  });
}
const visibleStopAckBeforeDrain = nativeMessages.slice(visibleStopAckStart);
assert.equal(
  visibleStopAckBeforeDrain.filter(message =>
    message.type === "stopAcknowledgementFinal"
    && message.responseId === "visible-stop-ack-28"
    && message.text === "지금 다 멈췄어."
  ).length,
  1,
  "spoken stop acknowledgement transcript must be mirrored visibly exactly once",
);
assert.equal(
  visibleStopAckBeforeDrain.filter(message =>
    ["assistantProgress", "assistantFinal"].includes(message.type)
    && message.responseId === "visible-stop-ack-28"
  ).length,
  0,
  "spoken stop acknowledgement must stay outside ordinary assistant-output lifecycle state",
);
assert.equal(
  visibleStopAckBeforeDrain.filter(message =>
    message.type === "stopAcknowledgementDrained"
  ).length,
  0,
  "stop acknowledgement must not complete before playback drains",
);
runtime.playbackDrained({
  generation: 28,
  responseId: "visible-stop-ack-28",
});
runtime.playbackDrained({
  generation: 28,
  responseId: "visible-stop-ack-28",
});
const visibleStopAckMessages = nativeMessages.slice(visibleStopAckStart);
assert.equal(
  visibleStopAckMessages.filter(message =>
    message.type === "stopAcknowledgementDrained"
    && message.responseId === "visible-stop-ack-28"
  ).length,
  1,
  "matching stop acknowledgement playback may authorize teardown once",
);
assert.ok(
  visibleStopAckMessages.findIndex(message =>
    message.type === "stopAcknowledgementFinal"
  ) < visibleStopAckMessages.findIndex(message =>
    message.type === "stopAcknowledgementDrained"
  ),
  "visible stop acknowledgement must reach the host before teardown authorization",
);
runtime.receiveRealtimeEvent({
  generation: 28,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "visible-stop-ack-28",
    transcript: "late duplicate",
  },
});
assert.equal(
  nativeMessages.slice(visibleStopAckStart).filter(message =>
    message.type === "stopAcknowledgementFinal"
  ).length,
  1,
  "late acknowledgement transcripts must remain retired after completion",
);

const reorderedStopAckStart = nativeMessages.length;
runActiveStopTargetRegression(
  29,
  "설명은 멈춰.",
  "stop_session",
  "current_voice_or_codex_work",
);
runtime.receiveRealtimeEvent({
  generation: 29,
  event: {
    type: "response.created",
    response: {
      id: "reordered-stop-ack-29",
      metadata: { voice_relay_kind: "semantic_stop" },
    },
  },
});
runtime.playbackDrained({
  generation: 29,
  responseId: "reordered-stop-ack-29",
});
assert.equal(
  nativeMessages.slice(reorderedStopAckStart).filter(message =>
    message.type === "stopAcknowledgementDrained"
  ).length,
  0,
  "drain arriving before transcript must wait for the visible mirror",
);
runtime.receiveRealtimeEvent({
  generation: 29,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "reordered-stop-ack-29",
    transcript: "설명을 멈췄어.",
  },
});
const reorderedStopAckMessages =
  nativeMessages.slice(reorderedStopAckStart);
assert.ok(
  reorderedStopAckMessages.findIndex(message =>
    message.type === "stopAcknowledgementFinal"
  ) < reorderedStopAckMessages.findIndex(message =>
    message.type === "stopAcknowledgementDrained"
  ),
  "drain-before-transcript race must still emit visible final before completion",
);

const emptyStopAckStart = nativeMessages.length;
runActiveStopTargetRegression(
  30,
  "지금 하던 거 전부 멈춰.",
  "stop_session",
  "current_voice_or_codex_work",
);
runtime.receiveRealtimeEvent({
  generation: 30,
  event: {
    type: "response.created",
    response: {
      id: "empty-stop-ack-30",
      metadata: { voice_relay_kind: "semantic_stop" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: 30,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "empty-stop-ack-30",
    transcript: "   ",
  },
});
runtime.playbackDrained({
  generation: 30,
  responseId: "empty-stop-ack-30",
});
assert.equal(
  nativeMessages.slice(emptyStopAckStart).filter(message =>
    ["stopAcknowledgementFinal", "stopAcknowledgementDrained"].includes(
      message.type,
    )
  ).length,
  0,
  "empty acknowledgement transcript must fail closed to the host timeout",
);

const completionBoundaryStart = nativeMessages.length;
const completionGeneration = 27;
const completionRouteCallId = "completion-boundary-call-27";
runtime.start({
  generation: completionGeneration,
  language: "ko-KR",
  additionalLanguages: [],
  productName: "Voice Relay",
  assistantName: "Aria",
  wakePhrases: ["configured wake"],
  shouldGreet: false,
});
runtime.transportOpened({ generation: completionGeneration });
runtime.transportReady({ generation: completionGeneration });
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "completion-boundary-primary-27",
    transcript: "현재 작업을 시작해줘.",
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.created",
    response: {
      id: "completion-boundary-route-27",
      metadata: { voice_relay_kind: "route_classifier" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_voice_turn",
    call_id: completionRouteCallId,
    arguments: JSON.stringify({
      kind: "codex",
      social_origin: "not_applicable",
      spoken_language: "ko-KR",
      spoken_register: "casual",
      stop_target: "not_applicable",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.done",
    response: {
      id: "completion-boundary-route-27",
      metadata: { voice_relay_kind: "route_classifier" },
      output: [{ type: "function_call" }],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.created",
    response: {
      id: "completion-boundary-progress-27",
      metadata: { voice_relay_kind: "codex_progress" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.done",
    response: {
      id: "completion-boundary-progress-27",
      status: "cancelled",
      metadata: { voice_relay_kind: "codex_progress" },
      output: [],
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "completion-boundary-follow-up-27",
    transcript: "그리고 다음 요청도 확인해줘.",
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.created",
    response: {
      id: "completion-boundary-control-27",
      metadata: { voice_relay_kind: "active_codex_control" },
    },
  },
});
runtime.resolveCodex({
  generation: completionGeneration,
  callId: completionRouteCallId,
  output: "기존 작업 완료",
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.function_call_arguments.done",
    name: "route_active_codex_turn",
    arguments: JSON.stringify({
      action: "steer_active_codex",
      spoken_language: "ko-KR",
      spoken_register: "casual",
      stop_target: "not_applicable",
    }),
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.done",
    response: {
      id: "completion-boundary-control-27",
      metadata: { voice_relay_kind: "active_codex_control" },
      output: [{ type: "function_call" }],
    },
  },
});
const completionFinalCreate = nativeMessages
  .slice(completionBoundaryStart)
  .filter(message => message.type === "realtimeSend")
  .map(message => JSON.parse(message.eventJSON))
  .find(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  );
assert.ok(
  completionFinalCreate,
  "the completed original turn must retain its final speech before the queued new request",
);
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.created",
    response: {
      id: "completion-boundary-final-27",
      metadata: { voice_relay_kind: "codex_final" },
    },
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.output_audio.delta",
    response_id: "completion-boundary-final-27",
    delta: "AAAA",
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.output_audio_transcript.done",
    response_id: "completion-boundary-final-27",
    transcript: "기존 작업 완료",
  },
});
runtime.receiveRealtimeEvent({
  generation: completionGeneration,
  event: {
    type: "response.done",
    response: {
      id: "completion-boundary-final-27",
      status: "completed",
      metadata: { voice_relay_kind: "codex_final" },
      output: [],
    },
  },
});
runtime.playbackDrained({
  generation: completionGeneration,
  responseId: "completion-boundary-final-27",
});
const completionBoundaryMessages =
  nativeMessages.slice(completionBoundaryStart);
assert.equal(
  completionBoundaryMessages.filter(message =>
    message.type === "codexSteer"
    && message.text === "그리고 다음 요청도 확인해줘."
  ).length,
  0,
  "a follow-up whose classifier settles after Codex completion must not steer a finished turn",
);
assert.equal(
  completionBoundaryMessages
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON))
    .filter(event =>
      event.type === "response.create"
      && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  2,
  "a follow-up crossing completion must become exactly one ordinary new routed request",
);

function beginDeferredFinalRace(generation) {
  const callId = `deferred-final-call-${generation}`;
  runtime.start({
    generation,
    language: "en-US",
    additionalLanguages: [],
    productName: "Voice Relay",
    assistantName: "Aria",
    wakePhrases: ["Hey Aria"],
    shouldGreet: false,
  });
  runtime.transportOpened({ generation });
  runtime.transportReady({ generation });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "conversation.item.input_audio_transcription.completed",
      item_id: `deferred-final-original-${generation}`,
      transcript: "Check the latest weather near me.",
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: `deferred-final-route-${generation}`,
        metadata: { voice_relay_kind: "route_classifier" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.function_call_arguments.done",
      name: "route_voice_turn",
      call_id: callId,
      arguments: JSON.stringify({
        kind: "codex",
        social_origin: "not_applicable",
        spoken_language: "en-US",
        spoken_register: "casual",
        stop_target: "not_applicable",
      }),
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: `deferred-final-route-${generation}`,
        metadata: { voice_relay_kind: "route_classifier" },
        output: [{ type: "function_call" }],
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.created",
      response: {
        id: `deferred-final-progress-${generation}`,
        metadata: { voice_relay_kind: "codex_progress" },
      },
    },
  });
  runtime.receiveRealtimeEvent({
    generation,
    event: {
      type: "response.done",
      response: {
        id: `deferred-final-progress-${generation}`,
        status: "cancelled",
        metadata: { voice_relay_kind: "codex_progress" },
        output: [],
      },
    },
  });
  return callId;
}

function raceRealtimeEvents(start) {
  return nativeMessages
    .slice(start)
    .filter(message => message.type === "realtimeSend")
    .map(message => JSON.parse(message.eventJSON));
}

const meaningfulDeferredFinalGeneration = 28;
const meaningfulDeferredFinalCall =
  beginDeferredFinalRace(meaningfulDeferredFinalGeneration);
const meaningfulDeferredFinalStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: meaningfulDeferredFinalGeneration,
  event: {
    type: "input_audio_buffer.speech_started",
    item_id: "deferred-final-user-28",
  },
});
runtime.resolveCodex({
  generation: meaningfulDeferredFinalGeneration,
  callId: meaningfulDeferredFinalCall,
  output: "It is clear and 19 degrees.",
});
assert.equal(
  raceRealtimeEvents(meaningfulDeferredFinalStart).filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  0,
  "a Codex final arriving after user speech starts must remain deferred",
);
runtime.receiveRealtimeEvent({
  generation: meaningfulDeferredFinalGeneration,
  event: {
    type: "input_audio_buffer.speech_stopped",
    item_id: "deferred-final-user-28",
  },
});
assert.equal(
  raceRealtimeEvents(meaningfulDeferredFinalStart).filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  0,
  "speech stop must not release a final before transcription settles",
);
runtime.receiveRealtimeEvent({
  generation: meaningfulDeferredFinalGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "deferred-final-user-28",
    transcript: "Check tomorrow instead.",
  },
});
const meaningfulDeferredFinalMessages =
  nativeMessages.slice(meaningfulDeferredFinalStart);
const meaningfulDeferredFinalEvents =
  raceRealtimeEvents(meaningfulDeferredFinalStart);
assert.equal(
  meaningfulDeferredFinalEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  0,
  "a meaningful replacement utterance must suppress the stale Codex final",
);
assert.equal(
  meaningfulDeferredFinalEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  1,
  "the replacement utterance must start exactly one new routed turn",
);
assert.equal(
  meaningfulDeferredFinalMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "user_turn_started"
    && message.text === "Check tomorrow instead."
  ).length,
  1,
  "the replacement utterance must take turn ownership exactly once",
);
assert.equal(
  meaningfulDeferredFinalMessages.filter(message =>
    message.type === "diagnostic"
    && message.stage === "deferred_codex_final_superseded"
  ).length,
  1,
  "the deferred final must record one explicit supersession",
);
assert.equal(
  meaningfulDeferredFinalMessages.filter(message =>
    message.type === "playbackInterrupt"
  ).length,
  0,
  "discarding an unstarted final must not emit a false playback interrupt",
);

const emptyDeferredFinalGeneration = 29;
const emptyDeferredFinalCall =
  beginDeferredFinalRace(emptyDeferredFinalGeneration);
const emptyDeferredFinalStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: emptyDeferredFinalGeneration,
  event: {
    type: "input_audio_buffer.speech_started",
    item_id: "deferred-final-user-29",
  },
});
runtime.receiveRealtimeEvent({
  generation: emptyDeferredFinalGeneration,
  event: {
    type: "input_audio_buffer.speech_stopped",
    item_id: "deferred-final-user-29",
  },
});
runtime.resolveCodex({
  generation: emptyDeferredFinalGeneration,
  callId: emptyDeferredFinalCall,
  output: "It is clear and 19 degrees.",
});
assert.equal(
  raceRealtimeEvents(emptyDeferredFinalStart).filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  0,
  "a final arriving after speech stop must still wait for transcription",
);
runtime.receiveRealtimeEvent({
  generation: emptyDeferredFinalGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "deferred-final-user-29",
    transcript: "",
  },
});
const emptyDeferredFinalEvents =
  raceRealtimeEvents(emptyDeferredFinalStart);
assert.equal(
  emptyDeferredFinalEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  1,
  "an empty transcription must release the deferred final exactly once",
);
assert.equal(
  emptyDeferredFinalEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  0,
  "an empty transcription must not create a replacement route",
);

const failedDeferredFinalGeneration = 30;
const failedDeferredFinalCall =
  beginDeferredFinalRace(failedDeferredFinalGeneration);
const failedDeferredFinalStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: failedDeferredFinalGeneration,
  event: {
    type: "input_audio_buffer.speech_started",
    item_id: "deferred-final-user-30",
  },
});
runtime.resolveCodex({
  generation: failedDeferredFinalGeneration,
  callId: failedDeferredFinalCall,
  output: "It is clear and 19 degrees.",
});
runtime.receiveRealtimeEvent({
  generation: failedDeferredFinalGeneration,
  event: {
    type: "input_audio_buffer.speech_stopped",
    item_id: "deferred-final-user-30",
  },
});
runtime.receiveRealtimeEvent({
  generation: failedDeferredFinalGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.failed",
    item_id: "deferred-final-user-30",
    error: { code: "transcription_failed" },
  },
});
const failedDeferredFinalEvents =
  raceRealtimeEvents(failedDeferredFinalStart);
assert.equal(
  failedDeferredFinalEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  1,
  "a failed transcription must release the deferred final exactly once",
);
assert.equal(
  failedDeferredFinalEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  0,
  "a failed transcription must not create a replacement route",
);

const failedOldRequestGeneration = 31;
const failedOldRequestCall =
  beginDeferredFinalRace(failedOldRequestGeneration);
const failedOldRequestStart = nativeMessages.length;
runtime.receiveRealtimeEvent({
  generation: failedOldRequestGeneration,
  event: {
    type: "input_audio_buffer.speech_started",
    item_id: "deferred-final-user-31",
  },
});
runtime.resolveCodex({
  generation: failedOldRequestGeneration,
  callId: failedOldRequestCall,
  error: "REMOTE_CONTROL_REQUEST_TIMEOUT",
});
runtime.receiveRealtimeEvent({
  generation: failedOldRequestGeneration,
  event: {
    type: "input_audio_buffer.speech_stopped",
    item_id: "deferred-final-user-31",
  },
});
runtime.receiveRealtimeEvent({
  generation: failedOldRequestGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "stale-prior-user-31",
    transcript: "A stale prior transcription.",
  },
});
assert.equal(
  raceRealtimeEvents(failedOldRequestStart).filter(event =>
    event.type === "response.create"
  ).length,
  0,
  "a stale item terminal must not release a final or route a replacement",
);
runtime.receiveRealtimeEvent({
  generation: failedOldRequestGeneration,
  event: {
    type: "conversation.item.input_audio_transcription.completed",
    item_id: "deferred-final-user-31",
    transcript: "Try a different request.",
  },
});
const failedOldRequestEvents =
  raceRealtimeEvents(failedOldRequestStart);
assert.equal(
  failedOldRequestEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "codex_final"
  ).length,
  0,
  "a meaningful replacement must suppress the old generic failure speech",
);
assert.equal(
  failedOldRequestEvents.filter(event =>
    event.type === "response.create"
    && event.response?.metadata?.voice_relay_kind === "route_classifier"
  ).length,
  1,
  "the current item terminal must start one replacement route after a stale terminal",
);

console.log("Realtime response queue tests passed");
