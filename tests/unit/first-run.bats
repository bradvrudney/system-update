#!/usr/bin/env bats
# selfupdate_first_run (uberhacker/system-update#10): which installation a
# single file's first run makes, and when it makes none. The end-to-end runs
# are in bundle.bats.

load ../test_helper

setup() {
  SU_OUT=1
  export SU_OS_RELEASE="$FIXTURES/os-release/arch.txt"
  export SU_SYSTEM_CONFIG=/nonexistent SU_CONFIG_FILE="$BATS_TEST_TMPDIR/empty.conf"
  export HOME="$BATS_TEST_TMPDIR/home" SU_INSTALL_ROOT="$BATS_TEST_TMPDIR/usr-local"
  export PATH="/usr/bin:/bin"
  mkdir -p "$HOME"
  : > "$SU_CONFIG_FILE"
  load_su
  SU_BUNDLED=1
  SU_BIN="$BATS_TEST_TMPDIR/system-update"
  SU_DRY_RUN=0
  # Record the mode instead of installing.
  selfupdate_install() { echo "install $1"; }
}

@test "as root it installs system-wide (sudo ./system-update)" {
  is_root() { return 0; }
  run selfupdate_first_run
  assert_equal 0 "$status"
  assert_contains "$output" "install system"
}

@test "as a user it installs into ~/.local/bin, without sudo" {
  is_root() { return 1; }
  run selfupdate_first_run
  assert_contains "$output" "install user"
}

@test "a failed installation is a warning; the run goes on" {
  is_root() { return 1; }
  selfupdate_install() { return 1; }
  run selfupdate_first_run
  assert_equal 0 "$status"
  assert_contains "$output" "could not install system-update"
}

@test "not a single file, turned off, or already installed: nothing" {
  is_root() { return 1; }
  SU_BUNDLED=0
  run selfupdate_first_run
  assert_equal "" "$output"
  SU_BUNDLED=1
  config_set FIRST_RUN_INSTALL 0 test
  run selfupdate_first_run
  assert_equal "" "$output"
  config_set FIRST_RUN_INSTALL 1 test
  mkdir -p "$SU_INSTALL_ROOT/bin"
  : > "$SU_INSTALL_ROOT/bin/system-update"
  run selfupdate_first_run
  assert_equal "" "$output"
}

@test "--no-install sets FIRST_RUN_INSTALL=0" {
  args_parse --no-install
  args_apply
  assert_equal 0 "$(cfg FIRST_RUN_INSTALL)"
}
