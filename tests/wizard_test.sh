#!/usr/bin/env bash
# Integration tests for scripts/configure (the layout wizard).
#
# Strategy: mock hyprctl + pgrep, redirect XDG_CONFIG_HOME to a scratch tree,
# drive the wizard with canned answers via a PTY (util-linux `script`), then
# assert on the generated files.
#
# Usage:  ./tests/wizard_test.sh
# Exit:   0 on success, non-zero on any assertion failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIZARD="$REPO_ROOT/hypr/scripts/configure"

PASS=0
FAIL=0

# ---- helpers ----

say() { printf '%s\n' "$*"; }
assert() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    say "  ok   $desc"
  else
    FAIL=$((FAIL + 1))
    say "  FAIL $desc"
    say "       expected: $expected"
    say "       actual:   $actual"
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    say "  ok   $desc"
  else
    FAIL=$((FAIL + 1))
    say "  FAIL $desc"
    say "       expected to contain: $needle"
    say "       actual: $haystack"
  fi
}
assert_file() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    PASS=$((PASS + 1))
    say "  ok   $desc"
  else
    FAIL=$((FAIL + 1))
    say "  FAIL $desc (missing: $path)"
  fi
}

# Build a scratch environment with mocked hyprctl/pgrep and an empty XDG dir.
# Writes its path to stdout.
make_env() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/bin" "$dir/.config/hypr/config"

  cat > "$dir/bin/hyprctl" <<'PYEOF'
#!/usr/bin/env bash
case "$*" in
  "monitors all -j")
    cat <<'JSON'
[
  {"name":"DP-9","description":"Dell U2723QE ABC","width":2560,"height":1440,"refreshRate":119.998,"x":0,"y":0,"scale":1.0,"disabled":false},
  {"name":"DP-8","description":"Dell U2723QE DEF","width":2560,"height":1440,"refreshRate":119.998,"x":2560,"y":0,"scale":1.0,"disabled":false},
  {"name":"DP-10","description":"Dell U2723QE GHI","width":2560,"height":1440,"refreshRate":119.998,"x":5120,"y":0,"scale":1.0,"disabled":false},
  {"name":"eDP-1","description":"","width":1920,"height":1200,"refreshRate":60.0,"x":5120,"y":240,"scale":1.0,"disabled":true}
]
JSON
    ;;
  "monitors -j") echo '[{"name":"DP-9"}]' ;;
esac
exit 0
PYEOF
  chmod +x "$dir/bin/hyprctl"

  # pgrep -x Hyprland returns 1 (not running) so the wizard skips `hyprctl reload`.
  cat > "$dir/bin/pgrep" <<'SEOF'
#!/usr/bin/env bash
[[ "$*" == "-x Hyprland" ]] && exit 1
exec /usr/bin/pgrep "$@"
SEOF
  chmod +x "$dir/bin/pgrep"

  echo "$dir"
}

# Run the wizard against a scratch env, piping stdin answers. Captures output.
# Args: <env_dir> <stdin_contents> <log_path>
run_wizard() {
  local env="$1" answers="$2" log="$3"
  (
    export PATH="$env/bin:$PATH"
    export XDG_CONFIG_HOME="$env/.config"
    # `script` gives the wizard a PTY so `exec </dev/tty` resolves.
    # shellcheck disable=SC2016
    printf '%s' "$answers" | script -qc "$WIZARD" /dev/null
  ) > "$log" 2>&1
}

# ---- test cases ----

