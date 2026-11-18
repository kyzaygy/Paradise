#!/usr/bin/env bash
# Pushes build/report (screenshots, test summaries, build errors) to the ci-screens branch,
# so the results can be read with git without downloading workflow artifacts.
set -euo pipefail
REPORT="$(cd "$(dirname "$0")/.." && pwd)/build/report"
[ -d "$REPORT" ] || exit 0
cd "$REPORT"
printf 'commit %s\nrun %s\n' "${GITHUB_SHA:-local}" "${GITHUB_RUN_NUMBER:-0}" > RUN.txt
git init -q
git checkout -q -b ci-screens
git add -A
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -qm "UI report for ${GITHUB_SHA:-local}"
git push -qf "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" ci-screens
