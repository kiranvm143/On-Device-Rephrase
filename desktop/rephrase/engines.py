"""Rewrite engines.

Claude and ChatGPT run your own installed CLI (Claude Code / Codex), which uses the account you
signed into it with. Rephrase never sees or stores a login. Ollama is a free local model.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from . import codexdl, prompts

ENGINES = ["claude", "chatgpt", "ollama"]

TITLES = {
    "claude": "Claude (your Claude account)",
    "chatgpt": "ChatGPT (your ChatGPT account)",
    "ollama": "Local model (Ollama, free)",
}

SHORT = {"claude": "Claude", "chatgpt": "ChatGPT", "ollama": "Ollama"}

# Engine states, shown as badges in the popup's engine picker.
READY, NOT_INSTALLED, NOT_SIGNED_IN, NOT_RUNNING, NEEDS_MODEL = (
    "ready", "not_installed", "not_signed_in", "not_running", "needs_model")
BADGES = {NOT_INSTALLED: "not installed", NOT_SIGNED_IN: "sign in",
          NOT_RUNNING: "not running", NEEDS_MODEL: "needs model"}

TIMEOUT = 90


class EngineError(Exception):
    pass


class NeedsSetup(EngineError):
    """The engine isn't installed / signed in / running yet; the popup shows a setup button."""

    def __init__(self, engine: str, state: str, model: str = ""):
        self.engine, self.state, self.model = engine, state, model
        super().__init__(f"{engine}: {state}")


def find(name: str):
    found = shutil.which(name)
    if found:
        return found
    home = os.path.expanduser("~")
    local = os.environ.get("LOCALAPPDATA", os.path.join(home, "AppData", "Local"))
    extra = [
        os.path.join(home, ".local", "bin"),
        os.path.join(home, ".claude", "local"),
        os.path.join(home, ".npm-global", "bin"),
        os.path.join(home, "AppData", "Roaming", "npm"),
        os.path.join(local, "Programs", "claude"),
        os.path.join(local, "Programs", "Ollama"),
        "/usr/local/bin",
        os.path.dirname(codexdl.managed_path()),
    ]
    return shutil.which(name, path=os.pathsep.join(extra))


_find = find


def ollama_installed() -> bool:
    return find("ollama") is not None


def available(engine: str) -> bool:
    if engine == "claude":
        return find("claude") is not None
    if engine == "chatgpt":
        return find("codex") is not None or codexdl.has_chatgpt_sign_in()
    if engine == "ollama":
        return ollama_installed()
    return False


def status(engine: str, cfg: dict) -> str:
    """READY, or what's missing. Takes up to a few seconds (runs the CLI's own status command)."""
    if engine == "claude":
        exe = find("claude")
        if not exe:
            return NOT_INSTALLED
        try:
            r = _run([exe, "auth", "status", "--json"], None, timeout=15)
            return READY if json.loads(r.stdout or "{}").get("loggedIn") else NOT_SIGNED_IN
        except (EngineError, ValueError):
            return NOT_SIGNED_IN
    if engine == "chatgpt":
        exe = find("codex")
        if not exe:   # Rephrase downloads its own Codex on first use; only the sign-in matters
            return READY if codexdl.has_chatgpt_sign_in() else NOT_SIGNED_IN
        try:
            return READY if _run([exe, "login", "status"], None, timeout=15).returncode == 0 else NOT_SIGNED_IN
        except EngineError:
            return NOT_SIGNED_IN
    if engine == "ollama":
        try:
            names = ollama_models(cfg)
        except OSError:
            return NOT_RUNNING if ollama_installed() else NOT_INSTALLED
        model = cfg.get("ollama_model", "llama3.2")
        wanted = model if ":" in model else model + ":latest"
        return READY if wanted in names or model in names else NEEDS_MODEL
    return NOT_INSTALLED


def ollama_models(cfg: dict) -> list:
    url = cfg.get("ollama_url", "http://localhost:11434").rstrip("/") + "/api/tags"
    with urllib.request.urlopen(url, timeout=2) as resp:
        return [m.get("name", "") for m in json.loads(resp.read().decode("utf-8")).get("models", [])]


def default_engine() -> str:
    for e in ENGINES:
        if available(e):
            return e
    return "claude"