test_fresh_run_generates_expected_files() {
  say ""
  say "test: fresh wizard run generates monitors/workspaces/layouts.sh"
  local env log cfg
  env=$(make_env); log="$env/run.log"
  cfg="$env/.config/hypr/config"

  # Answers: 3 layouts (home, work, single); current=1;
  #   home: default split, default marker;
  #   work: 2 mons + laptop, default split, marker "Dell G2725D WORK";
  #   single: 1 mon, default split, no marker.
  local answers=$'3\nhome\nwork\nsingle\n1\n\n\n2\ny\n\nDell G2725D WORK\n1\n\n\n'
  run_wizard "$env" "$answers" "$log"

  assert_file "monitors.home.conf exists"       "$cfg/monitors.home.conf"
  assert_file "monitors.work.conf exists"       "$cfg/monitors.work.conf"
  assert_file "monitors.single.conf exists"     "$cfg/monitors.single.conf"
  assert_file "workspaces.home.conf exists"     "$cfg/workspaces.home.conf"
  assert_file "workspaces.work.conf exists"     "$cfg/workspaces.work.conf"
  assert_file "workspaces.single.conf exists"   "$cfg/workspaces.single.conf"
  assert_file "layouts.sh exists"               "$cfg/layouts.sh"

  # Home captured 3 real descs + 1 disabled laptop.
  assert_contains "home has Dell U2723QE ABC" "$(cat "$cfg/monitors.home.conf")" "desc:Dell U2723QE ABC,2560x1440@120"
  assert_contains "home has disabled eDP"     "$(cat "$cfg/monitors.home.conf")" "monitor=eDP-1,disable"
  assert_contains "refresh rate rounded to 120" "$(cat "$cfg/monitors.home.conf")" "@120"

  # 3/4/3 workspace split for home.
  local hw; hw=$(grep -c 'Dell U2723QE ABC' "$cfg/workspaces.home.conf")
  assert "home left external gets 3 workspaces" "$hw" "3"
  hw=$(grep -c 'Dell U2723QE DEF' "$cfg/workspaces.home.conf")
  assert "home middle external gets 4 workspaces" "$hw" "4"
  hw=$(grep -c 'Dell U2723QE GHI' "$cfg/workspaces.home.conf")
  assert "home right external gets 3 workspaces" "$hw" "3"

  # Current layout symlinked.
  assert_contains "monitors.conf symlinks to home" "$(readlink "$cfg/monitors.conf")" "monitors.home.conf"

  # Detection function exercises.
  # shellcheck disable=SC1091
  . "$cfg/layouts.sh"
  assert "detect_location -> home" "$(detect_location '[{"description":"Dell U2723QE ABC"}]')" "home"
  assert "detect_location -> work" "$(detect_location '[{"description":"Dell G2725D WORK"}]')" "work"
  assert "detect_location -> single (fallback)" "$(detect_location '[{"description":"nothing"}]')" "single"

  rm -rf "$env"
}

test_sanitization_and_dedup() {
  say ""
  say "test: layout names reject spaces and duplicates"
  local env log
  env=$(make_env); log="$env/run.log"

  # "bad name" (space) then "home"; then duplicate "home"; then "work"; then "single".
  local answers=$'3\nbad name\nhome\nhome\nwork\nsingle\n1\n\n\n2\ny\n\nMARK\n1\n\n\n'
  run_wizard "$env" "$answers" "$log"

  local out; out=$(cat "$log")
  assert_contains "rejects space in name" "$out" "names may contain only letters, digits"
  assert_contains "rejects duplicate name" "$out" "already used for an earlier layout"

  rm -rf "$env"
}

test_backup_on_different_content() {
  say ""
  say "test: re-run backs up only files that changed"
  local env log cfg
  env=$(make_env); log="$env/run.log"
  cfg="$env/.config/hypr/config"

  local answers=$'3\nhome\nwork\nsingle\n1\n\n\n2\ny\n\nMARK_V1\n1\n\n\n'
  run_wizard "$env" "$answers" "$log"
  [[ -d "$cfg/.backups" ]] && { say "  FAIL first run must not create backups"; FAIL=$((FAIL + 1)); }

  # Re-run with the same answers except a different marker for 'work'.
  local answers2=$'3\nhome\nwork\nsingle\n1\n\n\n2\ny\n\nMARK_V2\n1\n\n\n'
  run_wizard "$env" "$answers2" "$log"

  local bak_files
  bak_files=$(find "$cfg/.backups" -type f 2>/dev/null | wc -l)
  assert "exactly 1 file backed up (layouts.sh)" "$bak_files" "1"
  local bak_path
  bak_path=$(find "$cfg/.backups" -type f 2>/dev/null | head -n1)
  assert_contains "backup is layouts.sh" "$bak_path" "layouts.sh"

  # Re-run with IDENTICAL answers: no new backup files.
  run_wizard "$env" "$answers2" "$log"
  local bak_files_after
  bak_files_after=$(find "$cfg/.backups" -type f 2>/dev/null | wc -l)
  assert "no extra backups when content identical" "$bak_files_after" "1"

  rm -rf "$env"
}

test_default_layouts_sh_falls_through_to_single() {
  say ""
  say "test: shipped layouts.sh always returns 'single'"
  # shellcheck disable=SC1091
  (
    unset -f detect_location || true
    . "$REPO_ROOT/hypr/config/layouts.sh"
    assert "default detect_location" "$(detect_location '[{"name":"DP-1"},{"name":"DP-2"},{"name":"DP-3"}]')" "single"
  )
}

# ---- run ----

say "Running wizard integration tests..."
test_fresh_run_generates_expected_files
test_sanitization_and_dedup
test_backup_on_different_content
test_default_layouts_sh_falls_through_to_single

say ""
say "=========================================="
say "  passed: $PASS"
say "  failed: $FAIL"
say "=========================================="

(( FAIL == 0 ))
