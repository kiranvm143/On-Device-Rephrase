"""Install / sign in / start each engine from the popup, so you never need a terminal.

Sign-in uses each vendor's own CLI (`claude auth login`, `codex login`), which opens your browser.
Rephrase never sees your password or tokens. Every action runs on a background thread and reports
through `report(activity, progress)`; the popup polls and redraws.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import webbrowser

from . import config, engines
from .engines import NEEDS_MODEL, NOT_INSTALLED, NOT_RUNNING, NOT_SIGNED_IN

WIN = sys.platform == "win32"


def copy(engine: str, state: str, model: str = "") -> dict:
    """Headline, detail and button title for the setup panel."""
    name = engines.SHORT[engine]
    table = {
        ("claude", NOT_INSTALLED): ("Claude needs Claude Code",
            "Rephrase uses your Claude account through Claude Code, Anthropic's official app. "
            "Installing takes about a minute.", "Install Claude Code"),
        ("claude", NOT_SIGNED_IN): ("Sign in to Claude",
            "Your browser will open to sign in with your Claude account. Rephrase never sees your password.",
            "Sign in to Claude"),
        ("chatgpt", NOT_INSTALLED): ("ChatGPT needs Codex",
            "Rephrase uses your ChatGPT account through Codex, OpenAI's official app.", "Install Codex"),
        ("chatgpt", NOT_SIGNED_IN): ("Sign in with ChatGPT",
            "Your browser will open to sign in with your ChatGPT account. Rephrase never sees your password.",
            "Sign in with ChatGPT"),
        ("ollama", NOT_INSTALLED): ("Install Ollama",
            "Ollama runs AI models on this computer: free, private and offline.", "Install Ollama"),
        ("ollama", NOT_RUNNING): ("Ollama isn't running", "Ollama is installed but not started.", "Start Ollama"),
        ("ollama", NEEDS_MODEL): (f"Download the {model or 'llama3.2'} model",
            "A one-time download of about 2 GB. After that it works offline.", "Download model"),
    }
    headline, detail, action = table.get((engine, state), (f"{name} isn't ready", "Pick another engine above.", None))
    return {"headline": headline, "detail": detail, "action": action}


class Runner:
    """Runs one setup job at a time on a background thread. Owned by the app (not the popup), so a
    sign-in keeps going if the popup closes when your browser opens. The popup reads its fields."""

    def __init__(self, cfg, on_done):
        self.cfg = cfg
        self.on_done = on_done          # called from the worker thread with (engine, error)
        self.busy = False
        self.activity = ""
        self.progress = None            # 0..1 while downloading a model
        self.error = ""

    def start(self, engine: str, state: str):
        if self.busy:
            return
        self.busy, self.activity, self.progress, self.error = True, "Working…", None, ""

        def report(activity, progress):
            self.activity, self.progress = activity, progress

        def work():
            error = perform(engine, state, self.cfg, report)
            self.busy, self.activity, self.progress, self.error = False, "", None, error
            self.on_done(engine, error)
        threading.Thread(target=work, daemon=True).start()


def _run(cmd, timeout):
    kwargs = {"creationflags": 0x08000000} if WIN else {}   # no console window
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout,
                          stdin=subprocess.DEVNULL, cwd=tempfile.gettempdir(), **kwargs)


def _open_terminal(cmd: list) -> bool:
    """Fallback when a CLI insists on a real terminal for sign-in."""
    if WIN:
        subprocess.Popen(["cmd", "/c", "start", "", "cmd", "/k"] + cmd)
        return True
    line = " ".join(f'"{c}"' for c in cmd)
    for term in (["x-terminal-emulator", "-e"], ["gnome-terminal", "--"], ["konsole", "-e"], ["xterm", "-e"]):
        if shutil.which(term[0]):
            subprocess.Popen(term + ["sh", "-c", line + "; echo; echo Done, you can close this window.; read x"])
            return True
    return False


def perform(engine: str, state: str, cfg: dict, report) -> str:
    """Runs the setup step for `state`. Returns an error message, or "" when it went fine."""
    try:
        if engine == "claude" and state == NOT_INSTALLED:
            report("Installing Claude Code… (about a minute)", None)
            if WIN:   # Anthropic's official installers
                cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                       "irm https://claude.ai/install.ps1 | iex"]
            else:
                cmd = ["bash", "-c", "curl -fsSL https://claude.ai/install.sh | bash"]
            r = _run(cmd, 600)
            config.log(f"setup: install claude exit={r.returncode}")
            return "" if engines.find("claude") else "Couldn't install Claude Code. See claude.com/product/claude-code."

        if engine == "chatgpt" and state == NOT_INSTALLED:
            npm = engines.find("npm")
            if not npm:
                webbrowser.open("https://github.com/openai/codex#installation")
                return "Install Node.js (nodejs.org) or Codex from the page that opened, then click Check again."
            report("Installing Codex…", None)
            r = _run([npm, "install", "-g", "@openai/codex"], 600)
            config.log(f"setup: install codex exit={r.returncode}")
            return "" if engines.find("codex") else "Couldn't install Codex: " + (r.stderr.strip().splitlines() or ["npm failed"])[-1][:160]

        if engine in ("claude", "chatgpt") and state == NOT_SIGNED_IN:
            exe = engines.find("claude" if engine == "claude" else "codex")
            cmd = [exe, "auth", "login"] if engine == "claude" else [exe, "login"]
            report("Finish signing in in your browser…", None)
            started = time.time()
            try:
                r = _run(cmd, 300)
            except subprocess.TimeoutExpired:
                return "Sign-in timed out. Click the button to try again."
            if r.returncode != 0 and time.time() - started < 10:
                # It wanted a terminal: open one, then keep checking until you're signed in.
                config.log(f"setup: {engine} sign-in needs a terminal")
                if not _open_terminal(cmd):
                    return "Couldn't open a terminal for sign-in. Run: " + " ".join(os.path.basename(c) for c in cmd)
                report("Finish signing in in the terminal window that opened…", None)
                for _ in range(150):
                    time.sleep(2)
                    if engines.status(engine, cfg) == engines.READY:
                        return ""
                return "Still not signed in. Click Check again when you're done."
            return ""

        if engine == "ollama" and state == NOT_INSTALLED:
            if WIN and shutil.which("winget"):
                report("Installing Ollama… (a few minutes)", None)
                _run(["winget", "install", "-e", "--id", "Ollama.Ollama", "--silent",
                      "--accept-package-agreements", "--accept-source-agreements"], 1200)
                if engines.ollama_installed():
                    return perform(engine, NOT_RUNNING, cfg, report)
            webbrowser.open("https://ollama.com/download")
            return "Install Ollama from the page that opened, then click Check again."

        if engine == "ollama" and state == NOT_RUNNING:
            report("Starting Ollama…", None)
            app = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Ollama", "ollama app.exe")
            if WIN and os.path.exists(app):
                subprocess.Popen([app])
            elif engines.find("ollama"):
                kwargs = {"creationflags": 0x08000000} if WIN else {"start_new_session": True}
                subprocess.Popen([engines.find("ollama"), "serve"], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, **kwargs)
            for _ in range(30):
                time.sleep(0.5)
                try:
                    engines.ollama_models(cfg)
                    return ""
                except OSError:
                    pass
            return "Ollama didn't start. Open the Ollama app, then click Check again."

        if engine == "ollama" and state == NEEDS_MODEL:
            model = cfg.get("ollama_model", "llama3.2")
            report(f"Downloading {model}…", 0.0)
            url = cfg.get("ollama_url", "http://localhost:11434").rstrip("/") + "/api/pull"
            req = urllib.request.Request(url, data=json.dumps({"model": model, "stream": True}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3600) as resp:
                for line in resp:
                    msg = json.loads(line.decode("utf-8") or "{}")
                    if msg.get("error"):
                        return "Ollama: " + msg["error"]
                    if msg.get("total"):
                        frac = msg.get("completed", 0) / msg["total"]
                        report(f"Downloading {model}… {int(frac * 100)}%", frac)
            return ""
    except Exception as e:  # keep the popup alive whatever happens
        config.log(f"setup: {engine} {state} failed: {e}")
        return f"Setup failed: {e}"
    return ""
