# Rephrase for Windows and Linux

Select text in any app, press **Ctrl+Alt+R**, pick a rewrite, press Enter to replace it.
See the [main README](../README.md) for install commands.

```bash
pip install .           # from this folder
rephrase                # run (tray icon + hotkey)
rephrase --trigger      # open the popup in the running instance (bind this to a desktop shortcut on Wayland)
rephrase --test "i has went there" claude   # try an engine from the terminal
```

Settings live in `config.json` (`%APPDATA%\Rephrase` on Windows, `~/.config/rephrase` on Linux).
