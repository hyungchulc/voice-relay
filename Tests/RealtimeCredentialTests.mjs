#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  requestRealtimeCredential,
} from "../Helpers/voice-relay-realtime-credential.mjs";

const scratch = fs.mkdtempSync(
  path.join(os.tmpdir(), "voice-relay-credential-tests-"),
);
const authPath = path.join(scratch, "auth.json");
const sampleToken = "test-token-never-log";
fs.writeFileSync(
  authPath,
  JSON.stringify({
    auth_mode: "chatgpt",
    tokens: { access_token: sampleToken },
  }),
  { mode: 0o600 },
);

try {
  let observedURL = "";
  let observedOptions = null;
  const result = await requestRealtimeCredential(
    { model: "gpt-realtime-test" },
    {
      authPath,
      fetchImpl: async (url, options) => {
        observedURL = String(url);
        observedOptions = options;
        return {
          ok: true,
          status: 200,
          async text() {
            return JSON.stringify({
              value: "ephemeral-test-secret",
              expires_at: Math.floor(Date.now() / 1000) + 120,
            });
          },
        };
      },
    },
  );
  assert.equal(
    observedURL,
    "https://api.openai.com/v1/realtime/client_secrets",
  );
  assert.equal(
    observedOptions.headers.Authorization,
    `Bearer ${sampleToken}`,
  );
  assert.deepEqual(
    JSON.parse(observedOptions.body),
    {
      session: {
        type: "realtime",
        model: "gpt-realtime-test",
      },
    },
  );
  assert.equal(result.clientSecret, "ephemeral-test-secret");
  assert.equal(result.model, "gpt-realtime-test");

  await assert.rejects(
    () =>
      requestRealtimeCredential(
        {},
        {
          authPath: path.join(scratch, "missing.json"),
          fetchImpl: async () => {
            throw new Error("must not fetch");
          },
        },
      ),
    error => {
      assert.doesNotMatch(String(error), /missing\.json|test-token/);
      return /Codex OAuth is unavailable/.test(String(error));
    },
  );

  await assert.rejects(
    () =>
      requestRealtimeCredential(
        {},
        {
          authPath,
          fetchImpl: async () => ({
            ok: false,
            status: 401,
            async text() {
              return JSON.stringify({
                error: `do not expose ${sampleToken}`,
              });
            },
          }),
        },
      ),
    error => {
      assert.doesNotMatch(String(error), /test-token/);
      return /temporary Realtime credential \(401\)/.test(String(error));
    },
  );

  process.stdout.write("Realtime credential tests passed\n");
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}
