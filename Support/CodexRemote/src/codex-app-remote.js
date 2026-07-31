import fs from "node:fs";
import path from "node:path";

import { CodexDesktopCdp } from "./codex-cdp.js";
import {
  normalizeModelForConfig,
} from "./codex-control-command.js";
import {
  CodexRemoteControlClient,
  RemoteControllerRequestTimeoutError,
} from "./codex-remote-control-client.js";
import {
  AcceptedSteerResponseRevisionFence,
  createSessionLogTaskScopedFollowupEvidence,
  normalizeSessionId,
  streamCodexReplies,
  waitForCodexReplies,
} from "./session-log.js";

export const FULL_ACCESS_PERMISSIONS = Object.freeze({
  activePermissionProfile: Object.freeze({ id: ":danger-full-access", extends: null }),
  sandboxPolicy: Object.freeze({ type: "dangerFullAccess" }),
  approvalPolicy: "never",
  approvalsReviewer: "user",
});
const MAX_EXACT_ACCEPTANCE_SCAN_BYTES = 16 * 1024 * 1024;

export class SteerMutationDeadlineExpiredError extends Error {
  constructor({ mutationDispatched = false } = {}) {
    super("The additional instruction deadline expired");
    this.name = "SteerMutationDeadlineExpiredError";
    this.code = "APP_REMOTE_STEER_DEADLINE_EXPIRED";
    this.followupMutationDispatched =
      mutationDispatched === true
        ? true
        : mutationDispatched === false
          ? false
          : null;
    this.preDispatch = this.followupMutationDispatched === false;
    this.followupFailurePhase =
      this.followupMutationDispatched === false
        ? "steer_mutation_deadline_pre_dispatch"
        : this.followupMutationDispatched === true
          ? "steer_mutation_deadline_post_dispatch"
          : "steer_mutation_deadline_post_await_unknown";
    this.followupSafeToRetry = false;
  }
}

export function remainingSteerMutationTime(
  mutationDeadlineEpochMs,
  nowMs,
) {
  const deadline = Math.trunc(Number(mutationDeadlineEpochMs));
  const now = Math.trunc(Number(nowMs));
  if (!Number.isSafeInteger(deadline) || !Number.isSafeInteger(now)) {
    return 0;
  }
  return Math.max(0, deadline - now);
}

export function steerMutationDispatchEvidence(result) {
  if (result?.status === "steered") return true;
  if (result?.mutationDispatched === true) return true;
  if (result?.mutationDispatched === false) return false;
  return null;
}

export function steerFailureErrorForResult(result) {
  const mutationDispatched = steerMutationDispatchEvidence(result);
  if (
    result?.deadlineExpired === true
    || String(result?.reason || "") === "steer_deadline_expired"
  ) {
    return new SteerMutationDeadlineExpiredError({
      mutationDispatched,
    });
  }

  const error = new Error(
    String(
      result?.reason
        || "The additional instruction was not added to the active Codex task",
    ),
  );
  error.code = "APP_REMOTE_STEER_FAILED";
  if (Object.hasOwn(Object(result), "mutationDispatched")) {
    error.followupMutationDispatched = mutationDispatched;
  }
  if (typeof result?.failurePhase === "string") {
    error.followupFailurePhase = result.failurePhase;
  }
  if (typeof result?.safeToRetry === "boolean") {
    error.followupSafeToRetry = result.safeToRetry;
  }
  return error;
}

export async function awaitSteerMutationResultBeforeDeadline({
  operation,
  mutationDeadlineEpochMs,
  now = () => Date.now(),
}) {
  if (typeof operation !== "function") {
    throw new TypeError("Steer mutation operation must be a function");
  }
  if (
    remainingSteerMutationTime(
      mutationDeadlineEpochMs,
      now(),
    ) <= 0
  ) {
    throw new SteerMutationDeadlineExpiredError({
      mutationDispatched: false,
    });
  }
  const result = await operation();
  if (
    remainingSteerMutationTime(
      mutationDeadlineEpochMs,
      now(),
    ) <= 0
  ) {
    throw new SteerMutationDeadlineExpiredError({
      mutationDispatched: steerMutationDispatchEvidence(result),
    });
  }
  return result;
}

export function validatedSteerSuccessReceiptForSerialization(
  receipt,
  { now = () => Date.now() } = {},
) {
  if (receipt?.status !== "steered") return receipt;
  const mutationDeadlineEpochMs = Math.trunc(
    Number(receipt?.mutationDeadlineEpochMs),
  );
  if (
    !Number.isSafeInteger(mutationDeadlineEpochMs)
    || remainingSteerMutationTime(
      mutationDeadlineEpochMs,
      now(),
    ) <= 0
  ) {
    throw new SteerMutationDeadlineExpiredError({
      mutationDispatched:
        steerMutationDispatchEvidence(receipt) ?? true,
    });
  }
  return receipt;
}

export class SerializedSteerMutationQueue {
  constructor({
    now = () => Date.now(),
    mutationBudgetMs,
  }) {
    const budget = Math.trunc(Number(mutationBudgetMs));
    if (!Number.isSafeInteger(budget) || budget <= 0) {
      throw new Error("Steer mutation budget must be a positive integer");
    }
    this.now = now;
    this.mutationBudgetMs = budget;
    this.tail = Promise.resolve();
  }

  enqueue(operation) {
    if (typeof operation !== "function") {
      throw new TypeError("Steer mutation operation must be a function");
    }
    const receivedAtMs = Math.trunc(Number(this.now()));
    const mutationDeadlineEpochMs =
      receivedAtMs + this.mutationBudgetMs;
    if (
      !Number.isSafeInteger(receivedAtMs)
      || !Number.isSafeInteger(mutationDeadlineEpochMs)
    ) {
      throw new Error("Steer mutation deadline is invalid");
    }
    const run = async () => {
      if (
        remainingSteerMutationTime(
          mutationDeadlineEpochMs,
          this.now(),
        ) <= 0
      ) {
        throw new SteerMutationDeadlineExpiredError();
      }
      return operation({
        receivedAtMs,
        mutationDeadlineEpochMs,
      });
    };
    const result = this.tail.then(run, run);
    this.tail = result.catch(() => {});
    return result;
  }
}

export class CodexAppRemoteBackend {
  constructor({
    remoteDebugUrl,
    responseTimeoutMs = 10 * 60_000,
    cdpRequestTimeoutMs = 60_000,
    appPath,
    disableGpu = false,
    wakeBeforePrompt = true,
    wakeAllTargetsBeforePrompt = true,
    wakeAppBeforePrompt = false,
    bringToFrontBeforePrompt = false,
    rendererKeepAliveTimeoutMs = 750,
    remoteControlApiBaseUrl,
    remoteControlAuthIssuer,
    remoteControlOauthClientId,
    remoteControlControllerStatePath,
    remoteControlGlobalStatePath,
    remoteControlEnvironmentId,
    remoteControlNativeDeviceKeyPath,
    remoteControlDeviceKeyHelperSourcePath,
    remoteControlDeviceKeyHelperPath,
    remoteControlCliPath,
    remoteControlRequestTimeoutMs = cdpRequestTimeoutMs,
    remoteControlPairingTimeoutMs,
    remoteControlClient = null,
    threadId = "",
    cwd = "/tmp/voice-relay-unconfigured",
    model = "gpt-5.6-sol",
    reasoningEffort = "xhigh",
    serviceTier = null,
    expectedServiceTier = serviceTier,
    profileProvenance = null,
    statePath = "",
    invokeCommand = null,
    streamReplies = streamCodexReplies,
    waitReplies = waitForCodexReplies,
    taskScopedFollowupEvidence = createSessionLogTaskScopedFollowupEvidence(),
    now = () => Date.now(),
    steerAcceptanceTimeoutMs = responseTimeoutMs,
  }) {
    const restoredState = this.readStateFromPath(statePath);
    this.responseTimeoutMs = responseTimeoutMs;
    this.cwd = cwd;
    this.model = normalizeModelForConfig(model) || "gpt-5.6-sol";
    this.reasoningEffort = normalizeReasoningForConfig(reasoningEffort) || "xhigh";
    this.serviceTier = normalizeServiceTierForConfig(serviceTier);
    this.expectedServiceTier = normalizeServiceTierForConfig(
      expectedServiceTier,
    );
    this.profileProvenance = normalizeProfileProvenance(profileProvenance);
    this.statePath = statePath;
    this.threadId = String(threadId || restoredState?.threadId || "").trim();
    this.streamReplies = streamReplies;
    this.waitReplies = waitReplies;
    this.taskScopedFollowupEvidence = taskScopedFollowupEvidence;
    this.now = now;
    this.steerAcceptanceTimeoutMs = Math.max(
      1,
      Number(steerAcceptanceTimeoutMs) || responseTimeoutMs,
    );
    this.activeTurn = null;
    this.supportsLiveSteer = true;
    this.supportsTaskScopedFollowup = true;
    this.requiresRendererKeepAlive = false;
    this.startsOnBridgeStartup = true;
    this.stateWriteError = null;
    this.threadResidencyPrewarmGeneration = null;
    this.threadResidencyPrewarmPromise = null;
    this.desiredState = {
      modelText: this.model,
      reasoningText: this.reasoningEffort,
      serviceTier: this.serviceTier,
      backend: "app-remote",
      updatedAt: new Date(this.now()).toISOString(),
    };

    this.remoteControlClient =
      remoteControlClient ||
      (invokeCommand
        ? null
        : new CodexRemoteControlClient({
            apiBaseUrl: remoteControlApiBaseUrl,
            authIssuer: remoteControlAuthIssuer,
            oauthClientId: remoteControlOauthClientId,
            controllerStatePath: remoteControlControllerStatePath,
            globalStatePath: remoteControlGlobalStatePath,
            environmentId: remoteControlEnvironmentId,
            nativeDeviceKeyPath: remoteControlNativeDeviceKeyPath,
            deviceKeyHelperSourcePath: remoteControlDeviceKeyHelperSourcePath,
            deviceKeyHelperPath: remoteControlDeviceKeyHelperPath,
            cliPath: remoteControlCliPath,
            cwd,
            requestTimeoutMs: remoteControlRequestTimeoutMs,
            pairingTimeoutMs: remoteControlPairingTimeoutMs,
          }));
    this.commandDispatcher = this.remoteControlClient
      ? new RemoteControlCommandDispatcher({
          client: this.remoteControlClient,
          cwd,
          model: this.model,
          reasoningEffort: this.reasoningEffort,
          serviceTier: this.serviceTier,
          now: this.now,
        })
      : null;
    this.cdp = null;
    this.invokeCommand =
      invokeCommand ||
      ((command, params, options = {}) =>
        this.commandDispatcher.invoke(command, params, options));
    this.removeStreamInitializedListener =
      this.remoteControlClient?.onStreamInitialized?.(() => {
        void this.prewarmThreadResidency({
          timeoutMs: 10_000,
        }).catch((error) => {
          console.warn(
            `${new Date(this.now()).toISOString()} app-remote residency prewarm failed: ${
              error instanceof Error ? error.message : String(error)
            }`,
          );
        });
      }) || null;
  }

  async start() {
    const transport = this.remoteControlClient?.start
      ? await this.remoteControlClient.start()
      : {
          status: "ready",
          transport: "injected",
          connected: true,
          streamInitialized: true,
          streamGeneration: null,
        };
    const threadResidency = await this.prewarmThreadResidency({
      timeoutMs: 10_000,
    });
    return {
      status: "ready",
      backend: "app-remote",
      connected: Boolean(transport?.connected),
      streamInitialized: Boolean(transport?.streamInitialized),
      streamGeneration:
        normalizedRemoteStreamGeneration(transport?.streamGeneration) ??
        normalizedRemoteStreamGeneration(
          this.remoteControlClient?.streamGeneration,
        ),
      threadResidency,
    };
  }

  async health() {
    const [transport, result] = await Promise.all([
      this.remoteControlClient?.health?.() || {
        ok: true,
        transport: "injected",
      },
      this.invokeCommand(
        "send-cli-request-for-host",
        {
          hostId: "local",
          method: "model/list",
          params: { cursor: null, includeHidden: true, limit: 100 },
          timeoutMs: 30_000,
          source: "voice_relay_app_remote_health",
        },
        { timeoutMs: 45_000 },
      ),
    ]);
    let threadResidency = {
      resident: false,
      reason: this.threadId ? "active_turn" : "thread_not_configured",
    };
    if (this.threadId && !this.activeTurn) {
      if (transport?.connected && transport?.streamInitialized) {
        threadResidency = await this.prewarmThreadResidency({
          timeoutMs: 10_000,
        }).catch((error) => ({
          resident: false,
          reason: "probe_failed",
          error: error instanceof Error ? error.message : String(error),
        }));
      } else {
        threadResidency = {
          resident: false,
          reason: "stream_not_initialized",
        };
      }
    }
    const configured = findModelProfile(result, this.model);
    const efforts = supportedReasoningEfforts(configured);
    const serviceTiers = supportedServiceTierIDs(configured);
    const serviceTierAvailable = !this.serviceTier
      || serviceTiers.includes(this.serviceTier);
    return {
      ok: Boolean(
        transport?.ok &&
          configured &&
          efforts.includes(this.reasoningEffort) &&
          serviceTierAvailable,
      ),
      backend: "app-remote",
      transport: "remote-controller",
      threadId: this.threadId || null,
      model: this.model,
      reasoningEffort: this.reasoningEffort,
      serviceTier: this.serviceTier,
      modelAvailable: Boolean(configured),
      reasoningEffortAvailable: efforts.includes(this.reasoningEffort),
      serviceTierAvailable,
      controller: transport,
      threadResidency,
      targetCount: 0,
      page: null,
    };
  }

