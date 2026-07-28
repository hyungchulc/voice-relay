import { spawn } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import path from "node:path";

import { AppServerJsonlClient } from "./codex-app-server.js";

export const REMOTE_CONTROL_PROTOCOL_VERSION = 3;
export const REMOTE_CONTROL_CONTROLLER_SCOPE =
  "remote_control_controller_websocket";
export const DEFAULT_REMOTE_CONTROL_API_BASE_URL =
  "https://chatgpt.com/backend-api";
export const DEFAULT_REMOTE_CONTROL_AUTH_ISSUER = "https://auth.openai.com";
export const DEFAULT_REMOTE_CONTROL_OAUTH_CLIENT_ID =
  "app_EMoamEEZ73f0CkXaXp7hrann";

export function normalizeManualPairingCode(value) {
  const compact = String(value || "")
    .replace(/[^a-z0-9]/giu, "")
    .toUpperCase();
  if (compact.length !== 8) {
    throw new Error(
      "Remote control manual pairing code must contain 8 letters or digits",
    );
  }
  return compact.slice(0, 4) + "-" + compact.slice(4);
}

const DEVICE_KEY_DOMAIN = "codex-device-key-sign-payload/v1";
const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;
const DEFAULT_REQUEST_TOMBSTONE_TTL_MS = 5 * 60_000;
const DEFAULT_REQUEST_TOMBSTONE_LIMIT = 256;
const LATE_RESPONSE_ASSEMBLY_MAX_BYTES = 2 * 1024 * 1024;
const LATE_RESPONSE_ASSEMBLY_LIMIT = 32;
const LATE_RESPONSE_ASSEMBLY_MAX_SEGMENTS = 256;
const DEFAULT_PAIRING_TIMEOUT_MS = 10 * 60_000;
const CLIENT_MESSAGE_MAX_BYTES = 100 * 1024;
const TRANSPORT_MESSAGE_MAX_BYTES = 150 * 1024;
const MAX_REASSEMBLED_MESSAGE_BYTES = 1024 * 1024 * 1024;
const SERVER_MESSAGE_ASSEMBLY_MAX_SEGMENTS = Math.ceil(
  MAX_REASSEMBLED_MESSAGE_BYTES / CLIENT_MESSAGE_MAX_BYTES,
);
const CALLBACK_PORTS = [1455, 1457];
const CALLBACK_PATH = "/auth/callback";
const STEP_UP_SCOPE = "codex.remote_control.enroll";
const STEP_UP_FRESHNESS_SECONDS = 300;
const STREAM_PING_INTERVAL_MS = 30_000;
const STREAM_PONG_TIMEOUT_MS = 10 * 60_000;
const RECONNECT_DELAY_MS = 1_000;
const WEBSOCKET_OPEN_TIMEOUT_MS = 30_000;
const DEVICE_KEY_CHALLENGE_TIMEOUT_MS = 10_000;
const NATIVE_KEY_PROTECTION_CLASS = "allow_os_protected_nonextractable";
const REMOTE_CONTROL_STREAM_GAP_CODE = "REMOTE_CONTROL_STREAM_GAP";
const GLOBAL_ENVIRONMENT_ID_KEY =
  "electron-local-remote-control-environment-id";

export class RemoteControllerRequestTimeoutError extends Error {
  constructor({
    method,
    requestId,
    streamId,
    streamGeneration,
    timeoutMs,
    requestMetadata = null,
  }) {
    super("Remote controller request timed out: " + method);
    this.name = "RemoteControllerRequestTimeoutError";
    this.code = "REMOTE_CONTROL_REQUEST_TIMEOUT";
    this.method = method;
    this.requestId = requestId;
    this.streamId = streamId || null;
    this.streamGeneration = streamGeneration;
    this.timeoutMs = timeoutMs;
    this.phase = nonEmptyString(requestMetadata?.phase) || null;
    this.attempt = safePositiveInteger(requestMetadata?.attempt);
    this.maxAttempts = safePositiveInteger(requestMetadata?.maxAttempts);
    this.deadlineAtMs = finiteNumberOrNull(requestMetadata?.deadlineAtMs);
    this.requestMetadata = normalizeRequestMetadata(requestMetadata);
  }
}

export class CodexRemoteControlClient {
  constructor({
    apiBaseUrl = DEFAULT_REMOTE_CONTROL_API_BASE_URL,
    authIssuer = DEFAULT_REMOTE_CONTROL_AUTH_ISSUER,
    oauthClientId = DEFAULT_REMOTE_CONTROL_OAUTH_CLIENT_ID,
    desktopOriginator = "Codex Desktop",
    controllerStatePath =
      "/tmp/voice-relay-unconfigured/state/codex-remote-control-client.json",
    globalStatePath = "/tmp/voice-relay-unconfigured/.codex/.codex-global-state.json",
    environmentId = "",
    nativeDeviceKeyPath =
      "/Applications/ChatGPT.app/Contents/Resources/native/remote-control-device-key.node",
    deviceKeyHelperSourcePath =
      "/tmp/voice-relay-unconfigured/Support/CodexRemote/scripts/remote-control-device-key-helper.swift",
    deviceKeyHelperPath =
      "/tmp/voice-relay-unconfigured/state/bin/voice-relay-remote-control-device-key-helper",
    cliPath = "/Applications/ChatGPT.app/Contents/Resources/codex",
    cwd = "/tmp/voice-relay-unconfigured",
    requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    requestTombstoneTtlMs = DEFAULT_REQUEST_TOMBSTONE_TTL_MS,
    requestTombstoneLimit = DEFAULT_REQUEST_TOMBSTONE_LIMIT,
    pairingTimeoutMs = DEFAULT_PAIRING_TIMEOUT_MS,
    fetchImpl = globalThis.fetch,
    WebSocketImpl = globalThis.WebSocket,
    authClient = null,
    deviceKeyClient = null,
    openExternalUrl = defaultOpenExternalUrl,
    now = () => Date.now(),
    randomUuid = randomUUID,
    logger = console,
  } = {}) {
    if (typeof fetchImpl !== "function") {
      throw new Error("Remote control requires a fetch implementation");
    }
    if (typeof WebSocketImpl !== "function") {
      throw new Error("Remote control requires a WebSocket implementation");
    }
    this.apiBaseUrl = String(apiBaseUrl || "").replace(/\/+$/u, "");
    this.authIssuer = String(authIssuer || "").replace(/\/+$/u, "");
    this.oauthClientId = oauthClientId;
    this.desktopOriginator = desktopOriginator;
    this.controllerStatePath = controllerStatePath;
    this.globalStatePath = globalStatePath;
    this.configuredEnvironmentId = String(environmentId || "").trim();
    this.nativeDeviceKeyPath = nativeDeviceKeyPath;
    this.deviceKeyHelperSourcePath = deviceKeyHelperSourcePath;
    this.deviceKeyHelperPath = deviceKeyHelperPath;
    this.cliPath = cliPath;
    this.cwd = cwd;
    this.requestTimeoutMs = positiveNumber(
      requestTimeoutMs,
      DEFAULT_REQUEST_TIMEOUT_MS,
    );
    this.requestTombstoneTtlMs = positiveNumber(
      requestTombstoneTtlMs,
      DEFAULT_REQUEST_TOMBSTONE_TTL_MS,
    );
    this.requestTombstoneLimit = Math.max(
      1,
      Math.floor(
        positiveNumber(
          requestTombstoneLimit,
          DEFAULT_REQUEST_TOMBSTONE_LIMIT,
        ),
      ),
    );
    this.pairingTimeoutMs = positiveNumber(
      pairingTimeoutMs,
      DEFAULT_PAIRING_TIMEOUT_MS,
    );
    this.fetchImpl = fetchImpl;
    this.WebSocketImpl = WebSocketImpl;
    this.authClient =
      authClient ||
      new AppServerJsonlClient({
        cliPath,
        cwd,
        requestTimeoutMs: this.requestTimeoutMs,
      });
    this.deviceKeyClient =
      deviceKeyClient ||
      createMacOSKeychainDeviceKeyClient({
        helperSourcePath: deviceKeyHelperSourcePath,
        helperPath: deviceKeyHelperPath,
      });
    this.openExternalUrl = openExternalUrl;
    this.now = now;
    this.randomUuid = randomUuid;
    this.logger = logger;

    this.events = new EventEmitter();
    this.authInitializePromise = null;
    this.removeAuthExitListener =
      this.authClient.onExit?.(() => {
        this.authInitializePromise = null;
      }) || null;
    this.connectPromise = null;
    this.initializePromise = null;
    this.ws = null;
    this.closed = false;
    this.clientId = null;
    this.environmentId = null;
    this.cursor = null;
    this.streamId = null;
    this.streamGeneration = 0;
    this.nextSequenceId = 1;
    this.nextRequestId = 1;
    this.pending = new Map();
    this.pendingRequestOrder = [];
    this.requestTombstones = new Map();
    this.unresolvedMutationFenceUntilMs = 0;
    this.lateResponseAssemblies = new Map();
    this.lateResponsesDiscarded = 0;
    this.lastLateResponse = null;
    this.unacked = new Map();
    this.serverAssemblies = new Map();
    this.seenServerSequenceId = null;
    this.pendingServerSegmentSequenceId = null;
    this.lastPongAtMs = null;
    this.pingTimer = null;
    this.reconnectTimer = null;
    this.terminalConnectionError = null;
  }

  async health() {
    let enrollment = null;
    try {
      enrollment = await this.readVerifiedEnrollment();
      const environments = await this.listEnvironments();
      const environmentId = await this.resolveEnvironmentId(environments);
      const environment =
        environments.find((entry) => entry?.env_id === environmentId) || null;
      if (
        this.terminalConnectionError &&
        !this.closed &&
        !this.isConnected()
      ) {
        this.scheduleReconnect();
      }
      return {
        ok: Boolean(enrollment && environment?.online),
        transport: "remote-controller",
        paired: Boolean(enrollment),
        reauthRequired: false,
        environmentId,
        environmentOnline: Boolean(environment?.online),
        environmentBusy: Boolean(environment?.busy),
        environmentClientType: environment?.client_type || null,
        connected: this.isConnected(),
        streamGeneration: this.streamGeneration,
        streamInitialized: Boolean(this.streamId && this.initializePromise),
        lateResponsesDiscarded: this.lateResponsesDiscarded,
        lastLateResponse: this.lastLateResponse,
      };
    } catch (error) {
      this.rememberTerminalConnectionError(error);
      return {
        ok: false,
        transport: "remote-controller",
        paired: Boolean(enrollment),
        reauthRequired:
          normalizedRemoteControlErrorCode(error) ===
          "REMOTE_CONTROL_REAUTH_REQUIRED",
        environmentId: this.environmentId || null,
        connected: this.isConnected(),
        streamGeneration: this.streamGeneration,
        streamInitialized: Boolean(this.streamId && this.initializePromise),
        lateResponsesDiscarded: this.lateResponsesDiscarded,
        lastLateResponse: this.lastLateResponse,
        errorCode: normalizedRemoteControlErrorCode(error),
        error: errorMessage(error),
      };
    }
  }

  async start() {
    try {
      return await this.ensurePersistentConnection();
    } catch (error) {
      if (!this.closed && !this.rememberTerminalConnectionError(error)) {
        this.scheduleReconnect();
      }
      throw error;
    }
  }

  async forgetLocalEnrollment() {
    this.close();
    const state = readJsonFile(this.controllerStatePath);
    const keyId = nonEmptyString(state?.enrollment?.keyId);
    let localDeviceKeyDeleted = false;
    if (keyId) {
      try {
        await this.deviceKeyClient.deleteDeviceKey(keyId);
        localDeviceKeyDeleted = true;
      } catch (error) {
        const wrapped = new Error(
          "Remote control local device key could not be deleted: " +
            errorMessage(error),
        );
        wrapped.code = "REMOTE_CONTROL_LOCAL_KEY_DELETE_FAILED";
        throw wrapped;
      }
    }
    fs.rmSync(this.controllerStatePath, { force: true });
    return {
      localEnrollmentCleared: !fs.existsSync(this.controllerStatePath),
      localDeviceKeyDeleted,
      remoteRevocationSupported: false,
    };
  }

