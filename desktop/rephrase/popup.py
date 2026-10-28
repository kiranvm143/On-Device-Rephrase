"""The rewrite popup: mode buttons, the result (with a red/green diff for Fix), Replace / Copy."""

import difflib
import queue
import re
import threading
import tkinter as tk

from . import engines, prompts, textio

WIDTH, HEIGHT = 480, 230


class Popup:
    def __init__(self, root, text, engine, cfg, on_replace, on_close):
        self.root = root
        self.text = text
        self.engine = engine
        self.cfg = cfg
        self.on_replace = on_replace
        self.on_close = on_close
        self.mode = "fix"
        self.results = {}          # mode -> ("ok" | "error", text)
        self.pending = set()
        self.queue = queue.Queue()

        win = self.win = tk.Toplevel(root)
        win.title("Rephrase")
        win.overrideredirect(True)
        win.attributes("-topmost", True)
        win.configure(bg="#c8c8c8")
        body = tk.Frame(win, bg="#f7f7f7", padx=12, pady=10)
        body.pack(fill="both", expand=True, padx=1, pady=1)

        bar = tk.Frame(body, bg="#f7f7f7")
        bar.pack(fill="x")
        self.mode_buttons = {}
        for i, m in enumerate(prompts.MODES, 1):
            b = tk.Button(bar, text=prompts.TITLES[m], relief="flat", bd=0, padx=8, pady=3,
                          bg="#f7f7f7", activebackground="#dde7f7", cursor="hand2",
                          command=lambda m=m: self.select(m))
            b.pack(side="left", padx=(0, 4))
            self.mode_buttons[m] = b
        tk.Label(bar, text=engines.TITLES[engine].split(" (")[0], fg="#888", bg="#f7f7f7").pack(side="right")

        self.view = tk.Text(body, wrap="word", height=6, relief="flat", bg="#f7f7f7",
                            font=("Segoe UI", 11) if root.tk.call("tk", "windowingsystem") == "win32" else ("Sans", 11),
                            highlightthickness=0, padx=2, pady=8)
        self.view.pack(fill="both", expand=True)
        self.view.tag_configure("del", foreground="#c62828", overstrike=True)
        self.view.tag_configure("ins", foreground="#1b7f3b", background="#e3f4e8")
        self.view.tag_configure("muted", foreground="#888")
        self.view.tag_configure("error", foreground="#c62828")

        foot = tk.Frame(body, bg="#f7f7f7")
        foot.pack(fill="x")
        tk.Label(foot, text="Enter replace · Ctrl+C copy · 1-5 / Tab switch · Esc close",
                 fg="#888", bg="#f7f7f7").pack(side="left")
        tk.Button(foot, text="Replace", command=self.replace, default="active").pack(side="right")
        tk.Button(foot, text="Copy", command=self.copy).pack(side="right", padx=6)

        win.bind("<Return>", lambda e: self.replace())
        win.bind("<KP_Enter>", lambda e: self.replace())
        win.bind("<Escape>", lambda e: self.close())
        win.bind("<Tab>", lambda e: self.cycle(1) or "break")
        win.bind("<Shift-Tab>", lambda e: self.cycle(-1) or "break")
        win.bind("<Control-c>", lambda e: self.copy())
        for i in range(1, len(prompts.MODES) + 1):
            win.bind(str(i), lambda e, i=i: self.select(prompts.MODES[i - 1]))
        win.bind("<FocusOut>", self._maybe_close_on_blur)

        self._place()
        textio.focus_tk_window(win)
        self.select("fix")
        self._poll()

    # --- Layout

    def _place(self):
        x, y = self.root.winfo_pointerxy()
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        x = min(max(8, x - 20), sw - WIDTH - 8)
        y = y + 24 if y + 24 + HEIGHT < sh - 40 else y - HEIGHT - 12
        self.win.geometry(f"{WIDTH}x{HEIGHT}+{x}+{max(8, y)}")

    def _maybe_close_on_blur(self, event):
        # Close when you click into another app, but not when focus moves between our own widgets.
        def check():
            if self.win.winfo_exists() and self.root.focus_get() is None:
                self.close()
        self.win.after(150, check)

    # --- Modes and results

    def cycle(self, step):
        i = prompts.MODES.index(self.mode)
        self.select(prompts.MODES[(i + step) % len(prompts.MODES)])

    def select(self, mode):
        self.mode = mode
        for m, b in self.mode_buttons.items():
            b.configure(bg="#dde7f7" if m == mode else "#f7f7f7",
                        font=("TkDefaultFont", 9, "bold") if m == mode else ("TkDefaultFont", 9))
        if mode not in self.results and mode not in self.pending:
            self.pending.add(mode)
            threading.Thread(target=self._work, args=(mode,), daemon=True).start()
        self._render()

    def _work(self, mode):
        try:
            out = engines.rewrite(self.text, mode, self.engine, self.cfg)
            self.queue.put((mode, ("ok", out)))
        except engines.EngineError as e:
            self.queue.put((mode, ("error", str(e))))
        except Exception as e:  # keep the popup alive whatever happens
            self.queue.put((mode, ("error", f"Unexpected error: {e}")))

    def _poll(self):
        try:
            while True:
                mode, result = self.queue.get_nowait()
                self.pending.discard(mode)
                self.results[mode] = result
                if mode == self.mode:
                    self._render()
        except queue.Empty:
            pass
        if self.win.winfo_exists():
            self.win.after(50, self._poll)

    def _render(self):
        v = self.view
        v.configure(state="normal")
        v.delete("1.0", "end")
        result = self.results.get(self.mode)
        if result is None:
            v.insert("end", f"Asking {engines.TITLES[self.engine].split(' (')[0]}…", "muted")
        elif result[0] == "error":
            v.insert("end", result[1], "error")
        elif self.mode == "fix":
            if result[1].strip() == self.text.strip():
                v.insert("end", "✓ Looks good — no changes needed.", "ins")
            else:
                self._insert_diff(self.text, result[1])
        else:
            v.insert("end", result[1])
        v.configure(state="disabled")

    def _insert_diff(self, old, new):
        a, b = re.findall(r"\S+\s*", old), re.findall(r"\S+\s*", new)
        sm = difflib.SequenceMatcher(a=[t.strip() for t in a], b=[t.strip() for t in b], autojunk=False)
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op == "equal":
                self.view.insert("end", "".join(b[j1:j2]))
            else:
                if i2 > i1:
                    self.view.insert("end", "".join(a[i1:i2]), "del")
                if j2 > j1:
                    self.view.insert("end", "".join(b[j1:j2]), "ins")

    # --- Actions

    def _result_text(self):
        r = self.results.get(self.mode)
        return r[1] if r and r[0] == "ok" else None

    def replace(self):
        text = self._result_text()
        if text is None:
            self.win.bell()
            return
        self.close()
        self.on_replace(text)

    def copy(self):
        text = self._result_text()
        if text is None:
            self.win.bell()
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.root.update()   # keeps the clipboard content after the window closes
        self.close()

    def close(self):
        if self.win.winfo_exists():
            self.win.destroy()
            self.on_close()