  async prewarmThreadResidency({ timeoutMs = 10_000 } = {}) {
    if (!this.threadId) {
      return { resident: false, reason: "thread_not_configured" };
    }
    if (this.activeTurn) {
      return { resident: false, reason: "active_turn" };
    }
    const streamGeneration = normalizedRemoteStreamGeneration(
      this.remoteControlClient?.streamGeneration,
    );
    if (streamGeneration === null) {
      return { resident: false, reason: "stream_not_initialized" };
    }
    if (
      this.threadResidencyPrewarmPromise &&
      this.threadResidencyPrewarmGeneration === streamGeneration
    ) {
      return this.threadResidencyPrewarmPromise;
    }
    const prewarmPromise = this.invokeCommand(
      "probe-thread-residency",
      {
        conversationId: this.threadId,
        model: this.model,
        reasoningEffort: this.reasoningEffort,
        workspaceRoots: [this.cwd],
      },
      { timeoutMs },
    );
    this.threadResidencyPrewarmGeneration = streamGeneration;
    this.threadResidencyPrewarmPromise = prewarmPromise;
    try {
      return await prewarmPromise;
    } finally {
      if (this.threadResidencyPrewarmPromise === prewarmPromise) {
        this.threadResidencyPrewarmPromise = null;
      }
    }
  }

  async keepAliveRenderer() {
    return {
      ok: true,
      backend: "app-remote",
      transport: "remote-controller",
      enabled: false,
      reason: "not_renderer_backed",
    };
  }

  async ask(text, options = {}) {
    return this.askWithMessages(text, options);
  }

