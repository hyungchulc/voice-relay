#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  buildOptionalAdditionalContext,
  buildOptionalContextPrefix,
} from "./voice-relay-context.mjs";
import {
  requestRealtimeCredential,
} from "./voice-relay-realtime-credential.mjs";
import { resolveVoiceRelayThreadID } from "./voice-relay-thread-policy.mjs";

const diagnostic = (...values) => {
  process.stderr.write(
    `${values.map((value) => String(value)).join(" ")}\n`,
  );
};
console.log = diagnostic;
console.info = diagnostic;
console.debug = diagnostic;
console.warn = diagnostic;
console.error = diagnostic;

const homeRoot = path.resolve(process.env.HOME || os.homedir());
const helperRoot = path.dirname(fileURLToPath(import.meta.url));
const supportRoot = path.resolve(
  process.env.VOICE_RELAY_SUPPORT_ROOT ||
    path.join(helperRoot, "..", "Support"),
);
const stateRoot = path.resolve(
  process.env.VOICE_RELAY_STATE_ROOT ||
    path.join(
      homeRoot,
      "Library",
      "Application Support",
      "Voice Relay",
      "Remote",
    ),
);
const workspacePath = path.resolve(
  process.env.VOICE_RELAY_WORKSPACE ||
    path.join(
      homeRoot,
      "Library",
      "Application Support",
      "Voice Relay",
      "Workspace",
    ),
);
const controllerStatePath = path.join(
  stateRoot,
  "codex-remote-control-client.json",
);
const backendStatePath = path.join(
  stateRoot,
  "codex-app-remote.json",
);
const remoteModulePath = path.join(
  supportRoot,
  "CodexRemote",
  "src",
  "codex-remote-control-client.js",
);
const backendModulePath = path.join(
  supportRoot,
  "CodexRemote",
  "src",
  "codex-app-remote.js",
);
fs.mkdirSync(stateRoot, { recursive: true, mode: 0o700 });
fs.mkdirSync(workspacePath, { recursive: true, mode: 0o700 });

for (const requiredPath of [remoteModulePath, backendModulePath]) {
  if (!fs.statSync(requiredPath, { throwIfNoEntry: false })?.isFile()) {
    throw new Error(
      "Voice Relay support modules are not configured. " +
        "Reinstall Voice Relay or set VOICE_RELAY_SUPPORT_ROOT to a " +
        "directory containing CodexRemote.",
    );
  }
}

const remoteModule = await import(
  pathToFileURL(remoteModulePath).href
);
const backendModule = await import(
  pathToFileURL(backendModulePath).href
);

const controller = new remoteModule.CodexRemoteControlClient({
  desktopOriginator: "Voice Relay",
  controllerStatePath,
  globalStatePath: path.join(
    homeRoot,
    ".codex",
    ".codex-global-state.json",
  ),
  nativeDeviceKeyPath:
    "/Applications/ChatGPT.app/Contents/Resources/native/remote-control-device-key.node",
  deviceKeyHelperSourcePath: path.join(
    supportRoot,
    "CodexRemote",
    "scripts",
    "remote-control-device-key-helper.swift",
  ),
  deviceKeyHelperPath: path.join(
    stateRoot,
    "voice-relay-remote-control-device-key-helper",
  ),
  cliPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
  cwd: workspacePath,
});

let backend = null;
let activeRequestId = null;
let threadResolutionPromise = null;
const CODEX_STEER_TERMINAL_DEADLINE_MS = 10 * 60_000;
const steerMutationQueue =
  new backendModule.SerializedSteerMutationQueue({
    now: () => Date.now(),
    mutationBudgetMs: CODEX_STEER_TERMINAL_DEADLINE_MS,
  });

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

input.on("line", (line) => {
  void handleLine(line);
});
input.on("close", () => {
  controller.close();
});

