import fs from "node:fs";
import path from "node:path";
import {
  normalizeModelForConfig,
  normalizeModelForUi,
  normalizeReasoningForConfig,
  normalizeReasoningForPersistentUi,
} from "./codex-control-command.js";

export function writeDesiredCodexState(filePath, update) {
  if (!filePath) return null;
  const previous = readDesiredCodexState(filePath) || {};
  const next = {
    ...previous,
    ...(update.modelText ? { modelText: normalizeModelForUi(update.modelText) } : {}),
    ...(update.reasoningText
      ? { reasoningText: normalizeReasoningForPersistentUi(update.reasoningText) }
      : {}),
    updatedAt: new Date().toISOString(),
  };
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmpPath = `${filePath}.tmp`;
  fs.writeFileSync(tmpPath, `${JSON.stringify(next, null, 2)}\n`);
  fs.renameSync(tmpPath, filePath);
  return next;
}

export function readDesiredCodexState(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null;
  try {
    const data = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const normalized = {
      ...(data?.modelText ? { modelText: normalizeModelForUi(data.modelText) } : {}),
      ...(data?.reasoningText
        ? { reasoningText: normalizeReasoningForPersistentUi(data.reasoningText) }
        : {}),
      ...(data?.updatedAt ? { updatedAt: String(data.updatedAt) } : {}),
    };
    if (data?.reasoningText && normalized.reasoningText !== data.reasoningText) {
      const tmpPath = `${filePath}.tmp`;
      fs.writeFileSync(tmpPath, `${JSON.stringify(normalized, null, 2)}\n`);
      fs.renameSync(tmpPath, filePath);
    }
    return normalized;
  } catch {
    return null;
  }
}

export function clearDesiredCodexState(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return { changed: false, path: filePath };
  fs.rmSync(filePath);
  return { changed: true, path: filePath };
}

export function updateCodexConfigFile(filePath, update) {
  if (!filePath) return { changed: false, path: filePath };
  let text = fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : "";
  const updates = {};
  if (update.modelText) updates.model = normalizeModelForConfig(update.modelText);
  if (update.reasoningText) {
    updates.model_reasoning_effort = normalizeReasoningForConfig(update.reasoningText);
  }
  let changed = false;
  for (const [key, value] of Object.entries(updates)) {
    if (!value) continue;
    const line = `${key} = ${JSON.stringify(value)}`;
    const pattern = new RegExp(`^${escapeRegExp(key)}\\s*=.*$`, "m");
    if (pattern.test(text)) {
      text = text.replace(pattern, (current) => {
        if (current === line) return current;
        changed = true;
        return line;
      });
    } else {
      text = `${line}\n${text}`;
      changed = true;
    }
  }
  if (changed) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const tmpPath = `${filePath}.tmp`;
    fs.writeFileSync(tmpPath, text);
    fs.renameSync(tmpPath, filePath);
  }
  return { changed, path: filePath, updates };
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
