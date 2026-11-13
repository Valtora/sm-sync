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
$env:SMSYNC_NO_CLIPBOARD = '1'
$env:SMSYNC_NO_LAUNCH = '1'
$env:SMSYNC_STEAM_ID = '76561190000000001'

function Run([string]$Player, [string[]]$Arguments, $Stdin) {
    $shell = if ($Player -in 'A', 'H') { 'powershell.exe' } else { 'pwsh.exe' }
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
("9.9.9`n- Test change line.`n`n" + (Get-Content (Join-Path $repo 'CHANGES.txt') -Raw)) | Set-Content "$release\CHANGES.txt" -Encoding ASCII
Compress-Archive -Path (Join-Path $root 'release\*') -DestinationPath "$root\release.zip"

$server = Start-Process python -ArgumentList "`"$PSScriptRoot\fake_storage.py`"", $Port, "`"$root\release.zip`"" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
try {
    foreach ($p in 'A', 'B') {
        New-Item -ItemType Directory -Force -Path "$root\$p\app", "$root\$p\save", "$root\$p\home" | Out-Null
        Copy-Item $script "$root\$p\app\"
        $settings = @{ Endpoint = "http://127.0.0.1:$Port"; Bucket = 'b'; AccessKeyId = 'k'; SecretAccessKey = 's'; SaveName = $world; SaveFolder = "$root\$p\save"
            GitHubApi = "http://127.0.0.1:$Port" }
        # A has a new settings file with no update key. B still carries one GitHub now rejects.
        if ($p -eq 'B') { $settings.GitHubRepo = 'o/r'; $settings.GitHubToken = 'expired-token' }
        $settings | ConvertTo-Json | Set-Content "$root\$p\app\sm-sync.config.json"
    }
    # A's world: 3 MB that starts like a SQLite file. B has an unrelated old stub.
    $bytes = New-Object byte[] (3MB); (New-Object Random 1).NextBytes($bytes)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes("SQLite format 3`0"), $bytes, 16)
    [IO.File]::WriteAllBytes("$root\A\save\$world.db", $bytes)
    [IO.File]::WriteAllBytes("$root\B\save\$world.db", [byte[]](1..50))
    (Get-Item "$root\B\save\$world.db").LastWriteTime = (Get-Date).AddDays(-2)

    $current = [regex]::Match((Get-Content $script -Raw), "script:Version        = '([\d.]+)'").Groups[1].Value
    Check "CHANGES.txt has an entry for $current" ((Get-Content (Join-Path $repo 'CHANGES.txt')) -contains $current)
    Check 'signing self-test on 5.1' (Has (Run A '-Action', 'selftest') 'self-test passed')
    Check 'signing self-test on 7' (Has (Run B '-Action', 'selftest') 'self-test passed')

    $o = Run A '-Action', 'play', '-NoLaunch', '-Yes'
    Check 'first player seeds and checks out' ((Has $o 'uploaded and available') -and (Has $o 'now checked out to you'))
    Check 'second player is refused' (Has (Run B '-Action', 'play', '-NoLaunch') 'A has the world checked out')
    Check 'second player cannot upload' (Has (Run B '-Action', 'finish') 'cannot be uploaded')

    Touch A 'progress by A'
    $o = Run A '-Action', 'finish', '-Note', 'Built a bridge. Fuel is in the red chest.'
    Check 'upload with a note' ((Has $o 'uploaded and available') -and (Has $o 'Message saved'))
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

    Check 'doctor can list the stored objects' (Has $o 'objects for this world')

    # A leftover object from a failed upload is removed by the next successful one.
    Invoke-WebRequest "http://127.0.0.1:$Port/b/My_World/v000001.db.gz" -Method Put -Body 'junk' -UseBasicParsing `
        -Headers @{ Authorization = 'AWS4-HMAC-SHA256 test'; 'x-amz-date' = 'test' } | Out-Null
    Check 'leftover object is in storage' ((Keys) -match 'v000001')
    [void](Run A '-Action', 'play', '-NoLaunch'); Touch A 'after the leftover'; [void](Run A '-Action', 'finish')
    Check 'leftover objects are cleaned up' ((Keys) -notmatch 'v000001')

    # A new, much smaller world under the same name must not replace the shared one unasked.
    [void](Run A '-Action', 'play', '-NoLaunch')
    $good = [IO.File]::ReadAllBytes("$root\A\save\$world.db")
    $small = New-Object byte[] (1MB); [Array]::Copy($good, $small, 16)
    [IO.File]::WriteAllBytes("$root\A\save\$world.db", $small)
    Check 'a much smaller world is not uploaded unasked' (Has (Run A @('-Action', 'finish') @('n')) 'much smaller than the shared world')
    [IO.File]::WriteAllBytes("$root\A\save\$world.db", $good)
    [void](Run A '-Action', 'finish')

    # A save from a newer game build warns the player whose game is older.
    $env:SMSYNC_GAME_BUILD = '200'
    [void](Run A '-Action', 'play', '-NoLaunch'); Touch A 'made on a newer game'; [void](Run A '-Action', 'finish')
    $env:SMSYNC_GAME_BUILD = '100'
    Check 'older game is warned about a newer save' (Has (Run B @('-Action', 'play', '-NoLaunch') @('n')) 'NEWER version of Scrap Mechanic')
    Remove-Item Env:SMSYNC_GAME_BUILD

    # Two players press Play at the same moment. A reads the state, pauses, and B gets in
    # first. A's write must then be refused, not overwrite B's check-out.
    $env:SMSYNC_HOME = "$root\A\home"; $env:SMSYNC_PLAYER = 'A'; $env:SMSYNC_TEST_CHECKOUT_DELAY = '6'
    # pwsh here: Windows PowerShell started this way inherits PowerShell 7's module path and cannot load its own modules.
    $slow = Start-Process pwsh.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput "$root\slow.txt" -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\A\app\sm-sync.ps1`"", '-Action', 'play', '-NoLaunch')
    Remove-Item Env:SMSYNC_TEST_CHECKOUT_DELAY
    Start-Sleep -Seconds 2
    $o = Run B '-Action', 'play', '-NoLaunch', '-Yes'
    $slow.WaitForExit()
    Check 'simultaneous check-out: the first writer wins' (Has $o 'now checked out to you')
    Check 'simultaneous check-out: the second is refused' (Has (Get-Content "$root\slow.txt" -Raw) 'a moment before you')
    Check 'simultaneous check-out: the state names the winner' (Has (Run A '-Action', 'status') 'checked out by B')
    # While B has the world, A is told B is probably playing and offered to join as a guest.
    $o = Run A '-NoUpdate' @('j', 'q')
    Check 'the other player is offered to join' ((Has $o 'is probably playing right now') -and (Has $o 'Join B in their game'))
    Check 'joining connects to the holder by Steam ID' (Has $o 'Steam ID 76561190000000001')
    Check 'joining starts no check-out' ((Has $o 'WITHOUT checking the world out') -and (Has (Run A '-Action', 'status') 'checked out by B'))
    [void](Run B '-Action', 'finish')

    $o = Run A '-NoUpdate' @('h', 'r', '3', '', 'a', 'd', 'w', 'q')
    Check 'menu, help and restore list render on 5.1' ((Has $o 'PLAYING TOGETHER') -and (Has $o 'Pick the copy to bring back') -and (Has $o 'by Valtora'))
    Check 'activity screen lists sessions' ((Has $o 'The last sessions') -and (Has $o 'Fuel is in the red chest'))
    Check 'diagnostics screen runs the checks' (Has $o 'honours conditional writes')

    # Report issue: the report must carry nothing that identifies the player.
    $env:SMSYNC_REPORT_FILE = "$root\report.txt"
    $o = Run A '-NoUpdate' @('i', 'y', 'q')
    Remove-Item Env:SMSYNC_REPORT_FILE
    $report = Get-Content "$root\report.txt" -Raw
    Check 'report issue opens the filled-in issue form' ((Has $o 'Would open https://github.com/Valtora/sm-sync/issues/new?template=bug_report.yml') -and (Has $o 'WHAT THE ISSUE WILL CONTAIN'))
    Check 'report has the check results and the log' ((Has $report 'honours conditional writes') -and (Has $report 'Last log lines:'))
    Check 'report hides the Windows user, the world and Steam IDs' (($report -notmatch [regex]::Escape($env:USERNAME)) -and -not (Has $report $world) -and -not (Has $report 'My_World') -and ($report -notmatch '7656\d{13}') -and (Has $report '<user>') -and (Has $report '<world>'))

    # First run with no settings file: a host goes through the setup on Windows PowerShell 5.1.
    $wizWorld = 'Wizard World'
    foreach ($p in 'H', 'G') {
        New-Item -ItemType Directory -Force -Path "$root\$p\app", "$root\$p\home", "$root\$p\saves\User_76561190000000002\Save\Survival" | Out-Null
        Copy-Item $script "$root\$p\app\"
    }
    $wizSave = "$root\H\saves\User_76561190000000002\Save\Survival\$wizWorld.db"
    [IO.File]::WriteAllBytes($wizSave, $bytes)
    $env:SMSYNC_SAVE_ROOT = "$root\H\saves"
    $o = Run H '-NoUpdate' @('2', '1', 'c', '', 'c', "http://127.0.0.1:$Port/scrap-mechanic", 'k', 's', 'y', 'q')
    $hostConfig = Get-Content "$root\H\app\sm-sync.config.json" -Raw | ConvertFrom-Json
    Check 'setup: a host is walked through all five steps' ((Has $o 'SETUP 1 OF 5') -and (Has $o 'SETUP 4 OF 5') -and (Has $o 'The storage accepted the keys') -and (Has $o 'SETUP 5 OF 5'))
    Check 'setup: writes the settings file' (($hostConfig.SaveName -eq $wizWorld) -and ($hostConfig.Bucket -eq 'scrap-mechanic') -and ($hostConfig.Endpoint -eq "http://127.0.0.1:$Port"))
    Check 'setup: uploads the world as the starting point' ((Has $o 'uploaded and available') -and ((Keys) -match 'Wizard_World/v000001'))
    $code = [regex]::Match(($o -replace '\s', ''), 'SMSYNC1:[A-Za-z0-9_-]+:[0-9a-f]{6}').Value
    Check 'setup: ends with an invite code' ($code.Length -gt 40)
    Check 'the menu shows the invite again' (Has (Run H '-NoUpdate' @('f', 'q')) 'Anyone who has this code')

    # A friend joins with that code, wrapped the way a chat app would wrap it.
    $env:SMSYNC_SAVE_ROOT = "$root\G\saves"
    $o = Run G '-NoUpdate' @('1', 'SMSYNC1:AAAA:000000', '', 'q')
    Check 'setup: a wrong invite code is refused' ((Has $o 'not a complete invite code') -and -not (Test-Path "$root\G\app\sm-sync.config.json"))
    $o = Run G '-NoUpdate' @('1', ("here you go " + $code.Substring(0, 30) + ' ' + $code.Substring(30)), 'q')
    Check 'setup: a friend joins with the invite code' ((Has $o "The shared world is '$wizWorld'") -and (Has $o 'The settings are saved'))
    $o = Run G '-Action', 'play', '-NoLaunch'
    Check 'setup: the friend gets the host''s world' ((Has $o 'now checked out to you') -and ((Get-FileHash "$root\G\saves\User_76561190000000002\Save\Survival\$wizWorld.db").Hash -eq (Get-FileHash $wizSave).Hash))
    Remove-Item Env:SMSYNC_SAVE_ROOT

    $o = Run A '-Action', 'update'
    $app = "$root\A\app"
    Check 'self-update installs the newer tag' ((Has $o 'v9.9.9') -and ((Get-Content "$app\sm-sync.ps1" -Raw) -match "Version        = '9\.9\.9'"))
    Check 'self-update copies player files only' ((Test-Path "$app\FRIEND-INSTRUCTIONS.txt") -and -not (Test-Path "$app\README.md") -and -not (Test-Path "$app\dev"))
    $o = Run B @() @('q')
    Check 'menu launch updates, relaunches and shows what is new' ((Has $o 'WHAT IS NEW') -and (Has $o 'Test change line') -and (Has $o 'v9.9.9'))
    Check 'what is new stops at the version already installed' (-not (Has $o 'Leave a message about your save'))
    Check 'a rejected update key is dropped, not fatal' (Has (Get-Content "$root\B\home\sm-sync.log" -Raw) 'the update key was rejected, carrying on without it')

    Stop-Process -Id $server.Id -Force
    $o = Run B '-Action', 'status'
    Check 'offline is retried and explained' ((Has $o 'Trying again (3 of 3)') -and (Has $o 'Could not reach the online storage'))
}
finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-Item Env:SMSYNC_HOME, Env:SMSYNC_PLAYER, Env:SMSYNC_GAME_PROCESS, Env:SMSYNC_NO_TOAST, Env:SMSYNC_WAIT_SECONDS, Env:SMSYNC_NO_CLIPBOARD, Env:SMSYNC_NO_LAUNCH, Env:SMSYNC_STEAM_ID, Env:SMSYNC_GAME_BUILD, Env:SMSYNC_TEST_CHECKOUT_DELAY, Env:SMSYNC_SAVE_ROOT, Env:SMSYNC_REPORT_FILE -ErrorAction SilentlyContinue
}
Write-Host ''
if ($failures) { Write-Host "$failures of $checks checks FAILED. Re-run with -ShowAll to see the output." -ForegroundColor Red; exit 1 }
Write-Host "All $checks checks passed." -ForegroundColor Green