async function handleLine(line) {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    write({
      error: {
        code: "INVALID_JSON",
        message: "Voice Relay connection helper received invalid JSON",
      },
    });
    return;
  }

  const id = String(request?.id || "");
  try {
    const command = String(request?.command || "");
    let result = await dispatch(command, request?.params || {}, id);
    if (command === "steer") {
      result =
        backendModule.validatedSteerSuccessReceiptForSerialization(
          result,
          { now: () => Date.now() },
        );
    }
    write({ id, result });
  } catch (error) {
    write({
      id,
      error: {
        code: String(error?.code || "APP_REMOTE_FAILED"),
        message: String(error?.message || error),
        ...("followupMutationDispatched" in Object(error)
          ? {
              mutationDispatched:
                error.followupMutationDispatched === true
                  ? true
                  : error.followupMutationDispatched === false
                    ? false
                    : null,
            }
          : {}),
        ...(typeof error?.followupFailurePhase === "string"
          ? { failurePhase: error.followupFailurePhase }
          : {}),
        ...(typeof error?.preDispatch === "boolean"
          ? { preDispatch: error.preDispatch }
          : {}),
      },
    });
  }
}

async function dispatch(command, params, id) {
  switch (command) {
    case "pair":
      return pairConnection(params);
    case "health":
      return connectionHealth();
    case "inspect":
      return inspectConnection();
    case "voices":
      return listVoices();
    case "ask":
      return ask(params, id);
    case "steer":
      return steer(params, id);
    case "interrupt":
      return interrupt();
    case "prepareThread":
      return prepareThread(params, id);
    case "realtimeCredential":
      return realtimeCredential(params, id);
    case "realtimeStop":
      return realtimeStop();
    case "resetSession":
      return resetSessionConnection();
    case "forgetPairing":
      return forgetLocalPairing();
    case "reset":
      return resetConnection();
    case "shutdown":
      controller.close();
      setTimeout(() => process.exit(0), 10);
      return { status: "closing" };
    default:
      throw new Error(`Unsupported Voice Relay connection command: ${command}`);
  }
}

async function pairConnection({ pairingCode = "" } = {}) {
  const enrollment = await controller.pair();
  const code = String(pairingCode || "").trim();
  if (code) {
    await controller.claimEnvironmentPairing(code);
  }
  try {
    await controller.start();
    await controller.request("model/list", { limit: 1 });
  } catch (error) {
    if (
      error?.code === "REMOTE_CONTROL_ENVIRONMENT_PAIRING_REQUIRED" &&
      !code
    ) {
      return {
        status: enrollment.status,
        paired: true,
        hostClaimRequired: true,
        remoteRpcReady: false,
      };
    }
    throw error;
  }
  const health = await controller.health();
  return {
    status: enrollment.status,
    paired: true,
    hostClaimRequired: false,
    remoteRpcReady: true,
    environmentOnline: Boolean(health.environmentOnline),
  };
}

async function connectionHealth() {
  const health = await controller.health();
  return {
    ...health,
    remoteRpcReady: Boolean(
      health.ok && health.paired && health.environmentOnline,
    ),
  };
}

async function inspectConnection() {
  await controller.start();
  const [accountResult, configResult, modelResult] = await Promise.all([
    controller.request("account/read", { refreshToken: false }),
    controller.request("config/read", {}),
    controller.request("model/list", { limit: 100 }),
  ]);
  const config = effectiveConfig(configResult);
  return {
    connected: true,
    transport: "app-remote",
    accountDescription: accountDescription(accountResult),
    effectiveConfig: config,
    availableModels: modelIDs(modelResult),
    threadID: readPersistedThreadID(),
  };
}

async function listVoices() {
  const model = "gpt-realtime-2.1";
  await requestRealtimeCredential({ model });
  return {
    description: `Direct Realtime ready · ${model}`,
    voices: [],
  };
}