  async askWithMessages(
    text,
    {
      prefix = "",
      onMessage = null,
      onTaskStarted = null,
      onAccepted = null,
      requestIdPrefix = "voice-relay-app-remote",
      requestTag = "voice_relay_request_id",
      inputItems = null,
      preferredThreadId = "",
      ownerSessionId = "",
      expectedTurnId = "",
      sessionFile = "",
      capturedOffset = null,
      requireSameTurn = false,
      allowRotation = true,
    } = {},
  ) {
    const requestId = `${requestIdPrefix}-${this.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const body = String(text || "").trim();
    if (!body) throw new Error("Codex app Remote prompt cannot be empty");
    if (this.activeTurn) {
      const error = new Error("Codex app Remote already has an active root request");
      error.code = "APP_REMOTE_BUSY";
      throw error;
    }
    const exactBinding =
      allowRotation === false
        ? normalizeExactAppBinding({
            preferredThreadId,
            ownerSessionId,
            expectedTurnId,
            sessionFile,
            capturedOffset,
            requireSameTurn,
          })
        : null;
    if (exactBinding && !validExactAppBinding(exactBinding, this.threadId)) {
      throw exactAppBindingError("wrong_thread");
    }
    const prompt = `${prefix}[${requestTag}: ${requestId}]\n${body}`.trim();
    const sinceMs = this.now();
    const acceptance = createDeferred();
    const dispatchProfile = immutableDispatchProfile({
      model: this.model,
      reasoningEffort: this.reasoningEffort,
      serviceTier: this.serviceTier,
      expectedServiceTier: this.expectedServiceTier,
      provenance: this.profileProvenance,
    });
    const lifecycle = {
      requestId,
      threadId: this.threadId || null,
      turnId: null,
      taskStartedTurnId: null,
      sessionFile: null,
      acceptedOffset: null,
      startedAt: new Date(sinceMs).toISOString(),
      steerPending: false,
      responseRevisionFence: new AcceptedSteerResponseRevisionFence(),
      cancelRequested: false,
      terminalError: null,
      acceptanceInterruptStarted: false,
      phase: "preparing",
      acceptance,
      exactBinding,
      dispatchProfile,
    };
    const streamAbortController = new AbortController();
    let replyPromise = null;
    const handleTaskStarted = async (evidence) => {
      if (this.activeTurn !== lifecycle || lifecycle.cancelRequested) return;
      lifecycle.taskStartedTurnId = evidence.turnId;
      if (lifecycle.phase !== "accepted") lifecycle.phase = "task_started";
      await onTaskStarted?.(evidence);
    };
    const handleAccepted = async (evidence) => {
      if (this.activeTurn !== lifecycle || lifecycle.cancelRequested) return;
      try {
        if (lifecycle.exactBinding) {
          assertExactAppAcceptance({
            binding: lifecycle.exactBinding,
            evidence,
            requestId,
          });
        }
        this.assertAcceptedTurnProfile(evidence, dispatchProfile);
      } catch (error) {
        lifecycle.cancelRequested = true;
        lifecycle.terminalError = error;
        lifecycle.acceptanceInterruptStarted = true;
        lifecycle.phase = "profile_mismatch";
        acceptance.resolve(null);
        await this.interruptLifecycle(lifecycle);
        throw error;
      }
      lifecycle.turnId = evidence.turnId;
      lifecycle.sessionFile = evidence.sessionFile;
      lifecycle.acceptedOffset = evidence.acceptedOffset;
      lifecycle.remoteStreamGeneration = normalizedRemoteStreamGeneration(
        this.remoteControlClient?.streamGeneration,
      );
      lifecycle.phase = "accepted";
      acceptance.resolve(evidence);
      await onAccepted?.(evidence);
    };
    const startReplyStream = (expectedRootSessionId) => {
      if (replyPromise) return replyPromise;
      replyPromise = Promise.resolve(
        this.streamReplies({
          requestId,
          expectedRootSessionId,
          sinceMs,
          timeoutMs: this.responseTimeoutMs,
          signal: streamAbortController.signal,
          onTaskStarted: handleTaskStarted,
          onAccepted: handleAccepted,
          onMessage: onMessage || (async () => {}),
          getAcceptedSteerRevision: () =>
            lifecycle.responseRevisionFence.snapshot(),
        }),
      );
      void replyPromise.catch(() => {});
      return replyPromise;
    };
    this.activeTurn = lifecycle;
    try {
      await this.assertProfileAvailable(dispatchProfile);
      this.throwIfCancelled(lifecycle);
      const threadId = await this.submitPrompt(prompt, inputItems, lifecycle, {
        onDispatching: startReplyStream,
      });
      this.throwIfCancelled(lifecycle);
      lifecycle.threadId = threadId;
      if (lifecycle.phase !== "accepted") lifecycle.phase = "streaming";
      try {
        const reply = await startReplyStream(threadId);
        return { requestId, prompt, reply };
      } catch (caught) {
        const error =
          caught instanceof Error ? caught : new Error(String(caught));
        if (
          isReplyStreamTimeout(error) &&
          this.activeTurn === lifecycle &&
          lifecycle.phase === "accepted" &&
          nonEmptyString(lifecycle.threadId) &&
          nonEmptyString(lifecycle.turnId) &&
          nonEmptyString(lifecycle.sessionFile) &&
          Number.isSafeInteger(lifecycle.acceptedOffset) &&
          !lifecycle.cancelRequested
        ) {
          lifecycle.cancelRequested = true;
          lifecycle.acceptanceInterruptStarted = true;
          lifecycle.phase = "response_timeout_interrupting";
          try {
            const interruptResult = await this.interruptLifecycle(lifecycle, {
              initiatedBy: "bridge_response_timeout",
            });
            if (interruptResult?.status === "ignored") {
              lifecycle.phase = "response_timeout_interrupt_ignored";
              error.acceptedTurnInterruptIgnored = true;
              error.acceptedTurnInterruptReason =
                nonEmptyString(interruptResult.reason) || "unknown";
            } else {
              lifecycle.phase = "response_timeout_interrupted";
              error.acceptedTurnInterrupted = true;
              error.acceptedTurnId = lifecycle.turnId;
            }
          } catch (interruptError) {
            lifecycle.phase = "response_timeout_interrupt_failed";
            error.acceptedTurnInterruptFailed = true;
            error.interruptError =
              interruptError instanceof Error
                ? interruptError.message
                : String(interruptError);
            error.cause = interruptError;
          }
        }
        throw error;
      }
    } finally {
      streamAbortController.abort();
      acceptance.resolve(null);
      if (this.stateWriteError) this.persistStateBestEffort();
      if (this.activeTurn === lifecycle) this.activeTurn = null;
    }
  }

  async submitPrompt(
    prompt,
    inputItems = null,
    lifecycle = this.activeTurn,
    { onDispatching = null } = {},
  ) {
    const dispatchProfile = lifecycle?.dispatchProfile
      || immutableDispatchProfile({
        model: this.model,
        reasoningEffort: this.reasoningEffort,
        serviceTier: this.serviceTier,
        expectedServiceTier: this.expectedServiceTier,
        provenance: this.profileProvenance,
      });
    if (!this.threadId) {
      if (lifecycle?.exactBinding) throw exactAppBindingError("wrong_thread");
      return this.startNewConversation(
        prompt,
        inputItems,
        lifecycle,
        dispatchProfile,
      );
    }

    lifecycle.phase = "resuming";
    let resumeResult;
    try {
      resumeResult = await this.resumeThread();
    } catch (error) {
      if (!isMissingConversationError(error)) throw error;
      if (lifecycle?.exactBinding) throw exactAppBindingError("wrong_thread");
      this.throwIfCancelled(lifecycle);
      this.threadId = "";
      lifecycle.threadId = null;
      this.persistStateBestEffort();
      return this.startNewConversation(
        prompt,
        inputItems,
        lifecycle,
        dispatchProfile,
      );
    }
    this.throwIfCancelled(lifecycle);
    if (lifecycle?.exactBinding) {
      await this.refreshExactAppBinding(lifecycle.exactBinding, resumeResult);
      this.throwIfCancelled(lifecycle);
    } else if (normalizeSessionId(resumeResult?.activeTurnId)) {
      throw appRemoteBusyError(
        "The Voice task already has an active turn; the new request was not dispatched",
      );
    }
    lifecycle.phase = "locking_profile";
    await this.lockThreadSettingsForNextTurn(dispatchProfile);
    this.throwIfCancelled(lifecycle);
    lifecycle.phase = "dispatching";
    onDispatching?.(this.threadId);
    await this.invokeCommand(
      "send-follow-up-message",
      {
        hostId: "local",
        conversationId: this.threadId,
        prompt,
        model: dispatchProfile.model,
        reasoningEffort: dispatchProfile.reasoningEffort,
        serviceTier: dispatchProfile.serviceTier,
        messageMetadata: { source: "voice_relay_remote" },
        inputItems: normalizeAppInputItems(inputItems),
        ...(lifecycle?.exactBinding?.expectedClosedTurnId
          ? {
              expectedClosedTurnId:
                lifecycle.exactBinding.expectedClosedTurnId,
            }
          : {}),
      },
      { timeoutMs: 60_000 },
    );
    if (lifecycle.phase !== "accepted") lifecycle.phase = "submitted";
    if (lifecycle.cancelRequested) {
      if (!lifecycle.acceptanceInterruptStarted) {
        await this.interruptLifecycle(lifecycle);
      }
      this.throwIfCancelled(lifecycle);
    }
    return this.threadId;
  }

  async startNewConversation(
    prompt,
    inputItems,
    lifecycle,
    dispatchProfile = lifecycle?.dispatchProfile,
  ) {
    this.throwIfCancelled(lifecycle);
    lifecycle.phase = "dispatching";
    const threadId = await this.invokeCommand(
      "start-conversation",
      startConversationParams({
        prompt,
        cwd: this.cwd,
        model: dispatchProfile.model,
        reasoningEffort: dispatchProfile.reasoningEffort,
        serviceTier: dispatchProfile.serviceTier,
        expectedServiceTier: dispatchProfile.expectedServiceTier,
        inputItems,
      }),
      { timeoutMs: 60_000 },
    );
    if (!threadId) throw new Error("Codex app Remote did not return a thread id");
    this.threadId = String(threadId);
    lifecycle.threadId = this.threadId;
    lifecycle.phase = "submitted";
    this.persistStateBestEffort();
    if (lifecycle.cancelRequested) {
      await this.interruptLifecycle(lifecycle);
      this.throwIfCancelled(lifecycle);
    }
    return this.threadId;
  }

  async resumeThread() {
    return this.invokeCommand(
      "maybe-resume-conversation",
      {
        hostId: "local",
        conversationId: this.threadId,
        model: this.model,
        reasoningEffort: this.reasoningEffort,
        serviceTier: this.serviceTier,
        workspaceRoots: [this.cwd],
        collaborationMode: null,
        permissions: FULL_ACCESS_PERMISSIONS,
        approvalsReviewer: "user",
        shouldSendPermissionOverrides: true,
        requireReconciliation: Boolean(this.activeTurn?.exactBinding),
      },
      { timeoutMs: 60_000 },
    );
  }

  async lockThreadSettingsForNextTurn(
    dispatchProfile = immutableDispatchProfile({
      model: this.model,
      reasoningEffort: this.reasoningEffort,
      serviceTier: this.serviceTier,
      expectedServiceTier: this.expectedServiceTier,
      provenance: this.profileProvenance,
    }),
  ) {
    return this.invokeCommand(
      "update-thread-settings-for-next-turn",
      {
        conversationId: this.threadId,
        threadSettings: lockedThreadSettings({
          model: dispatchProfile.model,
          reasoningEffort: dispatchProfile.reasoningEffort,
          serviceTier: dispatchProfile.serviceTier,
          expectedServiceTier: dispatchProfile.expectedServiceTier,
        }),
      },
      { timeoutMs: 60_000 },
    );
  }

  async refreshExactAppBinding(binding, resumeResult) {
    if (!validExactAppBinding(binding, this.threadId)) {
      throw exactAppBindingError("wrong_thread");
    }
    if (!validExactResumeResult(resumeResult)) {
      throw exactAppBindingError("missing_ack");
    }
    let capture;
    try {
      capture = await this.taskScopedFollowupEvidence.capture({
        rootSessionId: binding.ownerSessionId,
        turnId: binding.expectedTurnId,
      });
    } catch {
      throw exactAppBindingError("missing_ack");
    }
    const captureOffset = safeSessionOffset(capture?.offset);
    if (
      !capture ||
      normalizeSessionId(capture.rootSessionId) !== binding.ownerSessionId ||
      normalizeSessionId(capture.turnId) !== binding.expectedTurnId ||
      canonicalSessionPath(capture.sessionFile) !== binding.sessionFile ||
      captureOffset === null ||
      captureOffset < binding.preflightOffset ||
      typeof capture.turnOpen !== "boolean"
    ) {
      throw exactAppBindingError("missing_ack");
    }
    const activeTurnId = normalizeSessionId(resumeResult.activeTurnId);
    if (binding.requireSameTurn) {
      if (capture.turnOpen) {
        if (activeTurnId !== binding.expectedTurnId) {
          throw exactAppBindingError("submission_ambiguous");
        }
      } else {
        if (activeTurnId && activeTurnId !== binding.expectedTurnId) {
          throw exactAppBindingError("submission_ambiguous");
        }
        binding.requireSameTurn = false;
        binding.expectedClosedTurnId = binding.expectedTurnId;
      }
    } else {
      if (
        capture.turnOpen ||
        (activeTurnId && activeTurnId !== binding.expectedTurnId)
      ) {
        throw exactAppBindingError("submission_ambiguous");
      }
      binding.expectedClosedTurnId = binding.expectedTurnId;
    }
    binding.submissionOffset = captureOffset;
  }

  async preflightTaskScopedFollowup() {
    const active = this.activeTurn;
    if (!active || active.cancelRequested) {
      const preferredThreadId = normalizeSessionId(this.threadId);
      let capture = null;
      if (preferredThreadId) {
        try {
          capture = await this.taskScopedFollowupEvidence.capture({
            rootSessionId: preferredThreadId,
          });
        } catch {
          return { status: "failed", exactTask: false, reason: "missing_ack" };
        }
      }
      if (this.activeTurn !== active) {
        return {
          status: "failed",
          exactTask: false,
          reason: "submission_ambiguous",
        };
      }
      if (!preferredThreadId) {
        return { status: "failed", exactTask: false, reason: "wrong_thread" };
      }
      if (!capture) {
        return { status: "failed", exactTask: false, reason: "missing_ack" };
      }
      if (
        normalizeSessionId(capture.rootSessionId) !== preferredThreadId
      ) {
        return { status: "failed", exactTask: false, reason: "wrong_thread" };
      }
      const capturedOffset = safeSessionOffset(capture.offset);
      const capturedTurnId = normalizeSessionId(capture.turnId);
      const sessionFile = canonicalSessionPath(capture.sessionFile);
      if (
        !capturedTurnId ||
        !sessionFile ||
        capturedOffset === null ||
        typeof capture.turnOpen !== "boolean"
      ) {
        return { status: "failed", exactTask: false, reason: "missing_ack" };
      }
      if (active && capture?.turnOpen) {
        return {
          status: "failed",
          exactTask: false,
          reason: "submission_ambiguous",
        };
      }
      return {
        status: "idle",
        exactTask: true,
        binding: {
          preferredThreadId,
          preferredThreadTitle: "",
          taskScoped: true,
          ownerSessionId:
            normalizeSessionId(capture.rootSessionId) || preferredThreadId,
          expectedTurnId: capturedTurnId,
          sessionFile,
          capturedOffset,
          requireSameTurn: capture.turnOpen,
        },
      };
    }

    if (!active.turnId || !active.threadId) {
      const accepted = active.acceptance
        ? await waitForDeferred(active.acceptance, 15_000)
        : null;
      if (
        !accepted ||
        this.activeTurn !== active ||
        active.cancelRequested ||
        !active.turnId ||
        !active.threadId
      ) {
        return { status: "failed", exactTask: false, reason: "missing_ack" };
      }
    }

    const rootSessionId = normalizeSessionId(active.threadId);
    const turnId = normalizeSessionId(active.turnId);
    let capture;
    try {
      capture = await this.taskScopedFollowupEvidence.capture({
        rootSessionId,
        turnId,
      });
    } catch {
      return { status: "failed", exactTask: false, reason: "missing_ack" };
    }
    if (
      this.activeTurn !== active ||
      active.cancelRequested ||
      !capture?.turnOpen ||
      normalizeSessionId(capture.rootSessionId) !== rootSessionId ||
      normalizeSessionId(capture.turnId) !== turnId ||
      !capture.sessionFile
    ) {
      return {
        status: "failed",
        exactTask: false,
        reason:
          capture?.turnOpen === false || this.activeTurn !== active
            ? "submission_ambiguous"
            : "wrong_thread",
      };
    }
    try {
      await this.assertProfileAvailable();
    } catch (error) {
      return taskScopedProfilePreflightFailure(error);
    }
    return {
      status: "active",
      exactTask: true,
      binding: {
        preferredThreadId: rootSessionId,
        preferredThreadTitle: "",
        taskScoped: true,
        ownerSessionId: rootSessionId,
        expectedTurnId: turnId,
        sessionFile: String(capture.sessionFile),
      },
    };
  }

  async submitSteer(text, options = {}) {
    const prompt = String(text || "").trim();
    const requestId =
      normalizedFollowupRequestToken(options?.requestToken) ||
      `voice-relay-steer-app-remote-${this.now()}`;
    const mutationDeadlineEpochMs = Math.trunc(
      Number(options?.mutationDeadlineEpochMs),
    );
    const preEnterStartedAt = this.now();
    const expired = (mutationDispatched = false) => ({
      status: "failed",
      reason: "steer_deadline_expired",
      requestId,
      mutationDispatched,
      deadlineExpired: true,
    });
    const remainingMutationTime = () =>
      remainingSteerMutationTime(
        mutationDeadlineEpochMs,
        this.now(),
      );
    if (!prompt) throw new Error("Steer note cannot be empty");
    if (
      !Number.isSafeInteger(mutationDeadlineEpochMs)
      || remainingMutationTime() <= 0
    ) {
      return expired(false);
    }
    if (!this.activeTurn) {
      return {
        status: "ignored",
        reason: "no_active_app_remote_turn",
        requestId,
      };
    }
    const active = this.activeTurn;
    if (active.steerPending) {
      return {
        status: "ignored",
        reason: "steer_already_pending",
        requestId,
      };
    }
    active.steerPending = true;
    try {
      if (!active.turnId || !active.threadId) {
        const activeAcceptanceTime = Math.min(
          15_000,
          remainingMutationTime(),
        );
        if (activeAcceptanceTime <= 0) return expired(false);
        const accepted = await waitForDeferred(
          active.acceptance,
          activeAcceptanceTime,
        );
        if (remainingMutationTime() <= 0) return expired(false);
        if (
          !accepted ||
          this.activeTurn !== active ||
          active.cancelRequested ||
          !active.turnId ||
          !active.threadId
        ) {
          return { status: "ignored", reason: "active_turn_not_accepted", requestId };
        }
      }
      if (remainingMutationTime() <= 0) return expired(false);
      const capture = await this.taskScopedFollowupEvidence.capture({
        rootSessionId: active.threadId,
        turnId: active.turnId,
      });
      if (remainingMutationTime() <= 0) return expired(false);
      if (this.activeTurn !== active || active.cancelRequested) {
        return { status: "ignored", reason: "active_turn_cancelled", requestId };
      }
      if (!capture?.turnOpen) {
        return { status: "ignored", reason: "active_turn_closed", requestId };
      }
      const capturedOffset = Number(capture.offset);
      if (!Number.isSafeInteger(capturedOffset) || capturedOffset < 0) {
        return { status: "failed", reason: "missing_same_turn_ack", requestId };
      }
      const captureCompletedAt = this.now();
      const dispatchTimeRemaining = remainingMutationTime();
      if (dispatchTimeRemaining <= 0) return expired(false);
      active.steerDispatching = true;
      console.log(
        `${new Date().toISOString()} app-remote steer ${requestId} dispatching same-turn follow-up without conversation resume`,
      );
      let dispatchError = null;
      let mutationDispatchEvidence = false;
      let composerSubmittedAt = null;
      try {
        await this.invokeCommand(
          "send-follow-up-message",
          {
            hostId: "local",
            conversationId: this.threadId,
            expectedTurnId: active.turnId,
            expectedStreamGeneration: active.remoteStreamGeneration,
            prompt: `[bridge_followup_request_id: ${requestId}]\n${prompt}`,
            model: this.model,
            reasoningEffort: this.reasoningEffort,
            serviceTier: this.serviceTier,
            messageMetadata: { source: "voice_relay_remote_steer" },
          },
          {
            timeoutMs: Math.min(60_000, dispatchTimeRemaining),
            mutationDeadlineEpochMs,
          },
        );
        const currentStreamGeneration = normalizedRemoteStreamGeneration(
          this.remoteControlClient?.streamGeneration,
        );
        if (currentStreamGeneration !== null) {
          active.remoteStreamGeneration = currentStreamGeneration;
        }
        mutationDispatchEvidence = true;
        composerSubmittedAt = new Date(this.now()).toISOString();
      } catch (error) {
        dispatchError = error;
        if (error?.code === "APP_REMOTE_STEER_DEADLINE_EXPIRED") {
          return expired(error.followupMutationDispatched);
        }
        const failure = exactFollowupFailureDetails(error);
        mutationDispatchEvidence = failure.mutationDispatched;
        if (failure.safeToRetry && failure.mutationDispatched === false) {
          return {
            status: "failed",
            reason: "pre_dispatch_failed",
            requestId,
            ...failure,
          };
        }
      }
      const dispatchCompletedAt = this.now();
      const preEnterTimings = {
        captureMs: Math.max(0, captureCompletedAt - preEnterStartedAt),
        dispatchMs: Math.max(0, dispatchCompletedAt - captureCompletedAt),
        totalMs: Math.max(0, dispatchCompletedAt - preEnterStartedAt),
      };
      active.steerDispatching = false;
      if (this.activeTurn !== active || active.cancelRequested) {
        await this.interruptLifecycle(active);
        return { status: "ignored", reason: "active_turn_cancelled", requestId };
      }
      const acceptanceTimeRemaining = Math.min(
        this.steerAcceptanceTimeoutMs,
        remainingMutationTime(),
      );
      if (acceptanceTimeRemaining <= 0) {
        return expired(mutationDispatchEvidence);
      }
      const pendingAcceptance = Promise.resolve(
        this.taskScopedFollowupEvidence.waitForAcceptance({
          sessionFile: capture.sessionFile,
          rootSessionId: active.threadId,
          turnId: active.turnId,
          afterOffset: capturedOffset,
          requestToken: requestId,
          timeoutMs: acceptanceTimeRemaining,
        }),
      )
        .then((accepted) => {
          const acceptedResult = acceptedSteerResult({
            accepted,
            active,
            capture,
            capturedOffset,
            composerSubmittedAt,
            preEnterTimings,
            prompt,
            requestId,
          });
          if (acceptedResult.status === "steered") {
            mutationDispatchEvidence = true;
            const fence =
              active.responseRevisionFence ||
              (active.responseRevisionFence =
                new AcceptedSteerResponseRevisionFence());
            fence.accept({
              acceptedOffset:
                acceptedResult.acceptanceEvidence.acceptedOffset,
              requestToken:
                acceptedResult.acceptanceEvidence.requestToken,
              rootSessionId:
                acceptedResult.acceptanceEvidence.rootSessionId,
              turnId: acceptedResult.acceptanceEvidence.turnId,
              sessionFile:
                acceptedResult.acceptanceEvidence.sessionFile,
            });
          }
          if (remainingMutationTime() <= 0) {
            return expired(mutationDispatchEvidence);
          }
          if (acceptedResult.status === "steered" || !dispatchError) {
            return acceptedResult;
          }
          return {
            ...acceptedResult,
            reason: "delivery_unconfirmed",
            ...exactFollowupFailureDetails(dispatchError),
          };
        })
        .catch(() =>
          remainingMutationTime() <= 0
            ? expired(mutationDispatchEvidence)
            : {
                status: "failed",
                reason: dispatchError
                  ? "delivery_unconfirmed"
                  : "missing_same_turn_ack",
                requestId,
                composerSubmittedAt,
                ...(dispatchError
                  ? exactFollowupFailureDetails(dispatchError)
                  : {}),
              },
        );
      return await pendingAcceptance;
    } finally {
      if (this.activeTurn?.requestId === active.requestId) {
        this.activeTurn.steerPending = false;
        this.activeTurn.steerDispatching = false;
      }
    }
  }

  hasActiveTurn() {
    return Boolean(this.activeTurn && !this.activeTurn.cancelRequested);
  }

  async stopActiveRun() {
    const requestId = `voice-relay-stop-app-remote-${this.now()}`;
    const lifecycle = this.activeTurn;
    const activeBefore = Boolean(lifecycle && !lifecycle.cancelRequested);
    if (!activeBefore) {
      return {
        status: "ignored",
        reason: "no_active_app_remote_turn",
        requestId,
        activeBefore,
        activeAfter: false,
      };
    }
    lifecycle.cancelRequested = true;
    if (
      lifecycle.threadId &&
      ["dispatching", "submitted", "streaming", "accepted"].includes(lifecycle.phase)
    ) {
      await this.interruptLifecycle(lifecycle);
    }
    return {
      status: "stopped",
      requestId,
      activeBefore,
      activeAfter: false,
    };
  }

  throwIfCancelled(lifecycle) {
    if (!lifecycle?.cancelRequested) return;
    if (lifecycle.terminalError) throw lifecycle.terminalError;
    const error = new Error("Codex app Remote request cancelled");
    error.code = "APP_REMOTE_CANCELLED";
    throw error;
  }

  async interruptLifecycle(lifecycle, { initiatedBy = "user" } = {}) {
    const conversationId = String(lifecycle?.threadId || this.threadId || "").trim();
    if (!conversationId) return;
    return this.invokeCommand(
      "interrupt-conversation",
      {
        hostId: "local",
        conversationId,
        expectedTurnId: nonEmptyString(lifecycle?.turnId),
        initiatedBy,
      },
      { timeoutMs: 30_000 },
    );
  }

  async setModel(modelText) {
    const model = normalizeModelForConfig(modelText);
    if (!model) throw new Error("Model cannot be empty");
    await this.applyDefaultModelConfig({ model, reasoningEffort: this.reasoningEffort });
    this.model = model;
    return {
      status: "set",
      requestId: `voice-relay-model-app-remote-${this.now()}`,
      modelText: this.model,
      backend: "app-remote",
      appliesTo: "next_turn",
    };
  }

  async setReasoningLevel(reasoningText) {
    const reasoningEffort = normalizeReasoningForConfig(reasoningText);
    if (!reasoningEffort) throw new Error("Reasoning effort cannot be empty");
    await this.applyDefaultModelConfig({ model: this.model, reasoningEffort });
    this.reasoningEffort = reasoningEffort;
    return {
      status: "set",
      requestId: `voice-relay-reasoning-app-remote-${this.now()}`,
      reasoningText: this.reasoningEffort,
      serviceTier: this.serviceTier,
      backend: "app-remote",
      appliesTo: "next_turn",
    };
  }

  async applyDefaultModelConfig({ model = this.model, reasoningEffort = this.reasoningEffort } = {}) {
    return this.invokeCommand(
      "set-default-model-config-for-host",
      {
        hostId: "local",
        model,
        reasoningEffort,
        profile: null,
      },
      { timeoutMs: 30_000 },
    );
  }

  setDesiredReadyState(update = {}) {
    if (update.modelText) {
      this.model = normalizeModelForConfig(update.modelText) || this.model;
    }
    if (update.reasoningText) {
      this.reasoningEffort =
        normalizeReasoningForConfig(update.reasoningText) || this.reasoningEffort;
    }
    this.desiredState = {
      modelText: this.model,
      reasoningText: this.reasoningEffort,
      backend: "app-remote",
      appliesTo: "next_turn",
      updatedAt: new Date(this.now()).toISOString(),
    };
    this.writeState();
    return this.desiredState;
  }

  clearDesiredReadyState() {
    this.desiredState = null;
    return { status: "cleared", backend: "app-remote" };
  }

  readState() {
    return this.readStateFromPath(this.statePath);
  }

  readStateFromPath(statePath) {
    if (!statePath || !fs.existsSync(statePath)) return null;
    try {
      return JSON.parse(fs.readFileSync(statePath, "utf8"));
    } catch {
      return null;
    }
  }

  writeState() {
    if (!this.statePath) return;
    const state = {
      threadId: this.threadId || null,
      backend: "app-remote",
      updatedAt: new Date(this.now()).toISOString(),
    };
    fs.mkdirSync(path.dirname(this.statePath), { recursive: true });
    const temporaryPath = `${this.statePath}.${process.pid}.${Math.random()
      .toString(36)
      .slice(2, 10)}.tmp`;
    try {
      fs.writeFileSync(temporaryPath, `${JSON.stringify(state, null, 2)}\n`, {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      fs.renameSync(temporaryPath, this.statePath);
    } finally {
      try {
        if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
      } catch {}
    }
  }

  persistStateBestEffort() {
    try {
      this.writeState();
      this.stateWriteError = null;
      return true;
    } catch (error) {
      this.stateWriteError = error;
      console.warn(
        `${new Date(this.now()).toISOString()} app-remote state persistence degraded: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return false;
    }
  }

  async assertProfileAvailable(
    dispatchProfile = immutableDispatchProfile({
      model: this.model,
      reasoningEffort: this.reasoningEffort,
      serviceTier: this.serviceTier,
      expectedServiceTier: this.expectedServiceTier,
      provenance: this.profileProvenance,
    }),
  ) {
    let result;
    for (let attempt = 1; attempt <= 2; attempt += 1) {
      try {
        result = await this.invokeCommand(
          "send-cli-request-for-host",
          {
            hostId: "local",
            method: "model/list",
            params: { cursor: null, includeHidden: true, limit: 100 },
            timeoutMs: 30_000,
            source: "voice_relay_app_remote_profile_gate",
          },
          { timeoutMs: 45_000 },
        );
        break;
      } catch (error) {
        if (attempt >= 2 || !isRetryableProfileReadFailure(error)) throw error;
        console.warn(
          `${new Date(this.now()).toISOString()} app-remote profile gate retrying after read-only stream recovery attempt=${attempt}`,
        );
      }
    }
    const configured = findModelProfile(result, dispatchProfile.model);
    const availableEfforts = supportedReasoningEfforts(configured);
    const availableServiceTiers = supportedServiceTierIDs(configured);
    if (
      !configured
      || !availableEfforts.includes(dispatchProfile.reasoningEffort)
      || (dispatchProfile.serviceTier
        && !availableServiceTiers.includes(dispatchProfile.serviceTier))
    ) {
      throw new Error(
        `Configured app Remote profile is unavailable: ${dispatchProfile.model}/${dispatchProfile.reasoningEffort}/${dispatchProfile.serviceTier || "default"}`,
      );
    }
  }

  assertAcceptedTurnProfile(
    { sessionFile, turnId } = {},
    dispatchProfile = immutableDispatchProfile({
      model: this.model,
      reasoningEffort: this.reasoningEffort,
      serviceTier: this.serviceTier,
      expectedServiceTier: this.expectedServiceTier,
      provenance: this.profileProvenance,
    }),
  ) {
    const context = readTurnContext(sessionFile, turnId);
    if (!context) throw new Error("Accepted app Remote turn context was not found");
    const actualSandbox = context.sandbox_policy?.type;
    if (
      context.model !== dispatchProfile.model ||
      context.effort !== dispatchProfile.reasoningEffort ||
      context.approval_policy !== "never" ||
      actualSandbox !== "danger-full-access"
    ) {
      throw acceptedTurnProfileMismatchError({
        expected: dispatchProfile,
        actual: {
          model: context.model,
          reasoningEffort: context.effort,
          approvalPolicy: context.approval_policy,
          sandbox: actualSandbox,
        },
      });
    }
  }
}

