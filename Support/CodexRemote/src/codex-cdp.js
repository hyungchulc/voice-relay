import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  createSessionLogTaskScopedFollowupEvidence,
  normalizeSessionId,
  streamCodexReplies,
  waitForCodexReplies,
} from "./session-log.js";
import {
  clearDesiredCodexState,
  readDesiredCodexState,
  writeDesiredCodexState,
} from "./codex-settings.js";
import { CodexAppServerBackend } from "./codex-app-server.js";
import { normalizeModelForUi } from "./codex-control-command.js";

export { normalizeModelForUi as normalizeModelLabel };
import { resolveCodexAppPath } from "./codex-app-paths.js";

const execFileAsync = promisify(execFile);
const DESIRED_READY_STALE_GRACE_MS = 60_000;
const POST_RESTART_OBSERVED_READY_FALLBACK_MS = 15_000;
const POST_RESTART_COMPOSER_READY_FALLBACK_MS = 60_000;
const APP_WAKE_RETRY_DELAY_MS = 1_500;
const COMPOSER_SEND_READY_ATTEMPT_MS = 5_000;
const TASK_SCOPED_ACCEPTANCE_TIMEOUT_MS = 5_000;
const TASK_SCOPED_ACCEPTANCE_SETTLEMENT_TIMEOUT_MS = 30_000;
const COMPOSER_RECOVERY_DELAY_MS = 500;
const CDP_EVALUATE_ATTEMPT_TIMEOUT_MS = 5_000;
const MAIN_CODEX_COMPOSER_SELECTOR = '.ProseMirror:not([aria-label="Message ChatGPT"])';
const CODEX_COMPOSER_SURFACE_SELECTOR = ".composer-surface-chrome";

export class CodexDesktopCdp {
  constructor({
    remoteDebugUrl,
    responseTimeoutMs,
    cdpRequestTimeoutMs = 60_000,
    appPath = resolveCodexAppPath(),
    disableGpu = false,
    wakeBeforePrompt = true,
    wakeAllTargetsBeforePrompt = false,
    wakeAppBeforePrompt = false,
    bringToFrontBeforePrompt = false,
    reniceOnDebug = false,
    reniceValue = -5,
    reniceCooldownMs = 60_000,
    reniceProcesses = bestEffortReniceCodexProcesses,
    rendererKeepAliveTimeoutMs = Number(process.env.CODEX_RENDERER_KEEPALIVE_TIMEOUT_MS ?? 750),
    preferredThreadId = "",
    preferredThreadTitle = "",
    preferredThreadTimeoutMs = 60_000,
    threadStatePath = "",
    threadRotateAfterMs = 0,
    threadStartCliPath = "/opt/homebrew/bin/codex",
    threadStartCwd = "/tmp/voice-relay-unconfigured",
    threadStartModel = "",
    threadStartReasoningEffort = "",
    threadStartApprovalPolicy = "never",
    threadStartSandbox = "danger-full-access",
    threadStartRequestTimeoutMs = 60_000,
    threadHandoffStatePath = "",
    threadHandoffMaxBytes = 512 * 1024,
    threadHandoffMaxEntries = 12,
    threadHandoffMaxChars = 6000,
    threadStarter = null,
    taskScopedFollowupEvidence = createSessionLogTaskScopedFollowupEvidence(),
    postRestartThreadDelayMs = 30_000,
    postRestartReadyTimeoutMs = 60_000,
    readyModelTexts = ["5.6"],
    readyReasoningTexts = ["High"],
    readyStatePath =
      process.env.CODEX_READY_STATE_PATH ||
      "/tmp/voice-relay-unconfigured/state/codex-ui-ready-state.json",
    desiredStatePath =
      process.env.CODEX_DESIRED_STATE_PATH ||
      "/tmp/voice-relay-unconfigured/state/codex-ui-desired-state.json",
    connectPage = CdpPage.connect,
    wakeApp = bestEffortWakeApp,
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    now = () => Date.now(),
  }) {
    this.remoteDebugUrl = remoteDebugUrl.replace(/\/+$/, "");
    this.responseTimeoutMs = responseTimeoutMs;
    this.cdpRequestTimeoutMs = cdpRequestTimeoutMs;
    this.appPath = appPath;
    this.disableGpu = disableGpu;
    this.wakeBeforePrompt = wakeBeforePrompt;
    this.wakeAllTargetsBeforePrompt = wakeAllTargetsBeforePrompt;
    this.wakeAppBeforePrompt = wakeAppBeforePrompt;
    this.bringToFrontBeforePrompt = bringToFrontBeforePrompt;
    this.reniceOnDebug = reniceOnDebug;
    this.reniceValue = normalizeReniceValue(reniceValue);
    this.reniceCooldownMs = Math.max(0, Number(reniceCooldownMs) || 0);
    this.reniceProcesses = reniceProcesses;
    this.lastReniceAt = 0;
    this.rendererKeepAliveTimeoutMs = Math.max(250, Number(rendererKeepAliveTimeoutMs) || 750);
    this.preferredThreadId = preferredThreadId;
    this.preferredThreadTitle = preferredThreadTitle;
    this.preferredThreadTimeoutMs = preferredThreadTimeoutMs;
    this.threadStatePath = threadStatePath;
    this.threadRotateAfterMs = normalizePositiveMs(threadRotateAfterMs);
    this.threadStartCliPath = threadStartCliPath;
    this.threadStartCwd = threadStartCwd;
    this.threadStartModel = threadStartModel;
    this.threadStartReasoningEffort = threadStartReasoningEffort;
    this.threadStartApprovalPolicy = threadStartApprovalPolicy;
    this.threadStartSandbox = threadStartSandbox;
    this.threadStartRequestTimeoutMs = threadStartRequestTimeoutMs;
    this.threadHandoffStatePath = threadHandoffStatePath;
    this.threadHandoffMaxBytes = normalizePositiveMs(threadHandoffMaxBytes);
    this.threadHandoffMaxEntries = normalizePositiveMs(threadHandoffMaxEntries);
    this.threadHandoffMaxChars = normalizePositiveMs(threadHandoffMaxChars);
    this.threadStarter = threadStarter;
    this.taskScopedFollowupEvidence = taskScopedFollowupEvidence;
    this.supportsTaskScopedFollowup = Boolean(
      taskScopedFollowupEvidence &&
        typeof taskScopedFollowupEvidence.capture === "function" &&
        typeof taskScopedFollowupEvidence.waitForAcceptance === "function",
    );
    this.lastRotationHandoffSeeded = false;
    this.postRestartThreadDelayMs = postRestartThreadDelayMs;
    this.postRestartReadyTimeoutMs = postRestartReadyTimeoutMs;
    this.readyModelTexts = readyModelTexts;
    this.readyReasoningTexts = readyReasoningTexts;
    this.readyStatePath = readyStatePath;
    this.desiredStatePath = desiredStatePath;
    this.readyState = this.loadReadyState();
    this.desiredState = this.loadDesiredState();
    this.connectPage = connectPage;
    this.wakeApp = wakeApp;
    this.sleep = sleep;
    this.now = now;
    this.lastPromptTargetId = null;
  }

  async health() {
    const targets = await this.listTargets();
    const page = this.pickPageTarget(targets);
    return {
      ok: Boolean(page),
      targetCount: targets.length,
      page: page
        ? { id: page.id, title: page.title, url: page.url, type: page.type }
        : null,
    };
  }

  async ask(
    text,
    {
      prefix = "",
      preferredThreadId = "",
      preferredThreadTitle = "",
      ownerSessionId = "",
      expectedTurnId = "",
      allowRotation = true,
      requestIdPrefix = "voice-relay-codex",
      requestTag = "voice_relay_request_id",
    } = {},
  ) {
    return this.askWithMessages(text, {
      prefix,
      preferredThreadId,
      preferredThreadTitle,
      ownerSessionId,
      expectedTurnId,
      allowRotation,
      requestIdPrefix,
      requestTag,
    });
  }

