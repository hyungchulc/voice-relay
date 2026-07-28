#!/usr/bin/env node

let request = "";
for await (const chunk of process.stdin) {
  request += chunk;
  if (Buffer.byteLength(request) > 8 * 1024) {
    throw new Error("The current request is too large");
  }
}

const generatedAt = new Date();
const expiresAt = new Date(generatedAt.getTime() + 60_000);
const requestLength = [...request.trim()].length;

process.stdout.write(
  JSON.stringify({
    schema: "voice-relay-context-v1",
    generatedAt: generatedAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    text: [
      "# Example Device Context",
      `Local time: ${generatedAt.toString()}`,
      `Current request characters: ${requestLength}`,
      "This is synthetic example output. Replace this provider with a reviewed user-owned data source.",
    ].join("\n"),
  }) + "\n",
);
