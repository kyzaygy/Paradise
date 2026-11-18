#!/usr/bin/env bash
# Simulator checks on macOS: builds Paradise for the iOS Simulator, takes screenshots of the
# demo scenarios on several iPhones and runs the UI tests. Results go to build/report.
# Needs apple/Frameworks/PDCore.xcframework with a simulator slice (see .github/workflows/ui.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/build/report"
DERIVED="$ROOT/build/SimData"
BUNDLE=com.kyzaygy.paradise
SCENARIOS="reference connecting connected empty long full collapsed search favorites routes"
mkdir -p "$REPORT/shots"
note() { echo "$*" | tee -a "$REPORT/summary.txt"; }

# One GitHub annotation with the first lines of a file (annotations are readable without login).
annotate() {
  local title=$1 file=$2
  [ -s "$file" ] || return 0
  echo "::error title=$title::$(head -60 "$file" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')"
}

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')
[ -n "$RUNTIME" ] || { note "no iOS simulator runtime"; exit 1; }
note "runtime: $RUNTIME"

# device LABEL NAME... creates a simulator of the first device type that exists, prints its UDID
device() {
  local label=$1 types id name
  shift
  types=$(xcrun simctl list devicetypes -j)
  for name in "$@"; do
    id=$(python3 -c '
import json, sys
for t in json.loads(sys.argv[1])["devicetypes"]:
    if t["name"] == sys.argv[2]:
        print(t["identifier"]); break' "$types" "$name")
    if [ -n "$id" ] && xcrun simctl create "$label" "$id" "$RUNTIME" 2>/dev/null; then
      echo "$label: $name" >> "$REPORT/summary.txt"
      return 0
    fi
  done
  return 1
}

MAIN=$(device main "iPhone 14 Pro" "iPhone 15 Pro" "iPhone 16 Pro" "iPhone 17 Pro") || { note "no simulator for the main device"; exit 1; }
SMALL=$(device small "iPhone SE (2nd generation)" "iPhone SE (3rd generation)" "iPhone 16e") || SMALL=""
LARGE=$(device large "iPhone 17 Pro Max" "iPhone 16 Pro Max" "iPhone 15 Pro Max") || LARGE=""
TABLET=$(device tablet "iPad Air 11-inch (M3)" "iPad Air 11-inch (M2)" "iPad (A16)" "iPad (10th generation)") || TABLET=""

echo "==> Generating Xcode project"
command -v xcodegen >/dev/null || brew install xcodegen
(cd "$ROOT/apple" && xcodegen generate --spec project.yml) > "$REPORT/xcodegen.log" 2>&1 || { note "xcodegen failed"; annotate xcodegen "$REPORT/xcodegen.log"; exit 1; }

echo "==> Building for the simulator"
xcodebuild -project "$ROOT/apple/Paradise.xcodeproj" -scheme Paradise -configuration Debug \
  -destination "platform=iOS Simulator,id=$MAIN" -derivedDataPath "$DERIVED" \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build-for-testing > "$REPORT/build.log" 2>&1
if [ $? -ne 0 ]; then
  grep -E "error:|fatal error|Undefined symbol|ld: " "$REPORT/build.log" | sort -u | head -120 > "$REPORT/errors.txt"
  [ -s "$REPORT/errors.txt" ] || tail -n 80 "$REPORT/build.log" > "$REPORT/errors.txt"
  note "BUILD FAILED"
  annotate "simulator build" "$REPORT/errors.txt"
  exit 1
fi
grep -E "warning:" "$REPORT/build.log" | grep -v "/Frameworks/" | sort -u > "$REPORT/warnings.txt"
APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name Paradise.app -path "*iphonesimulator*" | head -1)
note "build ok: $APP"

shoot() {
  local udid=$1 tag=$2 scenario
  shift 2
  xcrun simctl boot "$udid" 2>/dev/null
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time "00:42" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl install "$udid" "$APP" || { note "install failed on $tag"; return 1; }
  for scenario in "$@"; do
    xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1
    xcrun simctl launch "$udid" "$BUNDLE" -ParadiseDemo "$scenario" -pref.language en > /dev/null || note "launch failed: $tag $scenario"
    sleep 8
    xcrun simctl io "$udid" screenshot "$REPORT/shots/$tag-$scenario.png" > /dev/null 2>&1 || note "screenshot failed: $tag $scenario"
  done
  xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1
}

echo "==> Screenshots"
# shellcheck disable=SC2086
shoot "$MAIN" main $SCENARIOS
[ -n "$SMALL" ] && { shoot "$SMALL" small reference connected long collapsed; xcrun simctl shutdown "$SMALL"; }
[ -n "$LARGE" ] && { shoot "$LARGE" large reference connected; xcrun simctl shutdown "$LARGE"; }
[ -n "$TABLET" ] && { shoot "$TABLET" tablet reference; xcrun simctl shutdown "$TABLET"; }
ls "$REPORT/shots" >> "$REPORT/summary.txt"

echo "==> UI tests"
xcodebuild test-without-building -project "$ROOT/apple/Paradise.xcodeproj" -scheme Paradise \
  -destination "platform=iOS Simulator,id=$MAIN" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$ROOT/build/UITests.xcresult" > "$REPORT/uitests.log" 2>&1
TESTS=$?
grep -E "Test Case .*(passed|failed)|: error: |XCTAssert|Executed [0-9]+ test" "$REPORT/uitests.log" > "$REPORT/uitests-summary.txt"
mkdir -p "$REPORT/failures"
xcrun xcresulttool export attachments --path "$ROOT/build/UITests.xcresult" --output-path "$REPORT/failures" --only-failures > /dev/null 2>&1 || true
if [ $TESTS -ne 0 ]; then
  note "UI TESTS FAILED"
  grep -E "failed|error:" "$REPORT/uitests-summary.txt" > "$REPORT/uitests-failures.txt"
  annotate "UI tests" "$REPORT/uitests-failures.txt"
else
  note "UI tests passed"
fi
exit $TESTS