export class RemoteControlCommandDispatcher {
  constructor({
    client,
    cwd = "/tmp/voice-relay-unconfigured",
    model = "gpt-5.6-sol",
    reasoningEffort = "xhigh",
    serviceTier = null,
    now = () => Date.now(),
  } = {}) {
    if (!client || typeof client.request !== "function") {
      throw new Error("Remote controller command dispatcher requires a client");
    }
    this.client = client;
    this.cwd = cwd;
    this.defaultModel = normalizeModelForConfig(model) || "gpt-5.6-sol";
    this.defaultReasoningEffort =
      normalizeReasoningForConfig(reasoningEffort) || "xhigh";
    this.defaultServiceTier = normalizeServiceTierForConfig(serviceTier);
    this.now = now;
    this.nextSettingsByThread = new Map();
    this.threadResidencyById = new Map();
  }

  async invoke(
    command,
    params = {},
    {
      timeoutMs = 60_000,
      mutationDeadlineEpochMs = null,
    } = {},
  ) {
    switch (command) {
      case "send-cli-request-for-host":
        return this.client.request(params.method, params.params, {
          timeoutMs: params.timeoutMs || timeoutMs,
        });
      case "maybe-resume-conversation":
        return this.resumeConversation(params, { timeoutMs });
      case "probe-thread-residency":
        return this.probeThreadResidency(params, { timeoutMs });
      case "update-thread-settings-for-next-turn":
        return this.updateThreadSettings(params, { timeoutMs });
      case "send-follow-up-message":
        return this.sendFollowup(params, {
          timeoutMs,
          mutationDeadlineEpochMs,
        });
      case "start-conversation":
        return this.startConversation(params, { timeoutMs });
      case "interrupt-conversation":
        return this.interruptConversation(params, { timeoutMs });
      case "set-default-model-config-for-host":
        return this.setDefaultModelConfig(params, { timeoutMs });
      default:
        throw new Error(
          "Unsupported Remote controller command: " + String(command || ""),
        );
    }
  }

  async resumeConversation(
    params,
    {
      timeoutMs,
      mutationDeadlineEpochMs = null,
    },
  ) {
    const threadId = requiredString(
      params.conversationId,
      "Remote controller conversation id",
    );
    const model =
      normalizeModelForConfig(params.model) || this.defaultModel;
    const reasoningEffort =
      normalizeReasoningForConfig(params.reasoningEffort) ||
      this.defaultReasoningEffort;
    const serviceTier = Object.hasOwn(params, "serviceTier")
      ? normalizeServiceTierForConfig(params.serviceTier)
      : this.defaultServiceTier;
    const cwd = firstWorkspaceRoot(params.workspaceRoots) || this.cwd;
    const residency = this.currentThreadResidency({
      threadId,
      model,
      reasoningEffort,
      cwd,
    });
    if (residency && params.forceResume !== true) {
      if (params.requireReconciliation !== true) {
        return {
          activeTurnId: null,
          threadSource: "remote-control-resident",
        };
      }
      try {
        const thread = await this.readThread(threadId, {
          timeoutMs: this.boundedCommandTimeout(
            timeoutMs,
            mutationDeadlineEpochMs,
          ),
          phase: "resident_thread_reconciliation",
          mutationDeadlineEpochMs,
        });
        this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
        this.markThreadResident({
          threadId,
          model,
          reasoningEffort,
          cwd,
          threadSource: thread?.threadSource || thread?.source,
        });
        return resumeResultFromThread(thread);
      } catch (error) {
        if (!isThreadResidencyMissingError(error)) throw error;
        this.invalidateThreadResidency(threadId);
      }
    }
    if (params.forceResume !== true) {
      try {
        const thread = await this.readThread(threadId, {
          timeoutMs: this.boundedCommandTimeout(
            timeoutMs,
            mutationDeadlineEpochMs,
          ),
          phase: "thread_residency_probe",
          mutationDeadlineEpochMs,
        });
        this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
        this.markThreadResident({
          threadId,
          model,
          reasoningEffort,
          cwd,
          threadSource: thread?.threadSource || thread?.source,
        });
        return resumeResultFromThread(thread);
      } catch (error) {
        if (!isThreadResidencyMissingError(error)) throw error;
      }
    }
    this.invalidateThreadResidency(threadId);
    await this.client.request(
      "thread/resume",
      {
        threadId,
        cwd,
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        config: {
          model,
          model_reasoning_effort: reasoningEffort,
        },
        model,
        serviceTier,
      },
      {
        timeoutMs: this.boundedCommandTimeout(
          timeoutMs,
          mutationDeadlineEpochMs,
        ),
      },
    );
    this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
    const thread = await this.readThread(threadId, {
      timeoutMs: this.boundedCommandTimeout(
        timeoutMs,
        mutationDeadlineEpochMs,
      ),
      phase: "post_resume_reconciliation",
      mutationDeadlineEpochMs,
    });
    this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
    this.markThreadResident({
      threadId,
      model,
      reasoningEffort,
      cwd,
      threadSource: thread?.threadSource || thread?.source,
    });
    return resumeResultFromThread(thread);
  }

