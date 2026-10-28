"""Settings in config.json: %APPDATA%\\Rephrase on Windows, ~/.config/rephrase on Linux."""

import json
import os
import sys
from pathlib import Path

DEFAULTS = {
    "engine": "",                       # "claude", "chatgpt" or "ollama"; empty = first one installed
    "hotkey": "<ctrl>+<alt>+r",         # pynput format
    "ollama_model": "llama3.2",
    "ollama_url": "http://localhost:11434",
    "claude_model": "haiku",
}


def config_dir() -> Path:
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
        return base / "Rephrase"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "rephrase"


def config_path() -> Path:
    return config_dir() / "config.json"


def load() -> dict:
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(config_path().read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass
    return cfg


def save(cfg: dict) -> None:
    config_dir().mkdir(parents=True, exist_ok=True)
    config_path().write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def log(message: str) -> None:
    """Appends to rephrase.log next to the config. Never logs the text itself."""
    try:
        config_dir().mkdir(parents=True, exist_ok=True)
        from datetime import datetime
        with open(config_dir() / "rephrase.log", "a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%H:%M:%S} {message}\n")
    except OSError:
        pass
