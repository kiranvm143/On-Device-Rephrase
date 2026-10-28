# Rephrase Developer Guide

How Rephrase is built, how to work on it, and how to ship a release. For using the app, see the
[User Guide](USER_GUIDE.md).

**Contents**

1. [Overview](#1-overview)
2. [Repository layout](#2-repository-layout)
3. [macOS app](#3-macos-app)
4. [Windows / Linux app](#4-windows--linux-app)
5. [Engines](#5-engines)
6. [Build, run and test](#6-build-run-and-test)
7. [Debugging](#7-debugging)
8. [CI and releases](#8-ci-and-releases)
9. [Common changes](#9-common-changes)
10. [Known limitations](#10-known-limitations)

---

## 1. Overview

Every platform does the same four things:

```
 capture text ──▶ popup (mode + engine) ──▶ engine rewrites ──▶ write text back
```

| | macOS (`macos/`, Swift) | Windows / Linux (`desktop/`, Python) |
|---|---|---|
| Find the text box | Accessibility API (`AXUIElement`) | — (selection only) |
| Read the text | AX selected text / value, fallback ⌘C | Simulated Ctrl+C |
| Write it back | ⌘V (⌘A first for whole-field) | Ctrl+V after re-focusing the window |
| Trigger | ✨ icon, ⌃⌥R (Carbon hotkey), menu bar | Ctrl+Alt+R (pynput), tray, `rephrase --trigger` |
| UI | SwiftUI in a non-activating `NSPanel` | Tk `Toplevel` |
| Engines | Apple Foundation Models, Claude, ChatGPT, Ollama | Claude, ChatGPT, Ollama |

The clipboard is always restored after a copy or paste.

**Principles**

- **No API keys, no credential handling.** Claude and ChatGPT go through the vendors' own CLIs, which the user signs
  into in the browser. Rephrase never reads tokens.
- **Text in, text out.** CLIs run with tools disabled and in a temp directory.
- **Never log user text.** Logs record roles, lengths and outcomes only.
- **Same prompts everywhere.** `RewriteEngine.swift` and `prompts.py` must stay in step.

---

## 2. Repository layout

```
macos/
  Package.swift                 Swift package (macOS 26, links FoundationModels)
  build.sh                      Builds Rephrase.app, signs it, installs to ~/Applications
  Sources/Rephrase/
    main.swift                  Entry point; --test, --probe, --demo modes
    AppDelegate.swift           Menu bar, hotkey, wiring
    HotKey.swift                Global ⌃⌥R via Carbon RegisterEventHotKey
    TextAccess.swift            Read selection / focused field (AX), copy & paste fallbacks
    BadgeController.swift       The ✨ icon: focus polling, typing fallback, drag & per-app offsets
    PopupController.swift       Popup model + SwiftUI views (modes, engine picker, setup panel)
    WordDiff.swift              Red/green word diff for Fix
    RewriteEngine.swift         Modes, prompts, engine dispatch, Apple on-device model
    CLIEngine.swift             Claude Code / Codex runners, status checks, process helper
    CodexDownloader.swift       Downloads + verifies Rephrase's private Codex
    Ollama.swift                Ollama HTTP client (chat, tags, pull with progress)
    EngineSetup.swift           Engine states, setup copy, install / sign-in / start actions
    LoginItem.swift             Open at Login (SMAppService)
    Log.swift                   ~/Library/Logs/Rephrase.log
    Probe.swift                 Dumps an app's AX tree for debugging
desktop/
  pyproject.toml                Package "rephrase-desktop", entry points rephrase / rephrase-gui
  launcher.py                   PyInstaller entry
  rephrase/
    app.py                      Tray, hotkey listener, local trigger socket, wiring
    popup.py                    Tk popup (modes, engine picker, setup panel, diff)
    textio.py                   Clipboard capture/paste, window focus, Wayland detection
    engines.py                  Engine runners, status checks, NeedsSetup
    enginesetup.py              Setup copy + install / sign-in / start / pull actions, Runner
    codexdl.py                  Downloads + verifies Rephrase's private Codex
    prompts.py                  Modes, prompts, output cleanup
    config.py                   config.json + rephrase.log
install/
  install.sh                    macOS (build from source, or release zip) and Linux (venv)
  install.ps1                   Windows (venv + shortcuts)
docs/                           This guide, the user guide, screenshots
.github/workflows/              ci.yml, release.yml
```

---

## 3. macOS app

### Text access (`TextAccess.swift`)

1. Set `AXManualAccessibility` on the front app (makes Electron/Chromium apps expose their text).
2. Get the focused element: system-wide first, then the app element, then (once per app) set
   `AXEnhancedUserInterface` and retry. This is what made Teams work.
3. Read `AXSelectedText`; if empty, use `AXValue` (whole field, `wholeField = true`).
4. If AX can't see the selection, simulate ⌘C (checking `changeCount`), and for the typing fallback apps
   (Zoom), ⌘A then ⌘C (`weSelectedAll = true`, so cancelling sends → to deselect).
5. Write back by putting the rewrite on the clipboard, re-activating the app, ⌘A if `wholeField`, then ⌘V, and
   restoring the old clipboard 0.6 s later (marked `org.nspasteboard.TransientType` so clipboard managers skip it).

### The ✨ icon (`BadgeController.swift`)

- Polls the focused element every 0.35 s. It shows for `AXTextField` / `AXTextArea` / `AXComboBox` or anything
  with a settable `AXValue`, if it has text and isn't `AXSecureTextField`. It also follows `AXEditableAncestor`
  for web editors.
- Small fields: the icon sits outside the right edge. Tall boxes: inside the bottom-right corner.
- **Typing fallback** (`typingFallbackApps`, currently Zoom): when the focused element is a container
  (`AXGroup`, `AXWebArea`, …) or missing, global key/mouse monitors record *when* you typed and *where* you
  clicked. The icon goes above the click. It's limited to a list so terminals never get ⌘A.
- **Dragging:** hold or drag in `BadgeView.mouseDown`. Offsets are stored per bundle ID in
  `UserDefaults["badgeOffsets"]`.
- Excluded apps: terminals and password managers (`excludedApps`).

### Popup (`PopupController.swift`)

- A `KeyPanel` (`NSPanel`, `.nonactivatingPanel`, `canBecomeKey = true`) takes keys without activating
  Rephrase, so the original app stays frontmost and ⌘V lands there.
- `PopupModel` caches one result per mode, with state `.loading / .done / .failed / .setup(kind, state)`.
  Switching engine clears the cache.
- `EnginePicker` (SwiftUI `Menu`) and `SetupPanel` read `EngineSetup.shared`.
- A global mouse-down monitor closes the popup when you click elsewhere.

### Permissions and signing

- **Accessibility** is required (AX reads and synthetic keys). TCC ties the grant to the code signature.
- `build.sh` signs ad-hoc with a designated requirement of `identifier "com.local.rephrase"`, so the grant survives
  rebuilds. Without that, every rebuild changes the cdhash and silently revokes access.
- Not sandboxed (AX and running CLIs need that), so no Mac App Store. A Developer ID + notarization would remove
  the Gatekeeper prompt for downloaded builds.
- `LoginItem` registers with `SMAppService.mainApp`, only for the copy in an Applications folder.

---

## 4. Windows / Linux app

- **Threads:** Tk runs on the main thread. The hotkey listener (pynput), tray (pystray `run_detached`), local
  socket and engine calls run on other threads and post closures to `App.events`, which `_drain` runs every 50 ms.
- **Single instance / trigger:** a TCP listener on `127.0.0.1:47613`. `rephrase --trigger` sends `trigger`.
  A second `rephrase` sends `ping`, sees the first one and exits.
- **Capture:** wait for the hotkey's modifiers to be released, put a random sentinel on the clipboard, send Ctrl+C,
  and poll until the clipboard changes (≤0.6 s). Then restore the clipboard.
- **Paste:** clipboard = rewrite, re-activate the window saved at trigger time (Windows: `SetForegroundWindow` with
  an Alt-tap to get past the foreground lock; X11: `xdotool windowactivate`), Ctrl+V, restore after 0.6 s.
- **Wayland:** detected from `XDG_SESSION_TYPE` / `WAYLAND_DISPLAY`. No hotkey and no simulated keys: capture
  reads the clipboard and replace only copies.
- **pynput is imported lazily** (only when keys are sent or the listener starts). On Linux it needs an X display just
  to import. CI imports every module headless to catch regressions.
- **Setup jobs** run in `enginesetup.Runner`, owned by `App`, so a browser sign-in survives the popup closing.
  The popup polls the runner's fields.

---

## 5. Engines

| Engine | How it's called | Status check |
|---|---|---|
| **Apple** (Mac) | `LanguageModelSession` with `permissiveContentTransformations` guardrails, fresh session per request, temperature 0.1 for Fix, 0.7 otherwise | `SystemLanguageModel.availability` |
| **Claude** | `claude -p --model haiku --system-prompt … --tools "" --safe-mode --no-session-persistence`, text on stdin (Windows/Linux put the instructions on stdin too, because `.cmd` launchers mangle multi-line args) | `claude auth status --json` → `loggedIn` |
| **ChatGPT** | `codex exec --skip-git-repo-check --ephemeral --sandbox read-only --color never -c model_reasoning_effort=low --output-last-message <tmp> -`, prompt on stdin | `codex login status` exit code. With no Codex binary, `~/.codex/auth.json` existing counts as ready |
| **Ollama** | `POST /api/chat` (non-streaming) | `GET /api/tags`, model present? |

**Prompting:** each mode's instructions say the text sits between `<text>` tags and is never a request to the model.
That stops "Can you send me…" being answered instead of edited, and resists injected instructions. Outputs are
cleaned by removing tags and wrapping quotes, capitalizing a standalone "i" and the first letter, and keeping the
original's trailing whitespace.

**Rephrase's own Codex** (`CodexDownloader.swift`, `codexdl.py`): fetch `releases/latest` of `openai/codex`, pick
`codex-<arch>-<platform>.tar.gz`, download it, compare SHA-256 with the asset's `digest` field, extract the single
binary (Python strips paths before extracting), and store it in Rephrase's folder. `find("codex")` also looks
there, so a user-installed Codex wins.

**Setup states:** `ready`, `not_installed`, `not_signed_in`, `not_running`, `needs_model`, `unavailable`. Engines
throw `RewriteError.needsSetup` / `NeedsSetup`, and the popup turns that into a setup panel whose wording and
button come from `SetupCopy` / `enginesetup.copy`. Sign-in runs the CLI's login without a TTY. If it exits
non-zero within 10 s, a terminal opens with the same command (Mac: a `.command` file, which needs no Automation
permission) and status is polled for 5 minutes.

---

## 6. Build, run and test

### macOS

Needs the Xcode Command Line Tools with the macOS 26 SDK.

```bash
./macos/build.sh                                       # build, sign, install to ~/Applications
open -a Rephrase
B=macos/build/Rephrase.app/Contents/MacOS/Rephrase
$B --test "i has went their" fix apple                 # one mode, one engine
$B --test "hey can u send it" chatgpt                  # all modes
$B --demo "$PWD/macos/build/shots"                     # popup + PNG snapshots (no Screen Recording needed)
```

`build.sh` uses `swift build --build-system native` (the default build system failed on Command Line Tools).

### Windows / Linux

```bash
python3 -m venv .venv && . .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -e ./desktop
rephrase                                               # run
rephrase --test "i has went their" claude fix          # try an engine
rephrase --trigger                                     # open the popup in the running app
```

On a Mac you can exercise the Python engines and even the Tk popup (system Python's Tk works). The hotkey and paste
paths need real Windows or X11.

### What to test before a release

- Mac: icon in Notes, Teams, Chrome and Zoom; ⌃⌥R with a selection; Replace / Copy / Esc; engine switch; one
  setup flow.
- Windows/Linux: install script, hotkey in Notepad / a browser, Replace, tray Engine menu, one setup flow.
- `rephrase --version` and every module importing headless (CI does this).

---

## 7. Debugging

| Tool | Use |
|---|---|
| `~/Library/Logs/Rephrase.log` | Mac: launch/trust state, hotkey presses, capture path, icon decisions (`badge: <app>: <reason>`), engine and setup steps |
| `open -n -a Rephrase --args --probe <bundle-id>` | Waits 8 s (switch to the app), then writes its AX tree to `~/Library/Logs/Rephrase-probe.txt`: roles, sizes and short labels, never text. This is how we found Zoom's chat box isn't exposed at all. |
| `rephrase.log` next to `config.json` | Windows/Linux: launch, trigger lengths, engine/setup steps |
| `--test` | Run an engine from the terminal and time it |

**Accessibility stops working after a rebuild?** Check `codesign -dr - ~/Applications/Rephrase.app` shows
`designated => identifier "com.local.rephrase"`. To reset a stale grant:
`tccutil reset Accessibility com.local.rephrase`, relaunch, and allow again.

---

## 8. CI and releases

- **`ci.yml`** (every push / PR): installs `desktop/` on Windows and Ubuntu with Python 3.9 and 3.12, imports every
  module headless, runs `rephrase --version` / `--trigger`, and checks `install.sh` (`bash -n`) and `install.ps1`
  (PowerShell parser).
- **`release.yml`** (tags `v*`): PyInstaller one-file builds for Windows and Linux, `macos/build.sh` on `macos-26`
  zipped with `ditto`, and a GitHub release with all three attached.

### Cutting a release

1. Bump versions: `desktop/pyproject.toml`, `desktop/rephrase/__init__.py`, and `CFBundleShortVersionString` /
   `CFBundleVersion` in `macos/build.sh`.
2. Commit, push, wait for CI to pass.
3. `git tag -a vX.Y.Z -m "Rephrase vX.Y.Z" && git push origin vX.Y.Z`
4. When the Release workflow finishes, download `Rephrase-macOS.zip` and run `--test` on it, then replace the
   auto-generated notes (`gh release edit vX.Y.Z --notes-file …`) with a short what's-new.

---

## 9. Common changes

**Change a prompt or add a mode:** edit `RewriteMode` in `RewriteEngine.swift` *and* `MODES` / `TITLES` / `TASKS`
in `prompts.py`. Keep the number keys (1–5) in mind: the popups bind one key per mode.

**Add an engine:**

1. Mac: add a case to `EngineKind` (title, short name, busy label), a branch in `RewriteEngine.rewrite`, a status
   check in `EngineSetup.refresh`, copy in `SetupCopy`, and actions in `performAction`.
2. Windows/Linux: add it to `ENGINES` / `TITLES` / `SHORT`, write `rewrite_<name>` and a `status` branch in
   `engines.py`, and add copy and an action in `enginesetup.py`.
3. Throw `needsSetup` / `NeedsSetup` for anything the user can fix, so the popup shows a button instead of an error.

**Support another app that hides its text box:** probe it, and if it really exposes nothing, add its bundle ID to
`typingFallbackApps` in `BadgeController.swift`.

**Change the Mac hotkey:** `HotKey(keyCode:modifiers:)` in `AppDelegate.swift` (key codes are the `kVK_*` values),
and the labels in the menu, popup footer and docs.

---

## 10. Known limitations

- Windows/Linux have no floating icon yet (hotkey only) and have had little real-world testing.
- Unsigned builds: Gatekeeper / SmartScreen prompts on first launch of downloaded apps.
- The ChatGPT engine takes ~8–10 s per rewrite (Codex starts a full agent per request) and the first use downloads
  ~100 MB.
- Claude needs a paid plan that includes Claude Code.
- Apps that draw their own text (Google Docs) or hide it from AX entirely only work through the copy/paste path.
- Wayland: clipboard mode only.
- The Mac hotkey isn't configurable from the UI.
