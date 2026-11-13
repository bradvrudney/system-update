#!/usr/bin/env bats
# Devin CLI: the public release manifest decides whether "devin update" runs
# at all, and a hung self-update command is cut off by TOOL_TIMEOUT.

load ../test_helper

setup() {
  SU_OUT=1
  load_su
  gh_stub_init
  bindir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bindir"
  export PATH="$bindir:$PATH"
  export SU_PROBE_TIMEOUT=5
  export SU_TIMEOUT=20
  SU_PKG=apt
  SU_DRY_RUN=0
  STEP_RESULT=""; STEP_NOTE=""
  manifest="$CURL_STUB_DIR/cli/current/manifest.json.json"
  mkdir -p "${manifest%/*}"
  calls="$BATS_TEST_TMPDIR/calls"
  : > "$calls"
}

# fake_devin VERSION [UPDATE_BODY]: a devin that prints VERSION and records
# each "devin update" call; the update body defaults to a quick success.
fake_devin() {
  make_fake_bin "$bindir" devin "case \"\$1\" in
  --version) cat \"$BATS_TEST_TMPDIR/ver\" 2>/dev/null || echo $1 ;;
  update) echo update >> \"$calls\"; ${2:-echo 3000.12.0 > \"$BATS_TEST_TMPDIR/ver\"} ;;
esac"
  tools_discover
}

serve_manifest() { printf '{"version":"%s","platforms":{}}\n' "$1" > "$manifest"; }

@test "already on the manifest version: up to date without running devin update" {
  fake_devin 3000.11.234 'while :; do sleep 1; done'
  serve_manifest 3000.11.234
  tool_devin_update
  assert_equal ok "$STEP_RESULT"
  assert_equal "up to date (3000.11.234)" "$STEP_NOTE"
  [ ! -s "$calls" ]
  grep -q 'static.devin.ai/cli/current/manifest.json$' "$CURL_STUB_LOG"
}

@test "older than the manifest: devin update runs and the summary shows the change" {
  fake_devin 3000.11.234
  serve_manifest 3000.12.0
  tool_devin_update
  assert_equal updated "$STEP_RESULT"
  assert_equal "3000.11.234 -> 3000.12.0" "$STEP_NOTE"
  assert_equal update "$(cat "$calls")"
}

@test "manifest unreachable: falls back to devin update" {
  fake_devin 3000.11.234 'echo "You are already on the latest version."'
  tool_devin_update
  assert_equal ok "$STEP_RESULT"
  assert_equal update "$(cat "$calls")"
}

@test "dry run against the manifest names both versions and runs nothing" {
  fake_devin 3000.11.234
  serve_manifest 3000.12.0
  SU_DRY_RUN=1
  tool_devin_update
  assert_equal dry-run "$STEP_RESULT"
  assert_contains "$STEP_NOTE" "3000.11.234 -> 3000.12.0"
  [ ! -s "$calls" ]
}

@test "a hanging devin update is cut off by TOOL_TIMEOUT and the note names it" {
  fake_devin 3000.11.234 'while :; do sleep 1; done'
  serve_manifest 3000.12.0
  SU_TOOL_TIMEOUT=2
  local start end
  start=$(date +%s)
  tool_devin_update
  end=$(date +%s)
  assert_equal failed "$STEP_RESULT"
  assert_contains "$STEP_NOTE" "timed out after 2s"
  [ $((end - start)) -lt 15 ]
}

@test "devin update that installs the new version but never exits counts as updated" {
  fake_devin 3000.12.28 "echo 3000.12.32 > \"$BATS_TEST_TMPDIR/ver\"; while :; do sleep 1; done"
  serve_manifest 3000.12.32
  SU_TOOL_TIMEOUT=2
  tool_devin_update
  assert_equal updated "$STEP_RESULT"
  assert_contains "$STEP_NOTE" "3000.12.28 -> 3000.12.32"
  assert_contains "$STEP_NOTE" "did not exit"
}

@test "a hung devin update that changed nothing says how to see what it waits for" {
  fake_devin 3000.12.28 'while :; do sleep 1; done'
  serve_manifest 3000.12.32
  SU_TOOL_TIMEOUT=2
  tool_devin_update
  assert_equal failed "$STEP_RESULT"
  assert_contains "$STEP_NOTE" "still 3000.12.28"
  assert_contains "$STEP_NOTE" "run 'devin update' in a terminal"
}

# Ed's issue 11: "devin update" sat for the whole TOOL_TIMEOUT and changed
# nothing. Run from a terminal, `timeout` puts the updater in a background
# process group, so an updater that asks on /dev/tty is stopped by SIGTTIN
# and waits silently. The test runs the step inside a pseudo-terminal
# (script(1)) to have a terminal to ask on; bats itself has none.
@test "a devin update that asks on the terminal fails at once instead of waiting for TOOL_TIMEOUT (issue 11)" {
  command -v script >/dev/null 2>&1 || skip "script(1) not installed"
  setsid_usable || skip "util-linux setsid not installed"
  fake_devin 3000.12.43 "echo 'Install 3000.12.57? [Y/n]' > /dev/tty && read -r a < /dev/tty && echo 3000.12.57 > \"$BATS_TEST_TMPDIR/ver\" || { echo 'no terminal to ask on' >&2; exit 1; }"
  serve_manifest 3000.12.57
  cat > "$BATS_TEST_TMPDIR/driver.sh" <<DRIVER
BATS_TEST_FILENAME="$BATS_TEST_FILENAME"
BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR"
source "$REPO_ROOT/tests/test_helper.bash"
SU_OUT=1
load_su
gh_stub_init
export PATH="$bindir:\$PATH"
SU_PROBE_TIMEOUT=5 SU_TIMEOUT=20 SU_TOOL_TIMEOUT=8 SU_PKG=apt SU_DRY_RUN=0
tools_discover
tool_devin_update >/dev/null 2>&1
printf '%s|%s\\n' "\$STEP_RESULT" "\$STEP_NOTE" > "$BATS_TEST_TMPDIR/result"
DRIVER
  local start end
  start=$(date +%s)
  SHELL=/bin/bash timeout 60 script -qec "bash $BATS_TEST_TMPDIR/driver.sh" /dev/null </dev/null >/dev/null 2>&1 || true
  end=$(date +%s)
  assert_equal "update" "$(cat "$calls")"
  assert_contains "$(cat "$BATS_TEST_TMPDIR/result")" "failed|update command failed (exit code 1)"
  [ $((end - start)) -lt 8 ]
}
