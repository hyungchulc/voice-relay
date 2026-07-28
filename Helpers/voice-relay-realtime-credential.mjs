import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const credentialEndpoint =
  "https://api.openai.com/v1/realtime/client_secrets";

function normalizedModel(value) {
  const model = String(value || "").trim();
  return model || "gpt-realtime-2.1";
}

function readCodexOAuthAccessToken(authPath) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(authPath, "utf8"));
  } catch {
    throw new Error(
      "Codex OAuth is unavailable. Sign in to the Codex/ChatGPT desktop app.",
    );
  }
  const accessToken = String(parsed?.tokens?.access_token || "").trim();
  if (!accessToken) {
    throw new Error(
      "Codex OAuth is unavailable. Sign in to the Codex/ChatGPT desktop app.",
    );
  }
  return accessToken;
}

export async function requestRealtimeCredential(
  params = {},
  options = {},
) {
  const model = normalizedModel(params.model);
  const authPath = path.resolve(
    String(
      options.authPath ||
        process.env.CODEX_AUTH_JSON ||
        path.join(os.homedir(), ".codex", "auth.json"),
    ),
  );
  const accessToken = readCodexOAuthAccessToken(authPath);
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const response = await fetchImpl(credentialEndpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model,
      },
    }),
    signal: AbortSignal.timeout(30_000),
  });
  const responseText = await response.text();
  let payload = {};
  try {
    payload = responseText ? JSON.parse(responseText) : {};
  } catch {}
  if (!response.ok) {
    throw new Error(
      `Could not create a temporary Realtime credential (${response.status})`,
    );
  }
  const clientSecret = String(
    payload?.value ||
      payload?.client_secret?.value ||
      "",
  ).trim();
  if (!clientSecret) {
    throw new Error(
      "The Realtime credential response did not include a temporary secret",
    );
  }
  const expiresAt = Number(
    payload?.expires_at ||
      payload?.client_secret?.expires_at ||
      0,
  );
  if (
    Number.isFinite(expiresAt) &&
    expiresAt > 0 &&
    expiresAt <= Math.floor(Date.now() / 1000) + 5
  ) {
    throw new Error(
      "The Realtime service returned an expired temporary credential",
    );
  }
  return {
    clientSecret,
    model,
    expiresAt: Number.isFinite(expiresAt) ? expiresAt : 0,
  };
}