async function ask(params, requestId) {
  if (activeRequestId) {
    const error = new Error("Voice Relay Codex connection already has an active turn");
    error.code = "APP_REMOTE_BUSY";
    throw error;
  }
  activeRequestId = requestId;
  try {
    const config = await remoteEffectiveConfig();
    const preferredThreadID = String(params.preferredThreadID || "").trim();
    const model =
      String(params.model || "").trim() === "inherit"
        ? config.model
        : String(params.model || config.model);
    const reasoningEffort =
      String(params.reasoningEffort || "").trim() === "inherit"
        ? config.reasoningEffort
        : String(params.reasoningEffort || config.reasoningEffort);
    if (model === "unknown" || reasoningEffort === "unknown") {
      const error = new Error(
        "Codex host model configuration is unavailable",
      );
      error.code = "APP_REMOTE_CONFIG_UNAVAILABLE";
      throw error;
    }
    const previousThreadID = resolveVoiceRelayThreadID(
      preferredThreadID,
      readPersistedThreadID(),
    );
    await ensureBackend({
      preferredThreadID,
      model,
      reasoningEffort,
    });
    const threadID = await ensureBoundThread(
      {
        ...params,
        preferredThreadID,
        model,
        reasoningEffort,
      },
      requestId,
    );
    const providersEnabled =
      params.additionalContextProvidersEnabled === true ||
      Boolean(String(params.additionalContextProvidersRoot || "").trim());
    const additionalContextResult = providersEnabled
      ? await buildOptionalAdditionalContext(
          params.additionalContextProvidersRoot,
          String(params.prompt || ""),
        )
      : { context: "", omission: null };
    if (additionalContextResult.omission) {
      write({
        event: "contextOmitted",
        requestId,
        source: additionalContextResult.omission.source,
        reason: additionalContextResult.omission.reason,
        fallback: "without_optional_context",
        ...(Number.isInteger(
          additionalContextResult.omission.providerIndex,
        )
          ? {
              providerIndex:
                additionalContextResult.omission.providerIndex,
            }
          : {}),
      });
    }
    const prefixResult = buildOptionalContextPrefix(
      params.additionalContext,
      additionalContextResult.context,
    );
    for (const omission of prefixResult.omissions) {
      write({
        event: "contextOmitted",
        requestId,
        source: omission.source,
        reason: omission.reason,
        fallback: "without_optional_context",
      });
    }
    const result = await backend.ask(String(params.prompt || ""), {
      prefix: prefixResult.prefix,
      requestIdPrefix: "voice-relay",
      requestTag: "voice_relay_request_id",
      preferredThreadId: threadID,
      onMessage: async (message) => {
        if (message?.phase !== "commentary") return;
        const messageId = String(message?.id || "").trim();
        const text = String(message?.text || "").trim();
        if (!messageId || !text) return;
        write({
          event: "commentary",
          requestId,
          messageId,
          text,
        });
      },
    });
    const answer = finalAnswer(result?.reply);
    const resultThreadID = String(backend.threadId || "");
    return {
      answer,
      threadID: resultThreadID,
      wasCreated: Boolean(
        resultThreadID && resultThreadID !== previousThreadID
      ),
    };
  } finally {
    activeRequestId = null;
  }
}

function steer(params, requestId) {
  const mutationBudgetMs = Math.trunc(
    Number(params.terminalDeadlineMs),
  );
  if (mutationBudgetMs !== CODEX_STEER_TERMINAL_DEADLINE_MS) {
    const error = new Error("The additional instruction deadline is invalid");
    error.code = "APP_REMOTE_INVALID_STEER";
    return Promise.reject(error);
  }
  return steerMutationQueue.enqueue(
    ({ mutationDeadlineEpochMs }) =>
      submitSteer(
        params,
        requestId,
        mutationDeadlineEpochMs,
      ),
  );
}

