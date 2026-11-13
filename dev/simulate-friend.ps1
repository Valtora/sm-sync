<#
Runs a release zip on this PC as a second player, without touching your real save or
starting the game.

It unpacks dist\Scrap-Mechanic-Sync.zip into a temp folder (no git, so auto-update is live),
gives it its own player name, its own settings folder and a sandbox save folder, then opens
the menu in this window.

    dev\make-release-zip.ps1
    dev\simulate-friend.ps1            # joins your real storage, using your settings file
    dev\simulate-friend.ps1 -Setup     # no settings: starts at the first-run setup
    dev\simulate-friend.ps1 -Fresh     # start again from the zip

With -Setup, press F in your own copy first and the invite is on the clipboard for the
simulated friend to pick up.
#>
param([string]$Name = 'Friend (test)', [switch]$Fresh, [switch]$Setup)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$zip = Join-Path $repo 'dist\Scrap-Mechanic-Sync.zip'
if (-not (Test-Path -LiteralPath $zip)) { throw 'Run dev\make-release-zip.ps1 first.' }

$root = Join-Path ([IO.Path]::GetTempPath()) 'sm-sync-friend'
if ($Fresh -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force }
$app = Join-Path $root 'Scrap Mechanic Sync'
# The tool looks for worlds under <root>\User_*\Save\Survival.
$saveRoot = Join-Path $root 'sandbox-saves'
$save = Join-Path $saveRoot 'User_76561190000000000\Save\Survival'
if (-not (Test-Path -LiteralPath $app)) {
    Expand-Archive -LiteralPath $zip -DestinationPath $root
    [void](New-Item -ItemType Directory -Force -Path $save)
    if (-not $Setup) {
        $mine = Join-Path $repo 'sm-sync.config.json'
        if (-not (Test-Path -LiteralPath $mine)) { throw 'There is no sm-sync.config.json in the repo to copy. Use -Setup to go through the first-run setup instead.' }
        $config = Get-Content -LiteralPath $mine -Raw | ConvertFrom-Json
        $config | Add-Member -NotePropertyName SaveFolder -NotePropertyValue $save -Force
        $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $app 'sm-sync.config.json') -Encoding UTF8
    }
}

$env:SMSYNC_HOME = Join-Path $root 'home'
$env:SMSYNC_PLAYER = $Name
$env:SMSYNC_NO_LAUNCH = '1'
$env:SMSYNC_SAVE_ROOT = $saveRoot
try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'sm-sync.ps1') }
finally { Remove-Item Env:SMSYNC_HOME, Env:SMSYNC_PLAYER, Env:SMSYNC_NO_LAUNCH, Env:SMSYNC_SAVE_ROOT -ErrorAction SilentlyContinue }
