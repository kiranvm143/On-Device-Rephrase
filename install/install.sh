#!/usr/bin/env bash
# Installs Rephrase on macOS or Linux.
#   curl -fsSL https://raw.githubusercontent.com/kiranvm143/On-Device-Rephrase/main/install/install.sh | bash
set -euo pipefail

REPO="kiranvm143/On-Device-Rephrase"
BRANCH="${REPHRASE_BRANCH:-main}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

download_source() {
    say "Downloading Rephrase ($BRANCH)…"
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$tmp"
    src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
}

install_macos() {
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 26 ] || fail "Rephrase for Mac needs macOS 26 or later (you have $(sw_vers -productVersion))."
    [ "$(uname -m)" = "arm64" ] || fail "Rephrase for Mac needs an Apple Silicon Mac (M1 or newer)."

    if xcrun --find swift >/dev/null 2>&1; then
        download_source
        say "Building (takes about a minute)…"
        osascript -e 'quit app "Rephrase"' >/dev/null 2>&1 || true
        "$src/macos/build.sh"
    else
        say "Swift isn't installed; downloading the prebuilt app instead…"
        local url="https://github.com/$REPO/releases/latest/download/Rephrase-macOS.zip"
        curl -fsSL "$url" -o "$tmp/Rephrase.zip" \
            || fail "No prebuilt app found. Install the build tools with: xcode-select --install, then run this again."
        osascript -e 'quit app "Rephrase"' >/dev/null 2>&1 || true
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/Rephrase.app"
        ditto -x -k "$tmp/Rephrase.zip" "$HOME/Applications"
    fi

    open -a "$HOME/Applications/Rephrase.app"
    cat <<'EOF'

Rephrase is installed in ~/Applications and running in your menu bar.

Next:
  1. Allow it in System Settings → Privacy & Security → Accessibility (macOS will ask).
  2. Type in any text box and click the ✨ icon, or select text and press ⌃⌥R.
  3. Optional: switch engines from the menu-bar icon → Engine
       Claude:  install Claude Code, run `claude` once and sign in
       ChatGPT: install Codex (npm i -g @openai/codex), run `codex login`
EOF
}

install_linux() {
    command -v python3 >/dev/null || fail "python3 is required."
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || fail "Python 3.9 or newer is required."

    local missing=()
    python3 -c 'import venv, ensurepip' 2>/dev/null || missing+=("python3-venv")
    python3 -c 'import tkinter' 2>/dev/null || missing+=("python3-tk")
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        command -v wl-copy >/dev/null || missing+=("wl-clipboard")
    else
        command -v xclip >/dev/null || command -v xsel >/dev/null || missing+=("xclip")
        command -v xdotool >/dev/null || missing+=("xdotool")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Rephrase needs a few system packages first. Install them with one of:"
        echo "  sudo apt install ${missing[*]}        # Debian / Ubuntu"
        echo "  sudo dnf install ${missing[*]/python3-venv/python3}   # Fedora"
        echo "  sudo pacman -S ${missing[*]/python3-venv/python} # Arch (python3-tk = tk)"
        fail "Missing: ${missing[*]}. Install them and run this script again."
    fi

    download_source
    local home_dir="${XDG_DATA_HOME:-$HOME/.local/share}/rephrase"
    say "Installing into $home_dir…"
    rm -rf "$home_dir/venv"
    python3 -m venv "$home_dir/venv"
    "$home_dir/venv/bin/pip" install -q --upgrade pip
    "$home_dir/venv/bin/pip" install -q "$src/desktop"

    mkdir -p "$HOME/.local/bin"
    ln -sf "$home_dir/venv/bin/rephrase" "$HOME/.local/bin/rephrase"

    local desktop_entry="[Desktop Entry]
Type=Application
Name=Rephrase
Comment=Rewrite selected text anywhere
Exec=$home_dir/venv/bin/rephrase
Icon=accessories-text-editor
Terminal=false
Categories=Utility;"
    mkdir -p "$HOME/.local/share/applications" "$HOME/.config/autostart"
    printf '%s\n' "$desktop_entry" > "$HOME/.local/share/applications/rephrase.desktop"
    printf '%s\nX-GNOME-Autostart-enabled=true\n' "$desktop_entry" > "$HOME/.config/autostart/rephrase.desktop"

    pkill -f "$home_dir/venv/bin/rephrase" 2>/dev/null || true
    nohup "$home_dir/venv/bin/rephrase" >/dev/null 2>&1 &

    cat <<EOF

Rephrase is installed and running (it also starts when you log in).

Next:
  1. Select text in any app and press Ctrl+Alt+R.
  2. Pick an engine from the tray icon → Engine:
       Claude:  install Claude Code, run \`claude\` once and sign in
       ChatGPT: install Codex (npm i -g @openai/codex), run \`codex login\`
       Local:   install Ollama (ollama.com), run \`ollama pull llama3.2\`
EOF
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        cat <<'EOF'

You're on Wayland, which blocks global hotkeys and simulated typing. Instead:
  - Add a keyboard shortcut in your desktop settings that runs:  rephrase --trigger
  - Copy text (Ctrl+C), press your shortcut, then paste the rewrite (Ctrl+V).
EOF
    fi
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo; echo "Tip: add ~/.local/bin to your PATH to run 'rephrase' from a terminal.";; esac
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux)  install_linux ;;
    *)      fail "This installer is for macOS and Linux. On Windows use install.ps1 (see the README)." ;;
esac
