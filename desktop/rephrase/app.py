"""Rephrase for Windows and Linux: tray icon + global hotkey + rewrite popup."""

import argparse
import os
import queue
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk

from . import __version__, config, engines, enginesetup, prompts, textio

PORT = 47613  # local-only socket so `rephrase --trigger` can reach the running app


def _send_to_running(message: str) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=0.5) as s:
            s.sendall(message.encode() + b"\n")
        return True
    except OSError:
        return False


class App:
    def __init__(self):
        self.cfg = config.load()
        if self.cfg.get("engine") not in engines.ENGINES:
            self.cfg["engine"] = engines.default_engine()
            config.save(self.cfg)
        self.events = queue.Queue()     # work for the Tk thread, from hotkey / tray / socket threads
        self.popup = None
        self.held = set()               # modifier keys currently held down
        # Install / sign-in jobs, shared by every popup so they survive the popup closing.
        self.setup_runner = enginesetup.Runner(self.cfg, lambda engine, error: self.events.put(
            lambda: self._setup_finished(engine, error)))

        self.root = tk.Tk()
        self.root.withdraw()

    # --- Startup

    def run(self):
        self._start_server()
        self._start_hotkey()
        self._start_tray()
        config.log(f"launch v{__version__} engine={self.cfg['engine']} wayland={textio.is_wayland()}")
        self.root.after(50, self._drain)
        self.root.mainloop()

    def _start_server(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", PORT))
        srv.listen(4)

        def serve():
            while True:
                conn, _ = srv.accept()
                with conn:
                    if conn.recv(64).strip() == b"trigger":
                        self.events.put(self.trigger)
        threading.Thread(target=serve, daemon=True).start()

    def _start_hotkey(self):
        if textio.is_wayland():
            config.log("hotkey: Wayland session, global hotkeys unavailable; bind `rephrase --trigger` instead")
            return
        from pynput import keyboard

        mods = {keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r, keyboard.Key.alt, keyboard.Key.alt_l,
                keyboard.Key.alt_r, keyboard.Key.alt_gr, keyboard.Key.shift, keyboard.Key.shift_l,
                keyboard.Key.shift_r, keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r}
        try:
            hotkey = keyboard.HotKey(keyboard.HotKey.parse(self.cfg["hotkey"]), lambda: self.events.put(self.trigger))
        except ValueError:
            config.log(f"hotkey: invalid '{self.cfg['hotkey']}', using <ctrl>+<alt>+r")
            hotkey = keyboard.HotKey(keyboard.HotKey.parse("<ctrl>+<alt>+r"), lambda: self.events.put(self.trigger))

        def on_press(key):
            if key in mods:
                self.held.add(key)
            hotkey.press(listener.canonical(key))

        def on_release(key):
            self.held.discard(key)
            hotkey.release(listener.canonical(key))

        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.daemon = True
        listener.start()

    def _start_tray(self):
        try:
            import pystray
            from PIL import Image, ImageDraw, ImageFont
        except Exception as e:  # no tray on this desktop: hotkey and --trigger still work
            config.log(f"tray: unavailable ({e})")
            return

        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.ellipse((2, 2, 62, 62), fill=(37, 99, 235, 255))
        try:
            font = ImageFont.load_default(size=36)   # Pillow 10.1+
        except TypeError:
            font = ImageFont.load_default()
        d.text((32, 32), "R", fill="white", font=font, anchor="mm")

        def engine_item(name):
            return pystray.MenuItem(
                engines.TITLES[name] + ("" if engines.available(name) else "  (not installed)"),
                lambda: self.events.put(lambda: self.set_engine(name)),
                checked=lambda item: self.cfg["engine"] == name, radio=True)

        hotkey_label = self.cfg["hotkey"].replace("<", "").replace(">", "").title()
        menu = pystray.Menu(
            pystray.MenuItem(f"Rephrase Selection ({hotkey_label})", lambda: self.events.put(self.trigger), default=True),
            pystray.MenuItem("Engine", pystray.Menu(*[engine_item(e) for e in engines.ENGINES])),
            pystray.MenuItem("Open Settings File", lambda: self._open(config.config_path())),
            pystray.MenuItem("Quit Rephrase", lambda: self.events.put(self.quit)),
        )
        self.icon = pystray.Icon("rephrase", img, "Rephrase", menu)
        try:
            self.icon.run_detached()
        except Exception as e:
            config.log(f"tray: failed to start ({e})")

    def _drain(self):
        try:
            while True:
                self.events.get_nowait()()
        except queue.Empty:
            pass
        self.root.after(50, self._drain)

    # --- Actions (always on the Tk thread)

    def _wait_for_modifiers_release(self):
        deadline = time.time() + 1.0
        while self.held and time.time() < deadline:
            time.sleep(0.02)
        time.sleep(0.05)

    def trigger(self):
        if self.popup is not None:
            return
        window = textio.active_window()
        text = textio.copy_selection(self._wait_for_modifiers_release)
        config.log(f"trigger: chars={len(text)} window={'yes' if window else 'no'}")
        if not text.strip():
            self.toast("Copy some text first (Ctrl+C), then trigger Rephrase." if textio.is_wayland()
                       else "Select some text first, then press the hotkey again.")
            return

        def on_replace(new_text):
            if not textio.paste_text(new_text, window):
                self.toast("Rewrite copied — press Ctrl+V to paste it.")

        def on_close():
            self.popup = None

        from .popup import Popup
        self.popup = Popup(self.root, text, self.cfg, self.setup_runner, self.set_engine, on_replace, on_close)

    def _setup_finished(self, engine, error):
        # With the popup open it re-checks on its own; otherwise say it's ready (or what went wrong).
        if self.popup is not None:
            return
        if error:
            self.toast(error)
        elif engines.status(engine, self.cfg) == engines.READY:
            self.toast(f"{engines.SHORT[engine]} is ready ✓  Select text and press the hotkey to use it.")

    def set_engine(self, name):
        self.cfg["engine"] = name
        config.save(self.cfg)
        config.log(f"engine: {name}")
        if hasattr(self, "icon"):
            self.icon.update_menu()

    def toast(self, message):
        t = tk.Toplevel(self.root)
        t.overrideredirect(True)
        t.attributes("-topmost", True)
        tk.Label(t, text=message, bg="#333", fg="white", padx=12, pady=8, wraplength=320).pack()
        x, y = self.root.winfo_pointerxy()
        t.geometry(f"+{x + 12}+{y + 12}")
        t.after(3500, t.destroy)

    def _open(self, path):
        if not path.exists():
            config.save(self.cfg)
        if sys.platform == "win32":
            os.startfile(path)  # noqa: S606 - opens the user's own settings file
        else:
            subprocess.Popen(["xdg-open", str(path)])

    def quit(self):
        if hasattr(self, "icon"):
            self.icon.stop()
        self.root.quit()


def _test(text, args):
    cfg = config.load()
    engine = next((a for a in args if a in engines.ENGINES), cfg.get("engine") or engines.default_engine())
    modes = [a for a in args if a in prompts.MODES] or prompts.MODES
    for mode in modes:
        start = time.time()
        try:
            out = engines.rewrite(text, mode, engine, cfg)
            print(f"[{engine} {prompts.TITLES[mode]} {time.time() - start:.2f}s] {out}")
        except engines.EngineError as e:
            print(f"[{engine} {prompts.TITLES[mode]}] error: {e}")


def main():
    parser = argparse.ArgumentParser(prog="rephrase", description="Rewrite selected text anywhere.")
    parser.add_argument("--trigger", action="store_true", help="open the popup in the running Rephrase")
    parser.add_argument("--test", nargs="+", metavar=("TEXT", "ENGINE_OR_MODE"),
                        help="rewrite TEXT in the terminal, e.g. --test 'i has went' claude fix")
    parser.add_argument("--version", action="version", version=__version__)
    args = parser.parse_args()

    if args.test:
        _test(args.test[0], args.test[1:])
        return
    if args.trigger:
        if not _send_to_running("trigger"):
            print("Rephrase isn't running. Start it with `rephrase` first.", file=sys.stderr)
            sys.exit(1)
        return
    if _send_to_running("ping"):
        print("Rephrase is already running (look for the tray icon).", file=sys.stderr)
        return
    App().run()


if __name__ == "__main__":
    main()