  async probeThreadResidency(params, { timeoutMs }) {
    const threadId = requiredString(
      params.conversationId,
      "Remote controller conversation id",
    );
    const model =
      normalizeModelForConfig(params.model) || this.defaultModel;
    const reasoningEffort =
      normalizeReasoningForConfig(params.reasoningEffort) ||
      this.defaultReasoningEffort;
    const cwd = firstWorkspaceRoot(params.workspaceRoots) || this.cwd;
    const residency = this.currentThreadResidency({
      threadId,
      model,
      reasoningEffort,
      cwd,
    });
    if (residency) {
      return {
        resident: true,
        source: "cached",
        streamGeneration: residency.streamGeneration,
        establishedAtMs: residency.establishedAtMs,
      };
    }
    const response = await this.client.request(
      "thread/read",
      { threadId, includeTurns: false },
      {
        timeoutMs,
        requestMetadata: {
          phase: "thread_residency_health_probe",
          attempt: 1,
          maxAttempts: 1,
        },
      },
    );
    const thread = response?.thread || response;
    if (!thread?.id || thread.id !== threadId) {
      throw new Error("Conversation not found: " + threadId);
    }
    if (isThreadNotLoaded(thread)) {
      throw new Error("Conversation not loaded: " + threadId);
    }
    const marked = this.markThreadResident({
      threadId,
      model,
      reasoningEffort,
      cwd,
      threadSource: thread?.threadSource || thread?.source,
    });
    return {
      resident: Boolean(marked),
      source: "thread_read",
      streamGeneration: marked?.streamGeneration ?? null,
      establishedAtMs: marked?.establishedAtMs ?? null,
    };
  }

  currentThreadResidency({ threadId, cwd }) {
    const residency = this.threadResidencyById.get(threadId);
    const streamGeneration = normalizedRemoteStreamGeneration(
      this.client.streamGeneration,
    );
    if (
      !residency ||
      streamGeneration === null ||
      residency.streamGeneration !== streamGeneration ||
      residency.environmentId !== nonEmptyString(this.client.environmentId) ||
      residency.cwd !== cwd
    ) {
      return null;
    }
    return residency;
  }

  markThreadResident({
    threadId,
    cwd,
    threadSource = "",
  }) {
    const streamGeneration = normalizedRemoteStreamGeneration(
      this.client.streamGeneration,
    );
    if (streamGeneration === null) {
      this.threadResidencyById.delete(threadId);
      return null;
    }
    const residency = {
      threadId,
      streamGeneration,
      environmentId: nonEmptyString(this.client.environmentId),
      cwd,
      threadSource: nonEmptyString(threadSource) || "remote-control",
      establishedAtMs: this.now(),
    };
    this.threadResidencyById.set(threadId, residency);
    return residency;
  }

  invalidateThreadResidency(threadId) {
    this.threadResidencyById.delete(threadId);
  }

  assertSteerMutationDeadline(mutationDeadlineEpochMs) {
    if (
      mutationDeadlineEpochMs === null
      || mutationDeadlineEpochMs === undefined
    ) {
      return null;
    }
    const remainingMs = remainingSteerMutationTime(
      mutationDeadlineEpochMs,
      this.now(),
    );
    if (remainingMs <= 0) {
      throw new SteerMutationDeadlineExpiredError();
    }
    return remainingMs;
  }

  boundedCommandTimeout(timeoutMs, mutationDeadlineEpochMs) {
    const requestedTimeoutMs = Number(timeoutMs);
    const normalizedTimeoutMs =
      Number.isFinite(requestedTimeoutMs) && requestedTimeoutMs > 0
        ? Math.max(1, Math.floor(requestedTimeoutMs))
        : 60_000;
    const remainingMs = this.assertSteerMutationDeadline(
      mutationDeadlineEpochMs,
    );
    return remainingMs === null
      ? normalizedTimeoutMs
      : Math.max(1, Math.min(normalizedTimeoutMs, remainingMs));
  }

  steerDeadlineRequestMetadata(
    mutationDeadlineEpochMs,
    phase = "exact_followup_turn_steer",
  ) {
    if (
      mutationDeadlineEpochMs === null
      || mutationDeadlineEpochMs === undefined
    ) {
      return { phase };
    }
    this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
    const deadlineAtMs = Math.trunc(Number(mutationDeadlineEpochMs));
    return {
      phase,
      deadlineAtMs,
      attemptDeadlineAtMs: deadlineAtMs,
    };
  }

  async updateThreadSettings(params, { timeoutMs }) {
    const threadId = requiredString(
      params.conversationId,
      "Remote controller conversation id",
    );
    const settings = normalizeLockedSettings(
      params.threadSettings,
      this.defaultModel,
      this.defaultReasoningEffort,
      this.defaultServiceTier,
    );
    const before = await this.readThread(threadId, {
      timeoutMs,
      phase: "pre_profile_update_reconciliation",
    });
    if (activeThreadTurn(before)?.id) {
      throw appRemoteBusyError(
        "The Voice task already has an active turn; profile settings were not changed",
      );
    }
    await this.client.request(
      "thread/settings/update",
      {
        threadId,
        model: settings.model,
        effort: settings.reasoningEffort,
        serviceTier: settings.serviceTier,
        approvalPolicy: "never",
        approvalsReviewer: "user",
        permissions: ":danger-full-access",
      },
      { timeoutMs },
    );
    const resumed = await this.client.request(
      "thread/resume",
      { threadId, excludeTurns: true },
      { timeoutMs },
    );
    const activeTurnId = normalizeSessionId(
      activeThreadTurn(resumed?.thread)?.id,
    );
    if (activeTurnId) {
      throw appRemoteBusyError(
        "The Voice task became active before the requested profile could be dispatched",
      );
    }
    assertResolvedThreadProfile({
      expected: settings,
      actual: resolvedThreadProfile(resumed),
    });
    this.nextSettingsByThread.set(threadId, settings);
    return {
      status: "updated",
      threadId,
      threadSettings: settings,
      resolvedProfile: resolvedThreadProfile(resumed),
    };
  }

  async sendFollowup(
    params,
    {
      timeoutMs,
      mutationDeadlineEpochMs = null,
    },
  ) {
    this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
    const threadId = requiredString(
      params.conversationId,
      "Remote controller conversation id",
    );
    const expectedTurnId = normalizeSessionId(params.expectedTurnId);
    const expectedClosedTurnId = normalizeSessionId(
      params.expectedClosedTurnId,
    );
    const input = directTurnInput(params.prompt, params.inputItems);
    const settings = this.turnSettings(threadId, params);
    if (expectedTurnId && expectedClosedTurnId) {
      const error = new Error(
        "Remote follow-up cannot bind an open and closed turn together",
      );
      error.code = "APP_REMOTE_AMBIGUOUS_TURN_BINDING";
      throw annotateExactFollowupError(error, {
        phase: "pre_followup_turn_binding_validation",
        mutationDispatched: false,
        safeToRetry: true,
      });
    }
    if (expectedTurnId) {
      const expectedStreamGeneration = normalizedRemoteStreamGeneration(
        params.expectedStreamGeneration,
      );
      const currentStreamGeneration = normalizedRemoteStreamGeneration(
        this.client.streamGeneration,
      );
      if (
        expectedStreamGeneration !== null &&
        currentStreamGeneration !== null &&
        expectedStreamGeneration !== currentStreamGeneration
      ) {
        let thread;
        let reconciledActiveTurnId = null;
        try {
          thread = await this.readThread(threadId, {
            timeoutMs: this.boundedCommandTimeout(
              timeoutMs,
              mutationDeadlineEpochMs,
            ),
            phase: "pre_exact_followup_stream_reconciliation",
            mutationDeadlineEpochMs,
          });
          this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
        } catch (error) {
          this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
          if (!isExactFollowupRehydratableReadFailure(error)) {
            throw annotateExactFollowupError(error, {
              phase: "pre_exact_followup_stream_reconciliation",
              mutationDispatched: false,
              safeToRetry: true,
            });
          }
          let resumed;
          try {
            resumed = await this.resumeConversation(
              {
                conversationId: threadId,
                model: settings.model,
                reasoningEffort: settings.reasoningEffort,
                serviceTier: settings.serviceTier,
                workspaceRoots: [this.cwd],
                forceResume: true,
                requireReconciliation: true,
              },
              {
                timeoutMs: this.boundedCommandTimeout(
                  timeoutMs,
                  mutationDeadlineEpochMs,
                ),
                mutationDeadlineEpochMs,
              },
            );
            this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
          } catch (resumeError) {
            this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
            throw annotateExactFollowupError(resumeError, {
              phase: "pre_exact_followup_stream_resume",
              mutationDispatched: null,
              safeToRetry: false,
            });
          }
          reconciledActiveTurnId = normalizeSessionId(resumed?.activeTurnId);
        }
        if (thread) {
          reconciledActiveTurnId = normalizeSessionId(
            activeThreadTurn(thread)?.id,
          );
        }
        if (reconciledActiveTurnId !== expectedTurnId) {
          const error = new Error(
            "Exact active turn changed after the Remote stream was replaced",
          );
          error.code = "APP_REMOTE_STALE_ACTIVE_TURN";
          error.expectedTurnId = expectedTurnId;
          error.actualTurnId = reconciledActiveTurnId || null;
          throw annotateExactFollowupError(error, {
            phase: "pre_exact_followup_turn_validation",
            mutationDispatched: false,
            safeToRetry: true,
          });
        }
        if (thread) {
          this.markThreadResident({
            threadId,
            model: settings.model,
            reasoningEffort: settings.reasoningEffort,
            cwd: this.cwd,
            threadSource: thread?.threadSource || thread?.source,
          });
        }
      }
      try {
        const steerTimeoutMs = this.boundedCommandTimeout(
          timeoutMs,
          mutationDeadlineEpochMs,
        );
        const requestMetadata = this.steerDeadlineRequestMetadata(
          mutationDeadlineEpochMs,
        );
        return await this.client.request(
          "turn/steer",
          {
            threadId,
            expectedTurnId,
            input,
          },
          {
            timeoutMs: steerTimeoutMs,
            requestMetadata,
          },
        );
      } catch (error) {
        if (error?.code === "APP_REMOTE_STEER_DEADLINE_EXPIRED") {
          throw error;
        }
        if (
          error?.code === "REMOTE_CONTROL_REQUEST_TIMEOUT"
          && error?.preDispatch === true
          && Number(error?.deadlineAtMs)
            === Number(mutationDeadlineEpochMs)
        ) {
          throw new SteerMutationDeadlineExpiredError({
            mutationDispatched: false,
          });
        }
        const preDispatch = error?.preDispatch === true;
        throw annotateExactFollowupError(error, {
          phase: "exact_followup_turn_steer",
          mutationDispatched: preDispatch ? false : null,
          safeToRetry: preDispatch,
        });
      }
    }
    let activeTurn;
    try {
      const thread = await this.readThread(threadId, {
        timeoutMs,
        phase: "pre_followup_reconciliation",
      });
      activeTurn = activeThreadTurn(thread);
      this.markThreadResident({
        threadId,
        model: settings.model,
        reasoningEffort: settings.reasoningEffort,
        cwd: this.cwd,
        threadSource: thread?.threadSource || thread?.source,
      });
    } catch (error) {
      if (!isThreadResidencyMissingError(error)) {
        throw annotateExactFollowupError(error, {
          phase: "pre_followup_reconciliation",
          mutationDispatched: false,
          safeToRetry: true,
        });
      }
      this.invalidateThreadResidency(threadId);
      let resumed;
      try {
        resumed = await this.resumeConversation(
          {
            conversationId: threadId,
            model: settings.model,
            reasoningEffort: settings.reasoningEffort,
            serviceTier: settings.serviceTier,
            workspaceRoots: [this.cwd],
            forceResume: true,
            requireReconciliation: true,
          },
          { timeoutMs },
        );
      } catch (resumeError) {
        throw annotateExactFollowupError(resumeError, {
          phase: "pre_followup_resume_recovery",
          mutationDispatched: false,
          safeToRetry: true,
        });
      }
      activeTurn = resumed.activeTurnId
        ? { id: resumed.activeTurnId }
        : null;
    }
    const reconciledActiveTurnId = normalizeSessionId(activeTurn?.id);
    if (expectedClosedTurnId && activeTurn && !reconciledActiveTurnId) {
      const error = new Error(
        "Remote follow-up found an active turn without a stable identity",
      );
      error.code = "APP_REMOTE_STALE_ACTIVE_TURN";
      error.expectedTurnId = expectedClosedTurnId;
      error.actualTurnId = null;
      throw annotateExactFollowupError(error, {
        phase: "pre_closed_followup_turn_validation",
        mutationDispatched: false,
        safeToRetry: true,
      });
    }
    if (
      expectedClosedTurnId &&
      reconciledActiveTurnId &&
      reconciledActiveTurnId !== expectedClosedTurnId
    ) {
      const error = new Error(
        "A different active turn owns the thread after the expected turn closed",
      );
      error.code = "APP_REMOTE_STALE_ACTIVE_TURN";
      error.expectedTurnId = expectedClosedTurnId;
      error.actualTurnId = reconciledActiveTurnId;
      throw annotateExactFollowupError(error, {
        phase: "pre_closed_followup_turn_validation",
        mutationDispatched: false,
        safeToRetry: true,
      });
    }
    if (reconciledActiveTurnId && !expectedClosedTurnId) {
      throw appRemoteBusyError(
        "The Voice task already has an active turn; the new root request was not dispatched",
      );
    }
    return this.client.request(
      "turn/start",
      {
        threadId,
        input,
        cwd: this.cwd,
        approvalPolicy: "never",
        model: settings.model,
        effort: settings.reasoningEffort,
        serviceTier: settings.serviceTier,
      },
      { timeoutMs },
    );
  }