async function submitSteer(
  params,
  requestId,
  mutationDeadlineEpochMs,
) {
  const text = String(params.text || "").trim();
  const controlRequestID = String(params.controlRequestID || "").trim();
  const voiceTurnID = String(params.voiceTurnID || "").trim();
  const remainingMutationTime = () =>
    backendModule.remainingSteerMutationTime(
      mutationDeadlineEpochMs,
      Date.now(),
    );
  const throwExpired = (mutationDispatched = false) => {
    throw new backendModule.SteerMutationDeadlineExpiredError({
      mutationDispatched,
    });
  };
  if (!text) {
    const error = new Error("The additional instruction is empty");
    error.code = "APP_REMOTE_INVALID_STEER";
    throw error;
  }
  if (!/^voice-relay-steer-[a-z0-9_-]{8,160}$/iu.test(controlRequestID)
      || !/^turn-\d+-\d+$/u.test(voiceTurnID)) {
    const error = new Error("The additional instruction identity is invalid");
    error.code = "APP_REMOTE_INVALID_STEER";
    throw error;
  }
  if (remainingMutationTime() <= 0) throwExpired();
  if (!backend || !backend.hasActiveTurn()) {
    const error = new Error(
      "There is no active Codex task for the additional instruction",
    );
    error.code = "APP_REMOTE_NO_ACTIVE_TURN";
    throw error;
  }
  const requestToken = controlRequestID;
  let result = null;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (remainingMutationTime() <= 0) throwExpired(false);
    result = await backendModule.awaitSteerMutationResultBeforeDeadline({
      operation: () => backend.submitSteer(text, {
        requestToken,
        mutationDeadlineEpochMs,
      }),
      mutationDeadlineEpochMs,
      now: () => Date.now(),
    });
    if (remainingMutationTime() <= 0) {
      throwExpired(
        backendModule.steerMutationDispatchEvidence(result),
      );
    }
    if (result?.reason !== "steer_already_pending") break;
    const retryDelayMs = Math.min(125, remainingMutationTime());
    if (retryDelayMs <= 0) {
      throwExpired(
        backendModule.steerMutationDispatchEvidence(result),
      );
    }
    await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    if (remainingMutationTime() <= 0) {
      throwExpired(
        backendModule.steerMutationDispatchEvidence(result),
      );
    }
    if (!backend.hasActiveTurn()) break;
  }
  const status = String(result?.status || "");
  if (status !== "steered") {
    throw backendModule.steerFailureErrorForResult(result);
  }
  if (remainingMutationTime() <= 0) throwExpired(true);
  return {
    status,
    requestId: String(result?.requestId || requestToken),
    turnId: String(result?.turnId || ""),
    voiceTurnId: voiceTurnID,
    mutationDeadlineEpochMs,
    mutationDispatched: true,
  };
}

async function interrupt() {
  if (!backend) return { status: "ignored", reason: "no_backend" };
  return backend.stopActiveRun();
}

async function prepareThread(params, requestId) {
  const threadID = await ensureBoundThread(params, requestId);
  return {
    status: "ready",
    threadID,
  };
}

async function realtimeCredential(params, requestId) {
  write({
    event: "diagnostic",
    requestId,
    stage: "direct_realtime_credential_start",
  });
  const credential = await requestRealtimeCredential(params);
  write({
    event: "diagnostic",
    requestId,
    stage: "direct_realtime_secret_ready",
  });
  return {
    ...credential,
    threadID: readPersistedThreadID(),
  };
}

async function realtimeStop() {
  return { status: "stopped" };
}

async function ensureBackend({ preferredThreadID, model, reasoningEffort }) {
  await controller.start();
  if (!backend) {
    backend = new backendModule.CodexAppRemoteBackend({
      remoteControlClient: controller,
      threadId: preferredThreadID,
      cwd: workspacePath,
      model,
      reasoningEffort,
      statePath: backendStatePath,
      responseTimeoutMs: 10 * 60_000,
    });
    // Starting the transport must not prewarm a possibly stale persisted task.
    // resolveBoundThread owns the read/resume/replace decision immediately
    // afterward and persists the final usable binding.
    const initialThreadID = backend.threadId;
    backend.threadId = "";
    await backend.start();
    backend.threadId = initialThreadID;
  }
  backend.threadId = resolveVoiceRelayThreadID(
    preferredThreadID,
    backend.threadId,
    readPersistedThreadID(),
  );
  backend.model = model;
  backend.reasoningEffort = reasoningEffort;
  if (backend.commandDispatcher) {
    backend.commandDispatcher.defaultModel = model;
    backend.commandDispatcher.defaultReasoningEffort = reasoningEffort;
  }
  return backend;
}

async function ensureBoundThread(params, requestId) {
  if (!threadResolutionPromise) {
    threadResolutionPromise = resolveBoundThread(params, requestId);
  }
  const activeResolution = threadResolutionPromise;
  try {
    return await activeResolution;
  } finally {
    if (threadResolutionPromise === activeResolution) {
      threadResolutionPromise = null;
    }
  }
}

