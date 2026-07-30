import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import {
  normalizeModelForConfig,
  normalizeReasoningForConfig,
} from "./codex-control-command.js";
import { buildThreadRotationHandoff } from "./thread-rotation-handoff.js";

const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;
const DEFAULT_RESPONSE_IDLE_TIMEOUT_MS = 10 * 60_000;
const DEFAULT_OUTPUT_TAIL_BYTES = 24 * 1024;
const THREAD_ROTATION_HANDOFF_TIMEOUT_MS = 10 * 60 * 1000;

export class CodexAppServerBackend {
  constructor({
    cliPath = "/opt/homebrew/bin/codex",
    threadId = "",
    startNewThread = false,
    cwd = "/tmp/voice-relay-unconfigured",
    responseTimeoutMs = DEFAULT_RESPONSE_IDLE_TIMEOUT_MS,
    requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    resumeTimeoutMs = requestTimeoutMs,
    threadConfig = null,
    model = "",
    reasoningEffort = "",
    approvalPolicy = "never",
    sandbox = "danger-full-access",
    fallbackBackend = null,
    threadStatePath = "",
    threadRotateAfterMs = 0,
    threadHandoffStatePath = "",
    threadHandoffMaxBytes = 512 * 1024,
    threadHandoffMaxEntries = 12,
    threadHandoffMaxChars = 6000,
    client = null,
    validateModelProfile = client == null,
    spawnCommand = spawn,
    now = () => Date.now(),
  } = {}) {
    this.cliPath = cliPath;
    this.threadId = threadId;
    this.startNewThread = startNewThread;
    this.cwd = cwd;
    this.responseTimeoutMs = normalizePositiveNumber(responseTimeoutMs);
    this.requestTimeoutMs = requestTimeoutMs;
    this.resumeTimeoutMs = resumeTimeoutMs;
    this.threadConfig = normalizeThreadConfig(threadConfig);
    this.model = model;
    this.reasoningEffort = reasoningEffort;
    this.approvalPolicy = approvalPolicy;
    this.sandbox = sandbox;
    this.fallbackBackend = fallbackBackend;
    this.threadStatePath = threadStatePath;
    this.threadRotateAfterMs = normalizePositiveNumber(threadRotateAfterMs);
    this.threadHandoffStatePath = threadHandoffStatePath;
    this.threadHandoffMaxBytes = normalizePositiveNumber(threadHandoffMaxBytes);
    this.threadHandoffMaxEntries = normalizePositiveNumber(threadHandoffMaxEntries);
    this.threadHandoffMaxChars = normalizePositiveNumber(threadHandoffMaxChars);
    this.validateModelProfile = Boolean(validateModelProfile);
    this.client =
      client ||
      new AppServerJsonlClient({
        cliPath,
        cwd,
        requestTimeoutMs,
        spawnCommand,
      });
    this.now = now;
    this.supportsLiveSteer = true;
    this.desiredState = null;
    this.initializePromise = null;
    this.resumePromise = null;
    this.startPromise = null;
    this.resumedThread = null;
    this.modelProfilePromise = null;
    this.modelProfile = null;
    this.activeTurn = null;
    this.client.onExit?.((exitInfo = {}) => {
      this.diag("app_server_exit_state_reset", {
        code: exitInfo.code ?? null,
        signal: exitInfo.signal ?? null,
        threadId: this.threadId || null,
      });
      this.resetAppServerSessionState();
    });
  }

  async health() {
    try {
      if (!this.threadId && !this.startNewThread) {
        throw new Error("Codex app-server backend requires CODEX_APP_SERVER_THREAD_ID");
      }
      await this.ensureInitialized();
      await this.ensureConfiguredProfile();
      return {
        ok: true,
        backend: "app-server",
        threadId: this.threadId || null,
        cwd: this.cwd,
        model: this.model || this.resumedThread?.model || null,
        reasoningEffort:
          this.reasoningEffort || this.resumedThread?.reasoningEffort || null,
        approvalPolicy: this.approvalPolicy,
        sandbox: this.sandbox,
        appServer: {
          running: true,
          cliPath: this.cliPath,
          pid: this.client.pid || null,
          resumed: Boolean(this.resumedThread),
          resumeChecked: Boolean(this.resumedThread),
          modelProfileVerified: Boolean(this.modelProfile),
        },
      };
    } catch (error) {
      return {
        ok: false,
        backend: "app-server",
        threadId: this.threadId || null,
        cwd: this.cwd,
        error: error instanceof Error ? error.message : String(error),
        appServer: {
          running: Boolean(this.client.pid),
          cliPath: this.cliPath,
          pid: this.client.pid || null,
        },
      };
    }
  }