  async pair() {
    const existing = await this.readVerifiedEnrollment({ allowMissing: true });
    if (existing) {
      return {
        status: "already_paired",
        paired: true,
      };
    }

    const headers = await this.getAuthHeaders();
    const identity = authIdentityFromHeaders(headers);
    if (!identity.accountUserId) {
      throw new Error(
        "Remote control pairing requires a current ChatGPT account user id",
      );
    }

    const start = await this.apiJson(
      "/codex/remote/control/client/enroll/start",
      {
        method: "POST",
        body: {},
      },
    );
    assertEnrollmentStartIdentity(start, identity);

    const stepUpToken = await requestRemoteControlStepUpToken({
      accountId: identity.accountId,
      authIssuer: this.authIssuer,
      oauthClientId: this.oauthClientId,
      desktopOriginator: this.desktopOriginator,
      timeoutMs: this.pairingTimeoutMs,
      fetchImpl: this.fetchImpl,
      openExternalUrl: this.openExternalUrl,
    });
    validateStepUpToken({
      token: stepUpToken,
      accountUserId: identity.accountUserId,
      nowMs: this.now(),
    });

    const publicKey = await this.deviceKeyClient.createDeviceKey(
      NATIVE_KEY_PROTECTION_CLASS,
    );
    const enrollment = {
      accountUserId: start.account_user_id,
      clientId: start.client_id,
      keyId: publicKey.keyId,
      algorithm: publicKey.algorithm,
      protectionClass: publicKey.protectionClass,
      publicKeySpkiDerBase64: publicKey.publicKeySpkiDerBase64,
    };
    let completed = false;
    try {
      const finish = await this.apiJson(
        "/codex/remote/control/client/enroll/finish",
        {
          method: "POST",
          body: {
            client_id: enrollment.clientId,
            step_up_token: stepUpToken,
            device_identity: deviceIdentityBody(enrollment),
            device_key_proof: await this.signEnrollmentChallenge({
              challenge: start.device_key_challenge,
              enrollment,
              expectedPath: "/codex/remote/control/client/enroll/finish",
              requireDeviceIdentityHash: false,
            }),
          },
        },
      );
      validateRemoteControlToken(finish, enrollment, this.now);
      this.writeControllerState({
        version: 1,
        enrollment,
        apiBaseUrl: this.apiBaseUrl,
        desktopOriginator: this.desktopOriginator,
        createdAt: new Date(this.now()).toISOString(),
        updatedAt: new Date(this.now()).toISOString(),
      });
      completed = true;
      return {
        status: "paired",
        paired: true,
      };
    } finally {
      if (!completed) {
        await Promise.resolve(
          this.deviceKeyClient.deleteDeviceKey(enrollment.keyId),
        ).catch(() => {});
      }
    }
  }

  async claimEnvironmentPairing(manualPairingCode) {
    const enrollment = await this.readVerifiedEnrollment();
    const environmentId = await this.resolveEnvironmentId();
    const response = await this.apiJson(
      "/wham/remote/control/client/pair",
      {
        method: "POST",
        body: {
          client_id: enrollment.clientId,
          manual_pairing_code:
            normalizeManualPairingCode(manualPairingCode),
        },
      },
    );
    const claimedEnvironmentId = String(
      response?.environment_id || "",
    ).trim();
    if (!claimedEnvironmentId) {
      throw new Error(
        "Remote control host pairing returned no environment id",
      );
    }
    if (claimedEnvironmentId !== environmentId) {
      const error = new Error(
        "Remote control pairing claimed a different GPT app environment",
      );
      error.code = "REMOTE_CONTROL_ENVIRONMENT_MISMATCH";
      throw error;
    }
    const environments = await this.listEnvironments();
    const environment = environments.find(
      (entry) => entry?.env_id === environmentId,
    );
    if (!environment) {
      throw new Error(
        "Remote control host pairing was not visible to the controller",
      );
    }
    return {
      environmentId,
      environmentOnline: Boolean(environment.online),
    };
  }

  async request(
    method,
    params = undefined,
    {
      timeoutMs = this.requestTimeoutMs,
      requestMetadata = null,
      signal = null,
    } = {},
  ) {
    throwIfAborted(signal);
    const normalizedTimeoutMs = positiveNumber(
      timeoutMs,
      this.requestTimeoutMs,
    );
    const configuredAttemptDeadlineAtMs = finiteNumberOrNull(
      requestMetadata?.attemptDeadlineAtMs,
    );
    const attemptDeadlineAtMs =
      configuredAttemptDeadlineAtMs ?? this.now() + normalizedTimeoutMs;
    const effectiveRequestMetadata = {
      ...(normalizeRequestMetadata(requestMetadata) || {}),
      deadlineAtMs:
        finiteNumberOrNull(requestMetadata?.deadlineAtMs) ??
        attemptDeadlineAtMs,
      attemptDeadlineAtMs,
    };
    const createPreDispatchTimeout = () =>
      preDispatchTimeoutError({
        method,
        timeoutMs: normalizedTimeoutMs,
        requestMetadata: effectiveRequestMetadata,
        streamId: this.streamId,
        streamGeneration: this.streamGeneration,
      });
    await waitForOperationDeadline(this.ensureConnected(), {
      deadlineAtMs: attemptDeadlineAtMs,
      now: this.now,
      signal,
      timeoutError: createPreDispatchTimeout,
    });
    throwIfAborted(signal);
    const initializeTimeoutMs = remainingRequestTimeoutMs({
      timeoutMs: normalizedTimeoutMs,
      requestMetadata: effectiveRequestMetadata,
      nowMs: this.now(),
    });
    if (initializeTimeoutMs <= 0) {
      throw createPreDispatchTimeout();
    }
    await waitForOperationDeadline(
      this.ensureInitialized({ timeoutMs: initializeTimeoutMs }),
      {
        deadlineAtMs: attemptDeadlineAtMs,
        now: this.now,
        signal,
        timeoutError: createPreDispatchTimeout,
      },
    );
    throwIfAborted(signal);
    const rawTimeoutMs = remainingRequestTimeoutMs({
      timeoutMs: normalizedTimeoutMs,
      requestMetadata: effectiveRequestMetadata,
      nowMs: this.now(),
    });
    if (rawTimeoutMs <= 0) {
      throw createPreDispatchTimeout();
    }
    return this.rawRequest(method, params, {
      timeoutMs: rawTimeoutMs,
      requestMetadata: effectiveRequestMetadata,
      signal,
    });
  }

