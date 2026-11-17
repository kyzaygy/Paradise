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
  (cd "$ROOT/core" && gomobile bind -target=ios/arm64 -iosversion=16.0 -trimpath \
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
# package NAME APP_ENTITLEMENTS EXT_ENTITLEMENTS EXTENSION
package() {
  local work payload out
  work="$(mktemp -d)"
  mkdir -p "$work/Payload"
  cp -R "$APP" "$work/Payload/"
  payload="$work/Payload/Paradise.app"
  # Ad hoc signature only carries entitlements; re-sign with your own certificate before installing.
  codesign --force --sign - --entitlements "$3" "$payload/PlugIns/PacketTunnel.appex"
  codesign --force --sign - --entitlements "$2" "$payload"
  out="$OUT/Paradise-$VERSION-$BUILD_NUMBER-$1.$4"
  rm -f "$out"
  (cd "$work" && zip -qry "$out" Payload)
  (cd "$OUT" && shasum -a 256 "$(basename "$out")") > "$out.sha256"
  cat "$out.sha256"
  du -h "$out"
}
# For re-signing with a developer certificate (entitlements come from your profile).
package unsigned "$ROOT/apple/Support/Paradise.entitlements" "$ROOT/apple/Support/PacketTunnel.entitlements" ipa
# For TrollStore: carries application-identifier and keychain groups so Keychain and the VPN work.
package trollstore "$ROOT/apple/TrollStore/Paradise.entitlements" "$ROOT/apple/TrollStore/PacketTunnel.entitlements" tipa
echo "$OUT/Paradise-$VERSION-$BUILD_NUMBER-unsigned.ipa" > "$OUT/ipa-path.txt"