  async startConversation(params, { timeoutMs }) {
    const model =
      normalizeModelForConfig(params.model || params.config?.model) ||
      this.defaultModel;
    const reasoningEffort =
      normalizeReasoningForConfig(
        params.reasoningEffort || params.config?.model_reasoning_effort,
      ) || this.defaultReasoningEffort;
    const serviceTier = Object.hasOwn(params, "serviceTier")
      ? normalizeServiceTierForConfig(params.serviceTier)
      : this.defaultServiceTier;
    const expectedServiceTier = Object.hasOwn(params, "expectedServiceTier")
      ? normalizeServiceTierForConfig(params.expectedServiceTier)
      : serviceTier;
    const cwd = nonEmptyString(params.cwd) || this.cwd;
    const started = await this.client.request(
      "thread/start",
      {
        cwd,
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        config: {
          model,
          model_reasoning_effort: reasoningEffort,
        },
        model,
        serviceTier,
        threadSource: "user",
      },
      { timeoutMs },
    );
    const threadId = started?.thread?.id;
    if (!threadId) {
      throw new Error("Remote controller thread/start did not return a thread id");
    }
    assertResolvedThreadProfile({
      expected: {
        model,
        reasoningEffort,
        expectedServiceTier,
      },
      actual: resolvedThreadProfile(started),
    });
    this.nextSettingsByThread.set(threadId, {
      model,
      reasoningEffort,
      serviceTier,
      expectedServiceTier,
      approvalPolicy: "never",
      sandbox: "danger-full-access",
    });
    await this.client.request(
      "turn/start",
      {
        threadId,
        input: normalizeDirectStartInput(params.input),
        cwd,
        approvalPolicy: "never",
        model,
        effort: reasoningEffort,
        serviceTier,
      },
      { timeoutMs },
    );
    this.markThreadResident({
      threadId,
      model,
      reasoningEffort,
      serviceTier,
      cwd,
      threadSource: "thread_start",
    });
    return threadId;
  }

  async interruptConversation(params, { timeoutMs }) {
    const threadId = requiredString(
      params.conversationId,
      "Remote controller conversation id",
    );
    const thread = await this.readThread(threadId, {
      timeoutMs,
      phase: "pre_interrupt_reconciliation",
    });
    const activeTurn = activeThreadTurn(thread);
    if (!activeTurn?.id) {
      return {
        status: "ignored",
        reason: "no_active_remote_turn",
      };
    }
    const expectedTurnId = nonEmptyString(params.expectedTurnId);
    if (expectedTurnId && activeTurn.id !== expectedTurnId) {
      return {
        status: "ignored",
        reason: "active_turn_changed",
        expectedTurnId,
        activeTurnId: activeTurn.id,
      };
    }
    return this.client.request(
      "turn/interrupt",
      {
        threadId,
        turnId: activeTurn.id,
      },
      { timeoutMs },
    );
  }

  async setDefaultModelConfig(params, { timeoutMs }) {
    const model =
      normalizeModelForConfig(params.model) || this.defaultModel;
    const reasoningEffort =
      normalizeReasoningForConfig(params.reasoningEffort) ||
      this.defaultReasoningEffort;
    const serviceTier = Object.hasOwn(params, "serviceTier")
      ? normalizeServiceTierForConfig(params.serviceTier)
      : this.defaultServiceTier;
    const catalog = await this.client.request(
      "model/list",
      { cursor: null, includeHidden: true, limit: 100 },
      { timeoutMs },
    );
    const profile = findModelProfile(catalog, model);
    const efforts = supportedReasoningEfforts(profile);
    const serviceTiers = supportedServiceTierIDs(profile);
    if (
      !profile
      || !efforts.includes(reasoningEffort)
      || (serviceTier && !serviceTiers.includes(serviceTier))
    ) {
      throw new Error(
        "Configured Remote controller profile is unavailable: " +
          model +
          "/" +
          reasoningEffort +
          "/" +
          (serviceTier || "default"),
      );
    }
    this.defaultModel = model;
    this.defaultReasoningEffort = reasoningEffort;
    this.defaultServiceTier = serviceTier;
    return {
      status: "set",
      model,
      reasoningEffort,
      serviceTier,
      appliesTo: "next_turn",
    };
  }

  async readThread(
    threadId,
    {
      timeoutMs,
      phase = "thread_read_reconciliation",
      mutationDeadlineEpochMs = null,
    },
  ) {
    const requestedTimeoutMs = this.boundedCommandTimeout(
      timeoutMs,
      mutationDeadlineEpochMs,
    );
    const totalTimeoutMs =
      Number.isFinite(requestedTimeoutMs) && requestedTimeoutMs > 0
        ? Math.max(2, Math.floor(requestedTimeoutMs))
        : 60_000;
    const relativeDeadlineAtMs = this.now() + totalTimeoutMs;
    const deadlineAtMs =
      mutationDeadlineEpochMs === null
      || mutationDeadlineEpochMs === undefined
        ? relativeDeadlineAtMs
        : Math.min(
            relativeDeadlineAtMs,
            Math.trunc(Number(mutationDeadlineEpochMs)),
          );
    let recovery = null;
    let primaryFailure = null;
    for (let attempt = 1; attempt <= 2; attempt += 1) {
      const remainingMs = Math.floor(deadlineAtMs - this.now());
      if (remainingMs <= 0) {
        this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
        if (primaryFailure) primaryFailure.deadlineExceeded = true;
        throw (
          primaryFailure || new Error("thread reconciliation deadline exceeded")
        );
      }
      const attemptTimeoutMs =
        attempt === 1
          ? Math.max(1, Math.floor(remainingMs / 2))
          : Math.max(1, remainingMs);
      const attemptDeadlineAtMs = Math.min(
        deadlineAtMs,
        this.now() + attemptTimeoutMs,
      );
      const baseRequestMetadata = {
        phase,
        attempt,
        maxAttempts: 2,
        deadlineAtMs,
        attemptDeadlineAtMs,
        streamRecovery: recovery?.reason || null,
      };
      let activeReadMethod = "thread/read";
      let activeRequestMetadata = {
        ...baseRequestMetadata,
        method: activeReadMethod,
      };
      try {
        const thread = await runWithAbsoluteDeadline({
          deadlineAtMs: attemptDeadlineAtMs,
          now: this.now,
          timeoutError: () => {
            const error = new RemoteControllerRequestTimeoutError({
              method: activeReadMethod,
              requestId: null,
              streamId: this.client.streamId || null,
              streamGeneration: this.client.streamGeneration ?? null,
              timeoutMs: Math.max(
                1,
                Math.floor(attemptDeadlineAtMs - this.now()),
              ),
              requestMetadata: activeRequestMetadata,
            });
            error.absoluteDeadlineExceeded = true;
            return error;
          },
          operation: async (signal) => {
            const requestRead = async (method, params) => {
              activeReadMethod = method;
              activeRequestMetadata = {
                ...baseRequestMetadata,
                method,
              };
              const requestTimeoutMs = Math.max(
                1,
                Math.floor(attemptDeadlineAtMs - this.now()),
              );
              const boundedRequestTimeoutMs = this.boundedCommandTimeout(
                requestTimeoutMs,
                mutationDeadlineEpochMs,
              );
              return this.client.request(method, params, {
                timeoutMs: boundedRequestTimeoutMs,
                requestMetadata: activeRequestMetadata,
                signal,
              });
            };
            const response = await requestRead(
              "thread/read",
              {
                threadId,
                includeTurns: false,
              },
            );
            const thread = response?.thread || response;
            if (!thread?.id || thread.id !== threadId) {
              throw new Error("Conversation not found: " + threadId);
            }
            if (isThreadNotLoaded(thread)) {
              const error = new Error("Conversation not loaded: " + threadId);
              error.code = "APP_REMOTE_THREAD_NOT_LOADED";
              throw error;
            }
            if (
              threadRuntimeStatusType(thread) === "active" &&
              !activeThreadTurn(thread)
            ) {
              const turnsResponse = await requestRead("thread/turns/list", {
                threadId,
                cursor: null,
                limit: 1,
                itemsView: "notLoaded",
                sortDirection: "desc",
              });
              const reconciled = {
                ...thread,
                turns: Array.isArray(turnsResponse?.data)
                  ? turnsResponse.data
                  : [],
              };
              if (!activeThreadTurn(reconciled)) {
                const error = new Error(
                  "Active conversation has no in-progress turn: " + threadId,
                );
                error.code = "APP_REMOTE_ACTIVE_TURN_UNAVAILABLE";
                throw error;
              }
              return reconciled;
            }
            return thread;
          },
        });
        this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
        return thread;
      } catch (error) {
        this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
        if (
          !isRetryableThreadReconciliationFailure(error, activeReadMethod) ||
          attempt === 2
        ) {
          if (
            attempt === 2 &&
            isRetryableThreadReconciliationFailure(error, activeReadMethod)
          ) {
            error.retryExhausted = true;
            error.primaryRequestId = primaryFailure?.requestId || null;
          }
          throw error;
        }
        primaryFailure = error;
        const recoveryTimeoutMs = Math.floor(deadlineAtMs - this.now());
        if (recoveryTimeoutMs <= 0) {
          this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
          error.deadlineExceeded = true;
          throw error;
        }
        if (typeof this.client.prepareReadOnlyRetry === "function") {
          try {
            recovery = await runWithAbsoluteDeadline({
              deadlineAtMs,
              now: this.now,
              timeoutError: () => {
                error.deadlineExceeded = true;
                return error;
              },
              operation: (signal) =>
                this.client.prepareReadOnlyRetry({
                  method: activeReadMethod,
                  timeoutMs: recoveryTimeoutMs,
                  timeoutError: error,
                  signal,
                }),
            });
            this.assertSteerMutationDeadline(mutationDeadlineEpochMs);
          } catch (recoveryError) {
            if (recoveryError !== error) {
              error.recoveryFailed = true;
              error.recoveryError =
                recoveryError instanceof Error
                  ? recoveryError.message
                  : String(recoveryError);
              error.cause = recoveryError;
            }
            throw error;
          }
        } else {
          recovery = {
            reset: false,
            reason: "client_recovery_unavailable",
          };
        }
      }
    }
    throw (
      primaryFailure ||
      new Error("thread reconciliation failed without a result")
    );
  }

