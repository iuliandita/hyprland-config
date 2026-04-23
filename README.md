# hyprland-config

[![ci](https://github.com/iuliandita/hyprland-config/actions/workflows/ci.yml/badge.svg)](https://github.com/iuliandita/hyprland-config/actions/workflows/ci.yml)

Location-aware Hyprland setup with automatic dock/undock detection.

One laptop, N layouts you name yourself (home / work / single by default):

- 3 external monitors + laptop off
- 2 external monitors + laptop display
- laptop only (no dock)

The right config is applied automatically when you plug or unplug the dock. No manual switching. The interactive installer (`./install.sh`) detects your current monitors and generates the per-layout config files from live hardware.

## Based on CachyOS

This started as the stock CachyOS Hyprland config (from the `cachyos-hyprland-settings` package, installed at `/etc/skel/.config/hypr/`). The location-aware monitor handling, screenshot script, hyprlock/hypridle integration, and a handful of keybind/app changes are mine; everything else follows CachyOS upstream.

If you're on CachyOS and want to compare against the stock config, `diff -ru /etc/skel/.config/hypr/ ~/.config/hypr/` after install will show you exactly what changed.

### Default apps I use

Defined in `hypr/config/defaults.conf`. Swap to your own preferences there.

| Variable | I use | CachyOS upstream |
|---|---|---|
| `$terminal` | `ghostty` | `alacritty` |
| `$browser` | `zen-browser` | (not set) |
| `$filemanager` | `nemo` | (empty) |
| `$applauncher` | `rofi -show combi -modi window,run,combi -combi-modi window,run` | `wofi` |
| `$idlehandler` | `hypridle` | `swayidle` |
| `$capturing` | `bash ~/.config/hypr/scripts/screenshot_swappy` | three vars (`$shot-region`/`$shot-window`/`$shot-screen`) using `grimblast` |

### Keybinds I changed

Only the bindings that differ from CachyOS upstream. Everything else (workspace switching, focus movement, volume / brightness / playback, scratchpads, window grouping, gaps toggle) is unchanged. Full set in `hypr/config/keybinds.conf`.

| Shortcut | Action | Difference from CachyOS |
|---|---|---|
| `Super + Shift + Return` | Open floating terminal (`termfloat`) | new |
| `Super + W` | Open browser | new |
| `Super + R` | Application launcher | moved from `Super + Space` |
| `Super + Shift + Space` | Toggle floating mode | moved from `Super + V` |
| `Super + F` | Maximize window | upstream toggled true fullscreen on this binding |
| `Super + Shift + F` | Toggle true fullscreen | new |
| `Super + Shift + R` | Resize submap | moved from `Super + R` (freed for launcher) |
| `Super + Shift + Q` | Exit Hyprland session | replaces `Super + Shift + M` (`loginctl terminate-user`) |
| `Super + Shift + S` | Screenshot to clipboard via swappy | replaces `Print` / `Ctrl+Print` / `Alt+Print` |
| `Super + Shift + P` | Open calculator (`gnome-calculator`) | new |
| `Super + L` | Lock screen (`hyprlock`) | replaces `swaylock-fancy` (incompatible with Hyprland 0.40+) |

## How it works

```
        +-----------------------+
        |  Hyprland IPC socket  |
        |  (monitoradded /      |
        |   monitorremoved)     |
        +----------+------------+
                   |
                   v
        +-----------------------+
        |   monitor-listener    |   <- autostart, tails .socket2.sock
        +----------+------------+
                   |
                   v
        +-----------------------+
        |   location-switch     |   <- sources config/layouts.sh,
        |                       |      calls detect_location() with
        |                       |      hyprctl monitors -j; matches
        |                       |      EDID markers per layout.
        +----------+------------+
                   |
                   v
        +-----------------------+
        |  flip symlinks:       |
        |  monitors.conf   -> monitors.<loc>.conf
        |  workspaces.conf -> workspaces.<loc>.conf
        |  hyprctl reload       |
        +-----------------------+
```

### Why symlinks?

`hyprland.conf` does `source = config/monitors.conf` and `source = config/workspaces.conf`. The real files are `monitors.<layout>.conf` - `monitors.single.conf` ships in the repo as a fallback; the wizard generates `monitors.home.conf`, `monitors.work.conf`, etc. for whatever layouts you name (and likewise for workspaces). `location-switch` just retargets the symlink and calls `hyprctl reload`. No config rewriting, no templating.

### Why match monitors by description, not `DP-N`?

DisplayPort numbers in Wayland are assigned by detection order, which shifts across reboots, dock cycles, or even cable order. EDID descriptions (`Dell Inc. DELL G2725D <serial>`) are stable.

`scripts/configure` emits `desc:<EDID>` matchers automatically whenever the detected monitor reports a non-empty description. Connector names (`DP-N`, `HDMI-A-N`) are only used as a fallback for outputs without an EDID description string.

## Install

```bash
git clone <this-repo> hyprland-config
cd hyprland-config
./install.sh
```

Or, without cloning (always review a `curl | bash` before running it):

```bash
curl -fsSL https://raw.githubusercontent.com/iuliandita/hyprland-config/main/install.sh | bash
```

`install.sh` copies everything to `~/.config/hypr/` and, when Hyprland is running and a TTY is attached, launches an interactive wizard (`scripts/configure`) that:

- lists detected monitors with resolution, refresh rate, and EDID description
- asks how many layouts you want (defaults: 1/2/3 based on detected monitors)
- asks layout names (defaults: `home`, `work`, `single`)
- captures the **current** layout from live hardware and stubs the rest for later
- proposes a workspace split per layout (`1 -> 10`, `2 -> 5,5`, `3 -> 3,4,3`, `4 -> 2,3,3,2`)
- asks for a unique EDID marker per layout so `location-switch` can auto-detect it

If there's no TTY or Hyprland isn't running (e.g. `curl | bash` from a plain shell), it skips the wizard and seeds a safe `single` fallback. Re-run `~/.config/hypr/scripts/configure` later with each dock state plugged in to fill the stubs.

Flags:

- `./install.sh --wizard` - force the wizard (errors if prerequisites are missing)
- `./install.sh --no-wizard` - skip the wizard (old behaviour: seed `single` symlinks only)
- `./install.sh --skip-deps` - skip the dependency check (useful for CI / trusted environments)

### Dependency check

Before touching any files, `install.sh` checks for the tools this config needs and groups them into tiers:

| Tier | Tools | If missing |
|---|---|---|
| **Required** | `hyprland` | hard fail with a distro-specific install hint |
| **Core** | `jq`, `notify-send` (libnotify), `ncat`, `hypridle`, `hyprlock` | warn; prompt to install |
| **UX** | `waybar`, `mako`, `swaybg`, `rofi`, `grim`, `slurp`, `swappy` | warn; prompt to install |
| **Defaults** | `ghostty`, `nemo`, `zen-browser`, `nwg-drawer`, `nwg-dock-hyprland`, `wob` | mention only; swap them in `config/defaults.conf` if you prefer your own |

Distro detection reads `/etc/os-release` (`ID` + `ID_LIKE`) and recognises these families:

- **Arch**: Arch, CachyOS, EndeavourOS, Manjaro, Garuda, Artix
- **Debian**: Debian, Ubuntu, Pop!\_OS, Mint, elementary, Zorin, Kali, Raspbian
- **Fedora**: Fedora, Nobara, Bazzite, Silverblue, Kinoite, RHEL, CentOS

When core or UX tools are missing, the installer prints the exact install command for the detected family and offers four choices:

```
Install the repo-available ones now? [A]uto / [M]anual-wait / [S]kip / [Q]uit [S]:
```

- **A (auto)**: runs the install command. Only wired up for Arch (package names are reliable across its derivatives). On Debian/Fedora this falls through to manual because names drift across versions and several tools aren't in default repos.
- **M (manual-wait)**: pauses so you can install the tools in another shell, then press enter to continue.
- **S (skip)**: continues with the install; fix it later.
- **Q (quit)**: exits before writing any files.

Package names are mapped per family where they differ (e.g. `notify-send` -> `libnotify` on Arch/Fedora but `libnotify-bin` on Debian; `ncat` -> `nmap` on Arch, `nmap-ncat` on Fedora). Tools that aren't in a family's default repos (e.g. Hyprland itself on older Debian/Fedora, `nwg-*` on any non-Arch, `ghostty`/`zen-browser` everywhere) are listed separately with "build manually / enable AUR / COPR / PPA" guidance rather than silently omitted.

If there's no TTY (e.g. `curl | bash` from a non-graphical shell) the installer prints the commands and continues without prompting.

### NetworkManager fallback

To enable NetworkManager-triggered switching (optional - `monitor-listener` alone works for dock hotplug):

```bash
sudo install -m 755 hypr/scripts/99-hypr-location /etc/NetworkManager/dispatcher.d/
```

The dispatcher resolves the logged-in user's home directory via `getent passwd`, so no per-host editing is needed.

## Customization

### Layout hardware, workspaces, and detection rules

Re-run the wizard any time you want to regenerate these:

```bash
~/.config/hypr/scripts/configure
```

It rewrites `config/monitors.<layout>.conf`, `config/workspaces.<layout>.conf`, and `config/layouts.sh` (the detection function sourced by `location-switch`). Stub layouts for setups you can't plug in right now get `TODO_external_N` placeholders in their monitor config; when you dock to that setup, re-run the wizard and pick the matching layout number as "current" to auto-fill it.

If you'd rather hand-edit:

- `config/monitors.<layout>.conf` - one `monitor=` line per output
- `config/workspaces.<layout>.conf` - `workspace=N,monitor:desc:<EDID>` per slot
- `config/layouts.sh` - `detect_location()` bash function; gets `hyprctl monitors all -j` output as `$1`, echoes a layout name

Prefer `desc:<EDID description>` over `DP-N` port names. DisplayPort numbers shuffle across reboots, dock cycles, and cable order; EDID descriptions are stable. Find them with:

```bash
hyprctl monitors all -j | jq -r '.[] | "\(.name)\t\(.description)"'
```

### Apps, keybinds, appearance

- `config/defaults.conf` - default apps ($terminal, $browser, etc.)
- `config/keybinds.conf` - all keyboard shortcuts
- `config/colors.conf` - CachyOS palette variables
- `config/autostart.conf` - things launched at login (waybar, mako, monitor-listener, ...)

## File layout

```
hypr/
├── hyprland.conf              # Entry point; sources everything in config/
├── hypridle.conf              # Idle -> lock / DPMS off
├── hyprlock.conf              # Lock screen (Tokyo Night)
├── config/
│   ├── animations.conf
│   ├── autostart.conf
│   ├── colors.conf
│   ├── decorations.conf
│   ├── defaults.conf
│   ├── environment.conf
│   ├── input.conf
│   ├── keybinds.conf
│   ├── layouts.sh             # detect_location() sourced by location-switch (regenerated by wizard)
│   ├── monitor.conf           # Fallback catch-all (unused by default)
│   ├── monitors.single.conf   # Laptop-only default (wizard creates monitors.<layout>.conf)
│   ├── variables.conf
│   ├── windowrules.conf
│   └── workspaces.single.conf # Wizard creates workspaces.<layout>.conf for other layouts
└── scripts/
    ├── configure              # Interactive layout wizard
    ├── location-switch        # Detect + flip symlinks + reload
    ├── monitor-listener       # Hyprland IPC -> location-switch
    ├── 99-hypr-location       # NetworkManager dispatcher (optional)
    ├── screenshot             # grim + slurp
    ├── screenshot_area
    ├── screenshot_full
    └── screenshot_swappy
```

`monitors.conf` and `workspaces.conf` are runtime-generated symlinks. They are not in the repo; `install.sh` creates them on first run.

## Dependencies

`install.sh` checks these for you and prints the exact install command for your distro family. The list, for reference:

- **Required**: `hyprland` 0.40+ (needs `ext-session-lock-v1`)
- **Core**: `jq`, `notify-send` (libnotify), `ncat` (from `nmap` on Arch, `nmap-ncat` on Fedora), `hypridle`, `hyprlock`
- **UX**: `waybar`, `mako`, `swaybg`, `rofi`, `grim`, `slurp`, `swappy`
- **Default apps** (swap in `config/defaults.conf`): `ghostty`, `nemo`, `zen-browser`, `nwg-drawer`, `nwg-dock-hyprland`, `wob`

## Testing

Integration tests live in `tests/wizard_test.sh`. They mock `hyprctl`/`pgrep`, redirect `XDG_CONFIG_HOME` to a scratch tree, drive the wizard via a PTY, and assert on the generated files. CI runs them plus shellcheck, shfmt, actionlint, trivy, and gitleaks on every push/PR.

Run locally:

```bash
./tests/wizard_test.sh
```

No real Hyprland required - everything is mocked. Pass `--skip-deps` to `install.sh` when testing manually so the dep check doesn't prompt.

## Notes

- Windows stay with their workspace across dock transitions. Unplug -> all 10 workspaces land on the laptop; replug -> workspaces re-home to their assigned monitors. Tiled layouts re-tile automatically. Floating windows keep absolute coords and may land oddly; nudge them.
- `swaylock` / `swaylock-effects` is incompatible with Hyprland 0.40+ (no `ext-session-lock-v1`). Stick with `hyprlock`.
- The `location-switch` idempotency guard compares symlink targets, so repeated firing while already in the right state is a no-op.