async function resolveBoundThread(params, requestId) {
  const preferredThreadID = String(params.preferredThreadID || "").trim();
  const createNewThreadIfUnset =
    params.createNewThreadIfUnset === true && !preferredThreadID;
  const activeBackend = await ensureBackend({
    preferredThreadID,
    model: params.model,
    reasoningEffort: params.reasoningEffort,
  });
  let threadID = createNewThreadIfUnset
    ? ""
    : resolveVoiceRelayThreadID(
        preferredThreadID,
        activeBackend.threadId,
        readPersistedThreadID(),
      );

  if (threadID) {
    try {
      await controller.request(
        "thread/read",
        { threadId: threadID, includeTurns: false },
        { timeoutMs: 60_000 },
      );
    } catch {
      try {
        await controller.request(
          "thread/resume",
          { threadId: threadID, cwd: workspacePath },
          { timeoutMs: 60_000 },
        );
      } catch {
        write({
          event: "diagnostic",
          requestId,
          stage: "saved_thread_unavailable_creating_replacement",
        });
        threadID = await startVoiceRelayThread();
      }
    }
  } else {
    threadID = await startVoiceRelayThread();
  }

  activeBackend.threadId = threadID;
  activeBackend.persistStateBestEffort();
  write({
    event: "threadBound",
    requestId,
    threadID,
  });
  return threadID;
}

async function startVoiceRelayThread() {
  const started = await controller.request(
    "thread/start",
    { cwd: workspacePath, threadSource: "user" },
    { timeoutMs: 60_000 },
  );
  const threadID = String(started?.thread?.id || "").trim();
  if (!threadID) {
    throw new Error(
      "Codex/ChatGPT could not create the dedicated Voice task",
    );
  }
  return threadID;
}

function readPersistedThreadID() {
  try {
    const state = JSON.parse(fs.readFileSync(backendStatePath, "utf8"));
    return resolveVoiceRelayThreadID(state?.threadId, state?.threadID);
  } catch {
    return "";
  }
}

async function resetConnection() {
  return forgetLocalPairing();
}

async function resetSessionConnection() {
  backend = null;
  controller.close();
  try {
    fs.rmSync(backendStatePath, { force: true });
  } catch (error) {
    error.message =
      `Voice Relay session reset failed for ${backendStatePath}: ${error.message}`;
    throw error;
  }
  return {
    status: "session_reset",
    localStateCleared: true,
    localDeviceKeyDeleted: false,
    remoteRevocationSupported: false,
  };
}

async function forgetLocalPairing() {
  backend = null;
  controller.close();
  const outcome = await controller.forgetLocalEnrollment();
  try {
    fs.rmSync(backendStatePath, { force: true });
  } catch (error) {
    error.message =
      `Voice Relay pairing reset failed for ${backendStatePath}: ${error.message}`;
    throw error;
  }
  return {
    status: "pairing_reset",
    ...outcome,
    localStateCleared: Boolean(outcome.localEnrollmentCleared),
    remoteRevocationSupported: false,
  };
}

async function remoteEffectiveConfig() {
  return effectiveConfig(await controller.request("config/read", {}));
}

function effectiveConfig(value) {
  const source = value?.config || value || {};
  const unavailable = "unknown";
  const model = String(source.model || unavailable);
  const reasoningEffort = String(
    source.model_reasoning_effort ||
      source.modelReasoningEffort ||
      unavailable,
  );
  const sandbox = String(
    source.sandbox_mode || source.sandboxMode || unavailable,
  );
  const approvalPolicy = String(
    source.approval_policy || source.approvalPolicy || unavailable,
  );
  return {
    model,
    reasoningEffort,
    sandbox,
    approvalPolicy,
    summary: `${model} · ${reasoningEffort} · ${sandbox} · ${approvalPolicy}`,
  };
}

function accountDescription(value) {
  const account = value?.account || value || {};
  if (!account || Object.keys(account).length === 0) return "ChatGPT";
  const plan = String(account.planType || account.plan_type || "").trim();
  const displayPlan = plan
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase())
    .join(" ");
  return displayPlan ? `ChatGPT ${displayPlan}` : "ChatGPT";
}

function modelIDs(value) {
  const entries = Array.isArray(value?.data)
    ? value.data
    : Array.isArray(value?.models)
      ? value.models
      : [];
  return entries
    .map((entry) => String(entry?.id || entry?.model || "").trim())
    .filter(Boolean);
}

function finalAnswer(reply) {
  const messages = Array.isArray(reply?.messages) ? reply.messages : [];
  const finals = messages
    .filter((message) => message?.phase === "final_answer")
    .map((message) => String(message?.text || "").trim())
    .filter(Boolean);
  if (finals.length) return finals.join("\n\n");
  throw new Error(
    "The Codex/ChatGPT task did not return a final response",
  );
}

function write(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
