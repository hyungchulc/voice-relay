export function resolveVoiceRelayThreadID(...candidates) {
  for (const candidate of candidates) {
    const threadID = String(candidate || "").trim();
    if (threadID) return threadID;
  }
  return "";
}
