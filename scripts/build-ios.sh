#!/usr/bin/env bash
# Builds an unsigned Paradise IPA on macOS (Xcode + Go required).
# Usage: scripts/build-ios.sh [build-number]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_NUMBER="${1:-1}"
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.0.0-20261011034528-197770444867}"
FRAMEWORK="$ROOT/apple/Frameworks/PDCore.xcframework"
OUT="$ROOT/build"
mkdir -p "$OUT"

if [ ! -d "$FRAMEWORK" ]; then
  echo "==> Building Go core (gomobile)"
  export PATH="$(go env GOPATH)/bin:$PATH"
  go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
  go install "golang.org/x/mobile/cmd/gobind@$GOMOBILE_VERSION"
  gomobile init
  (cd "$ROOT/core" && gomobile bind -target=ios/arm64 -iosversion=17.0 -trimpath \
    -ldflags='-checklinkname=0 -s -w' -o "$FRAMEWORK" ./pdcore)
fi

echo "==> Generating Xcode project"
command -v xcodegen >/dev/null || brew install xcodegen
(cd "$ROOT/apple" && xcodegen generate --spec project.yml)

echo "==> Building app and Packet Tunnel"
LOG="$OUT/xcodebuild.log"
set +e
xcodebuild -project "$ROOT/apple/Paradise.xcodeproj" -scheme Paradise -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build > "$LOG" 2>&1
STATUS=$?
set -e
if [ $STATUS -ne 0 ]; then
  grep -E "error:|fatal error|Undefined symbol|ld: " "$LOG" | sort -u | head -80 || true
  tail -n 60 "$LOG"
  exit $STATUS
fi

APP="$OUT/DerivedData/Build/Products/Release-iphoneos/Paradise.app"
test -d "$APP/PlugIns/PacketTunnel.appex" || { echo "PacketTunnel.appex is missing"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")

echo "==> Packaging IPA"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
PAYLOAD_APP="$WORK/Payload/Paradise.app"
# Ad hoc signature only to carry entitlements; re-sign with your own certificate before installing.
codesign --force --sign - --entitlements "$ROOT/apple/Support/PacketTunnel.entitlements" "$PAYLOAD_APP/PlugIns/PacketTunnel.appex"
codesign --force --sign - --entitlements "$ROOT/apple/Support/Paradise.entitlements" "$PAYLOAD_APP"
IPA="$OUT/Paradise-$VERSION-$BUILD_NUMBER-unsigned.ipa"
rm -f "$IPA"
(cd "$WORK" && zip -qry "$IPA" Payload)
shasum -a 256 "$IPA" | tee "$IPA.sha256"
du -h "$IPA"
echo "$IPA" > "$OUT/ipa-path.txt"
