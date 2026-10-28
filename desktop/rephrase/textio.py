"""Reading the selected text and writing the rewrite back, via the clipboard.

Windows and Linux/X11: simulate Ctrl+C / Ctrl+V into the app you were using, then restore the
clipboard. Wayland doesn't allow simulated keys, so there Rephrase works on the clipboard only:
copy the text yourself, trigger Rephrase, and the rewrite is put back on the clipboard to paste.
"""

import os
import shutil
import subprocess
import sys
import threading
import time
import uuid

import pyperclip

# pynput needs an X display just to import on Linux, so load it only when keys are sent
# (never on Wayland, and never for `rephrase --version` / `--trigger` / `--test`).
_keyboard = None


def is_wayland() -> bool:
    return sys.platform.startswith("linux") and (
        os.environ.get("XDG_SESSION_TYPE") == "wayland" or (
            "WAYLAND_DISPLAY" in os.environ and "DISPLAY" not in os.environ))


# --- Remembering and re-activating the app you were typing in

def active_window():
    if sys.platform == "win32":
        import ctypes
        return ctypes.windll.user32.GetForegroundWindow()
    if shutil.which("xdotool"):
        r = subprocess.run(["xdotool", "getactivewindow"], capture_output=True, text=True)
        return r.stdout.strip() or None
    return None


def activate(window) -> None:
    if not window:
        return
    if sys.platform == "win32":
        _win_force_foreground(window)
    elif shutil.which("xdotool"):
        subprocess.run(["xdotool", "windowactivate", "--sync", str(window)], capture_output=True)


def _win_force_foreground(hwnd) -> None:
    """Windows only lets the foreground app hand focus around; a synthetic Alt tap unlocks it."""
    import ctypes
    user32 = ctypes.windll.user32
    VK_MENU, KEYUP = 0x12, 0x0002
    user32.keybd_event(VK_MENU, 0, 0, 0)
    user32.keybd_event(VK_MENU, 0, KEYUP, 0)
    user32.SetForegroundWindow(hwnd)


def focus_tk_window(tk_window) -> None:
    """Brings the popup to the front so it gets Enter / Esc / 1-5."""
    tk_window.lift()
    tk_window.attributes("-topmost", True)
    if sys.platform == "win32":
        try:
            _win_force_foreground(int(tk_window.wm_frame(), 16))
        except (ValueError, OSError):
            pass
    tk_window.focus_force()


# --- Clipboard

def _send_ctrl(char: str) -> None:
    global _keyboard
    from pynput.keyboard import Controller, Key
    if _keyboard is None:
        _keyboard = Controller()
    with _keyboard.pressed(Key.ctrl):
        _keyboard.tap(char)


def _safe_paste() -> str:
    try:
        return pyperclip.paste() or ""
    except pyperclip.PyperclipException:
        return ""


def copy_selection(wait_for_release=None) -> str:
    """Returns the selected text in the front app, or "" if nothing is selected.
    The clipboard's text is restored afterwards."""
    if is_wayland():
        return _safe_paste()
    if wait_for_release:
        wait_for_release()
    saved = _safe_paste()
    sentinel = f"rephrase-{uuid.uuid4()}"
    pyperclip.copy(sentinel)
    _send_ctrl("c")
    deadline = time.time() + 0.6
    copied = sentinel
    while time.time() < deadline:
        time.sleep(0.03)
        copied = _safe_paste()
        if copied != sentinel:
            break
    pyperclip.copy(saved)
    return "" if copied == sentinel else copied


def paste_text(text: str, window=None) -> bool:
    """Replaces the selection in `window` with `text`. Returns False when it could only copy
    (Wayland), so the caller can tell you to press Ctrl+V."""
    if is_wayland():
        pyperclip.copy(text)
        return False
    saved = _safe_paste()
    pyperclip.copy(text)
    activate(window)
    time.sleep(0.12)
    _send_ctrl("v")

    def restore():
        time.sleep(0.6)
        pyperclip.copy(saved)
    threading.Thread(target=restore, daemon=True).start()
    return True
