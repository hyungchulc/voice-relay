#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${VOICE_RELAY_OUT:-${ROOT}/build}"
APP_DIR="${OUT_DIR}/Voice Relay.app"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voice-relay.XXXXXX")"
ARCHS="${VOICE_RELAY_ARCHS:-arm64 x86_64}"
SIGNING_IDENTITY="${VOICE_RELAY_SIGNING_IDENTITY:--}"
if [[ "$#" -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi
SPARKLE_ROOT="$("$ROOT/fetch-sparkle.sh")"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.framework"

bash "$ROOT/Tests/SourcePolicyTests.sh"
node "$ROOT/Tests/RealtimeResponseQueueTests.mjs"
node "$ROOT/Tests/ContextProviderTests.mjs"
node "$ROOT/Tests/RealtimeCredentialTests.mjs"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

if [[ "$APP_DIR" != */"Voice Relay.app" ]]; then
  echo "Refusing unexpected app output path: $APP_DIR" >&2
  exit 2
fi
rm -rf "$APP_DIR"
mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources" \
  "$APP_DIR/Contents/Frameworks"

SOURCES=(
  "$ROOT/Sources/AppLocalization.swift"
  "$ROOT/Sources/AmbientBackdropView.swift"
  "$ROOT/Sources/VoiceRelayOverlay.swift"
  "$ROOT/Sources/AuthorityPackComposer.swift"
  "$ROOT/Sources/CodexAppRemoteClient.swift"
  "$ROOT/Sources/LaunchAtLoginManager.swift"
  "$ROOT/Sources/OverlayPlacement.swift"
  "$ROOT/Sources/OnboardingWindowController.swift"
  "$ROOT/Sources/PresenceMonitor.swift"
  "$ROOT/Sources/SettingsStore.swift"
  "$ROOT/Sources/VoiceRelayUpdater.swift"
  "$ROOT/Sources/SettingsWindowController.swift"
  "$ROOT/Sources/SystemMediaPlaybackDetector.swift"
  "$ROOT/Sources/VoiceSurfacePolicy.swift"
  "$ROOT/Sources/VoiceOrbView.swift"
  "$ROOT/Sources/WakePhraseController.swift"
  "$ROOT/Sources/RealtimeAudioAdmissionPolicy.swift"
  "$ROOT/Sources/RealtimeEchoAdmissionPolicy.swift"
  "$ROOT/Sources/NativeRealtimeAudioTransport.swift"
  "$ROOT/Sources/DirectRealtimeController.swift"
)

ARCH_BINARIES=()
for arch in $ARCHS; do
  arch_binary="$BUILD_DIR/VoiceRelay-$arch"
  xcrun swiftc \
    -parse-as-library \
    -target "$arch-apple-macos14.0" \
    "${SOURCES[@]}" \
    -o "$arch_binary" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework ServiceManagement \
    -framework Speech \
    -framework WebKit \
    -framework Security \
    -F "$SPARKLE_ROOT" \
    -framework Sparkle \
    -Xlinker -rpath \
    -Xlinker @executable_path/../Frameworks \
    -O
  ARCH_BINARIES+=("$arch_binary")
done

if [[ "${#ARCH_BINARIES[@]}" -eq 1 ]]; then
  cp "${ARCH_BINARIES[0]}" "$BUILD_DIR/VoiceRelay"
else
  xcrun lipo -create "${ARCH_BINARIES[@]}" -output "$BUILD_DIR/VoiceRelay"
fi
HOST_ARCH="$(uname -m)"
xcrun swiftc \
  -parse-as-library \
  -target "$HOST_ARCH-apple-macos14.0" \
  "$ROOT/Sources/AppLocalization.swift" \
  "$ROOT/Sources/AuthorityPackComposer.swift" \
  "$ROOT/Sources/CodexAppRemoteClient.swift" \
  "$ROOT/Sources/LaunchAtLoginManager.swift" \
  "$ROOT/Sources/OverlayPlacement.swift" \
  "$ROOT/Sources/PresenceMonitor.swift" \
  "$ROOT/Sources/SettingsStore.swift" \
  "$ROOT/Sources/VoiceSurfacePolicy.swift" \
  "$ROOT/Sources/RealtimeAudioAdmissionPolicy.swift" \
  "$ROOT/Sources/RealtimeEchoAdmissionPolicy.swift" \
  "$ROOT/Tests/PolicyTests.swift" \
  -o "$BUILD_DIR/VoiceRelayPolicyTests" \
  -framework Cocoa \
  -framework ServiceManagement \
  -framework Security
"$BUILD_DIR/VoiceRelayPolicyTests"

cp "$BUILD_DIR/VoiceRelay" "$APP_DIR/Contents/MacOS/VoiceRelay"
/usr/bin/ditto \
  "$SPARKLE_FRAMEWORK" \
  "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT/Resources/authority-pack.json" \
  "$APP_DIR/Contents/Resources/authority-pack.json"
cp "$ROOT/Resources/VoiceRelay.icns" "$APP_DIR/Contents/Resources/VoiceRelay.icns"
cp "$ROOT/Resources/VoiceRelayIcon-1024.png" \
  "$APP_DIR/Contents/Resources/VoiceRelayIcon-1024.png"
mkdir -p "$APP_DIR/Contents/Resources/Helpers"
cp "$ROOT/Helpers/voice-relay-app-remote.mjs" \
  "$APP_DIR/Contents/Resources/Helpers/voice-relay-app-remote.mjs"
cp "$ROOT/Helpers/voice-relay-context.mjs" \
  "$APP_DIR/Contents/Resources/Helpers/voice-relay-context.mjs"
cp "$ROOT/Helpers/voice-relay-realtime-credential.mjs" \
  "$APP_DIR/Contents/Resources/Helpers/voice-relay-realtime-credential.mjs"
cp "$ROOT/Helpers/voice-relay-thread-policy.mjs" \
  "$APP_DIR/Contents/Resources/Helpers/voice-relay-thread-policy.mjs"
mkdir -p "$APP_DIR/Contents/Resources/Support"
cp -R "$ROOT/Support/CodexRemote" \
  "$APP_DIR/Contents/Resources/Support/CodexRemote"
chmod +x "$APP_DIR/Contents/MacOS/VoiceRelay"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
plutil -lint "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
node -e \
  'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
  "$APP_DIR/Contents/Resources/authority-pack.json"
SPARKLE_BUNDLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  SIGN_ARGS=(--force --sign -)
else
  SIGN_ARGS+=(--options runtime --timestamp=none)
fi
/usr/bin/codesign \
  "${SIGN_ARGS[@]}" \
  "$SPARKLE_BUNDLE/Versions/B/XPCServices/Installer.xpc" >/dev/null
/usr/bin/codesign \
  "${SIGN_ARGS[@]}" \
  --preserve-metadata=entitlements \
  "$SPARKLE_BUNDLE/Versions/B/XPCServices/Downloader.xpc" >/dev/null
/usr/bin/codesign \
  "${SIGN_ARGS[@]}" \
  "$SPARKLE_BUNDLE/Versions/B/Autoupdate" >/dev/null
/usr/bin/codesign \
  "${SIGN_ARGS[@]}" \
  "$SPARKLE_BUNDLE/Versions/B/Updater.app" >/dev/null
/usr/bin/codesign \
  "${SIGN_ARGS[@]}" \
  "$SPARKLE_BUNDLE" >/dev/null

if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  /usr/bin/codesign \
    --force \
    --sign - \
    --entitlements "$ROOT/Resources/VoiceRelay.entitlements" \
    --requirements '=designated => identifier "com.hyungchulc.voice-relay"' \
    "$APP_DIR" >/dev/null
else
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT/Resources/VoiceRelay.entitlements" \
    "$APP_DIR" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
