#!/usr/bin/env bash
# Simulator checks on macOS, in three stages (each a separate CI step):
#   ui-check.sh build   builds Paradise and the UI tests for the iOS Simulator
#   ui-check.sh shots   takes screenshots of the demo scenarios on several devices
#   ui-check.sh tests   runs the UI tests on the main device
# Results go to build/report. Needs apple/Frameworks/PDCore.xcframework with a simulator slice.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/build/report"
DERIVED="$ROOT/build/SimData"
STATE="$ROOT/build/devices.env"
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

runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")'
}

# device LABEL RUNTIME NAME... creates a simulator of the first device type that exists, prints its UDID
device() {
  local label=$1 rt=$2 types id name
  shift 2
  types=$(xcrun simctl list devicetypes -j)
  for name in "$@"; do
    id=$(python3 -c '
import json, sys
for t in json.loads(sys.argv[1])["devicetypes"]:
    if t["name"] == sys.argv[2]:
        print(t["identifier"]); break' "$types" "$name")
    if [ -n "$id" ] && xcrun simctl create "$label" "$id" "$rt" 2>/dev/null; then
      echo "$label: $name" >> "$REPORT/summary.txt"
      return 0
    fi
  done
  return 1
}

stage_build() {
  local rt main
  rt=$(runtime)
  [ -n "$rt" ] || { note "no iOS simulator runtime"; exit 1; }
  note "runtime: $rt"
  main=$(device main "$rt" "iPhone 14 Pro" "iPhone 15 Pro" "iPhone 16 Pro" "iPhone 17 Pro") || { note "no simulator for the main device"; exit 1; }
  {
    echo "RUNTIME=$rt"
    echo "MAIN=$main"
  } > "$STATE"
  command -v xcodegen >/dev/null || brew install xcodegen
  (cd "$ROOT/apple" && xcodegen generate --spec project.yml) > "$REPORT/xcodegen.log" 2>&1 || { note "xcodegen failed"; annotate xcodegen "$REPORT/xcodegen.log"; exit 1; }
  xcodebuild -project "$ROOT/apple/Paradise.xcodeproj" -scheme Paradise -configuration Debug \
    -destination "platform=iOS Simulator,id=$main" -derivedDataPath "$DERIVED" \
    ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build-for-testing > "$REPORT/build.log" 2>&1
  if [ $? -ne 0 ]; then
    grep -E "error:|fatal error|Undefined symbol|ld: " "$REPORT/build.log" | sort -u | head -120 > "$REPORT/errors.txt"
    [ -s "$REPORT/errors.txt" ] || tail -n 80 "$REPORT/build.log" > "$REPORT/errors.txt"
    note "BUILD FAILED"
    annotate "simulator build" "$REPORT/errors.txt"
    exit 1
  fi
  grep -E "warning:" "$REPORT/build.log" | grep -v "/Frameworks/" | sort -u > "$REPORT/warnings.txt"
  note "build ok"
}

app_path() {
  find "$DERIVED/Build/Products" -maxdepth 2 -name Paradise.app -path "*iphonesimulator*" | head -1
}

shoot() {
  local udid=$1 tag=$2 app scenario
  shift 2
  app=$(app_path)
  xcrun simctl boot "$udid" 2>/dev/null
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time "00:42" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl install "$udid" "$app" || { note "install failed on $tag"; return 1; }
  for scenario in "$@"; do
    xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1
    xcrun simctl launch "$udid" "$BUNDLE" -ParadiseDemo "$scenario" -pref.language en > /dev/null || note "launch failed: $tag $scenario"
    sleep 6
    xcrun simctl io "$udid" screenshot "$REPORT/shots/$tag-$scenario.png" > /dev/null 2>&1 || note "screenshot failed: $tag $scenario"
  done
  xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1
}

stage_shots() {
  # shellcheck disable=SC1090
  source "$STATE"
  local small large tablet
  # shellcheck disable=SC2086
  shoot "$MAIN" main $SCENARIOS
  ls "$REPORT/shots" >> "$REPORT/summary.txt"
  small=$(device small "$RUNTIME" "iPhone SE (2nd generation)" "iPhone SE (3rd generation)" "iPhone 16e") || small=""
  if [ -n "$small" ]; then shoot "$small" small reference connected long collapsed; xcrun simctl shutdown "$small"; fi
  large=$(device large "$RUNTIME" "iPhone 17 Pro Max" "iPhone 16 Pro Max" "iPhone 15 Pro Max") || large=""
  if [ -n "$large" ]; then shoot "$large" large reference connected; xcrun simctl shutdown "$large"; fi
  tablet=$(device tablet "$RUNTIME" "iPad Air 11-inch (M3)" "iPad Air 11-inch (M2)" "iPad (A16)" "iPad (10th generation)") || tablet=""
  if [ -n "$tablet" ]; then shoot "$tablet" tablet reference; xcrun simctl shutdown "$tablet"; fi
  ls "$REPORT/shots" > "$REPORT/shots.txt"
  note "screenshots done"
}

stage_tests() {
  # shellcheck disable=SC1090
  source "$STATE"
  xcodebuild test-without-building -project "$ROOT/apple/Paradise.xcodeproj" -scheme Paradise \
    -destination "platform=iOS Simulator,id=$MAIN" -derivedDataPath "$DERIVED" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300 \
    -resultBundlePath "$ROOT/build/UITests.xcresult" > "$REPORT/uitests.log" 2>&1
  local status=$?
  grep -E "Test Case .*(passed|failed)|: error: |Executed [0-9]+ test|Test Suite .* (passed|failed)" "$REPORT/uitests.log" > "$REPORT/uitests-summary.txt"
  mkdir -p "$REPORT/failures"
  xcrun xcresulttool export attachments --path "$ROOT/build/UITests.xcresult" --output-path "$REPORT/failures" --only-failures > /dev/null 2>&1 || true
  if [ $status -ne 0 ]; then
    note "UI TESTS FAILED"
    grep -E "failed|error:" "$REPORT/uitests-summary.txt" > "$REPORT/uitests-failures.txt"
    [ -s "$REPORT/uitests-failures.txt" ] || tail -n 60 "$REPORT/uitests.log" > "$REPORT/uitests-failures.txt"
    annotate "UI tests" "$REPORT/uitests-failures.txt"
  else
    note "UI tests passed"
  fi
  return $status
}

case "${1:-}" in
  build) stage_build ;;
  shots) stage_shots ;;
  tests) stage_tests ;;
  *) echo "usage: $0 build|shots|tests"; exit 2 ;;
esac
