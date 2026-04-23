#!/usr/bin/env bash
# Install hyprland-config into ~/.config/hypr/.
# Runs in three modes:
#   - local:     executed from inside a clone/extract. Sources live next to the script.
#   - bootstrap: piped from curl (no file on disk). Self-fetches the tarball.
#   - wizard:    after install, runs the interactive layout configurator when a TTY
#                and running Hyprland are available. --no-wizard disables it.
# Safe to re-run: existing files are backed up and overwritten; the wizard
# regenerates layout files.
#
# Dependency policy:
#   hyprland                  hard-required. Fails immediately if missing.
#   core (jq, ncat, ...)      warned. On Arch-family, offer auto-install. Elsewhere,
#                             print the install command and continue.
#   defaults (ghostty, ...)   mentioned only. Swap them in config/defaults.conf.

set -euo pipefail

REPO_TARBALL="https://github.com/iuliandita/hyprland-config/archive/refs/heads/main.tar.gz"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"

RUN_WIZARD=auto   # auto | yes | no
SKIP_DEPS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wizard)    RUN_WIZARD=yes ;;
    --no-wizard) RUN_WIZARD=no ;;
    --skip-deps) SKIP_DEPS=1 ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [--wizard|--no-wizard] [--skip-deps]

  --wizard       Force the interactive layout wizard. Fails if TTY or Hyprland missing.
  --no-wizard    Skip the wizard. Seeds a 'single' fallback symlink.
  --skip-deps    Skip the dependency check. Useful for CI or trusted environments.

With no flag: runs the wizard if a TTY and running Hyprland are detected,
otherwise falls back to seeding the 'single' symlinks.
EOF
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- distro detection ----
# Returns one of: arch | debian | fedora | unknown.
# ID_LIKE is the right field for derivatives: Garuda/CachyOS/Manjaro say 'arch',
# Pop/Mint/Ubuntu say 'debian', Nobara/Bazzite say 'fedora'.
detect_distro() {
  [[ -r /etc/os-release ]] || { echo unknown; return; }
  local id id_like
  id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2- | tr -d '"')
  id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2- | tr -d '"')
  case " $id $id_like " in
    *\ arch\ *|*\ cachyos\ *|*\ endeavouros\ *|*\ manjaro\ *|*\ garuda\ *|*\ artix\ *) echo arch; return;;
    *\ debian\ *|*\ ubuntu\ *|*\ pop\ *|*\ linuxmint\ *|*\ elementary\ *|*\ zorin\ *|*\ kali\ *|*\ raspbian\ *) echo debian; return;;
    *\ fedora\ *|*\ nobara\ *|*\ bazzite\ *|*\ silverblue\ *|*\ kinoite\ *|*\ rhel\ *|*\ centos\ *) echo fedora; return;;
  esac
  echo unknown
}

# Map tool -> package name for a given family. Falls through to the tool name.
pkg_for() {
  local tool="$1" family="$2"
  case "$family:$tool" in
    arch:notify-send)    echo "libnotify" ;;
    debian:notify-send)  echo "libnotify-bin" ;;
    fedora:notify-send)  echo "libnotify" ;;
    arch:ncat)           echo "nmap" ;;
    fedora:ncat)         echo "nmap-ncat" ;;
    debian:mako)         echo "mako-notifier" ;;
    *)                   echo "$tool" ;;
  esac
}

# Whether a tool is available in default repos on a given family.
in_default_repo() {
  local tool="$1" family="$2"
  case "$family:$tool" in
    arch:nwg-drawer|arch:nwg-dock-hyprland|arch:ghostty|arch:zen-browser) return 1 ;;
    debian:hyprland|debian:hypridle|debian:hyprlock) return 1 ;;
    debian:swappy|debian:nwg-drawer|debian:nwg-dock-hyprland|debian:ghostty|debian:zen-browser) return 1 ;;
    fedora:hyprland|fedora:hypridle|fedora:hyprlock) return 1 ;;
    fedora:swappy|fedora:wob|fedora:nwg-drawer|fedora:nwg-dock-hyprland|fedora:ghostty|fedora:zen-browser) return 1 ;;
    *) return 0 ;;
  esac
}

install_cmd_prefix() {
  case "$1" in
    arch)   echo "sudo pacman -S --needed" ;;
    debian) echo "sudo apt-get install -y" ;;
    fedora) echo "sudo dnf install -y" ;;
    *)      echo "" ;;
  esac
}

# Read from /dev/tty so prompts work even when stdin is a tarball (curl | bash).
prompt_tty() {
  local q="$1" default="${2-}" ans
  if [[ -r /dev/tty ]]; then
    read -r -p "$q" ans </dev/tty
  else
    ans=""
  fi
  echo "${ans:-$default}"
}