def _run(cmd, stdin_text, timeout=TIMEOUT):
    kwargs = {}
    if sys.platform == "win32":
        kwargs["creationflags"] = 0x08000000  # CREATE_NO_WINDOW: no console flash under pythonw
    try:
        return subprocess.run(
            cmd, input=stdin_text, capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=timeout, cwd=tempfile.gettempdir(),
            stdin=None if stdin_text is not None else subprocess.DEVNULL, **kwargs,
        )
    except subprocess.TimeoutExpired:
        raise EngineError(f"{os.path.basename(cmd[0])} took longer than {timeout} s.")
    except OSError as e:
        raise EngineError(f"Couldn't start {cmd[0]}: {e}")


def _looks_like_auth_error(text: str) -> bool:
    t = text.lower()
    return any(w in t for w in ("login", "log in", "sign in", "auth", "unauthorized", "401"))


def ask_claude(system: str, user: str, temperature: float, cfg: dict) -> str:
    exe = _find("claude")
    if not exe:
        raise NeedsSetup("claude", "not_installed")
    # Instructions go in through stdin: Windows .cmd launchers mangle multi-line arguments.
    cmd = [exe, "-p", "--model", cfg.get("claude_model", "haiku"),
           "--tools", "", "--safe-mode", "--no-session-persistence"]
    r = _run(cmd, system + "\n\n" + user)
    out = (r.stdout or "").strip()
    if r.returncode != 0 or not out:
        err = (r.stderr or "") + out
        if _looks_like_auth_error(err):
            raise NeedsSetup("claude", "not_signed_in")
        raise EngineError("Claude Code failed: " + (err.strip().splitlines() or ["unknown error"])[0][:200])
    return out


def ask_chatgpt(system: str, user: str, temperature: float, cfg: dict) -> str:
    try:
        exe = codexdl.ensure()   # one-time download of Rephrase's own Codex if there's none
    except (OSError, ValueError) as e:
        raise EngineError(f"Couldn't set up ChatGPT: {e}")
    fd, out_file = tempfile.mkstemp(prefix="rephrase-", suffix=".txt")
    os.close(fd)
    try:
        cmd = [exe, "exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
               "-c", "model_reasoning_effort=low", "--output-last-message", out_file, "-"]
        r = _run(cmd, system + "\n\n" + user)
        try:
            with open(out_file, encoding="utf-8") as f:
                answer = f.read().strip()
        except OSError:
            answer = ""
        if r.returncode != 0 or not answer:
            err = (r.stderr or "") + (r.stdout or "")
            if _looks_like_auth_error(err):
                raise NeedsSetup("chatgpt", "not_signed_in")
            raise EngineError("Codex failed: " + (err.strip().splitlines() or ["unknown error"])[-1][:200])
        return answer
    finally:
        try:
            os.remove(out_file)
        except OSError:
            pass


def ask_ollama(system: str, user: str, temperature: float, cfg: dict) -> str:
    body = json.dumps({
        "model": cfg.get("ollama_model", "llama3.2"),
        "stream": False,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "options": {"temperature": temperature},
    }).encode()
    url = cfg.get("ollama_url", "http://localhost:11434").rstrip("/") + "/api/chat"
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NeedsSetup("ollama", "needs_model", cfg.get("ollama_model", "llama3.2"))
        raise EngineError(f"Ollama error {e.code}.")
    except (urllib.error.URLError, OSError):
        raise NeedsSetup("ollama", "not_running" if ollama_installed() else "not_installed")
    return data.get("message", {}).get("content", "").strip()


ASK = {"claude": ask_claude, "chatgpt": ask_chatgpt, "ollama": ask_ollama}


def rewrite(text: str, mode: str, engine: str, cfg: dict) -> str:
    out = ASK[engine](prompts.instructions(mode), prompts.wrap(text), 0.1 if mode == "fix" else 0.7, cfg)
    return prompts.clean(out, text)


def draft_reply(conversation: str, engine: str, cfg: dict) -> str:
    """A reply to `conversation` (messages you selected), written as you."""
    out = ASK[engine](prompts.reply_instructions(), prompts.wrap_conversation(conversation[-6000:]), 0.7, cfg)
    return prompts.clean_reply(out)