  async submitRawCommand(text) {
    const requestId = `voice-relay-codex-${Date.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const prompt = String(text || "").trim();
    if (!prompt) {
      throw new Error("Raw Codex command cannot be empty");
    }

    await this.submitPromptToComposer(prompt, requestId);
    return { requestId, prompt };
  }

  async setReasoningLevel(reasoningText) {
    const requestId = `voice-relay-reasoning-${Date.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const targetReasoning = String(reasoningText || "").trim();
    if (!targetReasoning) {
      throw new Error("Reasoning level cannot be empty");
    }

    return this.withPage(async (page) => {
      console.log(`${new Date().toISOString()} codex reasoning ${requestId} selecting thread`);
      await this.ensurePreferredThread(page);
      await page.waitForExpression(
        mainComposerPresentExpression(),
        Math.max(15000, this.preferredThreadTimeoutMs),
      );
      const { result, readyState } = await this.setReasoningLevelOnPage(
        page,
        requestId,
        targetReasoning,
      );
      return { status: "set", requestId, reasoningText: targetReasoning, result, readyState };
    });
  }

  async setModel(modelText) {
    const requestId = `voice-relay-model-${Date.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const targetModel = normalizeModelForUi(modelText);
    if (!targetModel) {
      throw new Error("Model cannot be empty");
    }

    return this.withPage(async (page) => {
      console.log(`${new Date().toISOString()} codex model ${requestId} selecting thread`);
      await this.ensurePreferredThread(page);
      await page.waitForExpression(
        mainComposerPresentExpression(),
        Math.max(15000, this.preferredThreadTimeoutMs),
      );
      const { result, readyState } = await this.setModelOnPage(
        page,
        requestId,
        targetModel,
      );
      return { status: "set", requestId, modelText: targetModel, result, readyState };
    });
  }

  async submitSteer(
    text,
    {
      preferredThreadId = "",
      preferredThreadTitle = "",
      taskScoped = false,
      ownerSessionId = "",
      expectedTurnId = "",
      acceptanceTimeoutMs = 0,
    } = {},
  ) {
    const requestId = `voice-relay-steer-${Date.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const prompt = String(text || "").trim();
    if (!prompt) {
      throw new Error("Steer note cannot be empty");
    }

    return this.submitSteerToComposer(prompt, requestId, {
      preferredThreadId,
      preferredThreadTitle,
      taskScoped,
      ownerSessionId,
      expectedTurnId,
      acceptanceTimeoutMs,
    });
  }

  async stopActiveRun({ preferredThreadId = "", preferredThreadTitle = "" } = {}) {
    const requestId = `voice-relay-stop-${Date.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    return this.withPage(async (page) => {
      console.log(`${new Date().toISOString()} codex stop ${requestId} selecting thread`);
      await this.ensurePreferredThread(page, {
        preferredThreadId,
        preferredThreadTitle,
      });
      const before = await this.readActiveComposerRun(page);
      console.log(`${new Date().toISOString()} codex stop ${requestId} sending Escape`);
      await page.pressEscape();
      await this.sleep(250);
      const after = await this.readActiveComposerRun(page);
      return {
        status: "stopped",
        requestId,
        activeBefore: before?.active ?? null,
        activeAfter: after?.active ?? null,
        before,
        after,
      };
    });
  }

  async readActiveComposerRun(page) {
    try {
      return await page.evaluate(activeComposerRunExpression());
    } catch (error) {
      return {
        active: null,
        reason: errorMessage(error),
      };
    }
  }

  async preflightTaskScopedFollowup({ incoming = null, scope = "message" } = {}) {
    if (!this.supportsTaskScopedFollowup) {
      return { status: "failed", exactTask: false, reason: "missing_ack" };
    }
    return this.withPage(async (page) => {
      const timeoutMs = Math.max(
        1,
        Math.min(
          COMPOSER_SEND_READY_ATTEMPT_MS,
          Number(this.preferredThreadTimeoutMs) || COMPOSER_SEND_READY_ATTEMPT_MS,
        ),
      );
      let selection;
      try {
        selection = await this.ensurePreferredThread(page, {
          allowRotation: false,
          timeoutMs,
        });
        this.assertPreferredThreadSelection(selection, {
          preferredThreadId:
            selection?.requestedThreadId || this.preferredThreadId,
          preferredThreadTitle:
            selection?.requestedThreadTitle || this.preferredThreadTitle,
        });
        await this.verifyPreferredThreadSelection(page, {
          preferredThreadId:
            selection?.requestedThreadId || selection?.threadId || this.preferredThreadId,
          preferredThreadTitle:
            selection?.requestedThreadTitle || selection?.threadTitle || this.preferredThreadTitle,
        });
      } catch (error) {
        return {
          status: "failed",
          exactTask: false,
          reason: preferredThreadSelectionReason(error),
        };
      }

      const rootSessionId = normalizeSessionId(selection?.threadId);
      let evidence;
      try {
        evidence = await this.taskScopedFollowupEvidence.capture({
          rootSessionId,
          incoming,
          scope,
          timeoutMs,
        });
      } catch (error) {
        warnTaskScopedError({
          requestId: incoming?.guid || "preflight",
          phase: "preflight_capture",
          error,
          fallbackCode: "E_CAPTURE_PROBE",
        });
        return { status: "failed", exactTask: false, reason: "missing_ack" };
      }
      if (!validTaskScopedEvidenceCapture(evidence, { rootSessionId })) {
        return { status: "failed", exactTask: false, reason: "wrong_thread" };
      }

      const activeRun = await this.readActiveComposerRun(page);
      if (activeRun?.active === null) {
        return {
          status: "failed",
          exactTask: false,
          reason: "composer_unavailable",
        };
      }
      const binding = {
        preferredThreadId: selection.threadId,
        preferredThreadTitle: selection.threadTitle || "",
        taskScoped: true,
        ownerSessionId: normalizeSessionId(evidence.rootSessionId),
        expectedTurnId: normalizeSessionId(evidence.turnId),
        sessionFile: String(evidence.sessionFile || ""),
      };
      return {
        status: activeRun?.active ? "active" : "idle",
        exactTask: true,
        binding,
      };
    }, { wakeBeforePrompt: false });
  }

  assertPreferredThreadSelection(
    selection,
    { preferredThreadId = "", preferredThreadTitle = "" } = {},
  ) {
    const expectedThreadId = normalizeSessionId(preferredThreadId);
    const expectedThreadTitle = String(preferredThreadTitle || "").trim();
    if (!expectedThreadId && !expectedThreadTitle) return selection;
    if (!selection || selection.ok === false) {
      throw preferredThreadSelectionError(
        selection?.error === "preferred_thread_row_missing"
          ? "preferred_thread_row_missing"
          : "wrong_thread",
      );
    }
    if (
      expectedThreadId &&
      !sameCodexThreadId(selection.threadId, expectedThreadId)
    ) {
      throw preferredThreadSelectionError("wrong_thread");
    }
    if (
      !expectedThreadId &&
      expectedThreadTitle &&
      !sameUiText(selection.threadTitle, expectedThreadTitle)
    ) {
      throw preferredThreadSelectionError("wrong_thread");
    }
    return selection;
  }

  async verifyPreferredThreadSelection(
    page,
    { preferredThreadId = "", preferredThreadTitle = "" } = {},
  ) {
    const result = await page.evaluate(
      preferredThreadVerificationExpression({
        threadId: preferredThreadId,
        threadTitle: preferredThreadTitle,
      }),
    );
    return this.assertPreferredThreadSelection(result, {
      preferredThreadId,
      preferredThreadTitle,
    });
  }

  async askWithMessages(
    text,
    {
      prefix = "",
      onMessage = null,
      onAccepted = null,
      preferredThreadId = "",
      preferredThreadTitle = "",
      ownerSessionId = "",
      expectedTurnId = "",
      allowRotation = true,
      requestIdPrefix = "voice-relay-codex",
      requestTag = "voice_relay_request_id",
    } = {},
  ) {
    const normalizedRequestIdPrefix = String(requestIdPrefix || "voice-relay-codex").trim() || "voice-relay-codex";
    const normalizedRequestTag = String(requestTag || "voice_relay_request_id").trim() || "voice_relay_request_id";
    const requestId = `${normalizedRequestIdPrefix}-${Date.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const prompt = `${prefix}[${normalizedRequestTag}: ${requestId}]\n${text}`.trim();
    const sinceMs = Date.now();

    const submission = await this.submitPromptToComposer(prompt, requestId, {
      preferredThreadId,
      preferredThreadTitle,
      ownerSessionId,
      expectedTurnId,
      allowRotation,
    });
    const expectedRootSessionId =
      submission?.threadId || normalizeSessionId(ownerSessionId);

    const reply = onMessage
      ? await streamCodexReplies({
          requestId,
          expectedRootSessionId,
          sinceMs,
          timeoutMs: this.responseTimeoutMs,
          onAccepted,
          onMessage,
        })
      : await waitForCodexReplies({
          requestId,
          expectedRootSessionId,
          sinceMs,
          timeoutMs: this.responseTimeoutMs,
        });
    return { requestId, prompt, reply };
  }

  async submitPromptToComposer(
    prompt,
    requestId,
    {
      preferredThreadId = "",
      preferredThreadTitle = "",
      ownerSessionId = "",
      expectedTurnId = "",
      allowRotation = true,
    } = {},
  ) {
    return this.withPage(async (page, { postRestartDelayNeeded } = {}) => {
      const recoveredPages = [];
      let activePage = page;
      let selectedThread = null;
      const selectedThreadExpectation = () => ({
        preferredThreadId:
          selectedThread?.requestedThreadId ||
          preferredThreadId ||
          this.preferredThreadId,
        preferredThreadTitle:
          selectedThread?.requestedThreadTitle ||
          preferredThreadTitle ||
          this.preferredThreadTitle,
      });
      const verifySelectedThread = async (candidatePage) => {
        const expectation = selectedThreadExpectation();
        if (!expectation.preferredThreadId && !expectation.preferredThreadTitle) return null;
        return this.verifyPreferredThreadSelection(candidatePage, expectation);
      };
      const recoverPage = async (reason) => {
        const recovered = await this.reconnectPromptPage(requestId, reason);
        recoveredPages.push(recovered);
        activePage = recovered;
        return activePage;
      };
      try {
        console.log(`${new Date().toISOString()} codex prompt ${requestId} selecting thread`);
        selectedThread = await this.ensurePreferredThread(activePage, {
          preferredThreadId,
          preferredThreadTitle,
          ownerSessionId,
          expectedTurnId,
          allowRotation,
        });
        this.assertPreferredThreadSelection(selectedThread, selectedThreadExpectation());
        await activePage.waitForExpression(
          mainComposerPresentExpression(),
          Math.max(15000, this.preferredThreadTimeoutMs),
        );
        if (postRestartDelayNeeded && this.postRestartThreadDelayMs > 0) {
          console.log(
            `${new Date().toISOString()} codex prompt ${requestId} waiting for post-restart UI ready`,
          );
          try {
            await this.waitForPostRestartReady(activePage, requestId, {
              reason: "post-restart",
              correctReasoning: true,
              reconcileDesired: false,
            });
          } catch (error) {
            await this.allowComposerReadyFallback(
              activePage,
              requestId,
              "post-restart",
              error,
            );
          }
        } else {
          await this.correctDesiredReasoningBeforePrompt(activePage, requestId);
        }
        await verifySelectedThread(activePage);
        console.log(`${new Date().toISOString()} codex prompt ${requestId} filling composer`);
        const fillResult = await activePage.evaluate(fillPromptExpression(prompt));
        if (fillResult?.ok === false) {
          throw new Error(`Codex UI prompt fill failed: ${JSON.stringify(fillResult)}`);
        }
        console.log(`${new Date().toISOString()} codex prompt ${requestId} waiting for send`);
        activePage = await this.waitForComposerSendReadyWithRecovery(activePage, {
          requestId,
          prompt,
          recoverPage,
          verifySelection: verifySelectedThread,
        });
        await this.submitComposerDraftWithRecovery(activePage, {
          requestId,
          prompt,
          recoverPage,
          verifySelection: verifySelectedThread,
        });
        return {
          threadId: selectedThread?.threadId || null,
        };
      } finally {
        for (const recoveredPage of recoveredPages) {
          recoveredPage.close();
        }
      }
    });
  }

  async captureReadyStateBestEffort(page, requestId) {
    try {
      return await this.captureReadyState(page, requestId, { reconcileDesired: false });
    } catch (error) {
      console.warn(
        `${new Date().toISOString()} codex prompt ${requestId} skipping UI ready state capture before prompt fill: ${errorMessage(error)}`,
      );
      return null;
    }
  }

  async correctDesiredReasoningBeforePrompt(page, requestId) {
    const observed = await this.captureReadyStateBestEffort(page, requestId);
    const desiredState = readDesiredCodexState(this.desiredStatePath);
    const targetReasoning = desiredState?.reasoningText || "";
    if (!targetReasoning || !observed?.reasoningText) return observed;
    if (sameUiText(targetReasoning, observed.reasoningText)) return observed;

    console.log(
      `${new Date().toISOString()} codex prompt ${requestId} observed reasoning ${
        observed.reasoningText
      }; setting desired reasoning ${targetReasoning} before prompt fill`,
    );
    const { readyState } = await this.setReasoningLevelOnPage(
      page,
      requestId,
      targetReasoning,
      {
        captureBefore: false,
        reconcileDesired: false,
      },
    );
    if (readyState?.reasoningText && sameUiText(targetReasoning, readyState.reasoningText)) {
      return readyState;
    }
    throw new Error(
      `Codex UI desired reasoning did not settle before prompt fill: expected ${targetReasoning}, observed ${
        readyState?.reasoningText || "unknown"
      }`,
    );
  }

  async allowComposerReadyFallback(page, requestId, reason, error) {
    const message = error instanceof Error ? error.message : String(error);
    const composerPresent = await page.evaluate(
      `Boolean(document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)}))`,
    );
    if (!composerPresent) throw error;
    console.warn(
      `${new Date().toISOString()} codex prompt ${requestId} proceeding after ${reason} UI ready timeout because composer is available: ${message}`,
    );
  }

  async waitForComposerSendReadyWithRecovery(
    page,
    { requestId, prompt, recoverPage, verifySelection = async () => null },
  ) {
    const deadline = this.now() + this.responseTimeoutMs;
    let activePage = page;
    let attempts = 0;
    let lastError = null;
    while (this.now() < deadline) {
      attempts += 1;
      const remainingMs = Math.max(250, deadline - this.now());
      try {
        await activePage.waitForExpression(
          composerSendReadyExpression(),
          Math.min(COMPOSER_SEND_READY_ATTEMPT_MS, remainingMs),
        );
        console.log(
          `${new Date().toISOString()} codex prompt ${requestId} send ready after ${attempts} check(s)`,
        );
        return activePage;
      } catch (error) {
        lastError = error;
        console.warn(
          `${new Date().toISOString()} codex prompt ${requestId} send ready check failed; recovering renderer: ${errorMessage(error)}`,
        );
        activePage = await recoverPage(
          `send-ready check failed after prompt fill: ${errorMessage(error)}`,
        );
        await verifySelection(activePage);
        const fillResult = await activePage.evaluate(fillPromptExpression(prompt));
        if (fillResult?.ok === false) {
          throw new Error(
            `Codex UI prompt refill failed after renderer recovery: ${JSON.stringify(fillResult)}`,
          );
        }
        await this.sleep(COMPOSER_RECOVERY_DELAY_MS);
      }
    }
    throw new Error(
      `Timed out waiting for Codex composer send readiness after prompt fill: ${errorMessage(lastError)}`,
    );
  }

  async submitComposerDraftWithRecovery(
    page,
    { requestId, prompt, recoverPage, verifySelection = async () => null },
  ) {
    try {
      return await this.submitComposerDraft(page, requestId, verifySelection);
    } catch (error) {
      if (!isCdpTimeoutError(error)) {
        const state = await this.readComposerSubmissionState(page);
        if (!state?.activeRun && state?.draftLength > 0) {
          console.warn(
            `${new Date().toISOString()} codex prompt ${requestId} did not submit and composer still has ${state.draftLength} chars; clearing and refilling before one retry`,
          );
          await this.clearAndRefillComposerDraft(page, {
            requestId,
            prompt,
            reason: "enter submit left draft unsent",
            verifySelection,
          });
          return this.submitComposerDraft(page, requestId, verifySelection);
        }
        throw error;
      }
      console.warn(
        `${new Date().toISOString()} codex prompt ${requestId} submit state check timed out; reconnecting before retry: ${errorMessage(error)}`,
      );
      const recovered = await recoverPage(
        `submit state check timed out: ${errorMessage(error)}`,
      );
      const recoveredState = await this.readComposerSubmissionState(recovered);
      if (recoveredState?.submitted) {
        console.log(
          `${new Date().toISOString()} codex prompt ${requestId} submitted before recovery check completed`,
        );
        return { ok: true, method: "recovered", state: recoveredState };
      }
      if (recoveredState?.draftLength > 0 && !recoveredState?.activeRun) {
        await this.clearAndRefillComposerDraft(recovered, {
          requestId,
          prompt,
          reason: "submit-state timeout recovery found unsent draft",
          verifySelection,
        });
        return this.submitComposerDraft(recovered, requestId, verifySelection);
      }
      if (!recoveredState || recoveredState.draftLength > 0) {
        return this.submitComposerDraft(recovered, requestId, verifySelection);
      }
      throw error;
    }
  }

  async clearAndRefillComposerDraft(
    page,
    { requestId, prompt, reason, verifySelection = async () => null },
  ) {
    console.warn(`${new Date().toISOString()} codex prompt ${requestId} refilling composer: ${reason}`);
    await verifySelection(page);
    const clearResult = await page.evaluate(clearComposerDraftExpression());
    if (clearResult?.ok === false) {
      throw new Error(
        `Codex UI prompt clear failed before retry: ${JSON.stringify(clearResult)}`,
      );
    }
    const fillResult = await page.evaluate(fillPromptExpression(prompt));
    if (fillResult?.ok === false) {
      throw new Error(
        `Codex UI prompt refill failed before retry: ${JSON.stringify(fillResult)}`,
      );
    }
    await page.waitForExpression(
      composerTextSubmitReadyExpression(),
      Math.min(this.responseTimeoutMs, 5_000),
    );
  }

  async readComposerSubmissionState(page) {
    try {
      return await page.evaluate(composerSubmissionStateExpression());
    } catch {
      return null;
    }
  }

  async submitComposerDraft(page, requestId, verifySelection = async () => null) {
    await verifySelection(page);
    console.log(`${new Date().toISOString()} codex prompt ${requestId} submitting with Enter`);
    await page.pressEnter();
    const enterState = await this.waitForComposerSubmitted(page, {
      requestId,
      method: "Enter",
      timeoutMs: 2_500,
    });
    if (enterState?.submitted) {
      return { ok: true, method: "enter", state: enterState };
    }

    throw new Error(
      `Codex UI normal prompt did not submit with Enter: ${JSON.stringify(enterState)}`,
    );
  }

  async waitForComposerSubmitted(page, { requestId, method, timeoutMs }) {
    const deadline = this.now() + timeoutMs;
    let lastState = null;
    let lastError = null;
    while (this.now() < deadline) {
      try {
        lastState = await page.evaluate(composerSubmissionStateExpression());
      } catch (error) {
        lastError = error;
        if (isCdpTimeoutError(error)) throw error;
        await this.sleep(250);
        continue;
      }
      if (lastState?.submitted) {
        console.log(
          `${new Date().toISOString()} codex prompt ${requestId} submitted via ${method}`,
        );
        return lastState;
      }
      await this.sleep(250);
    }
    if (lastError) {
      console.warn(
        `${new Date().toISOString()} codex prompt ${requestId} submit state polling ended after error: ${errorMessage(lastError)}`,
      );
    }
    return lastState;
  }

  async submitSteerToComposer(
    prompt,
    requestId,
    {
      preferredThreadId = "",
      preferredThreadTitle = "",
      taskScoped = false,
      ownerSessionId = "",
      expectedTurnId = "",
      acceptanceTimeoutMs = 0,
    } = {},
  ) {
    return this.withPage(async (page) => {
      if (taskScoped) {
        return this.submitTaskScopedSteerOnPage(page, prompt, requestId, {
          preferredThreadId,
          preferredThreadTitle,
          ownerSessionId,
          expectedTurnId,
          acceptanceTimeoutMs,
        });
      }
      console.log(`${new Date().toISOString()} codex steer ${requestId} checking active composer`);
      const currentResult = await this.submitSteerOnActivePage(page, prompt, requestId);
      if (currentResult.status === "steered") return currentResult;

      const threadId = preferredThreadId || this.preferredThreadId;
      const threadTitle = preferredThreadTitle || this.preferredThreadTitle;
      if (!threadId && !threadTitle) return currentResult;

      console.log(
        `${new Date().toISOString()} codex steer ${requestId} selecting preferred thread after ${currentResult.reason || "inactive_composer"}`,
      );
      await this.ensurePreferredThread(page, {
        preferredThreadId,
        preferredThreadTitle,
      });

      return this.submitSteerOnActivePage(page, prompt, requestId);
    }, { wakeBeforePrompt: false });
  }

  async submitTaskScopedSteerOnPage(
    page,
    prompt,
    requestId,
    {
      preferredThreadId,
      preferredThreadTitle,
      ownerSessionId,
      expectedTurnId,
      acceptanceTimeoutMs,
    },
  ) {
    const threadId = String(preferredThreadId || "").trim();
    if (!threadId) return taskScopedSteerFailure(requestId, "wrong_thread");
    const rootSessionId = normalizeSessionId(ownerSessionId);
    const turnId = normalizeSessionId(expectedTurnId);
    if (!rootSessionId || !turnId || !this.supportsTaskScopedFollowup) {
      return taskScopedSteerFailure(requestId, "missing_ack");
    }
    const requestedAcceptanceTimeoutMs = Number(acceptanceTimeoutMs);
    const composerTimeoutMs = Math.max(
      1,
      Math.min(
        COMPOSER_SEND_READY_ATTEMPT_MS,
        requestedAcceptanceTimeoutMs > 0
          ? requestedAcceptanceTimeoutMs
          : this.preferredThreadTimeoutMs,
      ),
    );
    const acceptanceWaitTimeoutMs = Math.max(
      1,
      Math.min(
        TASK_SCOPED_ACCEPTANCE_TIMEOUT_MS,
        requestedAcceptanceTimeoutMs > 0
          ? requestedAcceptanceTimeoutMs
          : TASK_SCOPED_ACCEPTANCE_TIMEOUT_MS,
      ),
    );
    const preEnterStartedAt = this.now();
    let previousPhaseAt = preEnterStartedAt;
    const phaseMs = {};
    const markPreEnterPhase = (phase, at = this.now()) => {
      phaseMs[phase] = Math.max(0, at - previousPhaseAt);
      previousPhaseAt = at;
      return at;
    };

    let selection;
    try {
      selection = await this.ensurePreferredThread(page, {
        preferredThreadId: threadId,
        preferredThreadTitle,
        timeoutMs: composerTimeoutMs,
        ownerSessionId: rootSessionId,
        expectedTurnId: turnId,
        allowRotation: false,
      });
    } catch (error) {
      warnTaskScopedError({
        requestId,
        phase: "select_thread",
        error,
        fallbackCode: "E_THREAD_SELECTION",
      });
      return taskScopedSteerFailure(requestId, "composer_unavailable");
    }
    if (selection?.ok === false) {
      return taskScopedSteerFailure(
        requestId,
        selection.error === "preferred_thread_row_missing"
          ? "preferred_thread_row_missing"
          : "wrong_thread",
      );
    }
    if (!sameCodexThreadId(selection?.threadId || threadId, threadId)) {
      return taskScopedSteerFailure(requestId, "wrong_thread");
    }
    markPreEnterPhase("selectThread");

    const activeRun = await this.readActiveComposerRun(page);
    if (!activeRun?.active) {
      return taskScopedSteerFailure(
        requestId,
        String(activeRun?.reason || "").includes("composer")
          ? "composer_unavailable"
          : "missing_ack",
      );
    }

    try {
      await this.verifyPreferredThreadSelection(page, {
        preferredThreadId: threadId,
        preferredThreadTitle,
      });
    } catch (error) {
      return taskScopedSteerFailure(requestId, preferredThreadSelectionReason(error));
    }
    markPreEnterPhase("verifyActiveTask");

    let capturedEvidence;
    try {
      capturedEvidence = await this.taskScopedFollowupEvidence.capture({
        rootSessionId,
        turnId,
        requestToken: requestId,
        threadId,
        timeoutMs: composerTimeoutMs,
      });
    } catch (error) {
      warnTaskScopedError({
        requestId,
        phase: "capture_owner",
        error,
        fallbackCode: "E_CAPTURE_PROBE",
      });
      return taskScopedSteerFailure(requestId, "missing_ack");
    }
    if (
      !validTaskScopedEvidenceCapture(capturedEvidence, {
        rootSessionId,
        turnId,
      })
    ) {
      return taskScopedSteerFailure(requestId, "missing_ack");
    }
    const initialCaptureTimingMs = capturedEvidence.captureTimingMs || null;
    markPreEnterPhase("captureOwner");

    try {
      await this.verifyPreferredThreadSelection(page, {
        preferredThreadId: threadId,
        preferredThreadTitle,
      });
    } catch (error) {
      return taskScopedSteerFailure(requestId, preferredThreadSelectionReason(error));
    }
    markPreEnterPhase("verifyBeforeFill");

    const composerPrompt = `[bridge_followup_request_id: ${requestId}]\n${prompt}`;

    let fillResult;
    try {
      fillResult = await page.evaluate(
        fillPromptExpression(composerPrompt, { expectedThreadId: threadId }),
      );
      if (fillResult?.ok === false) {
        return taskScopedSteerFailure(
          requestId,
          fillResult.error === "wrong_thread" ? "wrong_thread" : "composer_unavailable",
        );
      }
      if (!(Number(fillResult?.draftLength) > 0)) {
        await page.waitForExpression(composerDraftReadyExpression(), composerTimeoutMs);
      }
    } catch (error) {
      warnTaskScopedError({
        requestId,
        phase: "fill_composer",
        error,
        fallbackCode: "E_COMPOSER_FILL",
      });
      return taskScopedSteerFailure(requestId, "composer_unavailable");
    }
    markPreEnterPhase("fillComposer");

    try {
      await this.verifyPreferredThreadSelection(page, {
        preferredThreadId: threadId,
        preferredThreadTitle,
      });
    } catch (error) {
      const cleared = await clearTaskScopedComposerDraft(page, {
        requestId,
        phase: "cleanup_after_owner_mismatch",
      });
      if (!cleared) {
        return taskScopedSteerFailure(requestId, "submission_ambiguous");
      }
      return taskScopedSteerFailure(requestId, preferredThreadSelectionReason(error));
    }
    markPreEnterPhase("verifyAfterFill");

    let postFillEvidence;
    try {
      postFillEvidence = await this.taskScopedFollowupEvidence.capture({
        rootSessionId,
        turnId,
        requestToken: requestId,
        threadId,
        timeoutMs: composerTimeoutMs,
      });
    } catch (error) {
      warnTaskScopedError({
        requestId,
        phase: "revalidate_owner_after_fill",
        error,
        fallbackCode: "E_CAPTURE_PROBE",
      });
    }
    const postFillTurnOpen =
      validTaskScopedEvidenceCapture(postFillEvidence, {
        rootSessionId,
        turnId,
      }) &&
      postFillEvidence.turnOpen === true &&
      Number(postFillEvidence.offset) >= Number(capturedEvidence.offset);
    if (!postFillTurnOpen) {
      const cleared = await clearTaskScopedComposerDraft(page, {
        requestId,
        phase: "cleanup_after_bound_turn_closed",
      });
      if (!cleared) {
        return taskScopedSteerFailure(requestId, "submission_ambiguous");
      }
      return taskScopedSteerFailure(requestId, "missing_ack");
    }
    const postFillCaptureTimingMs = postFillEvidence.captureTimingMs || null;
    capturedEvidence = postFillEvidence;
    markPreEnterPhase("revalidateOwner");

    let composerSubmittedAt = "";
    let preEnterTimings = null;
    try {
      let composerDispatchedMs = null;
      await page.pressEnter({
        onDispatched: () => {
          composerDispatchedMs = this.now();
        },
      });
      const enterSettledMs = this.now();
      const composerSubmittedMs = markPreEnterPhase(
        "pressEnter",
        composerDispatchedMs ?? enterSettledMs,
      );
      composerSubmittedAt = new Date(composerSubmittedMs).toISOString();
      preEnterTimings = {
        totalMs: Math.max(0, composerSubmittedMs - preEnterStartedAt),
        enterSettlementMs: Math.max(0, enterSettledMs - composerSubmittedMs),
        phaseMs,
        ownerCaptureMs: {
          initial: initialCaptureTimingMs,
          postFill: postFillCaptureTimingMs,
        },
      };
      console.log(
        `${composerSubmittedAt} codex task-followup ${requestId} composer submitted ${JSON.stringify(preEnterTimings)}`,
      );
    } catch (error) {
      warnTaskScopedError({
        requestId,
        phase: "submit_composer",
        error,
        fallbackCode: "E_COMPOSER_SUBMIT",
      });
      return taskScopedSteerFailure(requestId, "submission_ambiguous");
    }

    let acceptanceEvidence;
    try {
      acceptanceEvidence = await this.taskScopedFollowupEvidence.waitForAcceptance({
        sessionFile: capturedEvidence.sessionFile || "",
        rootSessionId,
        turnId,
        afterOffset: capturedEvidence.offset,
        requestToken: requestId,
        timeoutMs: acceptanceWaitTimeoutMs,
      });
    } catch (error) {
      warnTaskScopedError({
        requestId,
        phase: "wait_for_acceptance",
        error,
        fallbackCode: "E_ACCEPTANCE_PROBE",
      });
      return taskScopedSteerFailure(requestId, "missing_ack");
    }
    const acceptedResult = taskScopedSteerAcceptedResult({
      acceptanceEvidence,
      capturedEvidence,
      rootSessionId,
      turnId,
      requestId,
      prompt,
      composerSubmittedAt,
      preEnterTimings,
    });
    if (acceptedResult) return acceptedResult;

    const pendingAcceptance = this.taskScopedFollowupEvidence
      .waitForAcceptance({
        sessionFile: capturedEvidence.sessionFile || "",
        rootSessionId,
        turnId,
        afterOffset: capturedEvidence.offset,
        requestToken: requestId,
        timeoutMs: TASK_SCOPED_ACCEPTANCE_SETTLEMENT_TIMEOUT_MS,
      })
      .then((lateAcceptanceEvidence) =>
        taskScopedSteerAcceptedResult({
          acceptanceEvidence: lateAcceptanceEvidence,
          capturedEvidence,
          rootSessionId,
          turnId,
          requestId,
          prompt,
          composerSubmittedAt,
          preEnterTimings,
        }),
      );
    return {
      status: "submitted_pending_ack",
      requestId,
      prompt,
      incorporated: false,
      composerSubmittedAt,
      preEnterTimings,
      pendingAcceptance,
    };
  }

  async submitSteerOnActivePage(page, prompt, requestId) {
    const activeRun = await this.readActiveComposerRun(page);
    if (!activeRun?.active) {
      console.log(`${new Date().toISOString()} codex steer ${requestId} ignored no active run`);
      return {
        status: "ignored",
        reason: activeRun?.reason || "no_active_codex_run",
        requestId,
        prompt,
      };
    }

    console.log(`${new Date().toISOString()} codex steer ${requestId} filling composer`);
    const fillResult = await page.evaluate(fillPromptExpression(prompt));
    if (fillResult?.ok === false) {
      throw new Error(`Codex UI steer fill failed: ${JSON.stringify(fillResult)}`);
    }
    console.log(`${new Date().toISOString()} codex steer ${requestId} waiting for steer send`);
    await page.waitForExpression(
      composerDraftReadyExpression(),
      Math.min(this.responseTimeoutMs, 30_000),
    );
    console.log(`${new Date().toISOString()} codex steer ${requestId} submitting with Command+Enter`);
    await page.pressCommandEnter();
    return { status: "steered", requestId, prompt };
  }

  async listTargets() {
    const response = await fetch(`${this.remoteDebugUrl}/json/list`);
    if (!response.ok) {
      throw new Error(
        `Failed to list Codex CDP targets (${response.status}). Is Codex running with --remote-debugging-port?`,
      );
    }
    return response.json();
  }

  pickPageTarget(targets) {
    return this.codexPageTargets(targets).at(0) || null;
  }

  codexPageTargets(targets) {
    const pageTargets = targets.filter(
      (target) => target.type === "page" && target.webSocketDebuggerUrl,
    );
    const appTargets = pageTargets.filter((target) =>
      String(target.url || "").startsWith("app://-/index.html"),
    );
    if (appTargets.length === 0) return pageTargets;

    const primaryAppTargets = appTargets.filter(
      (target) => !isCodexQuickChatPrewarmTarget(target),
    );
    return primaryAppTargets.length > 0 ? primaryAppTargets : appTargets;
  }

  async withPage(fn, { wakeBeforePrompt = this.wakeBeforePrompt } = {}) {
    let targets = await this.listTargetsForPrompt();
    let target = this.pickPageTarget(targets);
    if (!target) {
      throw new Error("No Codex page target found in remote debugging targets");
    }
    const previousTargetId = this.lastPromptTargetId;
    let targetChanged = Boolean(
      previousTargetId && previousTargetId !== target.id,
    );
    let postRestartDelayNeeded = !previousTargetId || targetChanged;
    let page;
    try {
      page = await this.connectPage(
        target.webSocketDebuggerUrl,
        this.cdpRequestTimeoutMs,
      );
    } catch (error) {
      if (!this.wakeAppBeforePrompt || !isCdpTimeoutError(error)) {
        throw error;
      }
      console.warn(
        `${new Date().toISOString()} codex page connect timed out before prompt; waking app and retrying: ${errorMessage(error)}`,
      );
      targets = await this.listTargetsAfterAppWake();
      const retryTarget = this.pickPageTarget(targets);
      if (!retryTarget) {
        throw new Error("No Codex page target found after CDP connect timeout recovery");
      }
      target = retryTarget;
      targetChanged = Boolean(previousTargetId && previousTargetId !== target.id);
      postRestartDelayNeeded = !previousTargetId || targetChanged;
      page = await this.connectPage(
        target.webSocketDebuggerUrl,
        this.cdpRequestTimeoutMs,
      );
    }
    this.lastPromptTargetId = target.id || null;
    try {
      if (wakeBeforePrompt) {
        if (this.wakeAllTargetsBeforePrompt) {
          await this.wakeCodexTargets(targets);
        } else {
          await this.wakeCodex(page);
        }
      }
      return await fn(page, {
        postRestartDelayNeeded,
        targetChanged,
        targetId: target.id || null,
      });
    } finally {
      page.close();
    }
  }

  async listTargetsForPrompt() {
    let targets;
    try {
      targets = await this.listTargets();
    } catch (error) {
      if (!this.wakeAppBeforePrompt) throw error;
      console.warn(
        `${new Date().toISOString()} codex target list failed before prompt; waking app and retrying: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return this.listTargetsAfterAppWake();
    }

    if (this.pickPageTarget(targets)) {
      await this.maybeReniceCodexProcesses("before-prompt");
    }

    if (!this.pickPageTarget(targets) && this.wakeAppBeforePrompt) {
      console.warn(
        `${new Date().toISOString()} codex page target missing before prompt; waking app and retrying`,
      );
      return this.listTargetsAfterAppWake();
    }
    return targets;
  }

  async listTargetsAfterAppWake() {
    await this.wakeApp(this.appPath, this.remoteDebugUrl, {
      disableGpu: this.disableGpu,
    });
    await this.sleep(APP_WAKE_RETRY_DELAY_MS);
    await this.maybeReniceCodexProcesses("after-app-wake");
    return this.listTargets();
  }

  async maybeReniceCodexProcesses(reason) {
    if (!this.reniceOnDebug || process.platform !== "darwin") {
      return { ok: false, skipped: true, reason: "disabled" };
    }
    if (this.reniceValue >= 0) {
      return { ok: false, skipped: true, reason: "non_negative_nice_value" };
    }
    const now = this.now();
    if (this.lastReniceAt > 0 && now - this.lastReniceAt < this.reniceCooldownMs) {
      return { ok: true, skipped: true, reason: "cooldown" };
    }
    this.lastReniceAt = now;
    try {
      const result = await this.reniceProcesses({
        niceValue: this.reniceValue,
        appPath: this.appPath,
      });
      if (result?.ok) {
        console.log(
          `${new Date().toISOString()} codex renice ${reason} applied nice ${
            this.reniceValue
          } to ${result.pidCount || 0} process(es)`,
        );
      } else if (!result?.skipped) {
        console.warn(
          `${new Date().toISOString()} codex renice ${reason} skipped/failed: ${
            result?.error || result?.reason || "unknown"
          }`,
        );
      }
      return result;
    } catch (error) {
      console.warn(
        `${new Date().toISOString()} codex renice ${reason} skipped/failed: ${errorMessage(error)}`,
      );
      return { ok: false, error: errorMessage(error) };
    }
  }

  async reconnectPromptPage(requestId, reason) {
    console.warn(
      `${new Date().toISOString()} codex prompt ${requestId} reconnecting Codex page: ${reason}`,
    );
    const targets = await this.listTargetsForPrompt();
    const target = this.pickPageTarget(targets);
    if (!target) {
      throw new Error("No Codex page target found while recovering prompt submit");
    }
    const page = await this.connectPage(
      target.webSocketDebuggerUrl,
      this.cdpRequestTimeoutMs,
    );
    try {
      await this.wakeCodex(page);
      await this.ensurePreferredThread(page);
      await page.waitForExpression(
        mainComposerPresentExpression(),
        Math.max(15000, this.preferredThreadTimeoutMs),
      );
      return page;
    } catch (error) {
      page.close();
      throw error;
    }
  }

  async wakeCodex(page) {
    await page.nudgeRenderer();
    if (this.bringToFrontBeforePrompt) await page.bringToFront();
    await this.sleep(250);
  }

  async keepAliveRenderer() {
    const targets = await this.listTargets();
    const pages = this.codexPageTargets(targets);
    if (pages.length === 0) {
      return { ok: false, reason: "no_codex_page_target" };
    }

    const results = await Promise.allSettled(
      pages.map(async (target) => {
        const page = await this.connectPage(
          target.webSocketDebuggerUrl,
          this.cdpRequestTimeoutMs,
          { enableRuntimeTimeoutMs: this.rendererKeepAliveTimeoutMs },
        );
        try {
          await page.nudgeRenderer({ timeoutMs: this.rendererKeepAliveTimeoutMs });
          return { id: target.id || null, url: target.url || "" };
        } finally {
          page.close();
        }
      }),
    );
    const nudged = [];
    const failures = [];
    results.forEach((result, index) => {
      const target = pages[index];
      if (result.status === "fulfilled") {
        nudged.push(result.value);
      } else {
        failures.push({
          id: target?.id || null,
          error: errorMessage(result.reason),
        });
      }
    });
    return {
      ok: nudged.length > 0,
      targetCount: pages.length,
      nudgedCount: nudged.length,
      failedCount: failures.length,
      targetIds: nudged.map((target) => target.id).filter(Boolean),
      failures,
    };
  }

  async wakeCodexTargets(targets) {
    const pages = this.codexPageTargets(targets);
    const results = await Promise.allSettled(
      pages.map(async (target) => {
        const page = await this.connectPage(
          target.webSocketDebuggerUrl,
          this.cdpRequestTimeoutMs,
        );
        try {
          await page.nudgeRenderer();
          if (this.bringToFrontBeforePrompt) await page.bringToFront();
        } finally {
          page.close();
        }
      }),
    );
    for (const result of results) {
      if (result.status !== "rejected") continue;
      console.warn(
        `${new Date().toISOString()} codex target wake skipped/failed: ${
          result.reason instanceof Error
            ? result.reason.message
            : String(result.reason)
        }`,
      );
    }
    await this.sleep(250);
  }

  async setReasoningLevelOnPage(
    page,
    requestId,
    targetReasoning,
    { reconcileDesired = true, captureBefore = true } = {},
  ) {
    if (captureBefore) {
      await this.captureReadyState(page, requestId, { reconcileDesired });
    }

    const control = await page.evaluate(modelReasoningControlCenterExpression());
    if (control?.ok === false) {
      throw new Error(`Codex UI reasoning control missing: ${JSON.stringify(control)}`);
    }

    await page.request("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x: control.x,
      y: control.y,
      button: "left",
      clickCount: 1,
    });
    await page.request("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x: control.x,
      y: control.y,
      button: "left",
      clickCount: 1,
    });
    await this.sleep(500);

    let result = await page.evaluate(
      selectReasoningMenuItemExpression(targetReasoning, { allowSubmenuTrigger: true }),
    );
    if (result?.needsSubmenu === true) {
      try {
        await page.waitForExpression(
          reasoningMenuItemPresentExpression(targetReasoning),
          Math.max(500, Math.min(3_000, this.responseTimeoutMs)),
        );
      } catch {}
      result = await page.evaluate(
        selectReasoningMenuItemExpression(targetReasoning, { allowSubmenuTrigger: false }),
      );
    }
    if (result?.ok === false) {
      throw new Error(`Codex UI reasoning selection failed: ${JSON.stringify(result)}`);
    }
    await this.dismissModelReasoningMenu(page);
    await this.sleep(800);
    const readyState = await this.captureReadyState(page, requestId, {
      reconcileDesired,
    });
    return { result, readyState };
  }

  async setModelOnPage(
    page,
    requestId,
    targetModel,
    { reconcileDesired = true, captureBefore = true } = {},
  ) {
    if (captureBefore) {
      await this.captureReadyState(page, requestId, { reconcileDesired });
    }

    const control = await page.evaluate(modelReasoningControlCenterExpression());
    if (control?.ok === false) {
      throw new Error(`Codex UI model control missing: ${JSON.stringify(control)}`);
    }

    await page.request("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x: control.x,
      y: control.y,
      button: "left",
      clickCount: 1,
    });
    await page.request("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x: control.x,
      y: control.y,
      button: "left",
      clickCount: 1,
    });
    await this.sleep(500);

    const result = await page.evaluate(selectModelMenuItemExpression(targetModel));
    if (result?.ok === false) {
      throw new Error(`Codex UI model selection failed: ${JSON.stringify(result)}`);
    }
    await this.dismissModelReasoningMenu(page);
    await this.sleep(800);
    const readyState = await this.captureReadyState(page, requestId, {
      reconcileDesired,
    });
    return { result, readyState };
  }

  async dismissModelReasoningMenu(page) {
    await page.pressEscape();
    await page.waitForExpression(
      modelReasoningMenuClosedExpression(),
      Math.max(500, Math.min(3_000, this.responseTimeoutMs)),
    );
  }

  async waitForPostRestartReady(
    page,
    requestId,
    {
      reason = "post-restart",
      correctReasoning = false,
      reconcileDesired = true,
    } = {},
  ) {
    const expected = this.expectedReadyTexts({
      includeReadyState: false,
      reconcileDesired,
    });
    const expression = codexReadyExpression({
      modelTexts: expected.modelTexts,
      reasoningTexts: expected.reasoningTexts,
    });
    const deadline = this.now() + this.postRestartReadyTimeoutMs;
    const fallbackDeadline =
      this.now() +
      Math.min(
        POST_RESTART_OBSERVED_READY_FALLBACK_MS,
        this.postRestartReadyTimeoutMs,
      );
    const composerFallbackDeadline =
      this.now() +
      Math.min(
        POST_RESTART_COMPOSER_READY_FALLBACK_MS,
        this.postRestartReadyTimeoutMs,
      );
    let attempts = 0;
    let lastError = null;
    let lastFallbackCheckMs = 0;
    while (this.now() < deadline) {
      attempts += 1;
      const remainingMs = Math.max(250, deadline - this.now());
      const attemptTimeoutMs = Math.min(5_000, remainingMs);
      try {
        const observed = await this.captureReadyState(page, requestId, {
          reconcileDesired: false,
        });
        if (readyStateMatchesExpected(observed, expected)) {
          if (
            await this.confirmPostRestartReadyState(
              page,
              requestId,
              reason,
              expression,
              observed,
              attempts,
            )
          ) {
            return;
          }
        }

        const reasoningTarget = reasoningCorrectionTarget(observed, expected);
        if (correctReasoning && reasoningTarget) {
          console.log(
            `${new Date().toISOString()} codex prompt ${requestId} observed UI state ${
              observed.modelText
            }/${observed.reasoningText}; setting reasoning ${reasoningTarget} before prompt fill`,
          );
          await this.setReasoningLevelOnPage(page, requestId, reasoningTarget, {
            captureBefore: false,
            reconcileDesired: false,
          });
          if (
            await this.confirmPostRestartReadyState(
              page,
              requestId,
              reason,
              expression,
              null,
              attempts,
            )
          ) {
            return;
          }
        }
      } catch (error) {
        lastError = error;
      }
      try {
        await page.waitForExpression(expression, attemptTimeoutMs);
        if (
          await this.confirmPostRestartReadyState(
            page,
            requestId,
            reason,
            expression,
            null,
            attempts,
            { initialStrictReady: true },
          )
        ) {
          return;
        }
      } catch (error) {
        lastError = error;
        if (
          this.now() >= fallbackDeadline &&
          this.now() - lastFallbackCheckMs >= 5_000
        ) {
          lastFallbackCheckMs = this.now();
          if (await this.resolvePostRestartReadyFallback(page, requestId, expected)) {
            return;
          }
        }
        if (
          this.now() >= composerFallbackDeadline &&
          (await this.resolvePostRestartComposerFallback(page, requestId, reason))
        ) {
          return;
        }
        if (this.now() >= deadline) break;
        if (attempts % 3 === 0) {
          console.log(
            `${new Date().toISOString()} codex prompt ${requestId} still waiting for ${reason} UI ready`,
          );
        }
        await this.sleep(1_000);
      }
    }
    if (await this.resolvePostRestartReadyFallback(page, requestId, expected)) {
      return;
    }
    throw new Error(
      `Timed out waiting for ${reason} Codex model/reasoning UI before prompt fill: ${
        lastError instanceof Error ? lastError.message : String(lastError)
      }`,
    );
  }

  async confirmPostRestartReadyState(
    page,
    requestId,
    reason,
    expression,
    observedState,
    attempts,
    { initialStrictReady = false } = {},
  ) {
    try {
      if (!observedState && !initialStrictReady) {
        await page.waitForExpression(expression, 5_000);
      }
      await this.sleep(1_000);
      await page.waitForExpression(expression, 5_000);
      console.log(
        `${new Date().toISOString()} codex prompt ${requestId} ${reason} UI ready after ${attempts} check(s)`,
      );
      return true;
    } catch (error) {
      const expected = this.expectedReadyTexts({
        includeReadyState: false,
        reconcileDesired: false,
      });
      const firstState =
        observedState ||
        (await this.captureReadyState(page, requestId, {
          reconcileDesired: false,
        }));
      if (!readyStateMatchesExpected(firstState, expected)) return false;
      await this.sleep(1_000);
      const secondState =
        (await this.captureReadyState(page, requestId, {
          reconcileDesired: false,
        })) || firstState;
      if (!readyStateMatchesExpected(secondState, expected)) return false;
      console.warn(
        `${new Date().toISOString()} codex prompt ${requestId} proceeding with observed ${reason} UI state ${secondState.modelText}/${secondState.reasoningText}`,
      );
      return true;
    }
  }

  async resolvePostRestartReadyFallback(page, requestId, expected) {
    const firstState = await this.captureReadyState(page, requestId, {
      reconcileDesired: false,
    });
    if (!readyStateMatchesExpected(firstState, expected)) return false;
    await this.sleep(1_000);
    const secondState =
      (await this.captureReadyState(page, requestId, {
        reconcileDesired: false,
      })) || firstState;
    if (!readyStateMatchesExpected(secondState, expected)) return false;
    console.warn(
      `${new Date().toISOString()} codex prompt ${requestId} proceeding with observed post-restart UI state ${secondState.modelText}/${secondState.reasoningText}`,
    );
    return true;
  }

  async resolvePostRestartComposerFallback(page, requestId, reason) {
    const state = await page.evaluate(postRestartComposerReadyExpression());
    if (
      state?.marker !== "voice-relay-post-restart-composer-ready" ||
      !state.ready
    ) {
      return false;
    }
    console.warn(
      `${new Date().toISOString()} codex prompt ${requestId} proceeding after ${reason} composer-ready fallback: ${state.reason}`,
    );
    return true;
  }

  async captureReadyState(page, requestId, { reconcileDesired = true } = {}) {
    if (!this.readyStatePath) return null;
    const result = await page.evaluate(extractReadyStateExpression());
    if (!result?.ok || !result.modelText || !result.reasoningText) return null;

    const nextState = {
      modelText: result.modelText,
      reasoningText: result.reasoningText,
      controlText: result.controlText || "",
      observedAt: new Date().toISOString(),
    };
    const previousKey = `${this.readyState?.modelText || ""}\n${this.readyState?.reasoningText || ""}`;
    const nextKey = `${nextState.modelText}\n${nextState.reasoningText}`;
    this.readyState = nextState;
    this.writeReadyState(nextState);
    if (reconcileDesired) {
      this.desiredState = this.reconcileDesiredStateWithReady(
        readDesiredCodexState(this.desiredStatePath),
        nextState,
        requestId,
      );
    }
    if (previousKey !== nextKey) {
      console.log(
        `${new Date().toISOString()} codex prompt ${requestId} captured UI ready state ${nextState.modelText}/${nextState.reasoningText}`,
      );
    }
    return nextState;
  }

  expectedReadyTexts({ includeReadyState = true, reconcileDesired = true } = {}) {
    const desiredState = reconcileDesired
      ? this.loadDesiredState()
      : readDesiredCodexState(this.desiredStatePath);
    const targetModelTexts = desiredState?.modelText
      ? [desiredState.modelText]
      : [...this.readyModelTexts];
    const targetReasoningTexts = desiredState?.reasoningText
      ? [desiredState.reasoningText]
      : [...this.readyReasoningTexts];
    const includeObservedState = includeReadyState && !desiredState;
    return {
      modelTexts: [
        includeObservedState ? this.readyState?.modelText || "" : "",
        ...targetModelTexts,
      ],
      reasoningTexts: [
        includeObservedState ? this.readyState?.reasoningText || "" : "",
        ...targetReasoningTexts,
      ],
    };
  }

  setDesiredReadyState(update) {
    const state = writeDesiredCodexState(this.desiredStatePath, update);
    this.desiredState = state;
    return state;
  }

  clearDesiredReadyState() {
    const result = clearDesiredCodexState(this.desiredStatePath);
    this.desiredState = null;
    return result;
  }

  loadDesiredState() {
    const state = readDesiredCodexState(this.desiredStatePath);
    this.desiredState = this.reconcileDesiredStateWithReady(
      state,
      this.readyState,
      "loadDesiredState",
    );
    return this.desiredState;
  }

  reconcileDesiredStateWithReady(desiredState, readyState, requestId) {
    if (!desiredState || !readyState || !this.desiredStatePath) return desiredState;
    if (!desiredReadyMismatch(desiredState, readyState)) return desiredState;
    if (
      !readyStateIsNewerThanDesired(
        desiredState,
        readyState,
        DESIRED_READY_STALE_GRACE_MS,
      )
    ) {
      return desiredState;
    }

    const update = {};
    if (desiredState.modelText && readyState.modelText) update.modelText = readyState.modelText;
    if (desiredState.reasoningText && readyState.reasoningText) {
      update.reasoningText = readyState.reasoningText;
    }
    if (!Object.keys(update).length) return desiredState;

    const refreshedState = writeDesiredCodexState(this.desiredStatePath, update);
    console.log(
      `${new Date().toISOString()} codex prompt ${requestId} refreshed stale desired UI state from ready state`,
    );
    return refreshedState;
  }

  loadReadyState() {
    if (!this.readyStatePath || !fs.existsSync(this.readyStatePath)) return null;
    try {
      const data = JSON.parse(fs.readFileSync(this.readyStatePath, "utf8"));
      if (!data?.modelText || !data?.reasoningText) return null;
      return {
        modelText: String(data.modelText),
        reasoningText: String(data.reasoningText),
        controlText: String(data.controlText || ""),
        observedAt: String(data.observedAt || ""),
      };
    } catch {
      return null;
    }
  }

  writeReadyState(state) {
    if (!this.readyStatePath) return;
    try {
      fs.mkdirSync(path.dirname(this.readyStatePath), { recursive: true });
      const tmpPath = `${this.readyStatePath}.tmp`;
      fs.writeFileSync(tmpPath, `${JSON.stringify(state, null, 2)}\n`);
      fs.renameSync(tmpPath, this.readyStatePath);
    } catch (error) {
      console.warn(
        `${new Date().toISOString()} codex ready state write failed: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  async ensurePreferredThread(
    page,
    {
      preferredThreadId = "",
      preferredThreadTitle = "",
      timeoutMs = this.preferredThreadTimeoutMs,
      ownerSessionId = "",
      expectedTurnId = "",
      allowRotation = true,
    } = {},
  ) {
    const rotationThreadId = allowRotation
      ? await this.resolveRotationThreadId({
          preferredThreadId,
          preferredThreadTitle,
        })
      : "";
    const threadId = preferredThreadId || rotationThreadId || this.preferredThreadId;
    const threadTitle =
      preferredThreadTitle || (rotationThreadId ? "" : this.preferredThreadTitle);
    if (!threadId && !threadTitle) return null;

    let result = await page.evaluate(
      ensurePreferredThreadExpression({
        threadId,
        threadTitle,
      }),
    );
    for (let attempt = 0; result?.ok === false && rotationThreadId && attempt < 20; attempt += 1) {
      await this.sleep(500);
      result = await page.evaluate(
        ensurePreferredThreadExpression({
          threadId,
          threadTitle,
        }),
      );
    }
    if (result?.ok === false) {
      console.warn(
        `${new Date().toISOString()} preferred Codex thread not selected: ${JSON.stringify(
          result,
        )}`,
      );
      return result;
    }
    await page.waitForExpression(
      preferredThreadActiveExpression({
        threadId: result?.threadId || threadId,
        threadTitle,
      }),
      timeoutMs,
    );
    await page.waitForExpression(
      mainComposerPresentExpression(),
      timeoutMs,
    );
    return {
      ...result,
      ok: true,
      threadId: result?.threadId || threadId,
      threadTitle: result?.threadTitle || threadTitle,
      requestedThreadId: threadId,
      requestedThreadTitle: threadTitle,
      ownerSessionId: normalizeSessionId(ownerSessionId),
      expectedTurnId: normalizeSessionId(expectedTurnId),
    };
  }

  threadRotationEnabled() {
    return Boolean(this.threadStatePath && this.threadRotateAfterMs > 0);
  }

  async resolveRotationThreadId({ preferredThreadId = "", preferredThreadTitle = "" } = {}) {
    if (preferredThreadId || preferredThreadTitle || !this.threadRotationEnabled()) return "";
    const state = this.readThreadRotationState();
    const currentThreadId = state.threadId || this.preferredThreadId;
    if (!currentThreadId) return "";

    const startedAtMs = parseTimestampMs(state.startedAt || state.rotatedAt);
    if (!state.threadId || startedAtMs === null) {
      this.writeThreadRotationState({
        ...state,
        threadId: currentThreadId,
        startedAt: new Date(this.now()).toISOString(),
        updatedAt: new Date(this.now()).toISOString(),
        rotateAfterMs: this.threadRotateAfterMs,
      });
      return currentThreadId;
    }
    const ageMs = this.now() - startedAtMs;
    if (ageMs < this.threadRotateAfterMs) return currentThreadId;

    console.log(
      `${new Date(this.now()).toISOString()} codex desktop thread rotation due for ${currentThreadId}`,
    );
    let nextThreadId = "";
    try {
      this.lastRotationHandoffSeeded = false;
      nextThreadId = await this.startRotationThread(currentThreadId);
    } catch (error) {
      console.warn(
        `${new Date(this.now()).toISOString()} codex desktop thread rotation failed: ${errorMessage(
          error,
        )}`,
      );
      return currentThreadId;
    }
    if (!nextThreadId) return currentThreadId;

    const nowIso = new Date(this.now()).toISOString();
    this.writeThreadRotationState({
      threadId: nextThreadId,
      previousThreadId: currentThreadId,
      startedAt: nowIso,
      rotatedAt: nowIso,
      updatedAt: nowIso,
      rotateAfterMs: this.threadRotateAfterMs,
      handoffSeeded: Boolean(this.lastRotationHandoffSeeded),
    });
    return nextThreadId;
  }

  async startRotationThread(previousThreadId) {
    if (this.threadStarter) {
      return this.threadStarter({ previousThreadId });
    }
    const backend = new CodexAppServerBackend({
      cliPath: this.threadStartCliPath,
      startNewThread: true,
      cwd: this.threadStartCwd,
      requestTimeoutMs: this.threadStartRequestTimeoutMs,
      model: this.threadStartModel,
      reasoningEffort: this.threadStartReasoningEffort,
      approvalPolicy: this.threadStartApprovalPolicy,
      sandbox: this.threadStartSandbox,
      threadHandoffStatePath: this.threadHandoffStatePath,
      threadHandoffMaxBytes: this.threadHandoffMaxBytes,
      threadHandoffMaxEntries: this.threadHandoffMaxEntries,
      threadHandoffMaxChars: this.threadHandoffMaxChars,
      now: this.now,
    });
    try {
      await backend.ensureInitialized();
      await backend.ensureThreadStarted();
      this.lastRotationHandoffSeeded = await backend.seedThreadRotationHandoff(
        previousThreadId,
      );
      return backend.threadId;
    } finally {
      backend.client?.close?.();
    }
  }

  readThreadRotationState() {
    try {
      if (!this.threadStatePath || !fs.existsSync(this.threadStatePath)) return {};
      const parsed = JSON.parse(fs.readFileSync(this.threadStatePath, "utf8"));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (error) {
      console.warn(
        `${new Date(this.now()).toISOString()} codex desktop thread rotation state read failed: ${errorMessage(
          error,
        )}`,
      );
      return {};
    }
  }

  writeThreadRotationState(state) {
    try {
      fs.mkdirSync(path.dirname(this.threadStatePath), { recursive: true });
      fs.writeFileSync(this.threadStatePath, `${JSON.stringify(state, null, 2)}\n`);
    } catch (error) {
      console.warn(
        `${new Date(this.now()).toISOString()} codex desktop thread rotation state write failed: ${errorMessage(
          error,
        )}`,
      );
    }
  }
}

export class CdpPage {
  constructor(socket, requestTimeoutMs) {
    this.socket = socket;
    this.requestTimeoutMs = requestTimeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        pending.resolve(message);
      }
    });
  }

  static async connect(url, requestTimeoutMs, { enableRuntimeTimeoutMs = requestTimeoutMs } = {}) {
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", reject, { once: true });
    });
    const page = new CdpPage(socket, requestTimeoutMs);
    await page.request("Runtime.enable", {}, { timeoutMs: enableRuntimeTimeoutMs });
    return page;
  }

  async evaluate(expression, { timeoutMs } = {}) {
    const response = await this.request("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    }, {
      timeoutMs,
    });
    if (response.result?.exceptionDetails) {
      throw new Error(JSON.stringify(response.result.exceptionDetails));
    }
    return response.result?.result?.value ?? response.result?.result ?? null;
  }

  async bringToFront() {
    await this.request("Page.bringToFront");
  }

  async pressCommandEnter() {
    const params = {
      key: "Enter",
      code: "Enter",
      windowsVirtualKeyCode: 13,
      nativeVirtualKeyCode: 36,
      modifiers: 4,
    };
    await this.request("Input.dispatchKeyEvent", {
      ...params,
      type: "rawKeyDown",
    });
    await this.request("Input.dispatchKeyEvent", {
      ...params,
      type: "keyUp",
    });
  }

  async pressEnter({ onDispatched = null } = {}) {
    const params = {
      key: "Enter",
      code: "Enter",
      windowsVirtualKeyCode: 13,
      nativeVirtualKeyCode: 36,
      modifiers: 0,
    };
    const keyEvents = [
      this.request("Input.dispatchKeyEvent", {
        ...params,
        type: "rawKeyDown",
      }),
      this.request("Input.dispatchKeyEvent", {
        ...params,
        type: "keyUp",
      }),
    ];
    if (typeof onDispatched === "function") onDispatched();
    await Promise.all(keyEvents);
  }

  async pressEscape() {
    const params = {
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27,
      nativeVirtualKeyCode: 53,
      modifiers: 0,
    };
    await this.request("Input.dispatchKeyEvent", {
      ...params,
      type: "rawKeyDown",
    });
    await this.request("Input.dispatchKeyEvent", {
      ...params,
      type: "keyUp",
    });
  }

  async nudgeRenderer({ timeoutMs } = {}) {
    await this.request("Runtime.evaluate", {
      expression: "void 0",
      returnByValue: true,
    }, timeoutMs ? { timeoutMs } : {});
  }

  async waitForExpression(expression, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    let lastError = null;
    while (Date.now() < deadline) {
      const remainingMs = Math.max(250, deadline - Date.now());
      try {
        const value = await this.evaluate(`Boolean(${expression})`, {
          timeoutMs: Math.min(
            CDP_EVALUATE_ATTEMPT_TIMEOUT_MS,
            this.requestTimeoutMs,
            remainingMs,
          ),
        });
        if (value === true) return;
      } catch (error) {
        lastError = error;
      }
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    const suffix = lastError ? `: ${errorMessage(lastError)}` : "";
    throw new Error(`Timed out waiting for renderer condition: ${expression}${suffix}`);
  }

  request(method, params = {}, { timeoutMs = this.requestTimeoutMs } = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.has(id)) return;
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for CDP method ${method}`));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.socket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  close() {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("CDP page closed"));
    }
    this.pending.clear();
    this.socket.close();
  }
}

function isCodexQuickChatPrewarmTarget(target) {
  const rawUrl = String(target?.url || "");
  try {
    return new URL(rawUrl).searchParams.get("initialRoute") === "/chatgpt/quick-chat-prewarm";
  } catch {
    return rawUrl.includes("quick-chat-prewarm");
  }
}

async function bestEffortWakeApp(appPath, remoteDebugUrl = "", { disableGpu = false } = {}) {
  if (process.platform !== "darwin" || !appPath) return;
  try {
    await execFileAsync(
      "/usr/bin/open",
      codexAppOpenArgs(appPath, remoteDebugUrl, { disableGpu }),
      {
        timeout: 5_000,
      },
    );
  } catch (error) {
    console.warn(
      `${new Date().toISOString()} codex app wake skipped/failed: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
}

export async function bestEffortReniceCodexProcesses({
  niceValue = -5,
  appPath = resolveCodexAppPath(),
} = {}) {
  if (process.platform !== "darwin") {
    return { ok: false, skipped: true, reason: "unsupported_platform" };
  }
  const normalizedNice = normalizeReniceValue(niceValue);
  if (normalizedNice >= 0) {
    return { ok: false, skipped: true, reason: "non_negative_nice_value" };
  }

  let processList;
  try {
    processList = await execFileAsync("/bin/ps", ["-axo", "pid=,command="], {
      timeout: 3_000,
      maxBuffer: 2 * 1024 * 1024,
    });
  } catch (error) {
    return { ok: false, error: `ps failed: ${errorMessage(error)}` };
  }

  const pids = codexAppProcessPids(processList.stdout || "", appPath);
  if (pids.length === 0) {
    return { ok: false, skipped: true, reason: "no_codex_processes" };
  }

  try {
    await execFileAsync(
      "/usr/bin/sudo",
      [
        "-n",
        "/usr/bin/renice",
        String(normalizedNice),
        "-p",
        ...pids.map((pid) => String(pid)),
      ],
      { timeout: 3_000 },
    );
  } catch (error) {
    return {
      ok: false,
      error: `renice failed: ${errorMessage(error)}`,
      pidCount: pids.length,
      pids,
    };
  }

  return { ok: true, niceValue: normalizedNice, pidCount: pids.length, pids };
}

function codexAppProcessPids(processList, appPath) {
  const prefix = `${String(appPath || resolveCodexAppPath()).replace(/\/+$/, "")}/Contents/`;
  const pids = [];
  for (const rawLine of String(processList || "").split(/\r?\n/)) {
    const match = rawLine.trim().match(/^(\d+)\s+(.+)$/);
    if (!match) continue;
    const [, pidText, command] = match;
    if (!command.includes(prefix)) continue;
    if (command.includes("crashpad")) continue;
    pids.push(Number(pidText));
  }
  return [...new Set(pids)].filter((pid) => Number.isInteger(pid) && pid > 0);
}

const CODEX_DISABLE_GPU_ARGS = ["--disable-gpu"];
const CODEX_BACKGROUND_THROTTLE_ARGS = [
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--disable-backgrounding-occluded-windows",
  "--disable-features=IntensiveWakeUpThrottling,CalculateNativeWinOcclusion",
];

export function codexAppOpenArgs(appPath, remoteDebugUrl = "", { disableGpu = false } = {}) {
  const args = ["-g", "-n", "-a", appPath];
  const appArgs = [];
  const remoteDebug = parseRemoteDebugUrl(remoteDebugUrl);
  if (remoteDebug) {
    appArgs.push(
      `--remote-debugging-port=${remoteDebug.port}`,
      `--remote-allow-origins=${remoteDebug.origin}`,
    );
  }
  appArgs.push(...CODEX_BACKGROUND_THROTTLE_ARGS);
  if (isTruthy(disableGpu)) {
    appArgs.push(...CODEX_DISABLE_GPU_ARGS);
  }
  if (appArgs.length > 0) {
    args.push("--args", ...appArgs);
  }
  return args;
}

function isTruthy(value) {
  if (typeof value === "boolean") return value;
  return ["1", "true", "yes", "on"].includes(String(value || "").toLowerCase());
}

function parseRemoteDebugUrl(remoteDebugUrl) {
  if (!remoteDebugUrl) return null;
  try {
    const url = new URL(remoteDebugUrl);
    const port = url.port || (url.protocol === "https:" ? "443" : "80");
    return { port, origin: `${url.protocol}//${url.hostname}:${port}` };
  } catch {
    return null;
  }
}

function normalizeReniceValue(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return -5;
  return Math.max(-20, Math.min(20, Math.trunc(number)));
}

function isCdpTimeoutError(error) {
  return errorMessage(error).includes("Timed out waiting for CDP method");
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function mainComposerPresentExpression() {
  return `document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)}) != null`;
}

export function fillPromptExpression(prompt, { expectedThreadId = "" } = {}) {
  return `(async () => {
    const prompt = ${JSON.stringify(prompt)};
    const requiredThreadId = ${JSON.stringify(expectedThreadId)};
    if (requiredThreadId) {
      const activeThread = document.querySelector('[data-app-action-sidebar-thread-active="true"]');
      const activeThreadId = activeThread?.getAttribute("data-app-action-sidebar-thread-id") || "";
      if (normalizeThreadId(activeThreadId) !== normalizeThreadId(requiredThreadId)) {
        return { ok: false, error: "wrong_thread", threadId: activeThreadId };
      }
    }
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    if (!editor) return { ok: false, error: "missing ProseMirror editor" };

    editor.focus();
    document.execCommand("selectAll", false, null);
    document.execCommand("insertText", false, prompt);
    const draftLength = (editor.innerText || editor.textContent || "").trim().length;
    return { ok: true, draftLength };

    function normalizeThreadId(value) {
      return String(value || "").replace(/^local:/, "");
    }
  })()`;
}

function clearComposerDraftExpression() {
  return `(async () => {
    const marker = "voice-relay-clear-composer-draft";
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    if (!editor) return { ok: false, error: "missing ProseMirror editor", marker };

    editor.focus();
    document.execCommand("selectAll", false, null);
    document.execCommand("delete", false, null);
    const draftText = (editor.innerText || editor.textContent || "").trim();
    return { ok: true, marker, draftLength: draftText.length };
  })()`;
}

export function activeComposerRunExpression() {
  return `(() => {
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    if (!editor) return { active: false, reason: "missing_composer" };
    const composerRoot = editor.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor.parentElement;
    if (!composerRoot) return { active: false, reason: "missing_composer_root" };
    const stop = findComposerButton((button) => {
      const label = getButtonLabel(button);
      return label.includes("stop");
    });
    if (!stop) return { active: false, reason: "no_active_codex_run" };
    return { active: true };

    function findComposerButton(predicate) {
      return Array.from(composerRoot.querySelectorAll("button")).find((button) => {
        if (!String(button.className || "").includes("size-token-button-composer")) {
          return false;
        }
        return predicate(button);
      });
    }

    function getButtonLabel(button) {
      return [
        button.innerText || "",
        button.getAttribute("aria-label") || "",
        button.getAttribute("title") || "",
      ].join(" ").toLowerCase();
    }
  })()`;
}

function composerSendReadyExpression() {
  return `Boolean((() => {
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const composerRoot = editor?.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor?.parentElement;
    if (!composerRoot) return false;
    const send = Array.from(composerRoot.querySelectorAll("button")).find((button) => {
      if (!String(button.className || "").includes("size-token-button-composer")) {
        return false;
      }
      const label = [
        button.innerText || "",
        button.getAttribute("aria-label") || "",
        button.getAttribute("title") || "",
      ].join(" ").toLowerCase();
      return !label.includes("stop");
    });
    return send && !send.disabled && send.getAttribute("aria-disabled") !== "true";
  })())`;
}

function postRestartComposerReadyExpression() {
  return `(() => {
    const marker = "voice-relay-post-restart-composer-ready";
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const activeThread = document.querySelector('[data-app-action-sidebar-thread-active="true"]');
    if (!editor) return { marker, ready: false, reason: "missing_composer" };
    if (!activeThread) return { marker, ready: false, reason: "missing_active_thread" };
    const composerRoot = editor.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor.parentElement;
    if (!composerRoot) return { marker, ready: false, reason: "missing_composer_root" };
    const stop = Array.from(composerRoot.querySelectorAll("button")).find((button) => {
      if (!String(button.className || "").includes("size-token-button-composer")) {
        return false;
      }
      const label = [
        button.innerText || "",
        button.getAttribute("aria-label") || "",
        button.getAttribute("title") || "",
      ].join(" ").toLowerCase();
      return label.includes("stop");
    });
    if (stop) return { marker, ready: false, reason: "active_run" };
    return { marker, ready: true, reason: "composer_available" };
  })()`;
}

function composerTextSubmitReadyExpression() {
  return `Boolean((() => {
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const hasText = Boolean((editor?.innerText || editor?.textContent || "").trim());
    if (!hasText) return false;
    const composerRoot = editor.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor.parentElement;
    if (!composerRoot) return false;
    const send = Array.from(composerRoot.querySelectorAll("button")).find((button) => {
      if (!String(button.className || "").includes("size-token-button-composer")) {
        return false;
      }
      const label = [
        button.innerText || "",
        button.getAttribute("aria-label") || "",
        button.getAttribute("title") || "",
      ].join(" ").toLowerCase();
      return !label.includes("stop");
    });
    return send && !send.disabled && send.getAttribute("aria-disabled") !== "true";
  })())`;
}

function composerDraftReadyExpression() {
  return `Boolean((() => {
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    return Boolean((editor?.innerText || editor?.textContent || "").trim());
  })())`;
}

function composerSubmissionStateExpression() {
  return `(() => {
    const marker = "voice-relay-composer-submission-state";
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const draftText = (editor?.innerText || editor?.textContent || "").trim();
    const composerRoot = editor?.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor?.parentElement;
    const stop = Array.from(composerRoot?.querySelectorAll("button") || []).find((button) => {
      if (!String(button.className || "").includes("size-token-button-composer")) {
        return false;
      }
      const label = [
        button.innerText || "",
        button.getAttribute("aria-label") || "",
        button.getAttribute("title") || "",
      ].join(" ").toLowerCase();
      return label.includes("stop");
    });
    return {
      ok: true,
      marker,
      activeRun: Boolean(stop),
      draftLength: draftText.length,
      submitted: Boolean(stop) || draftText.length === 0,
    };
  })()`;
}

function modelReasoningControlCenterExpression() {
  return `(() => {
    const marker = "voice-relay-model-reasoning-control-center";
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const composerRoot = editor?.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor?.parentElement;
    if (!composerRoot) return { ok: false, error: "model_reasoning_composer_missing", marker };
    const control = modelReasoningControl();
    if (!control) return { ok: false, error: "model_reasoning_control_missing", marker };
    const rect = control.getBoundingClientRect();
    return {
      ok: true,
      marker,
      currentText: getControlText(control),
      x: rect.x + rect.width / 2,
      y: rect.y + rect.height / 2,
    };

    function modelReasoningControl() {
      return Array.from(
        composerRoot.querySelectorAll('button,[role="button"],select,[aria-haspopup]'),
      ).find((control) => {
        if (!isVisible(control)) return false;
        const text = getControlText(control);
        return isCompactModelReasoningText(text) && Boolean(parseModelReasoning(text));
      });
    }

    function getControlText(control) {
      return [
        control.innerText || "",
        control.textContent || "",
        control.getAttribute("aria-label") || "",
        control.getAttribute("title") || "",
      ].join("\\n").trim();
    }

    function isVisible(control) {
      const rect = control.getBoundingClientRect();
      const style = window.getComputedStyle(control);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }

    function isCompactModelReasoningText(text) {
      const compact = String(text || "").replace(/\\s+/g, " ").trim();
      if (!compact || compact.length > 80) return false;
      return (
        /(^|\\b)(gpt[- ]?)?\\d+\\.\\d+(\\b|$)/i.test(compact) &&
        /\\b(max|extra\\s+high|xhigh|high|medium|low)\\b/i.test(compact)
      );
    }

    function parseModelReasoning(text) {
      const compact = String(text || "").replace(/\\s+/g, " ").trim();
      if (!/(^|\\b)(gpt[- ]?)?\\d+\\.\\d+(\\b|$)/i.test(compact)) return null;
      if (/\\b(max|extra\\s+high|xhigh|high|medium|low)\\b/i.test(compact)) return true;
      return null;
    }
  })()`;
}

function selectReasoningMenuItemExpression(
  reasoningText,
  { allowSubmenuTrigger = true } = {},
) {
  return `(() => {
    const marker = "voice-relay-select-reasoning-menu-item";
    const target = ${JSON.stringify(reasoningText)};
    const candidates = Array.from(
      document.querySelectorAll('[role="menuitem"],button,[role="option"]'),
    ).filter(isVisible);
    const reasoningMenus = Array.from(document.querySelectorAll('[role="menu"]'))
      .filter(isVisible)
      .filter(hasReasoningChoices);
    const reasoningItems = reasoningMenus
      .flatMap((menu) => reasoningOptions(menu))
      .reverse();
    const item = reasoningItems.find(
      (candidate) => normalizedText(candidate).toLowerCase() === target.toLowerCase(),
    );
    if (item) {
      item.click();
      return { ok: true, marker, clicked: normalizedText(item) };
    }
    const allowSubmenuTrigger = ${allowSubmenuTrigger ? "true" : "false"};
    const submenuTrigger = allowSubmenuTrigger
      ? candidates.find((candidate) => /^Effort(?:\\s|$)/i.test(normalizedText(candidate)))
      : null;
    if (submenuTrigger) {
      submenuTrigger.click();
      return {
        ok: false,
        needsSubmenu: true,
        marker,
        target,
        visibleItemCount: candidates.length,
      };
    }
    return {
      ok: false,
      error: "reasoning_menu_item_missing",
      marker,
      target,
      visibleItemCount: candidates.length,
    };

    function normalizedText(element) {
      return (element.innerText || element.textContent || "")
        .replace(/\\s+/g, " ")
        .trim();
    }

    function reasoningOptions(menu) {
      return Array.from(
        menu.querySelectorAll('[role="menuitem"],button,[role="option"]'),
      ).filter((candidate) =>
        isVisible(candidate) && /^(Max|Extra High|High|Medium|Low|Minimal|None)$/i.test(
          normalizedText(candidate),
        ),
      );
    }

    function hasReasoningChoices(menu) {
      return new Set(
        reasoningOptions(menu).map((candidate) => normalizedText(candidate).toLowerCase()),
      ).size >= 2;
    }

    function isVisible(element) {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }
  })()`;
}

function reasoningMenuItemPresentExpression(reasoningText) {
  return `Boolean((() => {
    const marker = "voice-relay-reasoning-submenu-ready";
    const target = ${JSON.stringify(reasoningText)};
    void marker;
    return Array.from(document.querySelectorAll('[role="menu"]'))
      .filter(isVisible)
      .some((menu) => {
        const options = Array.from(
          menu.querySelectorAll('[role="menuitem"],button,[role="option"]'),
        ).filter((candidate) =>
          isVisible(candidate) && /^(Max|Extra High|High|Medium|Low|Minimal|None)$/i.test(
            normalizedText(candidate),
          ),
        );
        const distinctOptions = new Set(
          options.map((candidate) => normalizedText(candidate).toLowerCase()),
        );
        return (
          distinctOptions.size >= 2 &&
          options.some(
            (candidate) => normalizedText(candidate).toLowerCase() === target.toLowerCase(),
          )
        );
      });

    function normalizedText(element) {
      return (element.innerText || element.textContent || "")
        .replace(/\\s+/g, " ")
        .trim();
    }

    function isVisible(element) {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }
  })())`;
}

function modelReasoningMenuClosedExpression() {
  return `(() => {
    const marker = "voice-relay-model-reasoning-menu-closed";
    void marker;
    return !Array.from(document.querySelectorAll('[role="menu"]')).some(isVisible);

    function isVisible(element) {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }
  })()`;
}

function selectModelMenuItemExpression(modelText) {
  return `(() => {
    const marker = "voice-relay-select-model-menu-item";
    const normalizeModel = ${normalizeModelForUi.toString()};
    const target = normalizeModel(${JSON.stringify(modelText)});
    const items = Array.from(document.querySelectorAll('[role="menuitem"],[role="option"]'))
      .filter(isVisible)
      .map((candidate) => ({
        candidate,
        text: normalizedText(candidate),
        model: normalizeModel(normalizedText(candidate)),
      }));
    const item = items.find((entry) => entry.model && entry.model === target);
    if (!item) {
      return {
        ok: false,
        error: "model_menu_item_missing",
        marker,
        target,
        visibleItemCount: items.length,
      };
    }
    item.candidate.click();
    return { ok: true, marker, clicked: item.text, modelText: item.model };

    function normalizedText(element) {
      return (element.innerText || element.textContent || "")
        .replace(/\\s+/g, " ")
        .trim();
    }

    function isVisible(element) {
      const rect = element.getBoundingClientRect();
      const style = window.getComputedStyle(element);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }
  })()`;
}

export function extractReadyStateExpression() {
  return `(() => {
    const normalizeModel = ${normalizeModelForUi.toString()};
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const composerRoot = editor?.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor?.parentElement;
    if (!composerRoot) return { ok: false, error: "model_reasoning_composer_missing" };
    const controls = modelReasoningControls();
    for (const control of controls) {
      const controlText = getControlText(control);
      const parsed = parseModelReasoning(controlText);
      if (parsed) return { ok: true, ...parsed, controlText };
    }
    return { ok: false, error: "model_reasoning_control_missing" };

    function modelReasoningControls() {
      return Array.from(
        composerRoot.querySelectorAll('button,[role="button"],select,[aria-haspopup]'),
      ).filter((control) => {
        if (!isVisible(control)) return false;
        const text = getControlText(control);
        return isCompactModelReasoningText(text) && Boolean(parseModelReasoning(text));
      });
    }

    function getControlText(control) {
      return [
        control.innerText || "",
        control.textContent || "",
        control.getAttribute("aria-label") || "",
        control.getAttribute("title") || "",
      ].join("\\n").trim();
    }

    function isVisible(control) {
      const rect = control.getBoundingClientRect();
      const style = window.getComputedStyle(control);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }

    function isCompactModelReasoningText(text) {
      const compact = String(text || "").replace(/\\s+/g, " ").trim();
      if (!compact || compact.length > 80) return false;
      return (
        /(^|\\b)(gpt[- ]?)?\\d+\\.\\d+(\\b|$)/i.test(compact) &&
        /\\b(max|extra\\s+high|xhigh|high|medium|low)\\b/i.test(compact)
      );
    }

    function parseModelReasoning(text) {
      const parts = text
        .split(/\\n+/)
        .map((part) => part.replace(/\\s+/g, " ").trim())
        .filter(Boolean);
      if (parts.length === 0) return null;

      let modelText = "";
      let reasoningText = "";
      for (const part of parts) {
        const normalized = part.toLowerCase();
        if (!modelText) modelText = normalizeModel(part);
        if (!reasoningText && /\\bextra\\s+high\\b/i.test(normalized)) {
          reasoningText = "extra high";
          continue;
        }
        if (!reasoningText && /^(max|xhigh|high|medium|low)$/i.test(part)) {
          reasoningText = part;
        } else if (!reasoningText && /\\b(max|xhigh|high|medium|low)\\b/i.test(normalized)) {
          const match = normalized.match(/\\b(max|xhigh|high|medium|low)\\b/i);
          reasoningText = match ? match[1] : "";
        }
      }
      return modelText && reasoningText ? { modelText, reasoningText } : null;
    }
  })()`;
}

function codexReadyExpression({ modelTexts, reasoningTexts }) {
  return `Boolean((() => {
    const normalizeModel = ${normalizeModelForUi.toString()};
    const expectedModels = ${JSON.stringify(normalizeNeedles(modelTexts))}
      .map((value) => normalizeModel(value))
      .filter(Boolean);
    const expectedReasonings = ${JSON.stringify(normalizeNeedles(reasoningTexts))};
    const editor = document.querySelector(${JSON.stringify(MAIN_CODEX_COMPOSER_SELECTOR)});
    const activeThread = document.querySelector('[data-app-action-sidebar-thread-active="true"]');
    if (!editor || !activeThread) return false;
    const composerRoot = editor.closest(${JSON.stringify(CODEX_COMPOSER_SURFACE_SELECTOR)}) || editor.parentElement;
    if (!composerRoot) return false;

    const controls = modelReasoningControls();
    const modelReasoningReady = controls.some((control) => {
      const text = getControlText(control).replace(/\\s+/g, " ").trim().toLowerCase();
      if (!text) return false;
      return matchesAny(normalizeModel(text), expectedModels) && matchesAny(text, expectedReasonings);
    });
    if (!modelReasoningReady) return false;

    return !Array.from(composerRoot.querySelectorAll("button")).some((button) => {
      if (!String(button.className || "").includes("size-token-button-composer")) return false;
      const label = [
        button.innerText || "",
        button.getAttribute("aria-label") || "",
        button.getAttribute("title") || "",
      ].join(" ").toLowerCase();
      return label.includes("stop");
    });

    function matchesAny(text, needles) {
      return needles.length === 0 || needles.some((needle) => text.includes(needle));
    }

    function modelReasoningControls() {
      return Array.from(
        composerRoot.querySelectorAll('button,[role="button"],select,[aria-haspopup]'),
      ).filter((control) => {
        if (!isVisible(control)) return false;
        return isCompactModelReasoningText(getControlText(control));
      });
    }

    function getControlText(control) {
      return [
        control.innerText || "",
        control.textContent || "",
        control.getAttribute("aria-label") || "",
        control.getAttribute("title") || "",
      ].join("\\n").trim();
    }

    function isVisible(control) {
      const rect = control.getBoundingClientRect();
      const style = window.getComputedStyle(control);
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }

    function isCompactModelReasoningText(text) {
      const compact = String(text || "").replace(/\\s+/g, " ").trim();
      if (!compact || compact.length > 80) return false;
      return (
        /(^|\\b)(gpt[- ]?)?\\d+(?:\\.\\d+)?(\\b|$)/i.test(compact) &&
        /\\b(max|extra\\s+high|xhigh|high|medium|low)\\b/i.test(compact)
      );
    }
  })())`;
}

function normalizeNeedles(value) {
  return (Array.isArray(value) ? value : [value])
    .flatMap((item) => String(item || "").split(","))
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
}

function readyStateMatchesExpected(readyState, expected) {
  if (!readyState?.modelText || !readyState?.reasoningText) return false;
  return (
    textMatchesNeedles(readyState.modelText, expected.modelTexts) &&
    textMatchesNeedles(readyState.reasoningText, expected.reasoningTexts)
  );
}

function reasoningCorrectionTarget(readyState, expected) {
  if (!readyState?.modelText || !readyState?.reasoningText) return "";
  if (!textMatchesNeedles(readyState.modelText, expected.modelTexts)) return "";
  if (textMatchesNeedles(readyState.reasoningText, expected.reasoningTexts)) return "";
  return firstUiNeedle(expected.reasoningTexts);
}

function textMatchesNeedles(value, needles) {
  const text = String(value || "").trim().toLowerCase();
  const normalizedNeedles = normalizeNeedles(needles);
  if (!text || normalizedNeedles.length === 0) return false;
  return normalizedNeedles.some((needle) => text.includes(needle));
}

function firstUiNeedle(value) {
  return (Array.isArray(value) ? value : [value])
    .flatMap((item) => String(item || "").split(","))
    .map((item) => item.trim())
    .find(Boolean) || "";
}

function desiredReadyMismatch(desiredState, readyState) {
  return Boolean(
    (desiredState.modelText &&
      readyState.modelText &&
      !sameUiText(desiredState.modelText, readyState.modelText)) ||
      (desiredState.reasoningText &&
        readyState.reasoningText &&
        !sameUiText(desiredState.reasoningText, readyState.reasoningText)),
  );
}

function readyStateIsNewerThanDesired(desiredState, readyState, staleGraceMs) {
  const desiredMs = parseTimestampMs(desiredState.updatedAt);
  const readyMs = parseTimestampMs(readyState.observedAt);
  return desiredMs !== null && readyMs !== null && readyMs - desiredMs > staleGraceMs;
}

function parseTimestampMs(value) {
  const ms = Date.parse(String(value || ""));
  return Number.isFinite(ms) ? ms : null;
}

function sameUiText(a, b) {
  return String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
}

function normalizePositiveMs(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : 0;
}

function sameCodexThreadId(candidate, expected) {
  const left = normalizeSessionId(candidate);
  const right = normalizeSessionId(expected);
  if (!left || !right) return false;
  return left === right;
}

function preferredThreadSelectionError(reason) {
  const error = new Error(reason);
  error.code = reason;
  return error;
}

function preferredThreadSelectionReason(error) {
  const reason = String(error?.code || error?.reason || error?.message || error || "");
  return reason === "preferred_thread_row_missing"
    ? "preferred_thread_row_missing"
    : "wrong_thread";
}

function validTaskScopedEvidenceCapture(
  evidence,
  { rootSessionId, turnId = "" } = {},
) {
  const offset = Number(evidence?.offset);
  const expectedRootSessionId = normalizeSessionId(rootSessionId);
  const expectedTurnId = normalizeSessionId(turnId);
  return Boolean(
    evidence &&
      evidence.isSubagent !== true &&
      normalizeSessionId(evidence.rootSessionId) === expectedRootSessionId &&
      (!expectedTurnId || normalizeSessionId(evidence.turnId) === expectedTurnId) &&
      Number.isFinite(offset) &&
      offset >= 0,
  );
}

function validTaskScopedAcceptanceEvidence(
  evidence,
  { rootSessionId, turnId, requestToken, afterOffset } = {},
) {
  const acceptedOffset = Number(evidence?.offset);
  const capturedOffset = Number(afterOffset);
  return Boolean(
    evidence &&
      evidence.isSubagent !== true &&
      normalizeSessionId(evidence.rootSessionId) === normalizeSessionId(rootSessionId) &&
      normalizeSessionId(evidence.turnId) === normalizeSessionId(turnId) &&
      String(evidence.requestToken || "") === String(requestToken || "") &&
      Number.isFinite(acceptedOffset) &&
      Number.isFinite(capturedOffset) &&
      acceptedOffset > capturedOffset,
  );
}

function taskScopedSteerAcceptedResult({
  acceptanceEvidence,
  capturedEvidence,
  rootSessionId,
  turnId,
  requestId,
  prompt,
  composerSubmittedAt,
  preEnterTimings,
}) {
  if (
    !validTaskScopedAcceptanceEvidence(acceptanceEvidence, {
      rootSessionId,
      turnId,
      requestToken: requestId,
      afterOffset: capturedEvidence?.offset,
    })
  ) {
    return null;
  }
  return {
    status: "steered",
    requestId,
    prompt,
    incorporated: false,
    composerSubmittedAt,
    preEnterTimings,
    ...(acceptanceEvidence.acceptedAt
      ? { acceptedAt: acceptanceEvidence.acceptedAt }
      : {}),
    acceptanceEvidence: {
      source: "session_log",
      requestToken: requestId,
      rootSessionId,
      turnId,
      capturedOffset: capturedEvidence.offset,
      acceptedOffset: acceptanceEvidence.offset,
    },
  };
}

function taskScopedSteerFailure(requestId, reason) {
  return { status: "failed", reason, requestId };
}

async function clearTaskScopedComposerDraft(page, { requestId, phase }) {
  try {
    const result = await page.evaluate(clearComposerDraftExpression());
    if (result?.ok !== true || Number(result?.draftLength) !== 0) {
      warnTaskScopedError({
        requestId,
        phase,
        error: { code: "E_CLEAR_DRAFT_RESULT" },
        fallbackCode: "E_CLEAR_DRAFT_RESULT",
      });
      return false;
    }
    return true;
  } catch (error) {
    warnTaskScopedError({
      requestId,
      phase,
      error,
      fallbackCode: "E_CLEAR_DRAFT",
    });
    return false;
  }
}

function warnTaskScopedError({ requestId, phase, error, fallbackCode }) {
  console.warn(
    `${new Date().toISOString()} codex task-followup ${sanitizeLogToken(
      requestId,
      "unknown-request",
    )} phase=${sanitizeLogToken(phase, "unknown_phase")} error=${sanitizeLogToken(
      error?.code || error?.name,
      fallbackCode || "E_TASK_FOLLOWUP",
    )}`,
  );
}

function sanitizeLogToken(value, fallback) {
  const sanitized = String(value || fallback || "unknown")
    .replace(/[^A-Za-z0-9_.:-]/g, "_")
    .slice(0, 96);
  return sanitized || String(fallback || "unknown");
}

function ensurePreferredThreadExpression({ threadId, threadTitle }) {
  return `(async () => {
    const threadId = ${JSON.stringify(threadId || "")};
    const threadTitle = ${JSON.stringify(threadTitle || "")};
    const row = findPreferredThreadRow(threadId, threadTitle);
    if (!row) return { ok: false, error: "preferred_thread_row_missing", threadId, threadTitle };
    if (row.getAttribute("data-app-action-sidebar-thread-active") === "true") {
      return {
        ok: true,
        active: true,
        clicked: false,
        threadId: row.getAttribute("data-app-action-sidebar-thread-id") || "",
        threadTitle: row.getAttribute("data-app-action-sidebar-thread-title") || "",
      };
    }
    row.scrollIntoView({ block: "center" });
    row.click();
    return {
      ok: true,
      active: false,
      clicked: true,
      threadId: row.getAttribute("data-app-action-sidebar-thread-id") || "",
      threadTitle: row.getAttribute("data-app-action-sidebar-thread-title") || "",
    };

    function findPreferredThreadRow(id, title) {
      if (id) {
        const byId = Array.from(
          document.querySelectorAll("[data-app-action-sidebar-thread-row]"),
        ).find((candidate) =>
          sameThreadId(candidate.getAttribute("data-app-action-sidebar-thread-id") || "", id),
        );
        if (byId) return byId;
      }
      if (!title) return null;
      const rows = Array.from(document.querySelectorAll("[data-app-action-sidebar-thread-row]"));
      return rows.find((candidate) =>
        candidate.getAttribute("data-app-action-sidebar-thread-title") === title &&
        candidate.getAttribute("data-app-action-sidebar-thread-pinned") === "true",
      ) || null;
    }

    function sameThreadId(candidate, expected) {
      const left = String(candidate || "");
      const right = String(expected || "");
      if (!left || !right) return false;
      return left === right || left.replace(/^local:/, "") === right.replace(/^local:/, "");
    }
  })()`;
}

function preferredThreadVerificationExpression({ threadId, threadTitle }) {
  return `(() => {
    const expectedThreadId = ${JSON.stringify(threadId || "")};
    const expectedThreadTitle = ${JSON.stringify(threadTitle || "")};
    const activeThread = document.querySelector(
      '[data-app-action-sidebar-thread-row][data-app-action-sidebar-thread-active="true"]'
    );
    if (!activeThread) return { ok: false, error: "preferred_thread_row_missing" };
    const activeThreadId = activeThread.getAttribute("data-app-action-sidebar-thread-id") || "";
    const activeThreadTitle = activeThread.getAttribute("data-app-action-sidebar-thread-title") || "";
    const idMatches = !expectedThreadId || sameThreadId(activeThreadId, expectedThreadId);
    const titleMatches = !expectedThreadTitle || activeThreadTitle === expectedThreadTitle;
    return {
      ok: idMatches && (expectedThreadId || titleMatches),
      error: idMatches && (expectedThreadId || titleMatches) ? null : "wrong_thread",
      threadId: activeThreadId,
      threadTitle: activeThreadTitle,
    };

    function sameThreadId(candidate, expected) {
      const left = String(candidate || "").replace(/^local:/, "");
      const right = String(expected || "").replace(/^local:/, "");
      return Boolean(left && right && left === right);
    }
  })()`;
}

function preferredThreadActiveExpression({ threadId, threadTitle }) {
  if (threadId) {
    return `Array.from(document.querySelectorAll("[data-app-action-sidebar-thread-row]")).some((row) => {
      const candidate = String(row.getAttribute("data-app-action-sidebar-thread-id") || "");
      const expected = ${JSON.stringify(threadId)};
      return candidate && expected && candidate.replace(/^local:/, "") === expected.replace(/^local:/, "") && row.getAttribute("data-app-action-sidebar-thread-active") === "true";
    })`;
  }
  return `Array.from(document.querySelectorAll("[data-app-action-sidebar-thread-row]")).some((row) => row.getAttribute("data-app-action-sidebar-thread-title") === ${JSON.stringify(
    threadTitle,
  )} && row.getAttribute("data-app-action-sidebar-thread-pinned") === "true" && row.getAttribute("data-app-action-sidebar-thread-active") === "true")`;
}
