import fs from "node:fs";
import path from "node:path";

export const DEFAULT_CODEX_APP_PATH = "/Applications/ChatGPT.app";
export const LEGACY_CODEX_APP_PATH = "/Applications/Codex.app";

export function codexAppPathCandidates(configuredPath = "") {
  return uniquePaths([
    configuredPath,
    DEFAULT_CODEX_APP_PATH,
    LEGACY_CODEX_APP_PATH,
  ]);
}

export function resolveCodexAppPath(
  configuredPath = process.env.CODEX_APP_PATH || "",
  { existsSync = fs.existsSync } = {},
) {
  const candidates = codexAppPathCandidates(configuredPath);
  return candidates.find((candidate) => existsSync(candidate)) || candidates[0];
}

export function resolveCodexResourcePath(
  relativePath,
  {
    appPath = process.env.CODEX_APP_PATH || "",
    existsSync = fs.existsSync,
  } = {},
) {
  const candidates = codexAppPathCandidates(appPath).map((candidate) =>
    path.join(candidate, "Contents", "Resources", relativePath),
  );
  return candidates.find((candidate) => existsSync(candidate)) || candidates[0];
}

export function codexResourceExecutableCandidates(relativePath) {
  return codexAppPathCandidates().map((candidate) =>
    path.join(candidate, "Contents", "Resources", relativePath),
  );
}

export function codexAppExecutableCandidates() {
  return codexAppPathCandidates().flatMap((candidate) => [
    path.join(candidate, "Contents", "MacOS", "ChatGPT"),
    path.join(candidate, "Contents", "MacOS", "Codex"),
  ]);
}

export function commandUsesExecutable(command, candidates) {
  const text = String(command || "").trim();
  return candidates.some(
    (candidate) => text === candidate || text.startsWith(`${candidate} `),
  );
}

function uniquePaths(values) {
  return [
    ...new Set(
      values.map((value) => String(value || "").trim()).filter(Boolean),
    ),
  ];
}
