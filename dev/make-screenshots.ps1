<#
Retakes the screenshots in docs\ from a demo copy with made-up players and worlds, run
against the local stand-in for the storage. Nothing real is shown, so nothing needs
redacting. Windows Terminal windows open and close by themselves for about a minute.

    dev\make-screenshots.ps1

Needs Windows Terminal and python. Close any open Scrap Mechanic Sync window first.
SMSYNC_KEYS feeds the tool the key presses that lead to each screen.
#>
param([string]$Repo = (Split-Path $PSScriptRoot -Parent), [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs'), [int]$Port = 9395)
$ErrorActionPreference = 'Stop'
$demo = Join-Path ([IO.Path]::GetTempPath()) 'sm-sync-demo'
if (Test-Path $demo) { Remove-Item $demo -Recurse -Force }
$title = 'Scrap Mechanic Sync'

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
[void][Win]::SetProcessDPIAware()
function Find { return [Win]::FindWindow([NullString]::Value, $title) }
if ((Find) -ne [IntPtr]::Zero) { throw "A window titled '$title' is already open. Close it first." }

function Run([string]$App, [string]$Player, [string[]]$Arguments) {
    $env:SMSYNC_HOME = "$demo\home-$Player"; $env:SMSYNC_PLAYER = $Player
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$demo\$App\sm-sync.ps1" @Arguments -NoUpdate -Plain | Out-Null
}
function Shot([string]$App, [string]$Player, [string]$Extra, [string]$Keys, [string]$File, [int]$Rows) {
    $cmd = "$demo\run-$File.cmd"
    @(
        '@echo off'
        "set SMSYNC_HOME=$demo\home-$Player"
        "set SMSYNC_PLAYER=$Player"
        "set SMSYNC_SAVE_ROOT=$demo\saves-$Player"
        'set SMSYNC_GAME_PROCESS=NoSuchGame_demo'
        'set SMSYNC_NO_TOAST=1'
        'set SMSYNC_NO_LAUNCH=1'
        'set SMSYNC_NO_CLIPBOARD=1'
        "set SMSYNC_KEYS=$Keys"
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$demo\$App\sm-sync.ps1`" -NoUpdate $Extra"
    ) | Set-Content $cmd -Encoding ASCII
    Start-Process wt.exe -ArgumentList '-w', 'new', '--size', "120,$Rows", '--title', "`"$title`"", '--suppressApplicationTitle', '--tabColor', '#FF8A00', 'cmd.exe', '/c', "`"$cmd`""
    $h = [IntPtr]::Zero
    foreach ($i in 1..40) { Start-Sleep -Milliseconds 250; $h = Find; if ($h -ne [IntPtr]::Zero) { break } }
    if ($h -eq [IntPtr]::Zero) { throw 'The demo window did not appear.' }
    Start-Sleep -Seconds 6
    $r = New-Object Win+RECT
    [void][Win]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][Win]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save((Join-Path $OutDir "$File.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    "{0}.png  {1}x{2}" -f $File, $bmp.Width, $bmp.Height
    $bmp.Dispose()
    [void][Win]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    foreach ($i in 1..20) { Start-Sleep -Milliseconds 250; if ((Find) -eq [IntPtr]::Zero) { break } }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$demo*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    $left = Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq $title }
    if ($left) { [void]$left.CloseMainWindow(); Start-Sleep -Seconds 1 }
}

$env:SMSYNC_GAME_PROCESS = 'NoSuchGame_demo'; $env:SMSYNC_NO_TOAST = '1'; $env:SMSYNC_NO_LAUNCH = '1'; $env:SMSYNC_NO_CLIPBOARD = '1'
$server = Start-Process python -ArgumentList "`"$Repo\dev\test\fake_storage.py`"", $Port -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
try {
    # Scrapyard is a Survival world. Factory Island is a Custom game made with a made-up
    # Workshop mod, kept in Save\Custom. Test Track, on the new player's PC, is Creative.
    $bytes = New-Object byte[] (12MB)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("SQLite format 3`0"), $bytes, 16)
    $modId = '1234567890'
    $ws = "$demo\workshop"
    New-Item -ItemType Directory -Force -Path "$ws\$modId" | Out-Null
    '{"name": "Factory Tycoon", "type": "Custom Game"}' | Set-Content "$ws\$modId\description.json"
    $env:SMSYNC_WORKSHOP_ROOT = $ws
    foreach ($p in 'Alex', 'Sam') {
        $base = "$demo\saves-$p\User_76561190000000000\Save"
        New-Item -ItemType Directory -Force -Path "$demo\app-$p", "$demo\home-$p", "$base\Survival", "$base\Custom" | Out-Null
        Copy-Item "$Repo\sm-sync.ps1", "$Repo\CHANGES.txt" "$demo\app-$p\"
        $list = @(
            [ordered]@{ Endpoint = "http://127.0.0.1:$Port"; Bucket = 'scrap-mechanic'; AccessKeyId = ('a1' * 16); SecretAccessKey = ('b2' * 32); SaveName = 'Scrapyard'; Type = 'Survival'; SaveFolder = "$base\Survival" }
            [ordered]@{ Endpoint = "http://127.0.0.1:$Port"; Bucket = 'scrap-mechanic'; AccessKeyId = ('a1' * 16); SecretAccessKey = ('b2' * 32); SaveName = 'Factory Island'; Type = 'Custom'; SaveFolder = "$base\Custom" }
        )
        ConvertTo-Json -InputObject ([ordered]@{ Worlds = $list; LastWorld = 'Scrapyard' }) -Depth 4 | Set-Content "$demo\app-$p\sm-sync.config.json" -Encoding UTF8
    }
    $alexBase = "$demo\saves-Alex\User_76561190000000000\Save"
    [IO.File]::WriteAllBytes("$alexBase\Survival\Scrapyard.db", $bytes)
    & python -I "$Repo\dev\test\make_world.py" "$alexBase\Custom\Factory Island.db" 9 $modId
    $env:SMSYNC_SAVE_ROOT = "$demo\saves-Alex"
    foreach ($w in 'Scrapyard', 'Factory Island') { Run 'app-Alex' 'Alex' @('-Action', 'finish', '-World', $w, '-Yes') }
    $env:SMSYNC_SAVE_ROOT = "$demo\saves-Sam"
    Run 'app-Sam' 'Sam' @('-Action', 'play', '-NoLaunch', '-World', 'Scrapyard')
    Add-Content "$demo\saves-Sam\User_76561190000000000\Save\Survival\Scrapyard.db" 'progress'
    Run 'app-Sam' 'Sam' @('-Action', 'finish', '-World', 'Scrapyard', '-Note', 'Built the bridge. Fuel is in the red chest by the garage.')
    Run 'app-Sam' 'Sam' @('-Action', 'play', '-NoLaunch', '-World', 'Factory Island')
    Remove-Item Env:SMSYNC_SAVE_ROOT, Env:SMSYNC_WORKSHOP_ROOT

    # A copy with no settings, for the welcome screen and the setup. Its PC has one world of each type.
    $newBase = "$demo\saves-New\User_76561190000000000\Save"
    New-Item -ItemType Directory -Force -Path "$demo\app-New", "$demo\home-New", "$newBase\Survival", "$newBase\Custom" | Out-Null
    Copy-Item "$Repo\sm-sync.ps1" "$demo\app-New\"
    [IO.File]::WriteAllBytes("$newBase\Survival\Scrapyard.db", $bytes)
    [IO.File]::WriteAllBytes("$newBase\Custom\Factory Island.db", (New-Object byte[] (27MB)))
    [IO.File]::WriteAllBytes("$newBase\Test Track.db", (New-Object byte[] (4MB)))
    (Get-Item "$newBase\Custom\Factory Island.db").LastWriteTime = (Get-Date).AddDays(-1).AddHours(-3)
    (Get-Item "$newBase\Test Track.db").LastWriteTime = (Get-Date).AddDays(-9)

    Shot 'app-Alex' 'Alex' '-World Scrapyard' '' 'menu' 38
    Shot 'app-Alex' 'Alex' '' '' 'worlds' 24
    Shot 'app-New' 'New' '' '' 'welcome' 20
    Shot 'app-New' 'New' '' '2' 'setup-world' 22
    Shot 'app-New' 'New' '' '2,1,c,,c' 'setup-keys' 40
}
finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item Env:SMSYNC_HOME, Env:SMSYNC_PLAYER, Env:SMSYNC_GAME_PROCESS, Env:SMSYNC_NO_TOAST, Env:SMSYNC_NO_LAUNCH, Env:SMSYNC_NO_CLIPBOARD, Env:SMSYNC_SAVE_ROOT, Env:SMSYNC_WORKSHOP_ROOT -ErrorAction SilentlyContinue
}