  turnSettings(threadId, params) {
    const stored = this.nextSettingsByThread.get(threadId) || {};
    return {
      model:
        normalizeModelForConfig(params.model || stored.model) ||
        this.defaultModel,
      reasoningEffort:
        normalizeReasoningForConfig(
          params.reasoningEffort || stored.reasoningEffort,
        ) || this.defaultReasoningEffort,
      serviceTier: Object.hasOwn(params, "serviceTier")
        ? normalizeServiceTierForConfig(params.serviceTier)
        : Object.hasOwn(stored, "serviceTier")
          ? normalizeServiceTierForConfig(stored.serviceTier)
          : this.defaultServiceTier,
    };
  }
}

export function startConversationParams({
  prompt,
  cwd,
  model,
  reasoningEffort,
  serviceTier = null,
  expectedServiceTier = serviceTier,
  inputItems = null,
}) {
  return {
    hostId: "local",
    input: [
      { type: "text", text: prompt, text_elements: [] },
      ...normalizeAppInputItems(inputItems),
    ],
    attachments: [],
    commentAttachments: [],
    collaborationMode: null,
    cwd,
    workspaceRoots: [cwd],
    workspaceKind: "project",
    model,
    reasoningEffort,
    serviceTier: normalizeServiceTierForConfig(serviceTier),
    expectedServiceTier: normalizeServiceTierForConfig(expectedServiceTier),
    config: { model, model_reasoning_effort: reasoningEffort },
    permissions: FULL_ACCESS_PERMISSIONS,
    approvalsReviewer: "user",
    shouldSendPermissionOverrides: true,
    threadSource: "user",
  };
}

export function findModelProfile(result, model) {
  const requested = normalizeModelForConfig(model);
  return (
    (Array.isArray(result?.data) ? result.data : []).find(
      (entry) =>
        entry?.model === requested ||
        entry?.id === requested ||
        entry?.slug === requested,
    ) || null
  );
}

export function supportedReasoningEfforts(profile) {
  return Array.from(
    new Set(
      (profile?.supportedReasoningEfforts || [])
        .map((entry) =>
          typeof entry === "string" ? entry : entry?.reasoningEffort,
        )
        .filter(Boolean),
    ),
  );
}

export function supportedServiceTierIDs(profile) {
  return Array.from(
    new Set(
      (profile?.serviceTiers || [])
        .map((entry) => String(entry?.id || "").trim())
        .filter(Boolean),
    ),
  );
}

export function appCommandModuleExpression() {
  return `Array.from(document.querySelectorAll("link[rel=modulepreload]"))
    .map((link) => link.href)
    .filter((href) => href.endsWith(".js") && /app-(initial|main)/.test(href))`;
}

export function isAppCommandDispatcherSource(source) {
  const text = String(source || "").trim();
  if (!text || text.length > 200) return false;
  const match = text.match(
    /^(?:async\s+)?function(?:\s+[$\w]+)?\(\s*([$\w]+)\s*,\s*([$\w]+)\s*\)\s*\{\s*return\s+[$\w.]+\.sendRequest\(\s*([$\w]+)\s*,\s*([$\w]+)\s*\)\s*;?\s*\}$/u,
  );
  return Boolean(match && match[1] === match[3] && match[2] === match[4]);
}

export async function invokeAppCommand(
  cdp,
  command,
  params,
  { timeoutMs = 60_000 } = {},
) {
  return cdp.withPage(
    async (page) => {
      const expression = `(async () => {
        const isDispatcher = (${isAppCommandDispatcherSource.toString()});
        let dispatcher = globalThis.__voiceRelayAppRemoteDispatcher;
        if (
          typeof dispatcher === "function" &&
          !isDispatcher(dispatcher.toString())
        ) {
          dispatcher = null;
          delete globalThis.__voiceRelayAppRemoteDispatcher;
        }
        if (typeof dispatcher !== "function") {
          const moduleUrls = ${appCommandModuleExpression()};
          for (const moduleUrl of moduleUrls) {
            const module = await import(moduleUrl);
            dispatcher = Object.values(module).find((candidate) => {
              if (typeof candidate !== "function") return false;
              try {
                return isDispatcher(candidate.toString());
              } catch {
                return false;
              }
            });
            if (typeof dispatcher === "function") break;
          }
          if (typeof dispatcher === "function") {
            globalThis.__voiceRelayAppRemoteDispatcher = dispatcher;
          }
        }
        if (typeof dispatcher !== "function") {
          throw new Error("ChatGPT app Remote command dispatcher is unavailable");
        }
        return dispatcher(${JSON.stringify(command)}, ${JSON.stringify(params)});
      })()`;
      return page.evaluate(expression, { timeoutMs });
    },
    {},
  );
}

export function lockedThreadSettings({
  model,
  reasoningEffort,
  serviceTier = null,
  expectedServiceTier = serviceTier,
} = {}) {
  return {
    model: normalizeModelForConfig(model) || "gpt-5.6-sol",
    effort: normalizeReasoningForConfig(reasoningEffort) || "xhigh",
    serviceTier: normalizeServiceTierForConfig(serviceTier),
    expectedServiceTier: normalizeServiceTierForConfig(expectedServiceTier),
    approvalPolicy: "never",
    approvalsReviewer: "user",
    permissions: ":danger-full-access",
  };
}

function normalizeAppInputItems(inputItems) {
  if (!Array.isArray(inputItems)) return [];
  return inputItems.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const type = String(item.type || "").trim();
    if (type === "localImage") {
      const localPath = String(item.path || "").trim();
      return localPath ? [{ type: "localImage", path: localPath }] : [];
    }
    if (type === "image") {
      const url = String(item.url || "").trim();
      return url ? [{ type: "image", url }] : [];
    }
    if (type === "skill" || type === "mention") {
      const name = String(item.name || "").trim();
      const itemPath = String(item.path || "").trim();
      return name && itemPath ? [{ type, name, path: itemPath }] : [];
    }
    return [];
  });
}

function directTurnInput(prompt, inputItems) {
  const text = requiredString(prompt, "Remote controller prompt");
  return [
    { type: "text", text, text_elements: [] },
    ...normalizeAppInputItems(inputItems),
  ];
}

function normalizeDirectStartInput(input) {
  if (!Array.isArray(input)) {
    throw new Error("Remote controller start input is missing");
  }
  return input.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    if (item.type === "text") {
      const text = nonEmptyString(item.text);
      return text
        ? [
            {
              type: "text",
              text,
              text_elements: Array.isArray(item.text_elements)
                ? item.text_elements
                : [],
            },
          ]
        : [];
    }
    return normalizeAppInputItems([item]);
  });
}

function activeThreadTurn(thread) {
  const turns = Array.isArray(thread?.turns) ? thread.turns : [];
  return (
    [...turns]
      .reverse()
      .find((turn) =>
        ["inProgress", "in_progress", "running"].includes(turn?.status),
      ) || null
  );
}

function resumeResultFromThread(thread) {
  const activeTurn = activeThreadTurn(thread);
  return {
    activeTurnId: activeTurn?.id || null,
    threadSource:
      nonEmptyString(thread?.threadSource) ||
      nonEmptyString(thread?.source) ||
      "remote-control",
  };
}

function normalizeLockedSettings(
  settings,
  fallbackModel,
  fallbackReasoningEffort,
  fallbackServiceTier = null,
) {
  const hasServiceTier = Object.hasOwn(Object(settings), "serviceTier");
  const serviceTier = hasServiceTier
    ? normalizeServiceTierForConfig(settings.serviceTier)
    : normalizeServiceTierForConfig(fallbackServiceTier);
  return {
    model:
      normalizeModelForConfig(settings?.model) ||
      normalizeModelForConfig(fallbackModel) ||
      "gpt-5.6-sol",
    reasoningEffort:
      normalizeReasoningForConfig(
        settings?.effort || settings?.reasoningEffort,
      ) ||
      normalizeReasoningForConfig(fallbackReasoningEffort) ||
      "xhigh",
    serviceTier,
    expectedServiceTier: Object.hasOwn(
      Object(settings),
      "expectedServiceTier",
    )
      ? normalizeServiceTierForConfig(settings.expectedServiceTier)
      : serviceTier,
    approvalPolicy: "never",
    sandbox: "danger-full-access",
  };
}

export function normalizeServiceTierForConfig(value) {
  return String(value || "").trim() === "priority" ? "priority" : null;
}

export function resolveVoiceTurnProfileSelection(
  request = {},
  hostConfig = {},
) {
  const requestedModel = String(request.model || "inherit").trim();
  const requestedReasoningEffort = String(
    request.reasoningEffort || "inherit",
  ).trim();
  const modelInherited = !requestedModel || requestedModel === "inherit";
  const reasoningInherited =
    !requestedReasoningEffort || requestedReasoningEffort === "inherit";
  const fastModeEnabled =
    normalizeServiceTierForConfig(request.serviceTier) === "priority";
  return Object.freeze({
    model: normalizeModelForConfig(
      modelInherited ? hostConfig.model : requestedModel,
    ),
    reasoningEffort: normalizeReasoningForConfig(
      reasoningInherited
        ? hostConfig.reasoningEffort
        : requestedReasoningEffort,
    ),
    serviceTier: fastModeEnabled ? "priority" : null,
    expectedServiceTier: fastModeEnabled
      ? "priority"
      : normalizeServiceTierForConfig(hostConfig.serviceTier),
    provenance: Object.freeze({
      model: modelInherited ? "inherit" : "explicit",
      reasoningEffort: reasoningInherited ? "inherit" : "explicit",
      serviceTier: fastModeEnabled ? "explicit" : "inherit",
    }),
  });
}

function normalizeReasoningForConfig(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[_-]+/gu, " ")
    .replace(/\s+/gu, " ");
  if (!normalized || normalized === "inherit") return "";
  if (normalized === "extra high" || normalized === "extrahigh") {
    return "xhigh";
  }
  const token = normalized.replace(/\s+/gu, "");
  return /^[a-z][a-z0-9]{0,31}$/u.test(token) ? token : "";
}

function normalizeProfileProvenance(value) {
  return Object.freeze({
    model: value?.model === "inherit" ? "inherit" : "explicit",
    reasoningEffort:
      value?.reasoningEffort === "inherit" ? "inherit" : "explicit",
    serviceTier:
      value?.serviceTier === "inherit" ? "inherit" : "explicit",
  });
}

function immutableDispatchProfile({
  model,
  reasoningEffort,
  serviceTier = null,
  expectedServiceTier = serviceTier,
  provenance = null,
} = {}) {
  return Object.freeze({
    model: normalizeModelForConfig(model) || "gpt-5.6-sol",
    reasoningEffort:
      normalizeReasoningForConfig(reasoningEffort) || "xhigh",
    serviceTier: normalizeServiceTierForConfig(serviceTier),
    expectedServiceTier: normalizeServiceTierForConfig(expectedServiceTier),
    provenance: normalizeProfileProvenance(provenance),
  });
}

function firstWorkspaceRoot(value) {
  if (!Array.isArray(value)) return "";
  return nonEmptyString(value.find((entry) => nonEmptyString(entry))) || "";
}

function requiredString(value, label) {
  const text = nonEmptyString(value);
  if (!text) throw new Error(label + " cannot be empty");
  return text;
}

function nonEmptyString(value) {
  const text = String(value || "").trim();
  return text || "";
}

function normalizeExactAppBinding({
  preferredThreadId,
  ownerSessionId,
  expectedTurnId,
  sessionFile,
  capturedOffset,
  requireSameTurn,
}) {
  return {
    preferredThreadId: normalizeSessionId(preferredThreadId),
    ownerSessionId: normalizeSessionId(ownerSessionId),
    expectedTurnId: normalizeSessionId(expectedTurnId),
    sessionFile: canonicalSessionPath(sessionFile),
    preflightOffset: safeSessionOffset(capturedOffset),
    submissionOffset: null,
    requireSameTurn: requireSameTurn === true,
    expectedClosedTurnId: null,
  };
}

function validExactAppBinding(binding, configuredThreadId) {
  const configured = normalizeSessionId(configuredThreadId);
  return Boolean(
    binding &&
      configured &&
      binding.preferredThreadId === configured &&
      binding.ownerSessionId === configured &&
      binding.expectedTurnId &&
      binding.sessionFile &&
      binding.preflightOffset !== null,
  );
}

function validExactResumeResult(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const keys = Object.keys(value).sort();
  if (
    keys.length !== 2 ||
    keys[0] !== "activeTurnId" ||
    keys[1] !== "threadSource"
  ) {
    return false;
  }
  if (
    value.threadSource !== null &&
    (typeof value.threadSource !== "string" ||
      !Boolean(value.threadSource.trim()))
  ) {
    return false;
  }
  return (
    value.activeTurnId === null ||
    (typeof value.activeTurnId === "string" &&
      Boolean(normalizeSessionId(value.activeTurnId)))
  );
}

