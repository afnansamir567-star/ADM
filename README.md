# ADM

A.Professor's Download Manager — ADM

ADM is a single-file, terminal-first download manager (bash) with a small embedded Python engine for downloading arbitrary file types. It supports:

- direct file downloads with resume and multi-connection segmented download (adm_fetch.py embedded)
- video/social site downloads via yt-dlp (auto integration)
- optional aria2 integration for faster downloads
- playlist / channel sync, scheduling, clipboard detection, and basic player (mpv)
- works on Termux (Android) and Linux (Debian/Ubuntu, Arch, etc.)

This README explains the repository layout and gives step-by-step installation instructions for Termux (Android) and general Linux (tmux-enabled) systems.

---

## Repository layout

- `adm.sh` — main script. Self-contained: embeds the file engine (Python) and contains UI, settings, and all features.
- `README.md` — this file (project overview + install/run instructions).
- Data and settings are stored under `$HOME/Downloads/ADM/.data` (Linux) or `/sdcard/Download/ADM/.data` (Termux) by default at runtime.

---

## Requirements

- Termux (Android) or a Linux distribution
- bash (Linux shell)
- python3
- yt-dlp
- ffmpeg (for media processing)
- mpv (optional, for audio player)
- tmux (recommended on Linux for multi-pane UI)
- aria2 (optional, for faster downloads)

ADM will try to auto-install many of these (see first-time setup), but the steps below show how to install dependencies explicitly.

---

## Install on Termux (recommended flow)

1. Open Termux and update packages:

   pkg update -y && pkg upgrade -y

2. Install core packages used by ADM:

   pkg install python ffmpeg nodejs tmux mpv aria2 git -y

   - If you want Termux API features, also install: `pkg install termux-api`

3. Give Termux storage permission (ADM uses shared storage for Downloads):

   termux-setup-storage

   Grant permission when prompted.

4. Install yt-dlp (pip):

   python -m ensurepip --upgrade || true
   pip install --upgrade yt-dlp

5. Install ADM script:

   - Recommended: download the script to a safe location and run it once to trigger self-install.

     curl -fsSL https://raw.githubusercontent.com/afnansamir567-star/ADM/master/adm.sh -o ~/adm.sh
     chmod +x ~/adm.sh
     bash ~/adm.sh

     The script's self-installation copies `adm` into Termux's $PREFIX/bin and sets up data folders. After the first run it performs the first-time setup and installs missing tools automatically.

6. Run ADM:

   adm

   or to run without the tmux UI loop: `adm --main` (the script will autoboot into tmux when available).

---

## Install on Linux (Debian/Ubuntu example)

1. Update packages and install dependencies:

   sudo apt update && sudo apt upgrade -y
   sudo apt install python3 python3-pip ffmpeg nodejs tmux mpv aria2 curl git -y

2. Install yt-dlp:

   pip3 install --upgrade yt-dlp

3. Download and install ADM:

   curl -fsSL https://raw.githubusercontent.com/afnansamir567-star/ADM/master/adm.sh -o ~/adm.sh
   chmod +x ~/adm.sh
   bash ~/adm.sh

   The script will create `$HOME/.local/bin/adm` and add it to PATH by appending to `~/.bashrc` or `~/.zshrc` if needed.

4. Start ADM (recommended inside tmux):

   adm

   Or to explicitly run inside tmux (the script will auto-launch tmux on Linux):

   adm --main

---

## Quick usage and commands

- Start interactive UI (recommended):
  `adm`

- Run the main loop directly (no header loop):
  `adm --main`

- Health check (diagnose missing deps):
  `adm --doctor` or `adm --doctor` (same)

- Update ADM via the built-in updater (if you have configured an update URL):
  `adm --update`

- Uninstall ADM and remove data:
  `adm --uninstall`

- Sync channel subscriptions (non-interactive):
  `adm --sync`

- Run batch file of links (non-interactive):
  `adm --run-file /path/to/links.txt 5`  (last arg = quality slot 1-7)

---

## Termux-specific tips

- If you use Termux on Android, allow storage via `termux-setup-storage` so ADM can save to `/sdcard/Download/ADM`.
- If you want notifications, install `termux-api` and grant required permissions.
- To keep long runs alive across reboots, consider using Termux:Boot or a scheduling approach that invokes `adm --run-file` at a target time.

---

## Troubleshooting

- If yt-dlp fails for a site, update it:
  `pip3 install -U yt-dlp`

- If ffmpeg or mpv isn't found, install via package manager (`pkg` on Termux, `apt`/`pacman` on Linux).

- If permission errors occur when saving files, ensure the save folder is writable (Termux needs storage permission).

- Use `adm --doctor` for an automated health check that reports missing tools.

---

## Suggestions for repository organization (optional improvements)

If you want to maintain ADM as a multi-file repo instead of one big script, consider splitting:

- `adm.sh` (core CLI/UI) — keep lightweight, call external helpers
- `adm-fetch.py` (move embedded Python engine to a separate file)
- `Makefile` or `install.sh` for easier install
- `LICENSE` (choose a license)
- `CONTRIBUTING.md` and `CHANGELOG.md`

This makes it easier to test and package per distribution.

---

If you want, I can commit this updated README.md to the repository and/or add a separated install script and a smaller README in Bengali/English. What should I do next?