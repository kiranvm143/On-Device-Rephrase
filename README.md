# On-Device Rephrase

**A Grammarly-style writing helper for every app on your computer.** Select text (or just type in a text box),
click the ✨ icon or press a hotkey, and pick a rewrite: **Fix · Rephrase · Shorter · Professional · Friendly**.
Press Enter and your text is replaced.

<p align="center">
  <img src="docs/images/popup-fix.png" width="520" alt="Rephrase fixing grammar, with removed words in red and new words in green">
</p>

- **Works everywhere:** mail, chat, browsers, documents, Teams, Zoom, Slack…
- **Free and private on Mac:** Apple's on-device AI, with no account, nothing sent anywhere, and works offline.
- **Or use your own ChatGPT or Claude account**, or a free local model (Ollama), on Mac, Windows and Linux.
- **No API keys, no terminal.** Switch engines in the popup; if one needs setting up, the popup gives you one
  button (**Sign in**, **Install**, **Download model**). Sign-in happens in your browser.

## Install

**Mac** (macOS 26+, Apple Silicon) and **Linux**: paste into Terminal

```bash
curl -fsSL https://raw.githubusercontent.com/kiranvm143/On-Device-Rephrase/main/install/install.sh | bash
```

**Windows**: paste into PowerShell

```powershell
irm https://raw.githubusercontent.com/kiranvm143/On-Device-Rephrase/main/install/install.ps1 | iex
```

Or download the app from the [latest release](https://github.com/kiranvm143/On-Device-Rephrase/releases/latest)
(see the [User Guide](docs/USER_GUIDE.md#option-b-download-the-app) for the one-time first-launch step).

On Mac, allow Rephrase in **System Settings → Privacy & Security → Accessibility** when asked.

## Quick start

| | Mac | Windows / Linux |
|---|---|---|
| Open | Click ✨ in a text box, or select text and press **⌃⌥R** | Select text and press **Ctrl+Alt+R** |
| Pick a rewrite | `1`–`5` or `Tab` | `1`–`5` or `Tab` |
| Replace / Copy / Close | `↩` / `⌘C` / `esc` | `Enter` / `Ctrl+C` / `Esc` |
| Change engine | Engine name at the popup's top right | Engine name at the popup's top right |

## Engines

| Engine | Platforms | Cost | Your text goes to |
|---|---|---|---|
| **Apple on-device** (default on Mac) | Mac | Free | Nowhere |
| **ChatGPT** | All | Your ChatGPT plan | OpenAI |
| **Claude** | All | Paid Claude plan with Claude Code | Anthropic |
| **Local model (Ollama)** | All | Free | Nowhere |

<p align="center">
  <img src="docs/images/popup-setup.png" width="520" alt="The popup offering a one-click sign-in for Claude">
</p>

Rephrase never sees your passwords or tokens. ChatGPT and Claude run through OpenAI's and Anthropic's own
command-line tools, which you sign into in the browser; for ChatGPT, Rephrase downloads OpenAI's Codex tool once
and verifies its checksum. Please check this use fits your plan's terms. Anthropic, for example, intends Claude
subscription logins for its own apps, and an API key is the supported route for heavy or shared use.

## Documentation

- **[User Guide](docs/USER_GUIDE.md)**: install, first launch, every feature, engines and setup, settings,
  privacy, troubleshooting, uninstall, FAQ.
- **[Developer Guide](docs/DEVELOPER_GUIDE.md)**: how it works, repository layout, build and test, debugging,
  CI and releases, adding engines.

## Privacy in short

Apple and Ollama keep your text on your computer. ChatGPT and Claude receive only the text you rewrite. Rephrase
skips password fields, terminals and password managers, restores your clipboard, and never logs your text.

## Contributing

Bug reports and pull requests are welcome. Please open an
[issue](https://github.com/kiranvm143/On-Device-Rephrase/issues) with the last lines of the log (see
[Troubleshooting](docs/USER_GUIDE.md#8-troubleshooting)). Testing on Windows and Linux is especially helpful. To build
from source, see the [Developer Guide](docs/DEVELOPER_GUIDE.md#6-build-run-and-test).

## License

[MIT](LICENSE)