  async ask(text, options = {}) {
    return this.askWithMessages(text, options);
  }

  async askWithMessages(
    text,
    { prefix = "", onMessage = null, onAccepted = null } = {},
  ) {
    const requestId = `voice-relay-app-server-${this.now()}-${Math.random()
      .toString(36)
      .slice(2, 8)}`;
    const prompt = `${prefix}[voice_relay_request_id: ${requestId}]\n${text}`.trim();
    if (!prompt) throw new Error("Codex app-server prompt cannot be empty");
    try {
      this.diag("run_received", { requestId, cwd: this.cwd, model: this.model || null });
      await this.ensureReady();
    } catch (error) {
      if (!isResumeTimeoutError(error) || !this.fallbackBackend?.askWithMessages) {
        throw error;
      }
      console.warn(
        `${new Date().toISOString()} app-server resume timed out; falling back to desktop backend: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return this.fallbackBackend.askWithMessages(text, {
        prefix,
        onMessage,
        onAccepted,
      });
    }

    const messages = [];
    const deliveredItemIds = new Set();
    const deltaByItemId = new Map();
    const bufferedNotifications = [];
    const bufferNotifications = (notification) => {
      bufferedNotifications.push(notification);
    };
    this.client.onNotification(bufferNotifications);
    let turnStarted;
    try {
      this.diag("turn_start_call", {
        requestId,
        threadId: this.threadId,
        cwd: this.cwd,
        model: this.model || null,
        reasoningEffort: this.reasoningEffort || null,
      });
      turnStarted = await this.client.request("turn/start", {
        threadId: this.threadId,
        input: [{ type: "text", text: prompt, text_elements: [] }],
        cwd: this.cwd,
        approvalPolicy: this.approvalPolicy,
        model: this.model || null,
        effort: this.reasoningEffort || null,
      });
    } catch (error) {
      this.client.offNotification(bufferNotifications);
      throw error;
    }
    const turnId = turnStarted?.turn?.id;
    if (!turnId) {
      this.client.offNotification(bufferNotifications);
      throw new Error("Codex app-server did not return a turn id");
    }
    this.diag("turn_created", { requestId, threadId: this.threadId, turnId });

    this.activeTurn = {
      requestId,
      turnId,
      startedAt: new Date(this.now()).toISOString(),
    };
    await onAccepted?.({
      source: "app_server",
      rootSessionId: this.threadId,
      turnId,
      requestToken: requestId,
    });
    try {
      const completion = await this.waitForTurnCompletion({
        turnId,
        timeoutMs: this.responseTimeoutMs,
        initialNotifications: bufferedNotifications,
        removeInitialBuffer: () => this.client.offNotification(bufferNotifications),
        onNotification: async (notification) => {
          const { method, params } = notification;
          if (!isNotificationForTurn(params, this.threadId, turnId)) return;
          if (method === "item/agentMessage/delta") {
            const prior = deltaByItemId.get(params.itemId) || "";
            deltaByItemId.set(params.itemId, prior + String(params.delta || ""));
            return;
          }
          if (method !== "item/completed" || params.item?.type !== "agentMessage") {
            return;
          }
          if (deliveredItemIds.has(params.item.id)) return;
          deliveredItemIds.add(params.item.id);
          const message = normalizeAgentMessage(params.item, {
            fallbackText: deltaByItemId.get(params.item.id) || "",
          });
          if (!message.text.trim()) return;
          messages.push(message);
          if (onMessage) await onMessage({ ...message, file: null });
          return true;
        },
      });

      if (completion.turn?.status === "failed") {
        throw new Error(formatTurnError(completion.turn?.error));
      }
      if (completion.turn?.status === "interrupted") {
        throw new Error("Codex app-server turn was interrupted");
      }

      for (const item of completion.turn?.items || []) {
        if (item?.type !== "agentMessage" || deliveredItemIds.has(item.id)) continue;
        deliveredItemIds.add(item.id);
        const message = normalizeAgentMessage(item, {
          fallbackText: deltaByItemId.get(item.id) || "",
        });
        if (!message.text.trim()) continue;
        messages.push(message);
        if (onMessage) await onMessage({ ...message, file: null });
      }

      if (messages.length === 0 && deltaByItemId.size > 0) {
        const [itemId, textOut] = Array.from(deltaByItemId.entries()).at(-1);
        const message = {
          id: itemId || `${requestId}-final`,
          phase: "final_answer",
          text: textOut,
        };
        messages.push(message);
        if (onMessage) await onMessage({ ...message, file: null });
      }
      if (messages.length === 0) {
        throw new Error("Codex app-server returned no assistant message");
      }

      return {
        requestId,
        prompt,
        reply: {
          file: null,
          messages,
          complete: true,
          completedAt: new Date(this.now()).toISOString(),
          completedBy: "codex_app_server_turn_completed",
          threadId: this.threadId,
          turnId,
        },
      };
    } finally {
      this.client.offNotification(bufferNotifications);
      if (this.activeTurn?.turnId === turnId) this.activeTurn = null;
    }
  }

  async submitSteer(text) {
    const prompt = String(text || "").trim();
    const requestId = `voice-relay-steer-app-server-${this.now()}`;
    if (!prompt) throw new Error("Steer note cannot be empty");
    if (!this.activeTurn) {
      return {
        status: "ignored",
        reason: "no_active_app_server_turn",
        requestId,
      };
    }
    await this.ensureReady();
    await this.client.request("turn/steer", {
      threadId: this.threadId,
      expectedTurnId: this.activeTurn.turnId,
      input: [{ type: "text", text: prompt, text_elements: [] }],
    });
    return {
      status: "steered",
      requestId,
      turnId: this.activeTurn.turnId,
      prompt,
    };
  }

  hasActiveTurn() {
    return Boolean(this.activeTurn);
  }

  async stopActiveRun() {
    const requestId = `voice-relay-stop-app-server-${this.now()}`;
    const activeBefore = Boolean(this.activeTurn);
    if (!this.activeTurn) {
      return {
        status: "ignored",
        reason: "no_active_app_server_turn",
        requestId,
        activeBefore,
        activeAfter: false,
      };
    }
    const turnId = this.activeTurn.turnId;
    await this.ensureReady();
    await this.client.request("turn/interrupt", {
      threadId: this.threadId,
      turnId,
    });
    this.activeTurn = null;
    return {
      status: "stopped",
      requestId,
      turnId,
      activeBefore,
      activeAfter: false,
    };
  }

  async setReasoningLevel(reasoningText) {
    this.reasoningEffort =
      normalizeReasoningForConfig(reasoningText) || this.reasoningEffort;
    this.invalidateConfiguredProfileValidation();
    return {
      status: "set",
      requestId: `voice-relay-reasoning-app-server-${this.now()}`,
      reasoningText: this.reasoningEffort,
      backend: "app-server",
      appliesTo: "next_turn",
    };
  }

  setDesiredReadyState(update = {}) {
    if (update.modelText) {
      this.model = normalizeModelForConfig(update.modelText) || this.model;
    }
    if (update.reasoningText) {
      this.reasoningEffort =
        normalizeReasoningForConfig(update.reasoningText) || this.reasoningEffort;
    }
    this.invalidateConfiguredProfileValidation();
    this.desiredState = {
      ...(this.desiredState || {}),
      ...update,
      updatedAt: new Date(this.now()).toISOString(),
      backend: "app-server",
      appliesTo: "next_turn",
    };
    return this.desiredState;
  }

  clearDesiredReadyState() {
    this.desiredState = null;
    return { status: "cleared", backend: "app-server" };
  }

  async ensureReady() {
    if (!this.threadId && !this.startNewThread && !this.threadRotationEnabled()) {
      throw new Error("Codex app-server backend requires CODEX_APP_SERVER_THREAD_ID");
    }
    await this.ensureInitialized();
    await this.ensureConfiguredProfile();
    const rotated = await this.ensureThreadRotation();
    if (rotated) return;
    if (!this.threadId && !this.startNewThread) {
      throw new Error("Codex app-server backend requires CODEX_APP_SERVER_THREAD_ID");
    }
    if (this.startNewThread && !this.threadId) {
      await this.ensureThreadStarted();
      this.persistThreadRotationStateIfNeeded();
      return;
    }
    await this.ensureThreadResumed();
    this.persistThreadRotationStateIfNeeded();
  }

  async keepAliveRenderer() {
    await this.ensureReady();
    return {
      ok: true,
      backend: "app-server",
      threadId: this.threadId,
      pid: this.client.pid || null,
      model: this.modelProfile?.model || this.model || null,
      reasoningEffort:
        this.modelProfile?.reasoningEffort || this.reasoningEffort || null,
      modelProfileVerified: Boolean(this.modelProfile),
    };
  }

  resetAppServerSessionState() {
    this.initializePromise = null;
    this.resumePromise = null;
    this.startPromise = null;
    this.resumedThread = null;
    this.modelProfilePromise = null;
    this.modelProfile = null;
    this.activeTurn = null;
    if (this.startNewThread) this.threadId = "";
  }

  async ensureInitialized() {
    if (!this.initializePromise) {
      this.initializePromise = (async () => {
        const startedAt = Date.now();
        this.diag("app_server_spawn_start", { cwd: this.cwd, cliPath: this.cliPath });
        await this.client.ensureStarted();
        this.diag("app_server_spawn_done", {
          pid: this.client.pid || null,
          durationMs: Date.now() - startedAt,
        });
        const initializeStartedAt = Date.now();
        this.diag("initialize_call", { pid: this.client.pid || null });
        await this.client.request("initialize", {
          clientInfo: {
            name: "voice_relay_remote_bridge",
            title: "Voice Relay Remote Bridge",
            version: "0.1.0",
          },
          capabilities: {
            experimentalApi: true,
            requestAttestation: false,
          },
        });
        this.diag("initialize_done", {
          durationMs: Date.now() - initializeStartedAt,
        });
        this.client.notify("initialized");
      })().catch((error) => {
        this.initializePromise = null;
        throw error;
      });
    }
    return this.initializePromise;
  }

  async ensureConfiguredProfile() {
    if (!this.validateModelProfile || !this.model) return null;
    if (!this.modelProfilePromise) {
      this.modelProfilePromise = (async () => {
        const response = await this.client.request("model/list", { limit: 100 });
        const models = Array.isArray(response?.data) ? response.data : [];
        const configuredModel = models.find(
          (entry) =>
            entry?.id === this.model ||
            entry?.model === this.model ||
            entry?.slug === this.model,
        );
        if (!configuredModel) {
          throw new Error(
            `Configured Codex model is not available from app-server: ${this.model}`,
          );
        }
        const supportedReasoningEfforts = Array.from(
          new Set(
            (configuredModel.supportedReasoningEfforts || [])
              .map((entry) =>
                typeof entry === "string" ? entry : entry?.reasoningEffort,
              )
              .filter(Boolean),
          ),
        );
        if (
          this.reasoningEffort &&
          !supportedReasoningEfforts.includes(this.reasoningEffort)
        ) {
          throw new Error(
            `Configured Codex reasoning effort is not supported by ${this.model}: ${this.reasoningEffort}`,
          );
        }
        this.modelProfile = {
          model: configuredModel.id || configuredModel.model || this.model,
          reasoningEffort: this.reasoningEffort || null,
          supportedReasoningEfforts,
        };
        this.diag("model_profile_verified", this.modelProfile);
        return this.modelProfile;
      })().catch((error) => {
        this.modelProfilePromise = null;
        this.modelProfile = null;
        throw error;
      });
    }
    return this.modelProfilePromise;
  }

  invalidateConfiguredProfileValidation() {
    this.modelProfilePromise = null;
    this.modelProfile = null;
  }

  effectiveThreadConfig() {
    const config = { ...(this.threadConfig || {}) };
    if (this.model) config.model = this.model;
    if (this.reasoningEffort) {
      config.model_reasoning_effort = this.reasoningEffort;
    }
    return Object.keys(config).length ? config : null;
  }

  resolvedThreadProfile(response, operation) {
    const profile = {
      model: response?.model || null,
      reasoningEffort: response?.reasoningEffort || null,
    };
    if (this.model && profile.model !== this.model) {
      throw new Error(
        `Codex app-server ${operation} resolved model mismatch: expected ${this.model}, received ${profile.model || "missing"}`,
      );
    }
    if (
      this.reasoningEffort &&
      profile.reasoningEffort !== this.reasoningEffort
    ) {
      throw new Error(
        `Codex app-server ${operation} resolved reasoning effort mismatch: expected ${this.reasoningEffort}, received ${profile.reasoningEffort || "missing"}`,
      );
    }
    return profile;
  }

  async ensureThreadResumed() {
    if (!this.resumePromise) {
      this.resumePromise = (async () => {
        const startedAt = Date.now();
        this.diag("thread_resume_call", {
          threadId: this.threadId,
          cwd: this.cwd,
          model: this.model || null,
          reasoningEffort: this.reasoningEffort || null,
          timeoutMs: this.resumeTimeoutMs,
        });
        const response = await this.client.request("thread/resume", {
          threadId: this.threadId,
          cwd: this.cwd,
          approvalPolicy: this.approvalPolicy,
          sandbox: this.sandbox,
          config: this.effectiveThreadConfig(),
          model: this.model || null,
        }, {
          timeoutMs: this.resumeTimeoutMs,
        });
        this.resumedThread = this.resolvedThreadProfile(
          response,
          "thread/resume",
        );
        this.diag("thread_resumed", {
          threadId: this.threadId,
          durationMs: Date.now() - startedAt,
          model: this.resumedThread.model,
          reasoningEffort: this.resumedThread.reasoningEffort,
        });
        return response;
      })().catch((error) => {
        this.resumePromise = null;
        throw error;
      });
    }
    return this.resumePromise;
  }

  async ensureThreadStarted() {
    if (!this.startPromise) {
      this.startPromise = (async () => {
        const startedAt = Date.now();
        this.diag("thread_start_call", {
          cwd: this.cwd,
          model: this.model || null,
          reasoningEffort: this.reasoningEffort || null,
          timeoutMs: this.requestTimeoutMs,
        });
        const response = await this.client.request("thread/start", {
          cwd: this.cwd,
          approvalPolicy: this.approvalPolicy,
          sandbox: this.sandbox,
          config: this.effectiveThreadConfig(),
          model: this.model || null,
          threadSource: "automation",
        });
        const threadId = response?.thread?.id;
        if (!threadId) {
          throw new Error("Codex app-server thread/start did not return a thread id");
        }
        const profile = this.resolvedThreadProfile(response, "thread/start");
        this.threadId = threadId;
        this.resumedThread = profile;
        this.diag("thread_started", {
          threadId: this.threadId,
          durationMs: Date.now() - startedAt,
          model: this.resumedThread.model,
          reasoningEffort: this.resumedThread.reasoningEffort,
        });
        return response;
      })().catch((error) => {
        this.startPromise = null;
        throw error;
      });
    }
    return this.startPromise;
  }

  threadRotationEnabled() {
    return Boolean(this.threadStatePath && this.threadRotateAfterMs > 0);
  }

  async ensureThreadRotation() {
    if (!this.threadRotationEnabled()) return false;
    const state = this.readThreadRotationState();
    if (state.threadId && state.threadId !== this.threadId) {
      this.threadId = state.threadId;
      this.resumePromise = null;
      this.resumedThread = null;
    }
    if (!this.threadId) return false;

    const startedAtMs = parseStateTime(state.startedAt || state.rotatedAt);
    if (!state.threadId || !startedAtMs) {
      this.writeThreadRotationState({
        ...state,
        threadId: this.threadId,
        startedAt: new Date(this.now()).toISOString(),
        updatedAt: new Date(this.now()).toISOString(),
        rotateAfterMs: this.threadRotateAfterMs,
      });
      return false;
    }

    const ageMs = this.now() - startedAtMs;
    if (ageMs < this.threadRotateAfterMs) return false;

    const previousThreadId = this.threadId;
    this.diag("thread_rotation_due", {
      threadId: previousThreadId,
      ageMs,
      rotateAfterMs: this.threadRotateAfterMs,
    });
    this.threadId = "";
    this.resumePromise = null;
    this.startPromise = null;
    this.resumedThread = null;
    try {
      await this.ensureThreadStarted();
    } catch (error) {
      this.threadId = previousThreadId;
      this.startPromise = null;
      this.diag("thread_rotation_failed", {
        threadId: previousThreadId,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    }

    const handoffSeeded = await this.seedThreadRotationHandoff(previousThreadId);
    const nowIso = new Date(this.now()).toISOString();
    this.writeThreadRotationState({
      threadId: this.threadId,
      previousThreadId,
      startedAt: nowIso,
      rotatedAt: nowIso,
      updatedAt: nowIso,
      rotateAfterMs: this.threadRotateAfterMs,
      handoffSeeded,
    });
    this.diag("thread_rotated", {
      threadId: this.threadId,
      previousThreadId,
      rotateAfterMs: this.threadRotateAfterMs,
      handoffSeeded,
    });
    return true;
  }

  async seedThreadRotationHandoff(previousThreadId = "") {
    if (!this.threadHandoffStatePath || !this.threadId) return false;
    const handoff = buildThreadRotationHandoff({
      statePath: this.threadHandoffStatePath,
      previousThreadId,
      maxBytes: this.threadHandoffMaxBytes,
      maxEntries: this.threadHandoffMaxEntries,
      maxChars: this.threadHandoffMaxChars,
      now: this.now,
    });
    if (!handoff) return false;
    try {
      await this.runInternalTurn(handoff, {
        purpose: "thread_rotation_handoff",
        timeoutMs: Math.min(this.responseTimeoutMs, THREAD_ROTATION_HANDOFF_TIMEOUT_MS),
      });
      this.diag("thread_rotation_handoff_seeded", {
        threadId: this.threadId,
        previousThreadId: previousThreadId || null,
      });
      return true;
    } catch (error) {
      this.diag("thread_rotation_handoff_failed", {
        threadId: this.threadId,
        previousThreadId: previousThreadId || null,
        error: error instanceof Error ? error.message : String(error),
      });
      return false;
    }
  }

  async runInternalTurn(text, { purpose = "internal", timeoutMs = this.responseTimeoutMs } = {}) {
    const prompt = String(text || "").trim();
    if (!prompt) throw new Error("Codex app-server internal prompt cannot be empty");
    const bufferedNotifications = [];
    const bufferNotifications = (notification) => {
      bufferedNotifications.push(notification);
    };
    this.client.onNotification(bufferNotifications);
    let turnStarted;
    try {
      this.diag(`${purpose}_turn_start_call`, {
        threadId: this.threadId,
        cwd: this.cwd,
        model: this.model || null,
        reasoningEffort: this.reasoningEffort || null,
      });
      turnStarted = await this.client.request("turn/start", {
        threadId: this.threadId,
        input: [{ type: "text", text: prompt, text_elements: [] }],
        cwd: this.cwd,
        approvalPolicy: this.approvalPolicy,
        model: this.model || null,
        effort: this.reasoningEffort || null,
      });
    } catch (error) {
      this.client.offNotification(bufferNotifications);
      throw error;
    }
    const turnId = turnStarted?.turn?.id;
    if (!turnId) {
      this.client.offNotification(bufferNotifications);
      throw new Error("Codex app-server did not return an internal turn id");
    }
    const completion = await this.waitForTurnCompletion({
      turnId,
      timeoutMs,
      initialNotifications: bufferedNotifications,
      removeInitialBuffer: () => this.client.offNotification(bufferNotifications),
    });
    if (completion.turn?.status === "failed") {
      throw new Error(formatTurnError(completion.turn?.error));
    }
    if (completion.turn?.status === "interrupted") {
      throw new Error("Codex app-server internal turn was interrupted");
    }
    return { turnId, completion };
  }

  persistThreadRotationStateIfNeeded() {
    if (!this.threadRotationEnabled() || !this.threadId) return;
    const state = this.readThreadRotationState();
    if (state.threadId === this.threadId && parseStateTime(state.startedAt || state.rotatedAt)) {
      return;
    }
    const nowIso = new Date(this.now()).toISOString();
    this.writeThreadRotationState({
      ...state,
      threadId: this.threadId,
      startedAt: state.startedAt || nowIso,
      updatedAt: nowIso,
      rotateAfterMs: this.threadRotateAfterMs,
    });
  }

  readThreadRotationState() {
    try {
      if (!this.threadStatePath || !fs.existsSync(this.threadStatePath)) return {};
      const parsed = JSON.parse(fs.readFileSync(this.threadStatePath, "utf8"));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch (error) {
      this.diag("thread_rotation_state_read_failed", {
        path: this.threadStatePath,
        error: error instanceof Error ? error.message : String(error),
      });
      return {};
    }
  }

  writeThreadRotationState(state) {
    try {
      fs.mkdirSync(path.dirname(this.threadStatePath), { recursive: true });
      fs.writeFileSync(this.threadStatePath, `${JSON.stringify(state, null, 2)}\n`);
    } catch (error) {
      this.diag("thread_rotation_state_write_failed", {
        path: this.threadStatePath,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  diag(event, fields = {}) {
    try {
      process.stderr.write(
        `${JSON.stringify({
          ts: new Date(this.now()).toISOString(),
          event,
          ...fields,
        })}\n`,
      );
    } catch {
      // Diagnostics must not affect the automation path.
    }
  }

  waitForTurnCompletion({
    turnId,
    timeoutMs,
    initialNotifications = [],
    removeInitialBuffer = null,
    onNotification,
  }) {
    return new Promise((resolve, reject) => {
      let settled = false;
      let timer = null;
      let removeExitListener = null;
      const idleTimeoutMs = normalizePositiveNumber(timeoutMs);
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        this.client.offNotification(listener);
        removeExitListener?.();
        callback(value);
      };
      const resetIdleTimer = () => {
        if (!idleTimeoutMs) return;
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          finish(
            reject,
            new Error(
              `Codex app-server turn idle timed out after ${idleTimeoutMs}ms without an assistant message`,
            ),
          );
        }, idleTimeoutMs);
        timer.unref?.();
      };
      resetIdleTimer();
      let notificationWork = Promise.resolve();
      const listener = (notification) => {
        notificationWork = notificationWork
          .then(async () => {
            if (settled) return;
            return onNotification?.(notification);
          })
          .then((assistantMessageDelivered) => {
            if (settled) return;
            if (
              assistantMessageDelivered === true ||
              isAssistantMessageItemCompleted(notification, this.threadId, turnId)
            ) {
              resetIdleTimer();
            }
            if (
              notification.method === "turn/completed" &&
              notification.params?.threadId === this.threadId &&
              notification.params?.turn?.id === turnId
            ) {
              if (isIncompleteInterruptedTurn(notification.params.turn)) {
                this.diag("turn_completed_incomplete_interrupted_ignored", {
                  threadId: this.threadId,
                  turnId,
                });
                return;
              }
              finish(resolve, notification.params);
            }
            if (isFinalAnswerItemCompleted(notification, this.threadId, turnId)) {
              finish(resolve, {
                turn: {
                  id: turnId,
                  status: "completed",
                  error: null,
                  items: [notification.params.item],
                },
              });
            }
            if (
              notification.method === "error" &&
              notification.params?.threadId === this.threadId &&
              notification.params?.turnId === turnId
            ) {
              finish(
                reject,
                new Error(formatTurnError(notification.params?.error)),
              );
            }
          })
          .catch((error) => finish(reject, error));
      };
      this.client.onNotification(listener);
      removeExitListener =
        this.client.onExit?.((exitInfo = {}) => {
          const details = [
            exitInfo.code == null ? null : `code ${exitInfo.code}`,
            exitInfo.signal ? `signal ${exitInfo.signal}` : null,
          ].filter(Boolean);
          finish(
            reject,
            new Error(
              `Codex app-server exited while waiting for turn ${turnId}${
                details.length ? ` (${details.join(", ")})` : ""
              }`,
            ),
          );
        }) || null;
      removeInitialBuffer?.();
      for (const notification of initialNotifications) {
        listener(notification);
        if (settled) break;
      }
    });
  }
}

function isIncompleteInterruptedTurn(turn) {
  return (
    turn?.status === "interrupted" &&
    !turn.completedAt &&
    !turn.completed_at &&
    !turn.completedAtMs &&
    !turn.durationMs &&
    !turn.error
  );
}

function isFinalAnswerItemCompleted(notification, threadId, turnId) {
  return (
    notification.method === "item/completed" &&
    notification.params?.threadId === threadId &&
    notification.params?.turnId === turnId &&
    notification.params?.item?.type === "agentMessage" &&
    notification.params?.item?.phase === "final_answer"
  );
}

function isAssistantMessageItemCompleted(notification, threadId, turnId) {
  return (
    notification.method === "item/completed" &&
    notification.params?.threadId === threadId &&
    notification.params?.turnId === turnId &&
    notification.params?.item?.type === "agentMessage"
  );
}

export class AppServerJsonlClient {
  constructor({
    cliPath = "/opt/homebrew/bin/codex",
    cwd = "/tmp/voice-relay-unconfigured",
    requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    configOverrides = [],
    spawnCommand = spawn,
  } = {}) {
    this.cliPath = cliPath;
    this.cwd = cwd;
    this.requestTimeoutMs = requestTimeoutMs;
    this.configOverrides = normalizeConfigOverrides(configOverrides);
    this.spawnCommand = spawnCommand;
    this.child = null;
    this.pid = null;
    this.nextId = 1;
    this.pending = new Map();
    this.events = new EventEmitter();
    this.stderr = "";
    this.exited = false;
  }

  async ensureStarted() {
    if (this.child && !this.exited) return;
    this.child = this.spawnCommand(
      this.cliPath,
      [
        ...this.configOverrides.flatMap((override) => ["-c", override]),
        "app-server",
        "--listen",
        "stdio://",
      ],
      {
        cwd: this.cwd,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    this.pid = this.child.pid || null;
    this.exited = false;
    this.stderr = "";
    this.child.on("exit", (code, signal) => {
      this.exited = true;
      this.pid = null;
      const error = new Error(
        `Codex app-server exited${code === null ? "" : ` ${code}`}${
          signal ? ` signal ${signal}` : ""
        }: ${this.stderr}`,
      );
      for (const pending of this.pending.values()) {
        pending.reject(error);
        clearTimeout(pending.timer);
      }
      this.pending.clear();
      this.events.emit("exit", { code, signal });
    });
    this.child.on("error", (error) => {
      for (const pending of this.pending.values()) {
        pending.reject(error);
        clearTimeout(pending.timer);
      }
      this.pending.clear();
    });
    this.child.stderr?.setEncoding("utf8");
    this.child.stderr?.on("data", (chunk) => {
      this.stderr = tail(`${this.stderr}${chunk}`, DEFAULT_OUTPUT_TAIL_BYTES);
    });
    const lines = readline.createInterface({
      input: this.child.stdout,
      crlfDelay: Infinity,
    });
    lines.on("line", (line) => this.handleLine(line));
  }

  request(method, params = undefined, { timeoutMs = this.requestTimeoutMs } = {}) {
    return new Promise((resolve, reject) => {
      this.ensureStarted()
        .then(() => {
          const id = this.nextId++;
          const timer = setTimeout(() => {
            this.pending.delete(id);
            reject(new Error(`Codex app-server request timed out: ${method}`));
          }, timeoutMs);
          timer.unref?.();
          this.pending.set(id, { method, resolve, reject, timer });
          this.write({ id, method, params });
        })
        .catch(reject);
    });
  }

  notify(method, params = undefined) {
    this.write(params === undefined ? { method } : { method, params });
  }

  onNotification(listener) {
    this.events.on("notification", listener);
  }

  offNotification(listener) {
    this.events.off("notification", listener);
  }

  onExit(listener) {
    this.events.on("exit", listener);
    return () => this.events.off("exit", listener);
  }

  write(message) {
    if (!this.child || this.exited) {
      throw new Error("Codex app-server is not running");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  handleLine(rawLine) {
    const line = rawLine.trim();
    if (!line) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      this.stderr = tail(
        `${this.stderr}\n[json-parse-failed] ${line}: ${
          error instanceof Error ? error.message : String(error)
        }`,
        DEFAULT_OUTPUT_TAIL_BYTES,
      );
      return;
    }
    if (message.id !== undefined && (message.result !== undefined || message.error)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new Error(formatRpcError(pending.method, message.error)));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (message.id !== undefined && message.method) {
      this.write({
        id: message.id,
        error: {
          code: -32601,
          message: `Unsupported server request: ${message.method}`,
        },
      });
      return;
    }
    if (message.method) {
      this.events.emit("notification", message);
    }
  }

  close() {
    if (!this.child || this.exited) return;
    this.child.kill("SIGTERM");
  }
}

function isNotificationForTurn(params, threadId, turnId) {
  return params?.threadId === threadId && params?.turnId === turnId;
}

function normalizeThreadConfig(value) {
  if (value == null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Codex app-server thread config must be a JSON object");
  }
  return value;
}

function normalizePositiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : 0;
}

function normalizeConfigOverrides(value) {
  if (!Array.isArray(value)) return [];
  return value.map((entry) => String(entry || "").trim()).filter(Boolean);
}

function parseStateTime(value) {
  const timestamp = Date.parse(String(value || ""));
  return Number.isFinite(timestamp) ? timestamp : 0;
}

function normalizeAgentMessage(item, { fallbackText = "" } = {}) {
  return {
    id: item.id,
    phase: item.phase || "assistant",
    text: String(item.text || fallbackText || ""),
  };
}

function formatTurnError(error) {
  if (!error) return "Codex app-server turn failed";
  const details = error.additionalDetails ? `: ${error.additionalDetails}` : "";
  return `${error.message || "Codex app-server turn failed"}${details}`;
}

function formatRpcError(method, error) {
  if (!error) return `${method} failed`;
  if (typeof error === "string") return `${method} failed: ${error}`;
  const message = error.message || JSON.stringify(error);
  return `${method} failed: ${message}`;
}

function isResumeTimeoutError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return /timed out: thread\/resume/i.test(message);
}

function tail(text, maxBytes) {
  const value = String(text || "");
  if (Buffer.byteLength(value) <= maxBytes) return value;
  return value.slice(Math.max(0, value.length - maxBytes));
}
