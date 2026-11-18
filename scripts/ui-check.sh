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
  small=$(device small "$rt" "iPhone SE (2nd generation)" "iPhone SE (3rd generation)" "iPhone 16e") || small=""
  {
    echo "RUNTIME=$rt"
    echo "MAIN=$main"
    echo "SMALL=$small"
  } > "$STATE"
  # simulators boot slowly on CI runners: start them now, while the app builds
  xcrun simctl boot "$main" 2>/dev/null
  [ -n "$small" ] && xcrun simctl boot "$small" 2>/dev/null
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

status_bar() {
  local udid=$1 try
  xcrun simctl spawn "$udid" defaults write -g AppleICUForce24HourTime -bool YES 2>/dev/null
  for try in 1 2 3; do
    xcrun simctl status_bar "$udid" override --time "2026-11-18T00:42:00Z" --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100 2>> "$REPORT/statusbar.txt" && break
    sleep 3
  done
}

shoot() {
  local udid=$1 tag=$2 app container ready scenario i
  shift 2
  app=$(app_path)
  xcrun simctl boot "$udid" 2>/dev/null
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl install "$udid" "$app" || { note "install failed on $tag"; return 1; }
  sleep 5
  status_bar "$udid"
  container=$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)
  ready="$container/tmp/ParadiseDemo/ready"
  # first launch after boot: system banners (e.g. Apple Intelligence) show up and go away
  xcrun simctl launch "$udid" "$BUNDLE" -ParadiseDemo reference -pref.language en > /dev/null 2>&1
  sleep 15
  for scenario in "$@"; do
    xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1
    rm -f "$ready"
    xcrun simctl launch "$udid" "$BUNDLE" -ParadiseDemo "$scenario" -pref.language en > /dev/null || note "launch failed: $tag $scenario"
    for i in $(seq 1 60); do
      [ -f "$ready" ] && break
      sleep 0.5
    done
    if [ -f "$ready" ]; then sleep 2.5; else note "not ready after 30 s: $tag $scenario"; fi
    xcrun simctl io "$udid" screenshot "$REPORT/shots/$tag-$scenario.png" > /dev/null 2>&1 || note "screenshot failed: $tag $scenario"
  done
  xcrun simctl terminate "$udid" "$BUNDLE" > /dev/null 2>&1
  xcrun simctl status_bar "$udid" list >> "$REPORT/statusbar.txt" 2>&1
  xcrun simctl spawn "$udid" log show --last 15m --style compact --predicate 'process == "Paradise"' 2>/dev/null \
    | grep -iE "error|fault|crash|paradise" | tail -n 300 > "$REPORT/applog-$tag.txt"
}

collect_crashes() {
  mkdir -p "$REPORT/crashes"
  find "$HOME/Library/Logs/DiagnosticReports" -name "Paradise*" -mmin -120 -exec cp {} "$REPORT/crashes/" \; 2>/dev/null
  ls "$REPORT/crashes" >> "$REPORT/summary.txt" 2>/dev/null
}

stage_shots() {
  # shellcheck disable=SC1090
  source "$STATE"
  # shellcheck disable=SC2086
  shoot "$MAIN" main $SCENARIOS
  ls "$REPORT/shots" >> "$REPORT/summary.txt"
  # the main device is enough to start comparing: publish it before the small screen
  [ -n "${GH_TOKEN:-}" ] && "$ROOT/scripts/publish-report.sh" > /dev/null 2>&1
  if [ -n "$SMALL" ]; then shoot "$SMALL" small reference connected long collapsed; xcrun simctl shutdown "$SMALL"; fi
  ls "$REPORT/shots" > "$REPORT/shots.txt"
  collect_crashes
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
  collect_crashes
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
