#!/usr/bin/env bash
# End to end without a phone: for each fixture, the Mac agent with a fake poster, fake-phone
# playing the fixture to it over the real link, and the agent's poster log diffed against what
# `phice-replay --driver` predicts for the same frames.
#
#   scripts/e2e.sh [fixture ...]        default: every fixture
#
# The agent is restarted for each fixture: its driver keeps the last move's phone timestamp across
# connections, and every fixture's clock starts near zero, so a second fixture on the same agent
# would start with a zero interval that an offline replay never sees.
# Momentum steps follow the Mac's clock, not the phone's, so lines with a momentum phase are left
# out of the comparison. The first run may show a Local Network prompt; allow it and run again.
set -uo pipefail
cd "$(dirname "$0")/.."

fixtures=Tests/PhiceCoreTests/Fixtures
agent=.build/xcode/Build/Products/Debug/Phice.app/Contents/MacOS/Phice
work=$(mktemp -d /tmp/phice-e2e.XXXXXX)

echo "==> building fake-phone, phice-replay and the Debug agent (logs in $work)"
swift build --product fake-phone > "$work/build.log" 2>&1 \
  && swift build --product phice-replay >> "$work/build.log" 2>&1 \
  && (cd Apps && xcodegen generate --quiet \
      && xcodebuild -project Phice.xcodeproj -scheme PhiceMac -derivedDataPath ../.build/xcode \
         CODE_SIGNING_ALLOWED=NO build) >> "$work/build.log" 2>&1 \
  || { echo "build failed:"; tail -20 "$work/build.log"; exit 1; }
bin=$(swift build --show-bin-path)

if [ $# -gt 0 ]; then names=("$@"); else
  names=($(ls "$fixtures" | sed -n 's/\.frames\.jsonl$//p'))
fi

failed=()
for name in "${names[@]}"; do
  log="$work/$name.calls.jsonl"
  "$agent" --fake-poster "$log" --auto-allow > "$work/$name.agent.log" 2>&1 &
  pid=$!
  "$bin/fake-phone" --fixture "$name" > "$work/$name.phone.log" 2>&1
  phone=$?
  sleep 0.5  # let the agent write the last calls
  kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null

  settings=""
  [ -f "$fixtures/$name.settings.json" ] && settings="$fixtures/$name.settings.json"
  "$bin/phice-replay" "$fixtures/$name.frames.jsonl" ${settings:+--settings "$settings"} --driver \
    > "$work/$name.expected.jsonl"
  grep -v '"momentum"' "$work/$name.expected.jsonl" > "$work/$name.expected.cmp"
  grep -sv '"momentum"' "$log" > "$work/$name.got.cmp"
  note=""
  grep -q '"momentum"' "$work/$name.expected.jsonl" && note=" (momentum not compared)"

  if [ $phone -ne 0 ]; then
    echo "FAIL $name: fake-phone exited $phone: $(tail -1 "$work/$name.phone.log")"
    failed+=("$name")
  elif ! diff -q "$work/$name.expected.cmp" "$work/$name.got.cmp" > /dev/null; then
    echo "FAIL $name: the agent posted something else"
    diff "$work/$name.expected.cmp" "$work/$name.got.cmp" | sed -n 1,8p | cut -c1-160 | sed 's/^/     /'
    failed+=("$name")
  else
    echo "pass $name: $(wc -l < "$work/$name.got.cmp" | tr -d ' ') calls$note"
  fi
done

if [ ${#failed[@]} -eq 0 ]; then echo "==> all ${#names[@]} passed"; exit 0; fi
echo "==> ${#failed[@]} of ${#names[@]} failed: ${failed[*]}"
exit 1