dep_check() {
  (( SKIP_DEPS == 1 )) && { echo "==> skipped dependency check"; return; }

  local family
  family=$(detect_distro)
  echo "==> checking dependencies (detected distro family: $family)"

  # Hard require Hyprland.
  if ! command -v Hyprland >/dev/null 2>&1 && ! command -v hyprland >/dev/null 2>&1; then
    {
      echo
      echo "error: Hyprland is not installed. This config is meaningless without it."
      case "$family" in
        arch)   echo "  install: sudo pacman -S hyprland" ;;
        debian) echo "  install: sudo apt install hyprland  # Debian trixie / Ubuntu 24.04+" ;;
        fedora) echo "  install: sudo dnf copr enable solopasha/hyprland && sudo dnf install hyprland" ;;
        *)      echo "  see https://wiki.hyprland.org/Getting-Started/Installation/" ;;
      esac
    } >&2
    exit 1
  fi

  # Core tools the wizard + location-switch + lock/idle pipeline rely on.
  local tools_core=(jq notify-send ncat hypridle hyprlock)
  # UX tools the autostart + screenshot + bar/notifier setup rely on.
  local tools_ux=(waybar mako swaybg rofi grim slurp swappy)
  # Default-app suggestions. These are $variables in config/defaults.conf;
  # the user is expected to swap them if they don't have them.
  local tools_defaults=(ghostty nemo zen-browser nwg-drawer nwg-dock-hyprland wob)

  local -a missing_core=() missing_ux=() missing_defaults=()
  local t
  for t in "${tools_core[@]}";     do command -v "$t" >/dev/null 2>&1 || missing_core+=("$t"); done
  for t in "${tools_ux[@]}";       do command -v "$t" >/dev/null 2>&1 || missing_ux+=("$t"); done
  for t in "${tools_defaults[@]}"; do command -v "$t" >/dev/null 2>&1 || missing_defaults+=("$t"); done

  if (( ${#missing_core[@]} == 0 )) && (( ${#missing_ux[@]} == 0 )); then
    echo "    all core + UX dependencies present"
    if (( ${#missing_defaults[@]} > 0 )); then
      echo "    default-app tools missing (ok to skip, swap in config/defaults.conf):"
      echo "      ${missing_defaults[*]}"
    fi
    return
  fi

  echo "    the following tools are missing:"
  for t in "${missing_core[@]}"; do echo "      [core] $t"; done
  for t in "${missing_ux[@]}";   do echo "      [ux]   $t"; done
  if (( ${#missing_defaults[@]} > 0 )); then
    echo "    (default-app suggestions, safe to skip): ${missing_defaults[*]}"
  fi

  # Partition core+ux into {in default repo} vs {needs manual work}.
  local -a to_install=() manual=()
  local pkg have p
  for t in "${missing_core[@]}" "${missing_ux[@]}"; do
    if in_default_repo "$t" "$family"; then
      pkg=$(pkg_for "$t" "$family")
      have=0
      for p in "${to_install[@]}"; do [[ "$p" == "$pkg" ]] && have=1; done
      (( have == 0 )) && to_install+=("$pkg")
    else
      manual+=("$t")
    fi
  done

  local prefix install_cmd=""
  prefix=$(install_cmd_prefix "$family")
  if [[ -n "$prefix" ]] && (( ${#to_install[@]} > 0 )); then
    install_cmd="$prefix ${to_install[*]}"
  fi

  echo
  if [[ -n "$install_cmd" ]]; then
    echo "Install command for $family:"
    echo "  $install_cmd"
  fi
  if (( ${#manual[@]} > 0 )); then
    echo "Not in $family's default repos (build manually / enable AUR / COPR / PPA):"
    echo "  ${manual[*]}"
  fi
  echo

  if [[ ! -r /dev/tty ]]; then
    echo "    no TTY available - continuing without installing."
    echo "    run the command above manually, then rerun this installer."
    return
  fi

  local choice
  choice=$(prompt_tty "Install the repo-available ones now? [A]uto / [M]anual-wait / [S]kip / [Q]uit [S]: " "S")
  case "${choice,,}" in
    a*)
      if [[ "$family" == "arch" ]] && [[ -n "$install_cmd" ]]; then
        echo "==> running: $install_cmd"
        eval "$install_cmd"
      elif [[ -n "$install_cmd" ]]; then
        echo "    auto-install is enabled only for Arch-family (package name reliability)."
        echo "    run the command above yourself, then rerun the installer."
      else
        echo "    nothing to install via package manager."
      fi
      ;;
    m*)
      prompt_tty "Install the tools in another shell, then press enter to continue... " "" >/dev/null
      ;;
    q*)
      echo "    quitting. No files were written."
      exit 0
      ;;
    *)
      echo "    skipping - install these later."
      ;;
  esac
}

dep_check

# ---- source location (local vs bootstrap) ----
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/hypr" ]]; then
  SRC="$SCRIPT_DIR/hypr"
else
  echo "==> fetching sources"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$REPO_TARBALL" | tar -xz --strip-components=1 -C "$tmp"
  SRC="$tmp/hypr"
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: source tree not found at $SRC" >&2
  exit 1
fi

echo "==> installing to $DEST"
mkdir -p "$DEST/config" "$DEST/scripts"

# ---- backup-aware install ----
BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$DEST/.backups/$BACKUP_STAMP"
BACKUP_INIT=0

safe_install() {
  local mode="$1" src="$2" dst="$3" rel backup_target
  if [[ -e "$dst" ]]; then
    if cmp -s "$src" "$dst"; then
      return 0
    fi
    if (( BACKUP_INIT == 0 )); then
      mkdir -p "$BACKUP_DIR"
      echo "==> backing up existing files to $BACKUP_DIR"
      BACKUP_INIT=1
    fi
    rel="${dst#"$DEST"/}"
    backup_target="$BACKUP_DIR/$rel"
    mkdir -p "$(dirname "$backup_target")"
    cp -a "$dst" "$backup_target"
    echo "    backed up $rel"
  fi
  install -m "$mode" "$src" "$dst"
}

for f in "$SRC"/*.conf; do
  safe_install 644 "$f" "$DEST/$(basename "$f")"
done
if [[ -f "$SRC/CLAUDE.md" ]]; then
  safe_install 644 "$SRC/CLAUDE.md" "$DEST/CLAUDE.md"
fi

# Base config files: back up and overwrite. Per-layout files (monitors.<name>.conf,
# workspaces.<name>.conf) and layouts.sh are owned by the wizard after first run,
# so only seed them if missing.
for f in "$SRC"/config/*.conf; do
  name=$(basename "$f")
  case "$name" in
    monitors.*.conf|workspaces.*.conf)
      if [[ ! -e "$DEST/config/$name" ]]; then
        install -m 644 "$f" "$DEST/config/$name"
      fi
      ;;
    *)
      safe_install 644 "$f" "$DEST/config/$name"
      ;;
  esac
done
if [[ -f "$SRC/config/layouts.sh" ]] && [[ ! -e "$DEST/config/layouts.sh" ]]; then
  install -m 644 "$SRC/config/layouts.sh" "$DEST/config/layouts.sh"
fi
for f in "$SRC"/scripts/*; do
  safe_install 755 "$f" "$DEST/scripts/$(basename "$f")"
done

if [[ ! -e "$DEST/config/monitors.conf" ]]; then
  ln -sf "$DEST/config/monitors.single.conf" "$DEST/config/monitors.conf"
  echo "==> seeded monitors.conf -> monitors.single.conf"
fi
if [[ ! -e "$DEST/config/workspaces.conf" ]]; then
  ln -sf "$DEST/config/workspaces.single.conf" "$DEST/config/workspaces.conf"
  echo "==> seeded workspaces.conf -> workspaces.single.conf"
fi

# ---- wizard ----
can_wizard() {
  [[ -r /dev/tty ]] || return 1
  command -v hyprctl >/dev/null 2>&1 || return 1
  command -v jq      >/dev/null 2>&1 || return 1
  hyprctl monitors -j >/dev/null 2>&1 || return 1
}

case "$RUN_WIZARD" in
  yes)
    if ! can_wizard; then
      echo "error: --wizard requires a TTY, hyprctl, jq, and a running Hyprland." >&2
      exit 1
    fi
    echo "==> running layout wizard"
    echo
    "$DEST/scripts/configure"
    ;;
  auto)
    if can_wizard; then
      echo "==> running layout wizard (skip with --no-wizard)"
      echo
      "$DEST/scripts/configure"
    else
      echo "==> skipped wizard (no TTY or Hyprland not running)"
      echo "    Run later: $DEST/scripts/configure"
    fi
    ;;
  no)
    echo "==> skipped wizard (--no-wizard)"
    ;;
esac

echo
echo "==> done"
echo "Next steps:"
echo "  - Reload Hyprland:  hyprctl reload"
echo "  - Re-run wizard:    $DEST/scripts/configure"
echo "  - (Optional) NetworkManager dispatcher fallback:"
echo "      sudo install -m 755 $DEST/scripts/99-hypr-location /etc/NetworkManager/dispatcher.d/"
