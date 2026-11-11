<#
End-to-end tests for sm-sync.ps1 with two players, A and B, against a local stand-in for
the storage and for GitHub. Nothing here touches the real bucket, the real save or the game.

    dev\test\run-tests.ps1            # summary only
    dev\test\run-tests.ps1 -ShowAll   # print every command's output

Player A runs on Windows PowerShell 5.1 (what the other player has) and player B on
PowerShell 7, so both are exercised. Needs python on PATH for the fake server.
Exit code 0 means every check passed.
#>
param([switch]$ShowAll, [int]$Port = 9391)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script = Join-Path $repo 'sm-sync.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) 'sm-sync-tests'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
$world = 'My World'
$failures = 0; $checks = 0

$env:SMSYNC_GAME_PROCESS = 'NoSuchGame_smtest'
$env:SMSYNC_NO_TOAST = '1'
$env:SMSYNC_WAIT_SECONDS = '1'

function Run([string]$Player, [string[]]$Arguments, $Stdin) {
    $shell = if ($Player -eq 'A') { 'powershell.exe' } else { 'pwsh.exe' }
    $env:SMSYNC_HOME = "$root\$Player\home"; $env:SMSYNC_PLAYER = $Player
    $file = "$root\$Player\app\sm-sync.ps1"
    if ($null -ne $Stdin) { $out = $Stdin | & $shell -NoProfile -ExecutionPolicy Bypass -File $file @Arguments 2>&1 }
    else { $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $file @Arguments 2>&1 }
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($ShowAll) { Write-Host "`n>>> $Player : $($Arguments -join ' ')  (exit $LASTEXITCODE)" -ForegroundColor Cyan; Write-Host $text }
    return $text
}
function Check([string]$Name, [bool]$Ok) {
    $script:checks++
    if ($Ok) { if ($ShowAll) { Write-Host "  pass  $Name" -ForegroundColor Green } }
    else { $script:failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}
function Has([string]$Text, [string]$Needle) { return $Text.Contains($Needle) }
function Touch([string]$Player, [string]$Line) { Add-Content "$root\$Player\save\$world.db" $Line }
function SaveHash([string]$Player) { return (Get-FileHash "$root\$Player\save\$world.db").Hash }
function Keys {
    $content = (Invoke-WebRequest "http://127.0.0.1:$Port/_keys" -UseBasicParsing).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

# A fake v9.9.9 release, laid out the way a GitHub zipball is (one top-level folder).
$release = Join-Path $root 'release\Valtora-sm-sync-abc123'
New-Item -ItemType Directory -Force -Path "$release\dev" | Out-Null
(Get-Content $script -Raw) -replace "script:Version        = '[\d.]+'", "script:Version        = '9.9.9'" | Set-Content "$release\sm-sync.ps1" -Encoding ASCII
Set-Content "$release\README.md" 'repo only'
Set-Content "$release\FRIEND-INSTRUCTIONS.txt" 'new instructions'
Set-Content "$release\dev\tool.ps1" 'repo only'
Compress-Archive -Path (Join-Path $root 'release\*') -DestinationPath "$root\release.zip"

$server = Start-Process python -ArgumentList "`"$PSScriptRoot\fake_storage.py`"", $Port, "`"$root\release.zip`"" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
try {
    foreach ($p in 'A', 'B') {
        New-Item -ItemType Directory -Force -Path "$root\$p\app", "$root\$p\save", "$root\$p\home" | Out-Null
        Copy-Item $script "$root\$p\app\"
        @{ Endpoint = "http://127.0.0.1:$Port"; Bucket = 'b'; AccessKeyId = 'k'; SecretAccessKey = 's'; SaveName = $world; SaveFolder = "$root\$p\save"
           GitHubRepo = 'o/r'; GitHubToken = 'good-token'; GitHubApi = "http://127.0.0.1:$Port" } | ConvertTo-Json | Set-Content "$root\$p\app\sm-sync.config.json"
    }
    # A's world: 3 MB that starts like a SQLite file. B has an unrelated old stub.
    $bytes = New-Object byte[] (3MB); (New-Object Random 1).NextBytes($bytes)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("SQLite format 3`0"), $bytes, 16)
    [IO.File]::WriteAllBytes("$root\A\save\$world.db", $bytes)
    [IO.File]::WriteAllBytes("$root\B\save\$world.db", [byte[]](1..50))
    (Get-Item "$root\B\save\$world.db").LastWriteTime = (Get-Date).AddDays(-2)

    Check 'signing self-test on 5.1' (Has (Run A '-Action', 'selftest') 'self-test passed')
    Check 'signing self-test on 7' (Has (Run B '-Action', 'selftest') 'self-test passed')

    $o = Run A '-Action', 'play', '-NoLaunch', '-Yes'
    Check 'first player seeds and checks out' ((Has $o 'uploaded and available') -and (Has $o 'now checked out to you'))
    Check 'second player is refused' (Has (Run B '-Action', 'play', '-NoLaunch') 'A has the world checked out')
    Check 'second player cannot upload' (Has (Run B '-Action', 'finish') 'cannot be uploaded')

    Touch A 'progress by A'
    $o = Run A '-Action', 'finish', '-Note', 'Built a bridge. Fuel is in the red chest.'
    Check 'upload with a note' ((Has $o 'uploaded and available') -and (Has $o 'Note saved'))
    Check 'uploads are stored compressed' ((Keys) -match 'v000002\.db\.gz')

    $o = Run B '-Action', 'play', '-NoLaunch'
    Check 'download, check, check-out' ((Has $o 'Downloaded and checked') -and (Has $o 'now checked out to you'))
    Check 'note shown to the next player' (Has $o 'Fuel is in the red chest')
    Check 'both PCs hold the same world' ((SaveHash A) -eq (SaveHash B))
    Check 'previous save was backed up first' (@(Get-ChildItem "$root\B\home\backups").Count -eq 1)
    Check 'original player is now refused' (Has (Run A '-Action', 'play', '-NoLaunch') 'B has the world checked out')
    Check 'waiting gives up while checked out' (Has (Run A '-Action', 'wait') 'Still checked out')
    Check 'unchanged world is not re-uploaded' (Has (Run B '-Action', 'finish') 'nothing to send')
    Check 'waiting reports available' (Has (Run A '-Action', 'wait') 'AVAILABLE')

    Touch B 'played without checking out'
    $o = Run B '-Action', 'finish', '-Yes'
    Check 'playing without check-out is flagged' ((Has $o 'did not check the world out') -and (Has $o 'uploaded and available'))

    foreach ($n in 4..7) { [void](Run A '-Action', 'play', '-NoLaunch'); Touch A "round $n"; [void](Run A '-Action', 'finish') }
    $o = Run A '-Action', 'status'
    Check 'online history keeps the last 5' (Has $o 'versions 7, 6, 5, 4, 3')
    $k = Keys
    Check 'older versions are deleted from storage' (($k -notmatch 'v000001') -and ($k -notmatch 'v000002') -and ($k -match 'v000003'))

    # The game crashed: a leftover journal means the file alone is not a consistent save.
    [void](Run A '-Action', 'play', '-NoLaunch'); Touch A 'crashy'
    Set-Content "$root\A\save\$world.db-journal" 'x'
    Check 'crashed-game save is not uploaded' (Has (Run A '-Action', 'finish') 'did not close cleanly')
    Remove-Item "$root\A\save\$world.db-journal"
    $good = [IO.File]::ReadAllBytes("$root\A\save\$world.db")
    [IO.File]::WriteAllBytes("$root\A\save\$world.db", [byte[]](1..50))
    Check 'damaged save is not uploaded' (Has (Run A '-Action', 'finish') 'does not look like a Scrap Mechanic world')
    [IO.File]::WriteAllBytes("$root\A\save\$world.db", $good)

    # A closed the window mid-game: the watchdog uploads once the "game" (a ping) exits.
    $env:SMSYNC_GAME_PROCESS = 'PING'
    $game = Start-Process ping.exe -ArgumentList '-n', '5', '127.0.0.1' -PassThru -WindowStyle Hidden
    [void](Run A '-Action', 'watchdog', '-ParentPid', '999999')
    $env:SMSYNC_GAME_PROCESS = 'NoSuchGame_smtest'
    $o = Run A '-Action', 'status'
    Check 'watchdog uploads after the window is closed' ((Has $o 'World:        available') -and (Has $o 'version 8'))

    $o = Run B '-Action', 'take'
    Check 'check-out after watchdog upload' (Has $o 'now checked out to you')
    $o = Run A '-Action', 'take'
    Check 'forced check-out warns about out of sync' (Has $o 'out of sync')

    # Two players in the same second: B read the state, A changes it, B's write must fail.
    [void](Run A '-Action', 'finish')
    $o = Run A '-Action', 'doctor'
    Check 'doctor confirms conditional writes' (Has $o 'honours conditional writes')

    $o = Run A '-NoUpdate' @('h', 'r', '3', '', 'w', 'q')
    Check 'menu, help and restore list render on 5.1' ((Has $o 'PLAYING TOGETHER') -and (Has $o 'Pick the copy to bring back') -and (Has $o 'by Valtorra'))

    $o = Run A '-Action', 'update'
    $app = "$root\A\app"
    Check 'self-update installs the newer tag' ((Has $o 'v9.9.9') -and ((Get-Content "$app\sm-sync.ps1" -Raw) -match "Version        = '9\.9\.9'"))
    Check 'self-update copies player files only' ((Test-Path "$app\FRIEND-INSTRUCTIONS.txt") -and -not (Test-Path "$app\README.md") -and -not (Test-Path "$app\dev"))
    Check 'menu launch updates and relaunches' (Has (Run B @() @('q')) 'Updated from v')

    Stop-Process -Id $server.Id -Force
    $o = Run B '-Action', 'status'
    Check 'offline is retried and explained' ((Has $o 'Trying again (3 of 3)') -and (Has $o 'Could not reach the online storage'))
}
finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item Env:SMSYNC_HOME, Env:SMSYNC_PLAYER, Env:SMSYNC_GAME_PROCESS, Env:SMSYNC_NO_TOAST, Env:SMSYNC_WAIT_SECONDS -ErrorAction SilentlyContinue
}
Write-Host ''
if ($failures) { Write-Host "$failures of $checks checks FAILED. Re-run with -ShowAll to see the output." -ForegroundColor Red; exit 1 }
Write-Host "All $checks checks passed." -ForegroundColor Green
