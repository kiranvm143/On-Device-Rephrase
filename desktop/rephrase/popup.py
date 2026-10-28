"""The rewrite popup: mode buttons, engine picker, the result (with a red/green diff for Fix),
a setup panel when the chosen engine needs installing / signing in, and Replace / Copy."""

import difflib
import queue
import re
import threading
import tkinter as tk
from tkinter import ttk

from . import engines, enginesetup, prompts, textio

WIDTH, HEIGHT = 560, 250
BG, SELECTED, MUTED, RED, GREEN = "#f7f7f7", "#dde7f7", "#888", "#c62828", "#1b7f3b"


class Popup:
    def __init__(self, root, text, cfg, runner, on_engine_change, on_replace, on_close):
        self.root = root
        self.text = text
        self.cfg = cfg
        self.engine = cfg["engine"]
        self.runner = runner                # shared enginesetup.Runner
        self.on_engine_change = on_engine_change
        self.on_replace = on_replace
        self.on_close = on_close
        self.mode = "fix"
        self.results = {}                   # mode -> ("ok" | "error" | "setup", value)
        self.pending = set()
        self.statuses = {}                  # engine -> state, for the picker's badges
        self.queue = queue.Queue()
        self._was_busy = False
        ui_font = ("Segoe UI", 11) if root.tk.call("tk", "windowingsystem") == "win32" else ("Sans", 11)

        win = self.win = tk.Toplevel(root)
        win.title("Rephrase")
        win.overrideredirect(True)
        win.attributes("-topmost", True)
        win.configure(bg="#c8c8c8")
        body = tk.Frame(win, bg=BG, padx=12, pady=10)
        body.pack(fill="both", expand=True, padx=1, pady=1)

        # Header: modes on the left, engine picker on the right.
        bar = tk.Frame(body, bg=BG)
        bar.pack(fill="x")
        self.mode_buttons = {}
        for m in prompts.MODES:
            b = tk.Button(bar, text=prompts.TITLES[m], relief="flat", bd=0, padx=8, pady=3, bg=BG,
                          activebackground=SELECTED, cursor="hand2", command=lambda m=m: self.select(m))
            b.pack(side="left", padx=(0, 4))
            self.mode_buttons[m] = b
        self.engine_var = tk.StringVar(value=self.engine)
        self.picker = tk.Menubutton(bar, relief="flat", bg=BG, activebackground=SELECTED, cursor="hand2",
                                    font=("TkDefaultFont", 9, "bold"))
        self.picker_menu = tk.Menu(self.picker, tearoff=False)
        for e in engines.ENGINES:
            self.picker_menu.add_radiobutton(label=engines.TITLES[e], value=e, variable=self.engine_var,
                                             command=lambda e=e: self.switch_engine(e))
        self.picker["menu"] = self.picker_menu
        self.picker.pack(side="right")
        self._update_picker()

        # Content: either the result text or the setup panel.
        self.content = tk.Frame(body, bg=BG)
        self.content.pack(fill="both", expand=True)
        self.view = tk.Text(self.content, wrap="word", height=6, relief="flat", bg=BG, font=ui_font,
                            highlightthickness=0, padx=2, pady=8)
        self.view.tag_configure("del", foreground=RED, overstrike=True)
        self.view.tag_configure("ins", foreground=GREEN, background="#e3f4e8")
        self.view.tag_configure("muted", foreground=MUTED)
        self.view.tag_configure("error", foreground=RED)

        self.setup = tk.Frame(self.content, bg=BG, pady=8)
        self.setup_headline = tk.Label(self.setup, bg=BG, anchor="w", font=(ui_font[0], 12, "bold"))
        self.setup_headline.pack(fill="x")
        self.setup_detail = tk.Label(self.setup, bg=BG, fg="#555", anchor="w", justify="left",
                                     wraplength=WIDTH - 40)
        self.setup_detail.pack(fill="x", pady=(2, 8))
        row = tk.Frame(self.setup, bg=BG)
        row.pack(fill="x")
        self.setup_action = tk.Button(row, command=self.run_setup, default="active")
        self.setup_action.pack(side="left")
        self.setup_check = tk.Button(row, text="Check again", command=self.check_again)
        self.setup_check.pack(side="left", padx=8)
        self.setup_activity = tk.Label(row, bg=BG, fg="#333")
        self.setup_activity.pack(side="left")
        self.setup_progress = ttk.Progressbar(self.setup, mode="determinate", maximum=1.0, length=220)
        self.setup_error = tk.Label(self.setup, bg=BG, fg=RED, anchor="w", wraplength=WIDTH - 40, justify="left")
        self.setup_error.pack(fill="x", pady=(6, 0))

        foot = tk.Frame(body, bg=BG)
        foot.pack(fill="x")
        tk.Label(foot, text="Enter replace · Ctrl+C copy · 1-5 / Tab switch · Esc close",
                 fg=MUTED, bg=BG).pack(side="left")
        tk.Button(foot, text="Replace", command=self.replace, default="active").pack(side="right")
        tk.Button(foot, text="Copy", command=self.copy).pack(side="right", padx=6)

        win.bind("<Return>", lambda e: self.enter())
        win.bind("<KP_Enter>", lambda e: self.enter())
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
        self._refresh_statuses()
        self._poll()

    # --- Layout

    def _place(self):
        x, y = self.root.winfo_pointerxy()
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        x = min(max(8, x - 20), sw - WIDTH - 8)
        y = y + 24 if y + 24 + HEIGHT < sh - 40 else y - HEIGHT - 12
        self.win.geometry(f"{WIDTH}x{HEIGHT}+{x}+{max(8, y)}")

    def _maybe_close_on_blur(self, event):
        # Close when you click into another app, but not when focus moves between our own widgets
        # or to the engine menu.
        def check():
            if self.win.winfo_exists() and self.root.focus_get() is None:
                self.close()
        self.win.after(250, check)

    def _update_picker(self):
        self.picker.configure(text=f"{engines.SHORT[self.engine]} ▾")
        for i, e in enumerate(engines.ENGINES):
            badge = engines.BADGES.get(self.statuses.get(e, engines.READY), "")
            self.picker_menu.entryconfigure(i, label=engines.TITLES[e] + (f"  — {badge}" if badge else ""))

    def _refresh_statuses(self):
        def work():
            for e in engines.ENGINES:
                self.queue.put(("status", e, engines.status(e, self.cfg)))
        threading.Thread(target=work, daemon=True).start()

    # --- Engines

    def switch_engine(self, engine):
        if engine == self.engine:
            return
        self.engine = engine
        self.on_engine_change(engine)
        self._update_picker()
        self.retry_all()

    def retry_all(self):
        self.results.clear()
        self.pending.clear()
        self.select(self.mode)

    def run_setup(self):
        r = self.results.get(self.mode)
        if r and r[0] == "setup" and not self.runner.busy:
            engine, state, _ = r[1]
            self.runner.start(engine, state)

    def check_again(self):
        engine = self.engine

        def work():
            self.queue.put(("checked", engine, engines.status(engine, self.cfg)))
        threading.Thread(target=work, daemon=True).start()

    def enter(self):
        r = self.results.get(self.mode)
        if r and r[0] == "setup":
            self.run_setup()
        else:
            self.replace()

    # --- Modes and results

    def cycle(self, step):
        i = prompts.MODES.index(self.mode)
        self.select(prompts.MODES[(i + step) % len(prompts.MODES)])

    def select(self, mode):
        self.mode = mode
        for m, b in self.mode_buttons.items():
            b.configure(bg=SELECTED if m == mode else BG,
                        font=("TkDefaultFont", 9, "bold") if m == mode else ("TkDefaultFont", 9))
        if mode not in self.results and mode not in self.pending:
            self.pending.add(mode)
            threading.Thread(target=self._work, args=(mode, self.engine), daemon=True).start()
        self._render()

    def _work(self, mode, engine):
        try:
            result = ("ok", engines.rewrite(self.text, mode, engine, self.cfg))
        except engines.NeedsSetup as e:
            result = ("setup", (e.engine, e.state, e.model))
        except engines.EngineError as e:
            result = ("error", str(e))
        except Exception as e:  # keep the popup alive whatever happens
            result = ("error", f"Unexpected error: {e}")
        self.queue.put(("result", mode, engine, result))

    def _poll(self):
        if not self.win.winfo_exists():
            return
        try:
            while True:
                item = self.queue.get_nowait()
                if item[0] == "status":
                    self.statuses[item[1]] = item[2]
                    self._update_picker()
                elif item[0] == "checked":
                    _, engine, state = item
                    self.statuses[engine] = state
                    self._update_picker()
                    if engine == self.engine:
                        if state == engines.READY:
                            self.retry_all()
                        else:
                            r = self.results.get(self.mode)
                            model = r[1][2] if r and r[0] == "setup" else self.cfg.get("ollama_model", "llama3.2")
                            self.results[self.mode] = ("setup", (engine, state, model))
                            self._render()
                elif item[0] == "result":
                    _, mode, engine, result = item
                    if engine != self.engine:
                        continue            # an answer from before you switched engines
                    self.pending.discard(mode)
                    self.results[mode] = result
                    if result[0] == "setup":
                        self.statuses[engine] = result[1][1]
                        self._update_picker()
                    if mode == self.mode:
                        self._render()
        except queue.Empty:
            pass
        # A setup job just finished: check the engine again (and retry if it's ready now).
        if self._was_busy and not self.runner.busy:
            self.check_again()
        self._was_busy = self.runner.busy
        self._render_setup_progress()
        self.win.after(100, self._poll)

    def _render(self):
        result = self.results.get(self.mode)
        if result and result[0] == "setup":
            self.view.pack_forget()
            self.setup.pack(fill="both", expand=True)
            engine, state, model = result[1]
            c = enginesetup.copy(engine, state, model)
            self.setup_headline.configure(text=c["headline"])
            self.setup_detail.configure(text=c["detail"])
            self.setup_action.configure(text=c["action"] or "")
            self._render_setup_progress()
            return
        self.setup.pack_forget()
        self.view.pack(fill="both", expand=True)
        v = self.view
        v.configure(state="normal")
        v.delete("1.0", "end")
        if result is None:
            v.insert("end", f"Asking {engines.SHORT[self.engine]}…", "muted")
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

    def _render_setup_progress(self):
        r = self.results.get(self.mode)
        if not r or r[0] != "setup":
            return
        busy = self.runner.busy
        if busy or not self.setup_action.cget("text"):
            self.setup_action.pack_forget()
        elif not self.setup_action.winfo_ismapped():
            self.setup_action.pack(side="left", before=self.setup_check)
        self.setup_activity.configure(text=self.runner.activity if busy else "")
        if busy and self.runner.progress is not None:
            self.setup_progress["value"] = self.runner.progress
            if not self.setup_progress.winfo_ismapped():
                self.setup_progress.pack(anchor="w", pady=(6, 0), before=self.setup_error)
        else:
            self.setup_progress.pack_forget()
        self.setup_error.configure(text="" if busy else self.runner.error)

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
