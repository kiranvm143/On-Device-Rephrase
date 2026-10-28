# Installs Rephrase on Windows.
#   irm https://raw.githubusercontent.com/kiranvm143/On-Device-Rephrase/main/install/install.ps1 | iex
$ErrorActionPreference = 'Stop'

$Repo   = 'kiranvm143/On-Device-Rephrase'
$Branch = if ($env:REPHRASE_BRANCH) { $env:REPHRASE_BRANCH } else { 'main' }
$Home_  = Join-Path $env:LOCALAPPDATA 'Rephrase'

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Find-Python {
    foreach ($cand in @(@('py', '-3'), @('python'), @('python3'))) {
        $exe = Get-Command $cand[0] -ErrorAction SilentlyContinue
        if (-not $exe) { continue }
        $args_ = if ($cand.Count -gt 1) { $cand[1..($cand.Count - 1)] } else { @() }
        try {
            $ok = & $exe.Source @args_ -c "import sys, tkinter; print(sys.version_info >= (3, 9))" 2>$null
            if ($ok -eq 'True') { return @($exe.Source) + $args_ }
        } catch { }
    }
    return @()
}

# @() keeps a one-element result an array (PowerShell would unwrap it to a string).
$py = @(Find-Python)
if ($py.Count -eq 0) {
    Write-Host "Rephrase needs Python 3.9+ (with tkinter, included in the python.org installer)."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $answer = Read-Host "Install Python 3.12 for your user now with winget? [Y/n]"
        if ($answer -eq '' -or $answer -match '^[Yy]') {
            winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $py = @(Find-Python)
        }
    }
    if ($py.Count -eq 0) { throw "Install Python 3.12 from https://www.python.org/downloads/ and run this again." }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rephrase-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Say "Downloading Rephrase ($Branch)..."
    $zip = Join-Path $tmp 'src.zip'
    Invoke-WebRequest "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $tmp
    $src = Get-ChildItem $tmp -Directory | Select-Object -First 1

    Say "Installing into $Home_..."
    Get-Process -Name 'rephrase-gui' -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path "$Home_\venv") { Remove-Item "$Home_\venv" -Recurse -Force }
    New-Item -ItemType Directory -Path $Home_ -Force | Out-Null
    $pyExe = $py[0]; $pyArgs = if ($py.Count -gt 1) { $py[1..($py.Count - 1)] } else { @() }
    & $pyExe @pyArgs -m venv "$Home_\venv"
    & "$Home_\venv\Scripts\python.exe" -m pip install -q --upgrade pip
    & "$Home_\venv\Scripts\python.exe" -m pip install -q (Join-Path $src.FullName 'desktop')
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Start Menu entry and start-at-login, both launching without a console window.
$target = "$Home_\venv\Scripts\rephrase-gui.exe"
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup'))) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Rephrase.lnk'))
    $lnk.TargetPath = $target
    $lnk.Description = 'Rewrite selected text anywhere'
    $lnk.Save()
}

Start-Process $target

Write-Host @"

Rephrase is installed and running (look for the blue R in the system tray; it also starts at login).

Next:
  1. Select text in any app and press Ctrl+Alt+R.
  2. Pick an engine from the tray icon -> Engine:
       Claude:  install Claude Code, run 'claude' once and sign in
       ChatGPT: install Codex (npm i -g @openai/codex), run 'codex login'
       Local:   install Ollama (ollama.com), run 'ollama pull llama3.2'

To uninstall: delete $Home_ and the Rephrase shortcuts in the Start Menu and Startup folders.
"@