  async notify(method, params = undefined) {
    await this.ensureConnected();
    await this.ensureInitialized();
    this.sendJsonRpc(params === undefined ? { method } : { method, params });
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

  onLateResponse(listener) {
    this.events.on("late-response", listener);
    return () => this.events.off("late-response", listener);
  }

  onStreamInitialized(listener) {
    this.events.on("stream-initialized", listener);
    return () => this.events.off("stream-initialized", listener);
  }

  async ensureInitialized({ timeoutMs = this.requestTimeoutMs } = {}) {
    if (!this.initializePromise) {
      this.initializePromise = (async () => {
        await this.ensureConnected();
        await this.rawRequest(
          "initialize",
          {
            clientInfo: {
              name: "voice_relay_remote_controller",
              title: "Voice Relay Remote Controller",
              version: "0.1.0",
            },
            capabilities: {
              experimentalApi: true,
              requestAttestation: false,
            },
          },
          { timeoutMs, resetStream: true },
        );
        this.sendJsonRpc({ method: "initialized" });
        this.emitStreamInitialized();
      })().catch((error) => {
        this.initializePromise = null;
        throw error;
      });
    }
    return this.initializePromise;
  }

  async prepareReadOnlyRetry({
    method,
    timeoutMs = this.requestTimeoutMs,
    signal = null,
  } = {}) {
    throwIfAborted(signal);
    if (method !== "thread/read" && method !== "thread/turns/list") {
      return {
        reset: false,
        reason: "method_not_allowlisted",
        streamId: this.streamId,
        streamGeneration: this.streamGeneration,
      };
    }
    if (!this.isConnected()) {
      return {
        reset: false,
        reason: "transport_not_connected",
        streamId: this.streamId,
        streamGeneration: this.streamGeneration,
      };
    }
    const pendingMethods = [...this.pending.values()].map(
      (entry) => entry.method,
    );
    const pendingUnsafeMethods = pendingMethods.filter(
      (entry) => !isSafeToDiscardForReadRecovery(entry),
    );
    const unackedUnsafeMethods = [...this.unacked.values()]
      .map((entry) => entry?.envelope?.message?.method)
      .filter((entry) => entry && !isSafeToDiscardForReadRecovery(entry));
    this.pruneRequestTombstones();
    const unresolvedMutationTimeouts = [...this.requestTombstones.values()]
      .map((entry) => entry.method)
      .filter((entry) => !isSafeToDiscardForReadRecovery(entry));
    const unresolvedMutationFenceActive =
      this.unresolvedMutationFenceUntilMs > this.now();
    if (
      pendingMethods.length ||
      unackedUnsafeMethods.length ||
      unresolvedMutationTimeouts.length ||
      unresolvedMutationFenceActive
    ) {
      return {
        reset: false,
        reason:
          pendingUnsafeMethods.length ||
          unackedUnsafeMethods.length ||
          unresolvedMutationTimeouts.length ||
          unresolvedMutationFenceActive
          ? "unrelated_pending_mutation"
          : "unrelated_pending_request",
        pendingMethods,
        pendingUnsafeMethods,
        unackedUnsafeMethods,
        unresolvedMutationTimeouts,
        unresolvedMutationFenceUntilMs: this.unresolvedMutationFenceUntilMs,
        streamId: this.streamId,
        streamGeneration: this.streamGeneration,
      };
    }
    const previousStreamId = this.streamId;
    const previousStreamGeneration = this.streamGeneration;
    this.initializePromise = null;
    throwIfAborted(signal);
    await this.ensureInitialized({ timeoutMs });
    throwIfAborted(signal);
    return {
      reset: true,
      reason: "fresh_initialized_stream",
      previousStreamId,
      previousStreamGeneration,
      streamId: this.streamId,
      streamGeneration: this.streamGeneration,
    };
  }

  async ensureConnected() {
    if (this.closed) {
      throw new Error("Remote control client is closed");
    }
    if (this.isConnected()) return;
    if (!this.connectPromise) {
      this.connectPromise = this.connect().finally(() => {
        this.connectPromise = null;
      });
    }
    return this.connectPromise;
  }

  async ensurePersistentConnection() {
    await this.ensureConnected();
    if (!this.streamId || !this.initializePromise) {
      await this.ensureInitialized();
    } else {
      await this.initializePromise;
    }
    return {
      status: "ready",
      transport: "remote-controller",
      connected: this.isConnected(),
      streamInitialized: Boolean(this.streamId && this.initializePromise),
      streamGeneration: this.streamGeneration,
      environmentId: this.environmentId,
    };
  }

  async connect() {
    const enrollmentSession = await this.refreshEnrollment();
    const environments = await this.listEnvironments();
    const environmentId = await this.resolveEnvironmentId(environments);
    const environment = environments.find(
      (entry) => entry?.env_id === environmentId,
    );
    if (!environment?.online) {
      throw remoteEnvironmentUnavailableError(
        "The current GPT app Remote environment is offline",
      );
    }

    const authHeaders = await this.getAuthHeaders();
    const headers = {
      ...authHeaders,
      "x-codex-client-session-token":
        "Bearer " + enrollmentSession.remoteControlToken,
      "x-codex-client-id": enrollmentSession.clientId,
      "x-codex-protocol-version": String(REMOTE_CONTROL_PROTOCOL_VERSION),
    };
    if (this.cursor) {
      headers["x-codex-subscribe-cursor"] = this.cursor;
    }

    const ws = new this.WebSocketImpl(this.webSocketUrl(), {
      headers,
      perMessageDeflate: false,
    });
    await this.authorizeWebSocket({
      ws,
      enrollment: enrollmentSession.enrollment,
      clientId: enrollmentSession.clientId,
      remoteControlToken: enrollmentSession.remoteControlToken,
      tokenExpiresAt: enrollmentSession.tokenExpiresAt,
      scopes: enrollmentSession.scopes,
    });

    this.ws = ws;
    this.clientId = enrollmentSession.clientId;
    this.environmentId = environmentId;
    this.lastPongAtMs = this.now();
    this.terminalConnectionError = null;
    this.installWebSocketHandlers(ws);
    this.replayUnacked();
    if (this.streamId) this.sendPing();
    this.startPingTimer();
  }

  async authorizeWebSocket({
    ws,
    enrollment,
    clientId,
    remoteControlToken,
    tokenExpiresAt,
    scopes,
    webSocketOpenTimeoutMs = WEBSOCKET_OPEN_TIMEOUT_MS,
    deviceKeyChallengeTimeoutMs = DEVICE_KEY_CHALLENGE_TIMEOUT_MS,
  }) {
    const authorizationStartedAtMs = this.now();
    let webSocketOpenedAtMs = null;
    try {
      const challengePromise = waitForDeviceKeyChallenge(
        ws,
        deviceKeyChallengeTimeoutMs,
      );
      const openPromise = waitForWebSocketOpen(
        ws,
        webSocketOpenTimeoutMs,
      ).then(() => {
        webSocketOpenedAtMs = this.now();
      });
      const [challenge] = await Promise.all([
        challengePromise,
        openPromise,
      ]);
      validateConnectionChallenge({
        challenge,
        enrollment,
        clientId,
        webSocketUrl: this.webSocketUrl(),
        remoteControlToken,
        tokenExpiresAt,
        scopes,
        nowMs: this.now(),
      });
      const signature = await this.deviceKeyClient.signDeviceKey(
        enrollment.keyId,
        {
          type: "remoteControlClientConnection",
          nonce: challenge.nonce,
          audience: challenge.audience,
          sessionId: challenge.sessionId,
          targetOrigin: challenge.targetOrigin,
          targetPath: challenge.targetPath,
          accountUserId: challenge.accountUserId,
          clientId: challenge.clientId,
          tokenSha256Base64url: challenge.tokenSha256Base64url,
          tokenExpiresAt: challenge.tokenExpiresAt,
          scopes: challenge.scopes,
        },
      );
      ws.send(
        JSON.stringify({
          type: "device_key_proof",
          keyId: enrollment.keyId,
          signatureDerBase64: signature.signatureDerBase64,
          signedPayloadBase64: signature.signedPayloadBase64,
          algorithm: signature.algorithm,
        }),
      );
      const authorizedAtMs = this.now();
      this.logger?.info?.(
        new Date(authorizedAtMs).toISOString() +
          " remote controller websocket device-key proof sent" +
          " openMs=" +
          String(
            Math.max(
              0,
              (webSocketOpenedAtMs ?? authorizedAtMs) -
                authorizationStartedAtMs,
            ),
          ) +
          " challengeAndProofMs=" +
          String(
            Math.max(
              0,
              authorizedAtMs - (webSocketOpenedAtMs ?? authorizedAtMs),
            ),
          ),
      );
    } catch (error) {
      const failedAtMs = this.now();
      const stage =
        webSocketOpenedAtMs === null
          ? "websocket_open"
          : "device_key_authorization";
      this.logger?.warn?.(
        new Date(failedAtMs).toISOString() +
          " remote controller websocket authorization failed" +
          " stage=" +
          stage +
          " elapsedMs=" +
          String(Math.max(0, failedAtMs - authorizationStartedAtMs)) +
          ": " +
          errorMessage(error),
      );
      if (typeof ws?.close === "function") {
        try {
          ws.close();
        } catch (closeError) {
          this.logger?.warn?.(
            new Date(this.now()).toISOString() +
              " remote controller websocket close after authorization failure failed: " +
              errorMessage(closeError),
          );
        }
      }
      throw error;
    }
  }

  installWebSocketHandlers(ws) {
    ws.addEventListener("message", (event) => {
      if (this.ws !== ws) return;
      Promise.resolve(webSocketMessageText(event.data))
        .then((text) => this.handleEnvelopeText(text))
        .catch((error) => this.handleEnvelopeError(error));
    });
    ws.addEventListener("close", () => {
      if (this.ws !== ws) return;
      this.ws = null;
      this.stopPingTimer();
      if (!this.closed) this.scheduleReconnect();
    });
    ws.addEventListener("error", (event) => {
      if (this.ws !== ws) return;
      this.logger.warn?.(
        new Date(this.now()).toISOString() +
          " remote controller websocket error: " +
          errorMessage(event?.error || event),
      );
    });
  }

  handleEnvelopeError(error) {
    if (isRemoteControlStreamGapError(error)) {
      this.resetLostStream(error);
      return;
    }
    this.forceReconnect(error);
  }

  handleEnvelopeText(text) {
    let envelope;
    try {
      envelope = JSON.parse(text);
    } catch {
      throw new Error("Remote control websocket returned malformed JSON");
    }
    if (!envelope || typeof envelope !== "object" || Array.isArray(envelope)) {
      throw new Error("Remote control websocket returned an invalid envelope");
    }
    if (envelope.type === "device_key_challenge") return;
    if (
      envelope.type === "server_message_chunk" &&
      !isValidServerMessageChunkEnvelope(envelope)
    ) {
      if (
        envelope.client_id === this.clientId &&
        this.streamId &&
        (envelope.env_id !== this.environmentId ||
          envelope.stream_id !== this.streamId)
      ) {
        this.observeForeignStreamLateResponse(envelope);
      }
      this.logger.warn?.(
        new Date(this.now()).toISOString() +
          " remote controller ignored malformed server message chunk",
      );
      return;
    }
    if (envelope.client_id !== this.clientId) {
      throw new Error("Remote control websocket client id mismatch");
    }
    const isStreamEnvelope =
      envelope.type === "ack" ||
      envelope.type === "pong" ||
      envelope.type === "server_message" ||
      envelope.type === "server_message_chunk";
    if (isStreamEnvelope) {
      if (
        !this.streamId ||
        envelope.env_id !== this.environmentId ||
        envelope.stream_id !== this.streamId
      ) {
        this.observeForeignStreamLateResponse(envelope);
        return;
      }
    } else if (
      envelope.env_id &&
      this.environmentId &&
      envelope.env_id !== this.environmentId
    ) {
      throw new Error("Remote control websocket environment id mismatch");
    }
    if (envelope.type === "ack") {
      this.handleAck(envelope);
      return;
    }
    if (envelope.type === "pong") {
      this.handlePong(envelope);
      return;
    }
    if (
      envelope.type !== "server_message" &&
      envelope.type !== "server_message_chunk"
    ) {
      throw new Error("Remote control websocket returned an unsupported envelope");
    }
    const complete = this.observeServerEnvelope(envelope);
    if (!complete) return;
    this.handleServerMessage(complete.message, {
      streamId: complete.stream_id,
      streamGeneration: this.streamGeneration,
    });
    this.seenServerSequenceId = complete.seq_id;
    if (complete.cursor != null) this.cursor = complete.cursor;
  }

  observeServerEnvelope(envelope) {
    const sequenceId = safeNonNegativeInteger(envelope.seq_id);
    if (sequenceId === null) {
      throw remoteControlStreamGapError(
        "Remote control server sequence id is invalid",
      );
    }
    if (
      this.seenServerSequenceId !== null &&
      sequenceId <= this.seenServerSequenceId
    ) {
      return null;
    }
    if (
      this.seenServerSequenceId !== null &&
      sequenceId > this.seenServerSequenceId + 1
    ) {
      throw remoteControlStreamGapError(
        "Remote control server sequence gap detected",
        {
          source: "server_envelope",
          expectedSequenceId: this.seenServerSequenceId + 1,
          actualSequenceId: sequenceId,
        },
      );
    }
    if (envelope.type === "server_message") {
      if (
        this.pendingServerSegmentSequenceId !== null &&
        sequenceId > this.pendingServerSegmentSequenceId
      ) {
        throw remoteControlStreamGapError(
          "Remote control server segment gap detected",
        );
      }
      return envelope;
    }

    const segmentId = safeNonNegativeInteger(envelope.segment_id);
    const segmentCount = safePositiveInteger(envelope.segment_count);
    const messageSizeBytes = safePositiveInteger(envelope.message_size_bytes);
    if (
      segmentId === null ||
      segmentCount === null ||
      segmentCount > SERVER_MESSAGE_ASSEMBLY_MAX_SEGMENTS ||
      segmentId >= segmentCount ||
      messageSizeBytes === null ||
      messageSizeBytes > MAX_REASSEMBLED_MESSAGE_BYTES
    ) {
      throw remoteControlStreamGapError(
        "Remote control server segment metadata is invalid",
      );
    }
    const key =
      String(envelope.env_id) +
      ":" +
      String(envelope.stream_id) +
      ":" +
      String(sequenceId);
    let assembly = this.serverAssemblies.get(key);
    if (!assembly) {
      if (
        this.pendingServerSegmentSequenceId !== null &&
        sequenceId > this.pendingServerSegmentSequenceId
      ) {
        throw remoteControlStreamGapError(
          "Remote control server segment gap detected",
        );
      }
      if (segmentId !== 0) {
        throw remoteControlStreamGapError(
          "Remote control server segment gap detected",
        );
      }
      assembly = {
        first: envelope,
        segmentCount,
        messageSizeBytes,
        chunks: Array(segmentCount).fill(null),
        nextSegmentId: 0,
      };
      this.serverAssemblies.set(key, assembly);
      this.pendingServerSegmentSequenceId = sequenceId;
    }
    if (
      assembly.segmentCount !== segmentCount ||
      assembly.messageSizeBytes !== messageSizeBytes
    ) {
      this.serverAssemblies.delete(key);
      throw remoteControlStreamGapError(
        "Remote control server segment metadata changed",
      );
    }
    if (segmentId < assembly.nextSegmentId) return null;
    if (segmentId > assembly.nextSegmentId) {
      throw remoteControlStreamGapError(
        "Remote control server segment gap detected",
      );
    }
    assembly.chunks[segmentId] = String(
      envelope.message_chunk_base64 || "",
    );
    assembly.nextSegmentId += 1;
    if (assembly.chunks.some((chunk) => chunk == null)) return null;
    this.serverAssemblies.delete(key);
    this.pendingServerSegmentSequenceId = null;
    const payload = Buffer.concat(
      assembly.chunks.map((chunk) => Buffer.from(chunk, "base64")),
    );
    if (payload.length !== messageSizeBytes) {
      throw remoteControlStreamGapError(
        "Remote control server segment size mismatch",
      );
    }
    let message;
    try {
      message = JSON.parse(payload.toString("utf8"));
    } catch {
      throw remoteControlStreamGapError(
        "Remote control server reassembled message is invalid",
      );
    }
    return {
      type: "server_message",
      client_id: envelope.client_id,
      env_id: envelope.env_id,
      stream_id: envelope.stream_id,
      seq_id: sequenceId,
      cursor: envelope.cursor,
      message,
    };
  }

  handleServerMessage(
    message,
    {
      streamId = this.streamId,
      streamGeneration = this.streamGeneration,
    } = {},
  ) {
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      return;
    }
    if (
      Object.hasOwn(message, "id") &&
      (Object.hasOwn(message, "result") || Object.hasOwn(message, "error"))
    ) {
      const key = String(message.id);
      const pending = this.pending.get(key);
      if (!pending) {
        this.observeLateResponse(key, { streamId, streamGeneration });
        return;
      }
      if (
        pending.streamId !== streamId ||
        pending.streamGeneration !== streamGeneration
      ) {
        this.logger.warn?.(
          new Date(this.now()).toISOString() +
            " remote controller discarded a response from a stale stream generation",
        );
        return;
      }
      this.removePendingRequest(key, pending);
      if (message.error) {
        pending.reject(
          new Error(formatRpcError(pending.method, message.error)),
        );
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (message.type === "error") {
      const key = this.pendingRequestOrder.shift() || null;
      const pending = key ? this.pending.get(key) : null;
      if (!pending) return;
      this.removePendingRequest(key, pending);
      pending.reject(new Error(formatRpcError(pending.method, message)));
      return;
    }
    const pairingError = remoteEnvironmentPairingNotificationError(message);
    if (pairingError) {
      const key = this.pendingRequestOrder.shift() || null;
      const pending = key ? this.pending.get(key) : null;
      if (!pending) {
        this.events.emit("notification", message);
        return;
      }
      this.removePendingRequest(key, pending);
      pending.reject(pairingError);
      return;
    }
    if (message.method && Object.hasOwn(message, "id")) {
      this.sendJsonRpc({
        id: message.id,
        error: {
          code: -32601,
          message: "Unsupported controller request: " + message.method,
        },
      });
      return;
    }
    if (message.method) {
      this.events.emit("notification", message);
    }
  }

  rawRequest(
    method,
    params = undefined,
    {
      timeoutMs = this.requestTimeoutMs,
      resetStream = false,
      requestMetadata = null,
      signal = null,
    } = {},
  ) {
    throwIfAborted(signal);
    if (resetStream) this.resetStreamForInitialize();
    this.ensureStreamIdentity();
    const normalizedTimeoutMs = positiveNumber(
      timeoutMs,
      this.requestTimeoutMs,
    );
    return new Promise((resolve, reject) => {
      const id = this.nextRequestId++;
      const key = String(id);
      const pending = {
        id,
        method,
        resolve,
        reject,
        timer: null,
        streamId: this.streamId,
        streamGeneration: this.streamGeneration,
        requestMetadata: normalizeRequestMetadata(requestMetadata),
        envelopeKey: null,
        removeAbortListener: null,
        cleanup: null,
      };
      pending.cleanup = () => this.removePendingRequest(key, pending);
      const createTimeoutError = () =>
        new RemoteControllerRequestTimeoutError({
          method,
          requestId: id,
          streamId: pending.streamId,
          streamGeneration: pending.streamGeneration,
          timeoutMs: normalizedTimeoutMs,
          requestMetadata: pending.requestMetadata,
        });
      const settleTimedOut = (reason = null) => {
        if (!pending.cleanup()) return;
        let error;
        if (
          reason instanceof RemoteControllerRequestTimeoutError &&
          reason.method === method
        ) {
          error = reason;
          error.requestId = id;
          error.streamId = pending.streamId;
          error.streamGeneration = pending.streamGeneration;
          error.timeoutMs = normalizedTimeoutMs;
          error.requestMetadata = pending.requestMetadata;
        } else {
          error = createTimeoutError();
          if (reason instanceof Error) error.cause = reason;
          error.aborted = reason !== null;
        }
        this.rememberRequestTombstone(error);
        if (
          reason !== null &&
          !(reason instanceof RemoteControllerRequestTimeoutError)
        ) {
          reject(reason instanceof Error ? reason : error);
          return;
        }
        reject(error);
      };
      const timer = setTimeout(() => {
        settleTimedOut();
      }, normalizedTimeoutMs);
      timer.unref?.();
      pending.timer = timer;
      this.pending.set(key, pending);
      this.pendingRequestOrder.push(key);
      if (signal) {
        const onAbort = () => settleTimedOut(signal.reason);
        signal.addEventListener("abort", onAbort, { once: true });
        pending.removeAbortListener = () =>
          signal.removeEventListener("abort", onAbort);
      }
      try {
        const envelope = this.sendJsonRpc(
          params === undefined ? { id, method } : { id, method, params },
        );
        pending.envelopeKey = envelopeKey(envelope);
      } catch (error) {
        pending.cleanup();
        reject(error);
      }
    });
  }

  removePendingRequest(key, pending) {
    if (this.pending.get(String(key)) !== pending) return false;
    this.pending.delete(String(key));
    this.pendingRequestOrder = this.pendingRequestOrder.filter(
      (entry) => entry !== String(key),
    );
    clearTimeout(pending.timer);
    pending.removeAbortListener?.();
    pending.removeAbortListener = null;
    if (pending.envelopeKey) this.unacked.delete(pending.envelopeKey);
    return true;
  }

  sendJsonRpc(message) {
    if (!this.isConnected()) {
      throw new Error("Remote control websocket is not connected");
    }
    this.ensureStreamIdentity();
    const envelope = {
      type: "client_message",
      client_id: this.clientId,
      seq_id: this.nextSequenceId++,
      stream_id: this.streamId,
      env_id: this.environmentId,
      skip_history: false,
      message,
    };
    const key = envelopeKey(envelope);
    this.unacked.set(key, {
      envelope,
      acknowledgedSegments: new Set(),
      segmentCount: null,
    });
    try {
      this.sendEnvelope(envelope);
    } catch (error) {
      this.unacked.delete(key);
      throw error;
    }
    return envelope;
  }

  sendEnvelope(envelope) {
    if (!this.isConnected()) {
      throw new Error("Remote control websocket is not connected");
    }
    const segments = segmentClientEnvelope(envelope);
    const state = this.unacked.get(envelopeKey(envelope));
    if (state) state.segmentCount = segments.length;
    for (const segment of segments) {
      this.ws.send(JSON.stringify(segment));
    }
  }

  replayUnacked() {
    for (const state of this.unacked.values()) {
      this.sendEnvelope(state.envelope);
    }
  }

  handleAck(envelope) {
    const state = this.unacked.get(envelopeKey(envelope));
    if (state) {
      const segmentCount = state.segmentCount || 1;
      if (segmentCount > 1) {
        const segmentId = safeNonNegativeInteger(envelope.segment_id);
        if (segmentId !== null && segmentId < segmentCount) {
          state.acknowledgedSegments.add(segmentId);
        }
      }
    }
    const acknowledgedSequenceId = safeNonNegativeInteger(envelope.seq_id);
    if (acknowledgedSequenceId === null) return;
    const streamId = String(envelope.stream_id || "");
    for (const [key, candidate] of this.unacked) {
      if (String(candidate.envelope.stream_id || "") !== streamId) continue;
      if (candidate.envelope.seq_id > acknowledgedSequenceId) continue;
      const segmentCount = candidate.segmentCount || 1;
      if (
        segmentCount > 1 &&
        candidate.acknowledgedSegments.size < segmentCount
      ) {
        break;
      }
      this.unacked.delete(key);
    }
  }

  handlePong(envelope) {
    if (envelope.status === "unknown") {
      this.resetLostStream(
        new Error("Remote control app-server stream became unknown"),
      );
      return;
    }
    const sequenceId = safeNonNegativeInteger(envelope.seq_id);
    if (
      sequenceId !== null &&
      ((this.pendingServerSegmentSequenceId !== null &&
        sequenceId > this.pendingServerSegmentSequenceId) ||
        (this.seenServerSequenceId !== null &&
          sequenceId > this.seenServerSequenceId + 1))
    ) {
      const expectedSequenceId =
        this.pendingServerSegmentSequenceId !== null &&
        sequenceId > this.pendingServerSegmentSequenceId
          ? this.pendingServerSegmentSequenceId
          : this.seenServerSequenceId + 1;
      this.resetLostStream(
        remoteControlStreamGapError(
          "Remote control server sequence gap detected",
          {
            source: "pong",
            expectedSequenceId,
            actualSequenceId: sequenceId,
          },
        ),
      );
      return;
    }
    let acceptedSequence = false;
    if (
      sequenceId !== null &&
      (this.seenServerSequenceId === null ||
        sequenceId > this.seenServerSequenceId)
    ) {
      this.seenServerSequenceId = sequenceId;
      acceptedSequence = true;
    }
    if (acceptedSequence && envelope.cursor != null) {
      this.cursor = envelope.cursor;
    }
    this.lastPongAtMs = this.now();
  }

  sendPing() {
    if (!this.isConnected() || !this.streamId) return;
    const envelope = {
      type: "ping",
      client_id: this.clientId,
      seq_id: this.nextSequenceId++,
      stream_id: this.streamId,
      env_id: this.environmentId,
      state: "foreground",
      skip_history: true,
    };
    this.unacked.set(envelopeKey(envelope), {
      envelope,
      acknowledgedSegments: new Set(),
      segmentCount: 1,
    });
    this.ws.send(JSON.stringify(envelope));
  }

  startPingTimer() {
    if (this.pingTimer) return;
    this.pingTimer = setInterval(() => {
      if (
        this.lastPongAtMs &&
        this.now() - this.lastPongAtMs >= STREAM_PONG_TIMEOUT_MS
      ) {
        this.forceReconnect(
          new Error("Remote control app-server stream pong timed out"),
        );
        return;
      }
      this.sendPing();
    }, STREAM_PING_INTERVAL_MS);
    this.pingTimer.unref?.();
  }

  stopPingTimer() {
    if (!this.pingTimer) return;
    clearInterval(this.pingTimer);
    this.pingTimer = null;
  }

  scheduleReconnect() {
    if (this.closed || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.ensurePersistentConnection().catch((error) => {
        this.logger.warn?.(
          new Date(this.now()).toISOString() +
            " remote controller reconnect failed: " +
            errorMessage(error),
        );
        if (!this.rememberTerminalConnectionError(error)) {
          this.scheduleReconnect();
        }
      });
    }, RECONNECT_DELAY_MS);
    this.reconnectTimer.unref?.();
  }

  emitStreamInitialized() {
    const event = {
      environmentId: this.environmentId,
      streamId: this.streamId,
      streamGeneration: this.streamGeneration,
    };
    for (const listener of this.events.listeners("stream-initialized")) {
      try {
        listener(event);
      } catch (error) {
        this.logger.warn?.(
          new Date(this.now()).toISOString() +
            " remote controller stream-initialized listener failed: " +
            errorMessage(error),
        );
      }
    }
  }

  forceReconnect(error) {
    const ws = this.ws;
    this.ws = null;
    this.stopPingTimer();
    try {
      ws?.close();
    } catch {}
    if (!this.closed) {
      this.logger.warn?.(
        new Date(this.now()).toISOString() +
          " remote controller reconnecting: " +
          errorMessage(error),
      );
      if (!this.rememberTerminalConnectionError(error)) {
        this.scheduleReconnect();
      }
    }
  }

  rememberTerminalConnectionError(error) {
    if (!isTerminalRemoteControlConnectionError(error)) return false;
    this.terminalConnectionError = error;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    return true;
  }

  resetLostStream(error) {
    this.rejectAllPending(error);
    this.initializePromise = null;
    this.cursor = null;
    this.streamId = null;
    this.nextSequenceId = 1;
    this.unacked.clear();
    this.serverAssemblies.clear();
    this.seenServerSequenceId = null;
    this.pendingServerSegmentSequenceId = null;
    this.forceReconnect(error);
  }

  resetStreamForInitialize() {
    this.streamId = this.randomUuid();
    this.streamGeneration += 1;
    this.nextSequenceId = 1;
    this.unacked.clear();
    this.serverAssemblies.clear();
    this.seenServerSequenceId = null;
    this.pendingServerSegmentSequenceId = null;
    this.lastPongAtMs = this.now();
  }

  ensureStreamIdentity() {
    if (this.streamId) return;
    this.streamId = this.randomUuid();
    this.streamGeneration += 1;
  }

  rememberRequestTombstone(error) {
    this.pruneRequestTombstones();
    const key = String(error.requestId);
    this.requestTombstones.delete(key);
    this.requestTombstones.set(key, {
      code: error.code,
      method: error.method,
      requestId: error.requestId,
      streamId: error.streamId,
      streamGeneration: error.streamGeneration,
      phase: error.phase,
      attempt: error.attempt,
      timedOutAtMs: this.now(),
      expiresAtMs: this.now() + this.requestTombstoneTtlMs,
    });
    if (!isSafeToDiscardForReadRecovery(error.method)) {
      this.unresolvedMutationFenceUntilMs = Math.max(
        this.unresolvedMutationFenceUntilMs,
        this.now() + this.requestTombstoneTtlMs,
      );
    }
    while (this.requestTombstones.size > this.requestTombstoneLimit) {
      const oldest = this.requestTombstones.keys().next().value;
      if (oldest === undefined) break;
      this.requestTombstones.delete(oldest);
    }
  }

  pruneRequestTombstones() {
    const nowMs = this.now();
    for (const [key, tombstone] of this.requestTombstones) {
      if (tombstone.expiresAtMs > nowMs) continue;
      this.requestTombstones.delete(key);
    }
  }

  observeForeignStreamLateResponse(envelope) {
    if (envelope?.env_id !== this.environmentId) return;
    if (envelope.type === "server_message") {
      if (!Object.hasOwn(envelope?.message || {}, "id")) return;
      this.observeLateResponse(String(envelope.message.id), {
        streamId: envelope.stream_id,
        streamGeneration: null,
      });
      return;
    }
    if (envelope.type === "server_message_chunk") {
      this.observeForeignStreamLateChunk(envelope);
    }
  }

  observeForeignStreamLateChunk(envelope) {
    this.pruneRequestTombstones();
    this.pruneLateResponseAssemblies();
    const candidates = [...this.requestTombstones.values()].filter(
      (entry) => entry.streamId === envelope.stream_id,
    );
    if (!candidates.length) return;
    const segmentId = safeNonNegativeInteger(envelope.segment_id);
    const segmentCount = safePositiveInteger(envelope.segment_count);
    const messageSizeBytes = safePositiveInteger(envelope.message_size_bytes);
    const key =
      String(envelope.env_id) +
      ":" +
      String(envelope.stream_id) +
      ":" +
      String(envelope.seq_id);
    if (
      segmentId === null ||
      segmentCount === null ||
      segmentCount > LATE_RESPONSE_ASSEMBLY_MAX_SEGMENTS ||
      segmentId >= segmentCount ||
      messageSizeBytes === null ||
      messageSizeBytes > LATE_RESPONSE_ASSEMBLY_MAX_BYTES
    ) {
      if (segmentId === 0 || segmentId === null) {
        this.emitLateSegmentedDiscard(candidates, envelope);
      }
      return;
    }
    let assembly = this.lateResponseAssemblies.get(key);
    if (!assembly) {
      if (segmentId !== 0) {
        this.emitLateSegmentedDiscard(candidates, envelope);
        return;
      }
      while (
        this.lateResponseAssemblies.size >= LATE_RESPONSE_ASSEMBLY_LIMIT
      ) {
        const oldest = this.lateResponseAssemblies.keys().next().value;
        if (oldest === undefined) break;
        this.lateResponseAssemblies.delete(oldest);
      }
      assembly = {
        segmentCount,
        messageSizeBytes,
        chunks: Array(segmentCount).fill(null),
        decodedBytes: 0,
        nextSegmentId: 0,
        expiresAtMs: this.now() + this.requestTombstoneTtlMs,
      };
      this.lateResponseAssemblies.set(key, assembly);
    }
    if (
      assembly.segmentCount !== segmentCount ||
      assembly.messageSizeBytes !== messageSizeBytes ||
      segmentId !== assembly.nextSegmentId
    ) {
      this.lateResponseAssemblies.delete(key);
      this.emitLateSegmentedDiscard(candidates, envelope);
      return;
    }
    const encodedChunk = String(envelope.message_chunk_base64 || "");
    const remainingBytes = Math.min(
      LATE_RESPONSE_ASSEMBLY_MAX_BYTES,
      assembly.messageSizeBytes,
    ) - assembly.decodedBytes;
    const maxEncodedChars = Math.ceil(Math.max(0, remainingBytes) / 3) * 4 + 4;
    if (encodedChunk.length > maxEncodedChars) {
      this.lateResponseAssemblies.delete(key);
      this.emitLateSegmentedDiscard(candidates, envelope);
      return;
    }
    const decodedChunk = Buffer.from(encodedChunk, "base64");
    if (decodedChunk.length > remainingBytes) {
      this.lateResponseAssemblies.delete(key);
      this.emitLateSegmentedDiscard(candidates, envelope);
      return;
    }
    assembly.chunks[segmentId] = decodedChunk;
    assembly.decodedBytes += decodedChunk.length;
    assembly.nextSegmentId += 1;
    if (assembly.nextSegmentId < assembly.segmentCount) return;
    this.lateResponseAssemblies.delete(key);
    const payload = Buffer.concat(assembly.chunks, assembly.decodedBytes);
    if (payload.length !== assembly.messageSizeBytes) {
      this.emitLateSegmentedDiscard(candidates, envelope);
      return;
    }
    try {
      const message = JSON.parse(payload.toString("utf8"));
      if (Object.hasOwn(message || {}, "id")) {
        if (
          this.observeLateResponse(String(message.id), {
            streamId: envelope.stream_id,
            streamGeneration: null,
          })
        ) {
          return;
        }
      }
    } catch {}
    this.emitLateSegmentedDiscard(candidates, envelope);
  }

  pruneLateResponseAssemblies() {
    const nowMs = this.now();
    for (const [key, assembly] of this.lateResponseAssemblies) {
      if (assembly.expiresAtMs > nowMs) continue;
      this.lateResponseAssemblies.delete(key);
    }
  }

  emitLateSegmentedDiscard(candidates, envelope) {
    const detail = {
      code: "REMOTE_CONTROL_LATE_SEGMENTED_RESPONSE_DISCARDED",
      method: null,
      requestId: null,
      candidateRequestIds: candidates.map((entry) => entry.requestId),
      streamId: String(envelope.stream_id || "") || null,
      streamGeneration: null,
      phase: null,
      attempt: null,
      discardedAtMs: this.now(),
    };
    this.lateResponsesDiscarded += 1;
    this.lastLateResponse = detail;
    this.logger.warn?.(
      new Date(this.now()).toISOString() +
        " remote controller discarded an uncorrelated late segmented response",
    );
    this.events.emit("late-response", detail);
  }

  observeLateResponse(key, { streamId, streamGeneration } = {}) {
    this.pruneRequestTombstones();
    const tombstone = this.requestTombstones.get(String(key));
    if (!tombstone) return false;
    if (streamId && tombstone.streamId && tombstone.streamId !== streamId) {
      return false;
    }
    if (
      streamGeneration !== null &&
      streamGeneration !== undefined &&
      tombstone.streamGeneration !== streamGeneration
    ) {
      return false;
    }
    this.requestTombstones.delete(String(key));
    const detail = {
      code: "REMOTE_CONTROL_LATE_RESPONSE_DISCARDED",
      method: tombstone.method,
      requestId: tombstone.requestId,
      streamId: tombstone.streamId,
      streamGeneration: tombstone.streamGeneration,
      phase: tombstone.phase,
      attempt: tombstone.attempt,
      discardedAtMs: this.now(),
    };
    this.lateResponsesDiscarded += 1;
    this.lastLateResponse = detail;
    this.logger.warn?.(
      new Date(this.now()).toISOString() +
        " remote controller discarded late response " +
        String(detail.requestId) +
        " for " +
        detail.method,
    );
    this.events.emit("late-response", detail);
    return true;
  }

  async refreshEnrollment() {
    const enrollment = await this.readVerifiedEnrollment();
    const headers = await this.getAuthHeaders();
    const identity = authIdentityFromHeaders(headers);
    if (!identityMatchesAccountUser(identity, enrollment.accountUserId)) {
      throw pairingRequiredError(
        "Remote control pairing belongs to a different ChatGPT account",
      );
    }
    const start = await this.apiJson(
      "/codex/remote/control/client/refresh/start",
      {
        method: "POST",
        body: { client_id: enrollment.clientId },
      },
    );
    if (
      start.client_id !== enrollment.clientId ||
      start.account_user_id !== enrollment.accountUserId
    ) {
      throw pairingRequiredError(
        "Remote control refresh challenge does not match the local pairing",
      );
    }
    const finish = await this.apiJson(
      "/codex/remote/control/client/refresh/finish",
      {
        method: "POST",
        body: {
          client_id: enrollment.clientId,
          device_key_proof: await this.signEnrollmentChallenge({
            challenge: start.device_key_challenge,
            enrollment,
            expectedPath: "/codex/remote/control/client/refresh/finish",
            requireDeviceIdentityHash: true,
          }),
        },
      },
    );
    const token = validateRemoteControlToken(finish, enrollment, this.now());
    return {
      enrollment,
      clientId: enrollment.clientId,
      remoteControlToken: finish.remote_control_token,
      tokenExpiresAt: token.tokenExpiresAt,
      scopes: token.scopes,
    };
  }

  async signEnrollmentChallenge({
    challenge,
    enrollment,
    expectedPath,
    requireDeviceIdentityHash,
  }) {
    validateEnrollmentChallenge({
      challenge,
      enrollment,
      apiBaseUrl: this.apiBaseUrl,
      expectedPath,
      requireDeviceIdentityHash,
      nowMs: this.now(),
    });
    const identityHash =
      challenge.device_identity_hash || deviceIdentityHash(enrollment);
    const signature = await this.deviceKeyClient.signDeviceKey(
      enrollment.keyId,
      {
        type: "remoteControlClientEnrollment",
        nonce: challenge.nonce,
        audience: "remote_control_client_enrollment",
        challengeId: challenge.challenge_id,
        targetOrigin: challenge.target_origin,
        targetPath: challenge.target_path,
        accountUserId: challenge.account_user_id,
        clientId: challenge.client_id,
        deviceIdentitySha256Base64url: identityHash,
        challengeExpiresAt: challenge.challenge_expires_at,
      },
    );
    return {
      challenge_token: challenge.challenge_token,
      key_id: enrollment.keyId,
      signature_der_base64: signature.signatureDerBase64,
      signed_payload_base64: signature.signedPayloadBase64,
      algorithm: signature.algorithm,
    };
  }

  async readVerifiedEnrollment({ allowMissing = false } = {}) {
    const state = readJsonFile(this.controllerStatePath);
    const enrollment = state?.enrollment;
    if (
      !validEnrollmentRecord(enrollment) ||
      (state?.apiBaseUrl &&
        String(state.apiBaseUrl).replace(/\/+$/u, "") !== this.apiBaseUrl) ||
      (state?.desktopOriginator &&
        state.desktopOriginator !== this.desktopOriginator)
    ) {
      if (allowMissing) return null;
      throw pairingRequiredError("Remote control client is not paired");
    }
    let publicKey;
    try {
      publicKey = await this.deviceKeyClient.getDeviceKeyPublic(enrollment.keyId);
    } catch {
      if (allowMissing) return null;
      throw pairingRequiredError("Remote control device key is unavailable");
    }
    if (
      publicKey.keyId !== enrollment.keyId ||
      publicKey.algorithm !== enrollment.algorithm ||
      publicKey.protectionClass !== enrollment.protectionClass ||
      publicKey.publicKeySpkiDerBase64 !== enrollment.publicKeySpkiDerBase64
    ) {
      if (allowMissing) return null;
      throw pairingRequiredError("Remote control device key does not match state");
    }
    return enrollment;
  }

  async listEnvironments() {
    const response = await this.apiJson(
      "/codex/remote/control/environments?limit=100",
      { method: "GET" },
    );
    return Array.isArray(response?.items) ? response.items : [];
  }

  async resolveEnvironmentId(environments = null) {
    if (this.configuredEnvironmentId) return this.configuredEnvironmentId;
    const globalState = readJsonFile(this.globalStatePath);
    const fromGlobalState = String(
      globalState?.[GLOBAL_ENVIRONMENT_ID_KEY] || "",
    ).trim();
    if (fromGlobalState) return fromGlobalState;
    const items = environments || (await this.listEnvironments());
    const desktopEnvironments = items.filter(
      (entry) =>
        entry?.online && entry?.client_type === "CODEX_DESKTOP_APP",
    );
    if (desktopEnvironments.length === 1) {
      return desktopEnvironments[0].env_id;
    }
    throw remoteEnvironmentUnavailableError(
      "The current GPT app Remote environment could not be resolved exactly",
    );
  }

  async apiJson(apiPath, { method = "GET", body = undefined } = {}) {
    let headers = await this.getAuthHeaders();
    const execute = () =>
      this.fetchImpl(joinApiUrl(this.apiBaseUrl, apiPath), {
        method,
        headers: {
          ...headers,
          ...(body === undefined
            ? {}
            : { "content-type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    let response = await execute();
    if (response.status === 401) {
      headers = await this.getAuthHeaders({ refreshToken: true });
      response = await execute();
    }
    if (!response.ok) {
      const details = await safeResponseError(response);
      const error = new Error(
        "Remote control request failed (" +
          response.status +
          "): " +
          details.message,
      );
      error.status = response.status;
      error.remoteCode = details.code;
      if (
        response.status === 401 &&
        details.code === "token_invalidated"
      ) {
        error.code = "REMOTE_CONTROL_REAUTH_REQUIRED";
      } else if (
        response.status === 401 ||
        response.status === 403 ||
        response.status === 404
      ) {
        error.code = "REMOTE_CONTROL_PAIRING_REQUIRED";
      }
      throw error;
    }
    return response.json();
  }

  async getAuthHeaders({ refreshToken = false } = {}) {
    await this.ensureAuthInitialized();
    const initializedGeneration = this.authInitializePromise;
    const getAuthStatus = () =>
      this.authClient.request("getAuthStatus", {
        includeToken: true,
        refreshToken,
      });
    let result;
    try {
      result = await getAuthStatus();
    } catch (error) {
      if (!isAuthAppServerNotInitialized(error)) throw error;
      if (this.authInitializePromise === initializedGeneration) {
        this.authInitializePromise = null;
      }
      await this.ensureAuthInitialized();
      result = await getAuthStatus();
    }
    const token = String(result?.authToken || "");
    if (!token) {
      throw new Error("Sign in to ChatGPT to use Remote control");
    }
    const identity = authIdentityFromToken(token);
    const headers = {
      Authorization: "Bearer " + token,
      originator: this.desktopOriginator,
      "User-Agent": "Codex Desktop Remote Controller",
    };
    if (identity.accountId) {
      headers["ChatGPT-Account-Id"] = identity.accountId;
    }
    return headers;
  }

  async ensureAuthInitialized() {
    if (!this.authInitializePromise) {
      this.authInitializePromise = (async () => {
        await this.authClient.ensureStarted();
        await this.authClient.request("initialize", {
          clientInfo: {
            name: "voice_relay_remote_controller_auth",
            title: "Voice Relay Remote Controller Auth",
            version: "0.1.0",
          },
          capabilities: {
            experimentalApi: true,
            requestAttestation: false,
          },
        });
        this.authClient.notify("initialized");
      })().catch((error) => {
        this.authInitializePromise = null;
        throw error;
      });
    }
    return this.authInitializePromise;
  }

  writeControllerState(state) {
    writePrivateJson(this.controllerStatePath, state);
  }

  webSocketUrl() {
    const url = new URL(
      joinApiUrl(this.apiBaseUrl, "/codex/remote/control/client"),
    );
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return url.toString();
  }

  isConnected() {
    const openState = this.WebSocketImpl.OPEN ?? 1;
    return Boolean(this.ws && this.ws.readyState === openState);
  }

  rejectAllPending(error) {
    for (const [key, pending] of [...this.pending.entries()]) {
      this.removePendingRequest(key, pending);
      pending.reject(error);
    }
    this.pending.clear();
    this.pendingRequestOrder = [];
  }

  close() {
    this.closed = true;
    this.stopPingTimer();
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    const error = new Error("Remote control client closed");
    this.rejectAllPending(error);
    this.requestTombstones.clear();
    this.unresolvedMutationFenceUntilMs = 0;
    this.lateResponseAssemblies.clear();
    try {
      this.ws?.close();
    } catch {}
    this.ws = null;
    this.removeAuthExitListener?.();
    this.removeAuthExitListener = null;
    this.authInitializePromise = null;
    this.terminalConnectionError = null;
    this.authClient.close?.();
    this.events.emit("exit", { code: null, signal: "closed" });
  }
}

function isAuthAppServerNotInitialized(error) {
  const message = error instanceof Error ? error.message : String(error || "");
  return /(?:^|:\s*)Not initialized$/u.test(message.trim());
}

export function createNativeDeviceKeyClient(nativeDeviceKeyPath) {
  let nativeModule = null;
  const load = () => {
    if (process.platform !== "darwin") {
      throw new Error("Remote control device keys are only available on macOS");
    }
    if (!nativeModule) {
      nativeModule = createRequire(import.meta.url)(nativeDeviceKeyPath);
    }
    return nativeModule;
  };
  return {
    createDeviceKey: (protectionClass = NATIVE_KEY_PROTECTION_CLASS) =>
      load().createDeviceKey(protectionClass),
    deleteDeviceKey: (keyId) => load().deleteDeviceKey(keyId),
    getDeviceKeyPublic: (keyId) => load().getDeviceKeyPublic(keyId),
    signDeviceKey: async (keyId, payload) => {
      const signedPayload = encodeDeviceKeySignedPayload(payload);
      const signature = await load().signDeviceKey(keyId, signedPayload);
      return {
        ...signature,
        signedPayloadBase64: signedPayload.toString("base64"),
      };
    },
  };
}

export function createMacOSKeychainDeviceKeyClient({
  helperSourcePath,
  helperPath,
} = {}) {
  const sourcePath = String(helperSourcePath || "").trim();
  const binaryPath = String(helperPath || "").trim();
  if (!sourcePath || !binaryPath) {
    throw new Error("Remote control device-key helper paths are required");
  }
  let buildPromise = null;
  const ensureBuilt = () => {
    if (!buildPromise) {
      buildPromise = ensureDeviceKeyHelper({ sourcePath, binaryPath }).catch(
        (error) => {
          buildPromise = null;
          throw error;
        },
      );
    }
    return buildPromise;
  };
  const invoke = async (args) => {
    await ensureBuilt();
    const result = await runProcessJson(binaryPath, args, {
      timeoutMs: 30_000,
      label: "Remote control device-key helper",
    });
    return result;
  };
  return {
    createDeviceKey: async () => normalizeDeviceKeyRecord(await invoke(["create"])),
    deleteDeviceKey: async (keyId) =>
      invoke(["delete", validateDeviceKeyId(keyId)]),
    getDeviceKeyPublic: async (keyId) =>
      normalizeDeviceKeyRecord(
        await invoke(["get", validateDeviceKeyId(keyId)]),
      ),
    signDeviceKey: async (keyId, payload) => {
      const signedPayload = encodeDeviceKeySignedPayload(payload);
      const result = await invoke([
        "sign",
        validateDeviceKeyId(keyId),
        signedPayload.toString("base64"),
      ]);
      if (
        result?.algorithm !== "ecdsa_p256_sha256" ||
        typeof result?.signatureDerBase64 !== "string" ||
        !validBase64(result.signatureDerBase64)
      ) {
        throw new Error("Remote control device-key signature is invalid");
      }
      return {
        algorithm: result.algorithm,
        signatureDerBase64: result.signatureDerBase64,
        signedPayloadBase64: signedPayload.toString("base64"),
      };
    },
  };
}

async function ensureDeviceKeyHelper({ sourcePath, binaryPath }) {
  if (process.platform !== "darwin") {
    throw new Error("Remote control device keys are only available on macOS");
  }
  if (isExecutableFile(binaryPath)) return binaryPath;
  if (!fs.existsSync(sourcePath)) {
    throw new Error("Remote control device-key helper source is missing");
  }
  const parent = path.dirname(binaryPath);
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  fs.chmodSync(parent, 0o700);
  const temporaryPath = `${binaryPath}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  try {
    await runProcess(
      "/usr/bin/xcrun",
      [
        "swiftc",
        "-O",
        "-framework",
        "Security",
        sourcePath,
        "-o",
        temporaryPath,
      ],
      { timeoutMs: 120_000, label: "Remote control device-key helper build" },
    );
    await runProcess(
      "/usr/bin/codesign",
      [
        "--force",
        "--sign",
        "-",
        "--identifier",
        "com.hyungchulc.voice-relay.remote-control-device-key-helper",
        temporaryPath,
      ],
      { timeoutMs: 30_000, label: "Remote control device-key helper signing" },
    );
    fs.chmodSync(temporaryPath, 0o700);
    fs.renameSync(temporaryPath, binaryPath);
    return binaryPath;
  } finally {
    try {
      if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
    } catch {}
  }
}

function isExecutableFile(filePath) {
  try {
    const metadata = fs.statSync(filePath);
    fs.accessSync(filePath, fs.constants.X_OK);
    return metadata.isFile();
  } catch {
    return false;
  }
}

function runProcessJson(command, args, options) {
  return runProcess(command, args, options).then(({ stdout }) => {
    try {
      const value = JSON.parse(stdout);
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("invalid object");
      }
      return value;
    } catch {
      throw new Error((options?.label || "Helper") + " returned invalid JSON");
    }
  });
}

function runProcess(
  command,
  args,
  { timeoutMs = 30_000, label = "Process" } = {},
) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    let timer = null;
    const finish = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback();
    };
    const append = (target, chunk, currentBytes) => {
      if (currentBytes + chunk.length > 1024 * 1024) {
        child.kill("SIGKILL");
        finish(() => reject(new Error(label + " output exceeded the limit")));
        return currentBytes;
      }
      target.push(chunk);
      return currentBytes + chunk.length;
    };
    child.stdout.on("data", (chunk) => {
      stdoutBytes = append(stdout, chunk, stdoutBytes);
    });
    child.stderr.on("data", (chunk) => {
      stderrBytes = append(stderr, chunk, stderrBytes);
    });
    child.once("error", (error) => {
      finish(() => reject(new Error(label + " failed: " + errorMessage(error))));
    });
    child.once("close", (code, signal) => {
      finish(() => {
        const output = Buffer.concat(stdout).toString("utf8").trim();
        const errorOutput = Buffer.concat(stderr).toString("utf8").trim();
        if (code !== 0) {
          reject(
            new Error(
              label +
                " failed" +
                (signal ? " with signal " + signal : " with status " + code) +
                (errorOutput ? ": " + errorOutput.slice(0, 500) : ""),
            ),
          );
          return;
        }
        resolve({ stdout: output, stderr: errorOutput });
      });
    });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(new Error(label + " timed out")));
    }, positiveNumber(timeoutMs, 30_000));
    timer.unref?.();
  });
}

function normalizeDeviceKeyRecord(value) {
  const allowedProtectionClasses = new Set([
    "hardware_secure_enclave",
    "hardware_tpm",
    "os_protected_nonextractable",
  ]);
  if (
    !value ||
    value.algorithm !== "ecdsa_p256_sha256" ||
    !allowedProtectionClasses.has(value.protectionClass) ||
    !validBase64(value.publicKeySpkiDerBase64)
  ) {
    throw new Error("Remote control device-key record is invalid");
  }
  return {
    keyId: validateDeviceKeyId(value.keyId),
    algorithm: value.algorithm,
    protectionClass: value.protectionClass,
    publicKeySpkiDerBase64: value.publicKeySpkiDerBase64,
  };
}

function validateDeviceKeyId(value) {
  const keyId = String(value || "");
  if (!/^[A-Za-z0-9_-]+$/u.test(keyId)) {
    throw new Error("Remote control device key id is invalid");
  }
  return keyId;
}

function validBase64(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) {
    return false;
  }
  try {
    return Buffer.from(value, "base64").length > 0;
  } catch {
    return false;
  }
}

export function encodeDeviceKeySignedPayload(payload) {
  return Buffer.from(
    JSON.stringify({
      domain: DEVICE_KEY_DOMAIN,
      payload: canonicalDeviceKeyPayload(payload),
    }),
    "utf8",
  );
}

export function canonicalDeviceKeyPayload(payload) {
  if (payload?.type === "remoteControlClientConnection") {
    return {
      accountUserId: payload.accountUserId,
      audience: payload.audience,
      clientId: payload.clientId,
      nonce: payload.nonce,
      scopes: payload.scopes,
      sessionId: payload.sessionId,
      targetOrigin: payload.targetOrigin,
      targetPath: payload.targetPath,
      tokenExpiresAt: payload.tokenExpiresAt,
      tokenSha256Base64url: payload.tokenSha256Base64url,
      type: payload.type,
    };
  }
  if (payload?.type === "remoteControlClientEnrollment") {
    return {
      accountUserId: payload.accountUserId,
      audience: payload.audience,
      challengeExpiresAt: payload.challengeExpiresAt,
      challengeId: payload.challengeId,
      clientId: payload.clientId,
      deviceIdentitySha256Base64url:
        payload.deviceIdentitySha256Base64url,
      nonce: payload.nonce,
      targetOrigin: payload.targetOrigin,
      targetPath: payload.targetPath,
      type: payload.type,
    };
  }
  throw new Error("Unsupported remote control device-key payload");
}

export function deviceIdentityHash(enrollment) {
  return createHash("sha256")
    .update(
      JSON.stringify({
        algorithm: enrollment.algorithm,
        keyId: enrollment.keyId,
        protectionClass: enrollment.protectionClass,
        publicKeySpkiDerBase64: enrollment.publicKeySpkiDerBase64,
      }),
    )
    .digest("base64url");
}

export function segmentClientEnvelope(
  envelope,
  {
    clientMessageMaxBytes = CLIENT_MESSAGE_MAX_BYTES,
    transportMessageMaxBytes = TRANSPORT_MESSAGE_MAX_BYTES,
  } = {},
) {
  if (Buffer.byteLength(JSON.stringify(envelope), "utf8") <= clientMessageMaxBytes) {
    return [envelope];
  }
  const message = Buffer.from(JSON.stringify(envelope.message), "utf8");
  if (message.length > MAX_REASSEMBLED_MESSAGE_BYTES) {
    throw new Error("Remote control message exceeds the transport limit");
  }
  let segmentCount = Math.max(
    1,
    Math.ceil(message.length / clientMessageMaxBytes),
  );
  for (;;) {
    const chunkSize = Math.max(1, Math.ceil(message.length / segmentCount));
    const chunks = [];
    for (let offset = 0; offset < message.length; offset += chunkSize) {
      chunks.push(message.subarray(offset, offset + chunkSize));
    }
    segmentCount = chunks.length;
    const segments = chunks.map((chunk, segmentId) => {
      const { message: _message, ...base } = envelope;
      return {
        ...base,
        type: "client_message_chunk",
        segment_id: segmentId,
        segment_count: segmentCount,
        message_size_bytes: message.length,
        message_chunk_base64: chunk.toString("base64"),
      };
    });
    if (
      segments.every(
        (segment) =>
          Buffer.byteLength(JSON.stringify(segment), "utf8") <=
          transportMessageMaxBytes,
      )
    ) {
      return segments;
    }
    if (chunkSize === 1) {
      throw new Error("Remote control segment metadata exceeds the limit");
    }
    segmentCount += 1;
  }
}

export function validateConnectionChallenge({
  challenge,
  enrollment,
  clientId,
  webSocketUrl,
  remoteControlToken,
  tokenExpiresAt,
  scopes,
  nowMs,
}) {
  const url = new URL(webSocketUrl);
  const expectedOrigin =
    (url.protocol === "wss:" ? "https:" : "http:") + "//" + url.host;
  const expectedTokenHash = createHash("sha256")
    .update(remoteControlToken, "utf8")
    .digest("base64url");
  if (
    challenge?.type !== "device_key_challenge" ||
    challenge.purpose !== "remote_control_client_websocket" ||
    challenge.audience !== "remote_control_client_websocket" ||
    challenge.accountUserId !== enrollment.accountUserId ||
    challenge.clientId !== clientId ||
    challenge.targetOrigin !== expectedOrigin ||
    challenge.targetPath !== url.pathname ||
    challenge.tokenSha256Base64url !== expectedTokenHash ||
    challenge.tokenExpiresAt !== tokenExpiresAt ||
    challenge.tokenExpiresAt <= Math.floor(nowMs / 1000) ||
    !sameStringArray(challenge.scopes, scopes)
  ) {
    throw new Error(
      "Remote control device-key challenge does not match the paired session",
    );
  }
}

export function validateEnrollmentChallenge({
  challenge,
  enrollment,
  apiBaseUrl,
  expectedPath,
  requireDeviceIdentityHash,
  nowMs,
}) {
  const target = new URL(joinApiUrl(apiBaseUrl, expectedPath));
  const expectedIdentityHash = deviceIdentityHash(enrollment);
  const expiresAt = parseExpiryMs(challenge?.challenge_expires_at);
  if (
    challenge?.purpose !== "remote_control_client_enrollment" ||
    challenge.audience !== "remote_control_client_enrollment" ||
    challenge.account_user_id !== enrollment.accountUserId ||
    challenge.client_id !== enrollment.clientId ||
    challenge.target_origin !== target.origin ||
    challenge.target_path !== target.pathname ||
    !Number.isFinite(expiresAt) ||
    expiresAt <= nowMs ||
    (requireDeviceIdentityHash && !challenge.device_identity_hash) ||
    (challenge.device_identity_hash &&
      challenge.device_identity_hash !== expectedIdentityHash)
  ) {
    throw new Error(
      "Remote control enrollment challenge does not match local pairing",
    );
  }
}

export async function requestRemoteControlStepUpToken({
  accountId,
  authIssuer = DEFAULT_REMOTE_CONTROL_AUTH_ISSUER,
  oauthClientId = DEFAULT_REMOTE_CONTROL_OAUTH_CLIENT_ID,
  desktopOriginator = "Codex Desktop",
  timeoutMs = DEFAULT_PAIRING_TIMEOUT_MS,
  fetchImpl = globalThis.fetch,
  openExternalUrl = defaultOpenExternalUrl,
}) {
  const codeVerifier = randomBytes(32).toString("base64url");
  const codeChallenge = createHash("sha256")
    .update(codeVerifier)
    .digest("base64url");
  const state = randomBytes(32).toString("base64url");
  const callback = await createOAuthCallbackServer({ state, timeoutMs });
  try {
    const authorizeUrl = new URL(
      "/oauth/authorize",
      authIssuer.replace(/\/+$/u, "") + "/",
    );
    const search = new URLSearchParams({
      response_type: "code",
      client_id: oauthClientId,
      redirect_uri: callback.redirectUri,
      scope: STEP_UP_SCOPE,
      code_challenge: codeChallenge,
      code_challenge_method: "S256",
      state,
      originator: desktopOriginator,
      reauth: "remote_control",
      max_age: "0",
      codex_cli_simplified_flow: "true",
    });
    if (accountId) {
      search.set("allowed_workspace_id", accountId);
      search.set("current_workspace_id", accountId);
    }
    authorizeUrl.search = search.toString();
    const opened = await openExternalUrl(authorizeUrl.toString());
    if (opened === false) {
      throw new Error("Failed to open Remote control authorization");
    }
    const code = await callback.authorizationCode;
    const response = await fetchImpl(
      new URL(
        "/oauth/token",
        authIssuer.replace(/\/+$/u, "") + "/",
      ).toString(),
      {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          redirect_uri: callback.redirectUri,
          client_id: oauthClientId,
          code_verifier: codeVerifier,
        }).toString(),
      },
    );
    if (!response.ok) {
      throw new Error(
        "Remote control step-up token exchange failed with status " +
          response.status,
      );
    }
    const payload = await response.json();
    if (!payload?.access_token) {
      throw new Error("Remote control step-up token is missing");
    }
    return payload.access_token;
  } finally {
    callback.close();
  }
}

export function validateStepUpToken({ token, accountUserId, nowMs }) {
  const payload = decodeJwtPayload(token);
  const auth = payload?.["https://api.openai.com/auth"] || {};
  const tokenAccountUserId =
    auth.chatgpt_account_user_id || auth.account_user_id || null;
  const scopes = tokenScopes(payload);
  const nowSeconds = Math.floor(nowMs / 1000);
  if (tokenAccountUserId !== accountUserId) {
    throw new Error(
      "Remote control step-up token does not match the current account",
    );
  }
  if (
    !Number.isFinite(payload.iat) ||
    nowSeconds - payload.iat > STEP_UP_FRESHNESS_SECONDS
  ) {
    throw new Error("Remote control step-up token is not fresh");
  }
  if (
    !Number.isFinite(payload.pwd_auth_time) ||
    nowMs - payload.pwd_auth_time >
      STEP_UP_FRESHNESS_SECONDS * 1000
  ) {
    throw new Error(
      "Remote control step-up token lacks fresh password authentication",
    );
  }
  if (scopes.length !== 1 || scopes[0] !== STEP_UP_SCOPE) {
    throw new Error(
      "Remote control step-up token lacks enrollment authorization",
    );
  }
  return payload;
}

async function createOAuthCallbackServer({ state, timeoutMs }) {
  let server = null;
  let selectedPort = null;
  let resolveCode;
  let rejectCode;
  let settled = false;
  let timer = null;
  const authorizationCode = new Promise((resolve, reject) => {
    resolveCode = resolve;
    rejectCode = reject;
  });
  authorizationCode.catch(() => {});

  for (const port of CALLBACK_PORTS) {
    const candidate = http.createServer((request, response) => {
      try {
        const url = new URL(
          request.url || "",
          "http://localhost:" + String(port),
        );
        if (url.pathname !== CALLBACK_PATH) {
          sendTextResponse(response, 404, "Not Found");
          return;
        }
        if (url.searchParams.get("state") !== state) {
          sendTextResponse(response, 400, "State mismatch");
          return;
        }
        const authError = url.searchParams.get("error");
        if (authError) {
          const description = url.searchParams.get("error_description");
          sendTextResponse(response, 400, "Remote control login failed");
          settle(() =>
            rejectCode(
              new Error(
                description ? authError + ": " + description : authError,
              ),
            ),
          );
          return;
        }
        const code = url.searchParams.get("code");
        if (!code) {
          sendTextResponse(response, 400, "Missing authorization code");
          return;
        }
        sendTextResponse(
          response,
          200,
          "Remote control authorized. You can close this tab.",
        );
        settle(() => resolveCode(code));
      } catch (error) {
        sendTextResponse(response, 400, "Bad Request");
        settle(() => rejectCode(error));
      }
    });
    try {
      await new Promise((resolve, reject) => {
        candidate.once("error", reject);
        candidate.listen(port, "localhost", resolve);
      });
      server = candidate;
      selectedPort = port;
      break;
    } catch (error) {
      candidate.close();
      if (error?.code !== "EADDRINUSE") throw error;
    }
  }
  if (!server || !selectedPort) {
    throw new Error(
      "Remote control login callback ports 1455 and 1457 are in use",
    );
  }

  timer = setTimeout(() => {
    settle(() =>
      rejectCode(new Error("Timed out waiting for Remote control login")),
    );
  }, positiveNumber(timeoutMs, DEFAULT_PAIRING_TIMEOUT_MS));
  timer.unref?.();

  function settle(callback) {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    callback();
  }

  return {
    redirectUri:
      "http://localhost:" + String(selectedPort) + CALLBACK_PATH,
    authorizationCode,
    close: () => {
      server.close();
      if (!settled) {
        settle(() =>
          rejectCode(new Error("Remote control login was cancelled")),
        );
      }
    },
  };
}

function sendTextResponse(response, status, text) {
  response.writeHead(status, {
    "Content-Type": "text/plain; charset=utf-8",
    Connection: "close",
  });
  response.end(text);
}

function defaultOpenExternalUrl(url) {
  return new Promise((resolve, reject) => {
    const child = spawn("/usr/bin/open", [url], {
      stdio: "ignore",
      detached: true,
    });
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve(true);
    });
  });
}

function waitForWebSocketOpen(ws, timeoutMs) {
  const openState = ws.constructor?.OPEN ?? 1;
  if (ws.readyState === openState) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("Remote control websocket open timed out"));
    }, timeoutMs);
    timer.unref?.();
    const cleanup = () => {
      clearTimeout(timer);
      ws.removeEventListener("open", onOpen);
      ws.removeEventListener("error", onError);
      ws.removeEventListener("close", onClose);
    };
    const onOpen = () => {
      cleanup();
      resolve();
    };
    const onError = (event) => {
      cleanup();
      reject(event?.error || new Error("Remote control websocket failed"));
    };
    const onClose = () => {
      cleanup();
      reject(new Error("Remote control websocket closed before opening"));
    };
    ws.addEventListener("open", onOpen);
    ws.addEventListener("error", onError);
    ws.addEventListener("close", onClose);
  });
}

function waitForDeviceKeyChallenge(ws, timeoutMs) {
  return new Promise((resolve, reject) => {
    const openState = ws.constructor?.OPEN ?? 1;
    let timer = null;
    const startTimer = () => {
      if (timer !== null) return;
      timer = setTimeout(() => {
        cleanup();
        reject(
          new Error(
            "Remote control device-key challenge timed out after websocket open",
          ),
        );
      }, timeoutMs);
      timer.unref?.();
    };
    const cleanup = () => {
      if (timer !== null) clearTimeout(timer);
      ws.removeEventListener("open", onOpen);
      ws.removeEventListener("message", onMessage);
      ws.removeEventListener("close", onClose);
      ws.removeEventListener("error", onError);
    };
    const onOpen = () => {
      startTimer();
    };
    const onMessage = (event) => {
      Promise.resolve(webSocketMessageText(event.data))
        .then((text) => {
          let message;
          try {
            message = JSON.parse(text);
          } catch {
            return;
          }
          if (message?.type !== "device_key_challenge") return;
          cleanup();
          resolve(message);
        })
        .catch((error) => {
          cleanup();
          reject(error);
        });
    };
    const onClose = () => {
      cleanup();
      reject(
        new Error(
          "Remote control websocket closed before device-key authorization",
        ),
      );
    };
    const onError = (event) => {
      cleanup();
      reject(event?.error || new Error("Remote control websocket failed"));
    };
    ws.addEventListener("open", onOpen);
    ws.addEventListener("message", onMessage);
    ws.addEventListener("close", onClose);
    ws.addEventListener("error", onError);
    if (ws.readyState === openState) startTimer();
  });
}

async function webSocketMessageText(data) {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf8");
  }
  if (data && typeof data.text === "function") return data.text();
  return String(data);
}

function remoteControlStreamGapError(
  message,
  { source = "", expectedSequenceId = null, actualSequenceId = null } = {},
) {
  const safeSource = /^(?:pong|server_envelope)$/u.test(String(source || ""))
    ? String(source)
    : "";
  const safeExpected = safeNonNegativeInteger(expectedSequenceId);
  const safeActual = safeNonNegativeInteger(actualSequenceId);
  const details = [];
  if (safeSource) details.push("source=" + safeSource);
  if (safeExpected !== null) details.push("expected=" + String(safeExpected));
  if (safeActual !== null) details.push("actual=" + String(safeActual));
  const error = new Error(
    String(message || "Remote control stream gap") +
      (details.length ? " " + details.join(" ") : ""),
  );
  error.code = REMOTE_CONTROL_STREAM_GAP_CODE;
  error.source = safeSource || null;
  error.expectedSequenceId = safeExpected;
  error.actualSequenceId = safeActual;
  return error;
}

function isValidServerMessageChunkEnvelope(envelope) {
  const sequenceId = safeNonNegativeInteger(envelope?.seq_id);
  const segmentId = safeNonNegativeInteger(envelope?.segment_id);
  const segmentCount = safePositiveInteger(envelope?.segment_count);
  const messageSizeBytes = safePositiveInteger(envelope?.message_size_bytes);
  return Boolean(
    sequenceId !== null &&
      typeof envelope?.client_id === "string" &&
      typeof envelope?.env_id === "string" &&
      typeof envelope?.stream_id === "string" &&
      segmentId !== null &&
      segmentCount !== null &&
      segmentCount <= SERVER_MESSAGE_ASSEMBLY_MAX_SEGMENTS &&
      segmentId < segmentCount &&
      messageSizeBytes !== null &&
      messageSizeBytes <= MAX_REASSEMBLED_MESSAGE_BYTES &&
      typeof envelope?.message_chunk_base64 === "string" &&
      envelope.message_chunk_base64.length > 0
  );
}

function isRemoteControlStreamGapError(error) {
  return error?.code === REMOTE_CONTROL_STREAM_GAP_CODE;
}

function authIdentityFromHeaders(headers) {
  const authorization = headerValue(headers, "authorization");
  const match = /^Bearer\s+(.+)$/iu.exec(authorization || "");
  if (!match) return {};
  return authIdentityFromToken(match[1], {
    headerAccountId: headerValue(headers, "chatgpt-account-id"),
  });
}

function authIdentityFromToken(token, { headerAccountId = null } = {}) {
  const payload = decodeJwtPayload(token);
  const auth = payload?.["https://api.openai.com/auth"] || {};
  const tokenAccountId = auth.chatgpt_account_id || auth.account_id || null;
  return {
    accountId: tokenAccountId || headerAccountId || null,
    tokenAccountId,
    headerAccountId,
    accountUserId:
      auth.chatgpt_account_user_id || auth.account_user_id || null,
    authUserId: auth.user_id || null,
    subject: payload?.sub || null,
  };
}

function decodeJwtPayload(token) {
  const parts = String(token || "").split(".");
  if (parts.length < 2 || !parts[1]) {
    throw new Error("ChatGPT auth token is malformed");
  }
  return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
}

function tokenScopes(payload) {
  const scopes = new Set();
  for (const scope of String(payload?.scope || "").split(/\s+/u)) {
    if (scope) scopes.add(scope);
  }
  for (const scope of Array.isArray(payload?.scp) ? payload.scp : []) {
    if (scope) scopes.add(scope);
  }
  return [...scopes];
}

function assertEnrollmentStartIdentity(start, identity) {
  if (
    !start?.client_id ||
    !start?.account_user_id ||
    !start?.device_key_challenge ||
    !identityMatchesAccountUser(identity, start.account_user_id)
  ) {
    throw new Error(
      "Remote control enrollment start does not match the current account",
    );
  }
}

function identityMatchesAccountUser(identity, accountUserId) {
  if (!accountUserId) return false;
  if (identity?.accountUserId === accountUserId) return true;
  return Boolean(
    identity?.tokenAccountId &&
      identity.headerAccountId === identity.tokenAccountId &&
      identity.authUserId === accountUserId,
  );
}

function validateRemoteControlToken(response, enrollment, now) {
  if (
    response?.client_id !== enrollment.clientId ||
    response?.account_user_id !== enrollment.accountUserId ||
    !response?.remote_control_token
  ) {
    throw new Error(
      "Remote control token response does not match local pairing",
    );
  }
  const nowMs = typeof now === "function" ? now() : Number(now);
  const tokenExpiresAt = Math.floor(
    Date.parse(String(response.expires_at || "")) / 1000,
  );
  if (
    !Number.isFinite(tokenExpiresAt) ||
    !Number.isFinite(nowMs) ||
    tokenExpiresAt <= Math.floor(nowMs / 1000)
  ) {
    throw new Error("Remote control token expiration is invalid");
  }
  if (
    !sameStringArray(response.scopes, [
      REMOTE_CONTROL_CONTROLLER_SCOPE,
    ])
  ) {
    throw new Error("Remote control token scopes are invalid");
  }
  return {
    tokenExpiresAt,
    scopes: [REMOTE_CONTROL_CONTROLLER_SCOPE],
  };
}

function deviceIdentityBody(enrollment) {
  return {
    key_id: enrollment.keyId,
    public_key_spki_der_base64: enrollment.publicKeySpkiDerBase64,
    algorithm: enrollment.algorithm,
    protection_class: enrollment.protectionClass,
  };
}

function validEnrollmentRecord(value) {
  return Boolean(
    value &&
      typeof value === "object" &&
      typeof value.accountUserId === "string" &&
      value.accountUserId &&
      typeof value.clientId === "string" &&
      value.clientId &&
      typeof value.keyId === "string" &&
      value.keyId &&
      typeof value.algorithm === "string" &&
      value.algorithm &&
      typeof value.protectionClass === "string" &&
      value.protectionClass &&
      typeof value.publicKeySpkiDerBase64 === "string" &&
      value.publicKeySpkiDerBase64,
  );
}

function pairingRequiredError(message) {
  const error = new Error(message);
  error.code = "REMOTE_CONTROL_PAIRING_REQUIRED";
  return error;
}

function remoteEnvironmentUnavailableError(message) {
  const error = new Error(message);
  error.code = "REMOTE_CONTROL_ENVIRONMENT_UNAVAILABLE";
  return error;
}

function normalizedRemoteControlErrorCode(error) {
  const code = String(error?.code || "")
    .trim()
    .toUpperCase();
  return /^[A-Z0-9_:-]{1,80}$/u.test(code) ? code : null;
}

function isTerminalRemoteControlConnectionError(error) {
  return new Set([
    "REMOTE_CONTROL_ENVIRONMENT_PAIRING_REQUIRED",
    "REMOTE_CONTROL_PAIRING_REQUIRED",
    "REMOTE_CONTROL_REAUTH_REQUIRED",
  ]).has(normalizedRemoteControlErrorCode(error));
}

function remoteEnvironmentPairingNotificationError(message) {
  if (message?.method !== "error" || message?.params?.willRetry === true) {
    return null;
  }
  const notificationMessage = String(
    message?.params?.error?.message || "",
  );
  if (
    !/remote environment is not paired for this client/iu.test(
      notificationMessage,
    )
  ) {
    return null;
  }
  const error = pairingRequiredError(notificationMessage);
  error.code = "REMOTE_CONTROL_ENVIRONMENT_PAIRING_REQUIRED";
  return error;
}

function readJsonFile(filePath) {
  try {
    if (!filePath || !fs.existsSync(filePath)) return null;
    const value = JSON.parse(fs.readFileSync(filePath, "utf8"));
    return value && typeof value === "object" && !Array.isArray(value)
      ? value
      : null;
  } catch {
    return null;
  }
}

function writePrivateJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  const temporaryPath =
    filePath +
    "." +
    String(process.pid) +
    "." +
    randomBytes(6).toString("hex") +
    ".tmp";
  try {
    fs.writeFileSync(
      temporaryPath,
      JSON.stringify(value, null, 2) + "\n",
      {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      },
    );
    fs.renameSync(temporaryPath, filePath);
    fs.chmodSync(filePath, 0o600);
  } finally {
    try {
      if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
    } catch {}
  }
}

function joinApiUrl(baseUrl, apiPath) {
  return (
    String(baseUrl || "").replace(/\/+$/u, "") +
    "/" +
    String(apiPath || "").replace(/^\/+/u, "")
  );
}

function headerValue(headers, name) {
  const normalized = String(name || "").toLowerCase();
  for (const [key, value] of Object.entries(headers || {})) {
    if (key.toLowerCase() === normalized) return value;
  }
  return null;
}

function sameStringArray(left, right) {
  return (
    Array.isArray(left) &&
    Array.isArray(right) &&
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function safeNonNegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function safePositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : null;
}

function finiteNumberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function nonEmptyString(value) {
  const text = String(value || "").trim();
  return text || null;
}

function normalizeRequestMetadata(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const normalized = {};
  for (const [key, entry] of Object.entries(value)) {
    if (
      entry === null ||
      typeof entry === "string" ||
      typeof entry === "number" ||
      typeof entry === "boolean"
    ) {
      normalized[key] = entry;
    }
  }
  return Object.keys(normalized).length ? normalized : null;
}

function remainingRequestTimeoutMs({ timeoutMs, requestMetadata, nowMs }) {
  const deadlineAtMs = finiteNumberOrNull(
    requestMetadata?.attemptDeadlineAtMs,
  );
  if (deadlineAtMs !== null) {
    return Math.floor(deadlineAtMs - nowMs);
  }
  return positiveNumber(timeoutMs, DEFAULT_REQUEST_TIMEOUT_MS);
}

function preDispatchTimeoutError({
  method,
  timeoutMs,
  requestMetadata,
  streamId,
  streamGeneration,
}) {
  const error = new RemoteControllerRequestTimeoutError({
    method,
    requestId: null,
    streamId,
    streamGeneration,
    timeoutMs: positiveNumber(timeoutMs, DEFAULT_REQUEST_TIMEOUT_MS),
    requestMetadata,
  });
  error.preDispatch = true;
  return error;
}

function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  throw signal.reason instanceof Error
    ? signal.reason
    : new Error("Remote controller request aborted");
}

async function waitForOperationDeadline(
  promise,
  { deadlineAtMs, now, signal = null, timeoutError },
) {
  const remainingMs = Math.floor(deadlineAtMs - now());
  if (remainingMs <= 0) throw timeoutError();
  throwIfAborted(signal);
  let timer = null;
  let removeAbortListener = null;
  try {
    const deadlinePromise = new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(timeoutError()), remainingMs);
    });
    const abortPromise = signal
      ? new Promise((_resolve, reject) => {
          const onAbort = () => {
            reject(
              signal.reason instanceof Error
                ? signal.reason
                : new Error("Remote controller request aborted"),
            );
          };
          signal.addEventListener("abort", onAbort, { once: true });
          removeAbortListener = () =>
            signal.removeEventListener("abort", onAbort);
        })
      : new Promise(() => {});
    return await Promise.race([promise, deadlinePromise, abortPromise]);
  } finally {
    if (timer) clearTimeout(timer);
    removeAbortListener?.();
  }
}

function isSafeToDiscardForReadRecovery(method) {
  return (
    method === "thread/read" ||
    method === "thread/turns/list" ||
    method === "initialize" ||
    method === "initialized" ||
    method === "model/list"
  );
}

function parseExpiryMs(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value < 1_000_000_000_000 ? value * 1000 : value;
  }
  const text = String(value || "").trim();
  if (!text) return Number.NaN;
  if (/^\d+(?:\.\d+)?$/u.test(text)) {
    const numeric = Number(text);
    return numeric < 1_000_000_000_000 ? numeric * 1000 : numeric;
  }
  return Date.parse(text);
}

function positiveNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

function envelopeKey(envelope) {
  return (
    String(envelope.env_id) +
    ":" +
    String(envelope.stream_id) +
    ":" +
    String(envelope.seq_id)
  );
}

async function safeResponseError(response) {
  try {
    const text = await response.text();
    if (!text) {
      return {
        code: "",
        message: response.statusText || "Unknown error",
      };
    }
    try {
      const parsed = JSON.parse(text);
      const detail =
        parsed?.detail && typeof parsed.detail === "object"
          ? parsed.detail
          : parsed;
      const nestedError =
        detail?.error && typeof detail.error === "object"
          ? detail.error
          : parsed?.error && typeof parsed.error === "object"
            ? parsed.error
            : null;
      const code = String(detail?.code || parsed?.code || "")
        .trim()
        .toLowerCase();
      const message = String(
        nestedError?.message ||
          detail?.message ||
          (typeof parsed?.detail === "string" ? parsed.detail : "") ||
          parsed?.message ||
          text,
      );
      return {
        code: /^[a-z0-9_:-]{1,80}$/u.test(
          String(nestedError?.code || code).trim().toLowerCase(),
        )
          ? String(nestedError?.code || code).trim().toLowerCase()
          : "",
        message,
      };
    } catch {}
    return { code: "", message: text };
  } catch {
    return {
      code: "",
      message: response.statusText || "Unknown error",
    };
  }
}

function formatRpcError(method, error) {
  if (!error) return method + " failed";
  if (typeof error === "string") return method + " failed: " + error;
  const message = error.message || JSON.stringify(error);
  return method + " failed: " + message;
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
