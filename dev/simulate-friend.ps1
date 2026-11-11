<#
Runs the other player's copy on this PC, exactly as they will receive it, without touching
your real save or starting the game.

It unpacks dist\Scrap Mechanic Sync.zip into a temp folder (no git, so auto-update is live),
gives it its own player name, its own settings folder and a sandbox save folder, then opens
the menu in this window.

    dev\make-friend-zip.ps1 -Tag v0.1.0
    dev\simulate-friend.ps1
    dev\simulate-friend.ps1 -Fresh     # start again from the zip

Things to try: the status box while you have the world checked out, Play (downloads into
the sandbox), Finish session, Force check-out, and the self-update after you push a newer tag.
#>
param([string]$Name = 'Friend (test)', [switch]$Fresh)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$zip = Join-Path $repo 'dist\Scrap Mechanic Sync.zip'
if (-not (Test-Path -LiteralPath $zip)) { throw 'Run dev\make-friend-zip.ps1 first.' }

$root = Join-Path ([IO.Path]::GetTempPath()) 'sm-sync-friend'
if ($Fresh -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force }
$app = Join-Path $root 'Scrap Mechanic Sync'
if (-not (Test-Path -LiteralPath $app)) {
    Expand-Archive -LiteralPath $zip -DestinationPath $root
    $save = Join-Path $root 'sandbox-save'
    [void](New-Item -ItemType Directory -Force -Path $save)
    $configPath = Join-Path $app 'sm-sync.config.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config | Add-Member -NotePropertyName SaveFolder -NotePropertyValue $save -Force
    $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
}

$env:SMSYNC_HOME = Join-Path $root 'home'
$env:SMSYNC_PLAYER = $Name
$env:SMSYNC_NO_LAUNCH = '1'
try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'sm-sync.ps1') }
finally { Remove-Item Env:SMSYNC_HOME, Env:SMSYNC_PLAYER, Env:SMSYNC_NO_LAUNCH -ErrorAction SilentlyContinue }
