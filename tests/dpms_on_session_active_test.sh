#!/usr/bin/env bash
# Regression tests for hypr/scripts/dpms-on-session-active.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/hypr/scripts/dpms-on-session-active"

PASS=0
FAIL=0

say() { printf '%s\n' "$*"; }

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

make_env() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/bin" "$dir/run/hypr/current-sig"

  cat > "$dir/bin/loginctl" << 'EOF_LOGINCTL'
#!/usr/bin/env bash
case "$*" in
  "list-sessions --no-legend")
    # Simulate the helper having first discovered an old graphical session.
    printf '33 1000 id seat0 999 user tty1 no -\n'
    ;;
  "show-session 33 -p Type --value")
    printf 'wayland\n'
    ;;
  *)
    printf 'unexpected loginctl args: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF_LOGINCTL
  chmod +x "$dir/bin/loginctl"

  cat > "$dir/bin/busctl" << 'EOF_BUSCTL'
#!/usr/bin/env bash
case "$*" in
  "--system call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager GetSession s 33")
    printf 'o "/org/freedesktop/login1/session/_33"\n'
    ;;
  "--system get-property org.freedesktop.login1 /org/freedesktop/login1/session/_33 org.freedesktop.login1.Session Active")
    printf 'b false\n'
    ;;
  "--system get-property org.freedesktop.login1 /org/freedesktop/login1/session/_314 org.freedesktop.login1.Session User")
    printf '(uo) 1000 "/org/freedesktop/login1/user/_1000"\n'
    ;;
  "--system get-property org.freedesktop.login1 /org/freedesktop/login1/session/_314 org.freedesktop.login1.Session Type")
    printf 's "wayland"\n'
    ;;
  "--system get-property org.freedesktop.login1 /org/freedesktop/login1/session/_314 org.freedesktop.login1.Session Active")
    printf 'b false\n'
    ;;
  *)
    printf 'unexpected busctl args: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF_BUSCTL
  chmod +x "$dir/bin/busctl"

  cat > "$dir/bin/gdbus" << 'EOF_GDBUS'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DPMS_TEST_ENV/gdbus.args"
case " $* " in
  *" --object-path "*)
    # Object-scoped monitors do not receive the replacement session's signal.
    :
    ;;
  *)
    printf 'Monitoring signals from all objects owned by org.freedesktop.login1\n'
    printf "/org/freedesktop/login1/session/_314: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'Active': <true>}, @as [])\n"
    ;;
esac
EOF_GDBUS
  chmod +x "$dir/bin/gdbus"

  cat > "$dir/bin/hyprctl" << 'EOF_HYPRCTL'
#!/usr/bin/env bash
printf 'hyprctl %s\n' "$*" >> "$DPMS_TEST_ENV/hyprctl.log"
case "$*" in
  "dispatch dpms on")
    exit 0
    ;;
  "monitors -j")
    printf '[{"name":"DP-1","dpmsStatus":true}]\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF_HYPRCTL
  chmod +x "$dir/bin/hyprctl"

  cat > "$dir/bin/jq" << 'EOF_JQ'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF_JQ
  chmod +x "$dir/bin/jq"

  echo "$dir"
}

run_helper() {
  local env="$1"
  (
    export DPMS_TEST_ENV="$env"
    export PATH="$env/bin:$PATH"
    export USER=id
    export XDG_RUNTIME_DIR="$env/run"
    timeout 1s "$SCRIPT"
  ) > "$env/script.out" 2> "$env/script.err" || [[ $? == 124 ]]
}

test_replacement_graphical_session_active_edge_wakes_hyprland() {
  say ""
  say "test: replacement graphical session active edge wakes Hyprland"
  local env calls args
  env=$(make_env)

  run_helper "$env"

  calls="$(cat "$env/hyprctl.log" 2>/dev/null || true)"
  args="$(cat "$env/gdbus.args" 2>/dev/null || true)"
  assert_contains "subscribes to all login1 session signals" "$args" "--dest org.freedesktop.login1"
  if [[ "$args" == *"--object-path"* ]]; then
    FAIL=$((FAIL + 1))
    say "  FAIL does not pin monitor to one session object"
    say "       actual: $args"
  else
    PASS=$((PASS + 1))
    say "  ok   does not pin monitor to one session object"
  fi
  assert_contains "dispatches dpms on for replacement session" "$calls" "hyprctl dispatch dpms on"

  rm -rf "$env"
}

say "Running dpms-on-session-active tests..."
test_replacement_graphical_session_active_edge_wakes_hyprland

say ""
say "=========================================="
say "  passed: $PASS"
say "  failed: $FAIL"
say "=========================================="

((FAIL == 0))