function assertExactAppAcceptance({ binding, evidence, requestId }) {
  const acceptedOffset = safeSessionOffset(evidence?.acceptedOffset);
  const acceptedTurnId = normalizeSessionId(evidence?.turnId);
  if (
    normalizeSessionId(evidence?.rootSessionId) !== binding.ownerSessionId ||
    canonicalSessionPath(evidence?.sessionFile) !== binding.sessionFile ||
    String(evidence?.requestToken || "").trim() !== requestId ||
    acceptedOffset === null ||
    binding.submissionOffset === null ||
    acceptedOffset <= binding.submissionOffset ||
    !acceptedTurnId ||
    (binding.requireSameTurn && acceptedTurnId !== binding.expectedTurnId) ||
    (!binding.requireSameTurn &&
      !closedTurnAcceptanceStartsWithRequest({
        binding,
        acceptedTurnId,
        acceptedOffset,
        requestId,
      }))
  ) {
    throw exactAppBindingError("missing_ack");
  }
}

function closedTurnAcceptanceStartsWithRequest({
  binding,
  acceptedTurnId,
  acceptedOffset,
  requestId,
}) {
  if (
    acceptedTurnId === binding.expectedTurnId ||
    acceptedOffset <= binding.submissionOffset
  ) {
    return false;
  }
  const length = acceptedOffset - binding.submissionOffset;
  if (length > MAX_EXACT_ACCEPTANCE_SCAN_BYTES) return false;

  let stat;
  try {
    stat = fs.statSync(binding.sessionFile);
  } catch {
    return false;
  }
  if (acceptedOffset > stat.size) return false;

  const buffer = Buffer.alloc(length);
  let fd;
  try {
    fd = fs.openSync(binding.sessionFile, "r");
    if (
      fs.readSync(fd, buffer, 0, length, binding.submissionOffset) !== length
    ) {
      return false;
    }
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }

  let acceptedTurnContextSeen = false;
  for (const line of buffer.toString("utf8").split(/\r?\n/u)) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      return false;
    }
    if (entry?.type === "turn_context" && entry.payload?.turn_id) {
      const turnId = normalizeSessionId(entry.payload.turn_id);
      if (acceptedTurnContextSeen && turnId !== acceptedTurnId) return false;
      acceptedTurnContextSeen = turnId === acceptedTurnId;
      continue;
    }
    const userText = sessionUserMessageText(entry);
    if (acceptedTurnContextSeen && userText !== null) {
      return userText.includes(requestId);
    }
  }
  return false;
}

function sessionUserMessageText(entry) {
  const payload = entry?.payload;
  if (
    entry?.type === "response_item" &&
    payload?.type === "message" &&
    payload?.role === "user"
  ) {
    if (typeof payload.content === "string") return payload.content;
    if (Array.isArray(payload.content)) {
      return payload.content
        .map((item) => item?.text || item?.output_text || "")
        .join("");
    }
    return "";
  }
  if (entry?.type === "event_msg" && payload?.type === "user_message") {
    return String(payload.message || "");
  }
  return null;
}

function safeSessionOffset(value) {
  if (
    value === null ||
    value === undefined ||
    (typeof value === "string" && value.trim() === "")
  ) {
    return null;
  }
  const offset = Number(value);
  return Number.isSafeInteger(offset) && offset >= 0 ? offset : null;
}

function normalizedRemoteStreamGeneration(value) {
  const generation = Number(value);
  return Number.isSafeInteger(generation) && generation >= 0 ? generation : null;
}

function canonicalSessionPath(value) {
  const file = String(value || "").trim();
  if (!file) return "";
  try {
    return fs.realpathSync(file);
  } catch {
    return path.resolve(file);
  }
}

function exactAppBindingError(reason) {
  const error = new Error(`Codex app Remote exact task binding failed: ${reason}`);
  error.code = "APP_REMOTE_EXACT_TASK_MISMATCH";
  error.reason = reason;
  return error;
}

function appRemoteBusyError(message) {
  const error = new Error(message);
  error.code = "APP_REMOTE_BUSY";
  error.preDispatch = true;
  return error;
}

function resolvedThreadProfile(response) {
  return {
    model: nonEmptyString(response?.model) || "unknown",
    reasoningEffort:
      nonEmptyString(response?.reasoningEffort) || "unknown",
    serviceTier: nonEmptyString(response?.serviceTier) || null,
  };
}

function assertResolvedThreadProfile({ expected, actual }) {
  const expectedServiceTier = normalizeServiceTierForConfig(
    Object.hasOwn(Object(expected), "expectedServiceTier")
      ? expected.expectedServiceTier
      : expected.serviceTier,
  );
  const actualServiceTier = normalizeServiceTierForConfig(actual.serviceTier);
  if (
    actual.model === expected.model
    && actual.reasoningEffort === expected.reasoningEffort
    && actualServiceTier === expectedServiceTier
  ) {
    return;
  }
  const error = new Error(
    "Codex app Remote profile was not applied before dispatch: "
      + `expected ${expected.model}/${expected.reasoningEffort}/${expectedServiceTier || "default"}; `
      + `actual ${actual.model}/${actual.reasoningEffort}/${actual.serviceTier || "default"}`,
  );
  error.code = "APP_REMOTE_PROFILE_MISMATCH";
  error.preDispatch = true;
  error.expectedProfile = {
    model: expected.model,
    reasoningEffort: expected.reasoningEffort,
    serviceTier: expectedServiceTier,
  };
  error.actualProfile = actual;
  throw error;
}

function acceptedTurnProfileMismatchError({ expected, actual }) {
  const error = new Error(
    "Accepted app Remote turn profile mismatch: "
      + `expected ${expected.model}/${expected.reasoningEffort}/never/danger-full-access; `
      + `actual ${actual.model}/${actual.reasoningEffort}/${actual.approvalPolicy}/${actual.sandbox}`,
  );
  error.code = "APP_REMOTE_ACCEPTED_PROFILE_MISMATCH";
  error.expectedProfile = expected;
  error.actualProfile = actual;
  return error;
}

function readTurnContext(sessionFile, turnId) {
  if (!sessionFile || !turnId || !fs.existsSync(sessionFile)) return null;
  const lines = fs.readFileSync(sessionFile, "utf8").split(/\r?\n/u);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index].trim();
    if (!line) continue;
    try {
      const entry = JSON.parse(line);
      if (entry?.type === "turn_context" && entry.payload?.turn_id === turnId) {
        return entry.payload;
      }
    } catch {}
  }
  return null;
}

function createDeferred() {
  let settled = false;
  let resolvePromise;
  const promise = new Promise((resolve) => {
    resolvePromise = resolve;
  });
  return {
    promise,
    resolve(value) {
      if (settled) return;
      settled = true;
      resolvePromise(value);
    },
  };
}

async function waitForDeferred(deferred, timeoutMs) {
  if (!deferred?.promise) return null;
  let timeout;
  try {
    return await Promise.race([
      deferred.promise,
      new Promise((resolve) => {
        timeout = setTimeout(() => resolve(null), timeoutMs);
        timeout.unref?.();
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function runWithAbsoluteDeadline({
  deadlineAtMs,
  now,
  timeoutError,
  operation,
}) {
  const remainingMs = Math.floor(deadlineAtMs - now());
  if (remainingMs <= 0) throw timeoutError();
  const controller = new AbortController();
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(() => operation(controller.signal)),
      new Promise((_resolve, reject) => {
        timer = setTimeout(() => {
          const error = timeoutError();
          controller.abort(error);
          reject(error);
        }, remainingMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function acceptedSteerResult({
  accepted,
  active,
  capture,
  capturedOffset,
  composerSubmittedAt,
  preEnterTimings,
  prompt,
  requestId,
}) {
  const acceptedOffset = Number(accepted?.offset);
  if (
    normalizeSessionId(accepted?.rootSessionId) !==
      normalizeSessionId(active.threadId) ||
    normalizeSessionId(accepted?.turnId) !== normalizeSessionId(active.turnId) ||
    String(accepted?.requestToken || "").trim() !== requestId ||
    !Number.isSafeInteger(acceptedOffset) ||
    acceptedOffset <= capturedOffset
  ) {
    return {
      status: "failed",
      reason: "missing_same_turn_ack",
      requestId,
      composerSubmittedAt,
    };
  }
  return {
    status: "steered",
    requestId,
    turnId: accepted.turnId,
    prompt,
    composerSubmittedAt,
    preEnterTimings,
    acceptedAt: accepted.acceptedAt || null,
    incorporated: false,
    acceptanceEvidence: {
      source: "session_log",
      sessionFile: capture.sessionFile,
      rootSessionId: accepted.rootSessionId,
      turnId: accepted.turnId,
      requestToken: accepted.requestToken,
      capturedOffset,
      acceptedOffset,
      acceptedAt: accepted.acceptedAt || null,
    },
  };
}

function annotateExactFollowupError(
  error,
  { phase, mutationDispatched, safeToRetry },
) {
  const annotated =
    error instanceof Error ? error : new Error(String(error || "unknown error"));
  annotated.followupFailurePhase = String(phase || "unknown");
  annotated.followupMutationDispatched =
    mutationDispatched === true
      ? true
      : mutationDispatched === false
        ? false
        : null;
  annotated.followupSafeToRetry = safeToRetry === true;
  return annotated;
}

function exactFollowupFailureDetails(error) {
  const details = {
    failurePhase: String(error?.followupFailurePhase || "exact_followup_unknown"),
    mutationDispatched:
      error?.followupMutationDispatched === true
        ? true
        : error?.followupMutationDispatched === false
          ? false
          : null,
    safeToRetry: error?.followupSafeToRetry === true,
  };
  const errorCode = String(error?.code || "")
    .trim()
    .toUpperCase();
  if (/^[A-Z0-9_:-]{1,80}$/u.test(errorCode)) {
    details.errorCode = errorCode;
  }
  return details;
}

function normalizedFollowupRequestToken(value) {
  const token = String(value || "").trim();
  if (!/^voice-relay-steer-[a-z0-9_-]{8,160}$/iu.test(token)) return "";
  return token;
}

function isMissingConversationError(error) {
  const message = error instanceof Error ? error.message : String(error || "");
  return /(?:conversation|thread|task).*(?:not found|does not exist|missing|archived|deleted)/iu.test(
    message,
  );
}

function isThreadResidencyMissingError(error) {
  if (isMissingConversationError(error)) return true;
  const message = error instanceof Error ? error.message : String(error || "");
  return /(?:thread|conversation|task).*(?:not loaded|not resumed)|^Not initialized$/iu.test(
    message.trim(),
  );
}

function isExactFollowupRehydratableReadFailure(error) {
  return (
    isThreadResidencyMissingError(error) ||
    error?.code === "APP_REMOTE_ACTIVE_TURN_UNAVAILABLE"
  );
}

function isRetryableThreadReconciliationFailure(error, activeMethod = "") {
  const method = nonEmptyString(error?.method) || nonEmptyString(activeMethod);
  return (
    error?.code === "REMOTE_CONTROL_STREAM_GAP" ||
    (error?.code === "REMOTE_CONTROL_REQUEST_TIMEOUT" &&
      (method === "thread/read" || method === "thread/turns/list"))
  );
}

function threadRuntimeStatusType(thread) {
  return (
    nonEmptyString(thread?.status?.type) ||
    nonEmptyString(thread?.threadRuntimeStatus?.type)
  );
}

function isThreadNotLoaded(thread) {
  return threadRuntimeStatusType(thread) === "notLoaded";
}

function isRetryableProfileReadFailure(error) {
  return (
    error?.code === "REMOTE_CONTROL_STREAM_GAP" ||
    (error?.code === "REMOTE_CONTROL_REQUEST_TIMEOUT" &&
      (error?.method === "model/list" || error?.preDispatch === true))
  );
}

function taskScopedProfilePreflightFailure(error) {
  const errorCode = String(error?.code || "")
    .trim()
    .toUpperCase();
  const authUnavailable = new Set([
    "REMOTE_CONTROL_ENVIRONMENT_PAIRING_REQUIRED",
    "REMOTE_CONTROL_ENVIRONMENT_UNAVAILABLE",
    "REMOTE_CONTROL_PAIRING_REQUIRED",
    "REMOTE_CONTROL_REAUTH_REQUIRED",
  ]).has(errorCode);
  return {
    status: "failed",
    exactTask: false,
    reason: authUnavailable ? "auth_unavailable" : "pre_dispatch_failed",
    failurePhase: "task_followup_profile_preflight",
    mutationDispatched: false,
    safeToRetry: !authUnavailable,
    errorCode: /^[A-Z0-9_:-]{1,80}$/u.test(errorCode) ? errorCode : "",
  };
}

function isReplyStreamTimeout(error) {
  const message = error instanceof Error ? error.message : String(error || "");
  return /^Timed out waiting for (?:final )?Codex repl(?:y|ies) for /u.test(
    message,
  );
}
