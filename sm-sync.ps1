<#
sm-sync.ps1 - share Scrap Mechanic worlds (Survival, Creative or Custom) between players,
one at a time.

The save lives in a Cloudflare R2 bucket as numbered versions, next to a state file that
records who has the world checked out. Only that player may play and upload.

Runs on Windows PowerShell 5.1 and PowerShell 7.
KEEP THIS FILE ASCII ONLY: Windows PowerShell 5.1 misreads UTF-8 without a BOM. Box and
block characters are built at runtime from their code points.

Normal use is the menu (double-click "Scrap Mechanic Sync.cmd"). The first run is a setup
that either takes an invite code from a friend or walks through creating the storage.
Without the menu:  sm-sync.ps1 -Action play|finish|status|take|update|selftest|setup
#>
[CmdletBinding()]
param(
    [ValidateSet('menu', 'play', 'finish', 'status', 'take', 'update', 'selftest', 'wait', 'watchdog', 'doctor', 'setup')]
    [string]$Action = 'menu',
    [switch]$NoLaunch,     # play: check out and download, but do not start the game
    [switch]$Force,        # play/finish: override the other player's check-out
    [switch]$Yes,          # answer yes to every confirmation
    [switch]$Plain,        # no colours, boxes or progress bars
    [switch]$NoUpdate,     # never check for updates, at launch or while the menu is open
    [string]$UpdatedFrom,  # set by the updater when it relaunches the new version
    [string]$Note,         # finish: the session note, instead of asking for one
    [int]$ParentPid,       # watchdog: the menu window that started it
    [string]$World         # the save name of the world to act on, when more than one is set up
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell started from a PowerShell 7 window inherits its module path and then
# cannot load its own modules (Get-FileHash, Expand-Archive). Put the standard path back.
if ($PSVersionTable.PSEdition -ne 'Core') {
    $env:PSModulePath = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules')
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')
    ) -join ';'
}

# Bump Version for every release and tag the commit v<Version>.
# Bump MinPeerVersion only when older copies must not touch the shared state any more.
$script:Version        = '0.4.0'
$script:MinPeerVersion = '0.4.0'

# Where updates come from and where issues go. "GitHubRepo" in the settings file overrides it.
$script:DefaultRepo  = 'Valtora/sm-sync'
$script:InvitePrefix = 'SMSYNC1'

$script:SteamAppId   = '387990'
$script:GameProcess  = 'ScrapMechanic'
if ($env:SMSYNC_GAME_PROCESS) { $script:GameProcess = $env:SMSYNC_GAME_PROCESS }   # tests only
$script:KeepOnline   = 5
$script:AssumeYes    = [bool]$Yes
$script:EmptyHash    = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$script:Notice       = ''
$script:ProgressOpen = $false

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$script:HomeDir = $env:SMSYNC_HOME
if (-not $script:HomeDir) { $script:HomeDir = Join-Path $env:LOCALAPPDATA 'SMSync' }
$script:BackupRoot = Join-Path $script:HomeDir 'backups'
$script:BackupDir = $script:BackupRoot
$script:LogPath = Join-Path $script:HomeDir 'sm-sync.log'
[void](New-Item -ItemType Directory -Force -Path $script:BackupDir)

# ================================================================ console

# The watchdog runs hidden with nobody to answer a question, so it never asks one.
$script:Unattended = ($Action -eq 'watchdog')
$script:Interactive = (-not [Console]::IsInputRedirected) -and (-not $script:Unattended)
$script:Fancy = (-not $Plain) -and (-not $script:Unattended) -and $Host.UI.SupportsVirtualTerminal -and ((-not [Console]::IsOutputRedirected) -or $env:SMSYNC_FORCE_FANCY)
$script:E = [string][char]27
$script:W = 72

$script:Rgb = @{
    Orange = '255;138;0'; Amber = '255;200;60'; Text = '236;236;236'; Dim = '125;125;125'
    Good = '120;220;140'; Bad = '255;95;90'; Bg = '12;12;12'
    G0 = '255;210;70'; G1 = '255;185;45'; G2 = '255;160;20'; G3 = '255;138;0'; G4 = '225;105;0'
}
$script:Basic = @{
    Orange = 'DarkYellow'; Amber = 'Yellow'; Text = 'Gray'; Dim = 'DarkGray'; Good = 'Green'; Bad = 'Red'
    G0 = 'Yellow'; G1 = 'Yellow'; G2 = 'DarkYellow'; G3 = 'DarkYellow'; G4 = 'DarkYellow'
}
if ($script:Fancy) {
    $script:Ch = @{ TL = [string][char]0x250C; TR = [string][char]0x2510; BL = [string][char]0x2514; BR = [string][char]0x2518
        H = [string][char]0x2500; V = [string][char]0x2502; Block = [string][char]0x2588; Shade = [string][char]0x2591 }
}
else {
    $script:Ch = @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; Block = '#'; Shade = '.' }
}

function Write-Seg([object[]]$Parts, [switch]$NoNewline) {
    # $Parts is text, colour, text, colour ...
    if ($script:Fancy) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("$($script:E)[48;2;$($script:Rgb.Bg)m")
        for ($i = 0; $i -lt $Parts.Count; $i += 2) {
            if ($Parts[$i + 1] -eq 'Sel') {
                # The selected menu row: black on orange, then back to the normal background.
                [void]$sb.Append("$($script:E)[48;2;$($script:Rgb.Orange)m$($script:E)[38;2;0;0;0m").Append([string]$Parts[$i]).Append("$($script:E)[48;2;$($script:Rgb.Bg)m")
            }
            else { [void]$sb.Append("$($script:E)[38;2;$($script:Rgb[$Parts[$i + 1]])m").Append([string]$Parts[$i]) }
        }
        [void]$sb.Append("$($script:E)[K")
        Write-Host $sb.ToString() -NoNewline:$NoNewline
    }
    else {
        for ($i = 0; $i -lt $Parts.Count; $i += 2) {
            if ($Parts[$i + 1] -eq 'Sel') { Write-Host ([string]$Parts[$i]) -NoNewline -ForegroundColor Black -BackgroundColor DarkYellow }
            else { Write-Host ([string]$Parts[$i]) -NoNewline -ForegroundColor $script:Basic[$Parts[$i + 1]] }
        }
        if (-not $NoNewline) { Write-Host '' }
    }
}

function Say([string]$Text = '', [string]$Color = 'Text') { Write-Seg @($Text, $Color) }
# Each status line is preceded by a blank line so a screen of them stays readable.
# While $script:Transcript is a list, they are also recorded for the diagnostics report.
function Add-Transcript([string]$Line) { if ($null -ne $script:Transcript) { $script:Transcript.Add($Line) } }
function Say-Step([string]$Text) { Add-Transcript "..  $Text"; Say ''; Write-Seg @('  >   ', 'Orange', $Text, 'Text') }
function Say-Good([string]$Text) { Add-Transcript "OK  $Text"; Say ''; Write-Seg @('  OK  ', 'Good', $Text, 'Text') }
function Say-Warn([string]$Text) { Add-Transcript "!!  $Text"; Say ''; Write-Seg @('  !!  ', 'Amber', $Text, 'Amber') }
function Say-Bad([string]$Text)  { Add-Transcript "XX  $Text"; Say ''; Write-Seg @('  XX  ', 'Bad', $Text, 'Bad') }

function Split-Wrap([string]$Text, [int]$Width) {
    $lines = @(); $current = ''
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if ($current -and ($current.Length + $word.Length + 1) -gt $Width) { $lines += $current; $current = $word }
        elseif ($current) { $current = "$current $word" }
        else { $current = $word }
    }
    if ($current) { $lines += $current }
    return , $lines
}

function Say-Wrapped([string]$Label, [string]$LabelColor, [string]$Text, [string]$TextColor = 'Text') {
    $indent = ' ' * $Label.Length
    $first = $true
    foreach ($line in (Split-Wrap $Text ($script:W - $Label.Length))) {
        if ($first) { Write-Seg @($Label, $LabelColor, $line, $TextColor); $first = $false }
        else { Write-Seg @($indent, 'Text', $line, $TextColor) }
    }
}

function Clear-Screen {
    # Every screen starts here, so a resized window gets boxes of the new width.
    Update-Width
    if ($script:Fancy) { Write-Host "$($script:E)[48;2;$($script:Rgb.Bg)m$($script:E)[2J$($script:E)[3J$($script:E)[H" -NoNewline }
    else { Say ''; Say ('=' * 60) 'Dim' }
}

function Reset-Console {
    if ($script:Fancy) { Write-Host "$($script:E)[?25h$($script:E)[0m$($script:E)[2J$($script:E)[H" -NoNewline }
}

function Get-ConsoleWidth { try { return [Console]::WindowWidth } catch { return 100 } }
function Get-ConsoleHeight { if ($env:SMSYNC_HEIGHT) { return [int]$env:SMSYNC_HEIGHT }; if ([Console]::IsOutputRedirected) { return 60 }; try { return [Console]::WindowHeight } catch { return 60 } }

function Update-Width {
    # The width of boxes and wrapped text: the window's width less its margins, from 72 up
    # to 112, which fills Windows Terminal's default of 120 columns. Output that is not a
    # window keeps 72, so what the tests read does not depend on the console they run in.
    $script:W = 72
    if ($script:Fancy -and -not [Console]::IsOutputRedirected) { $script:W = [Math]::Max(72, [Math]::Min(112, (Get-ConsoleWidth) - 8)) }
}

function Request-ConsoleSize([int]$Columns, [int]$Rows) {
    # Grows a classic console window so the whole menu fits. Windows Terminal ignores this;
    # there the launcher asks for the size when it opens the window.
    if ($env:WT_SESSION -or -not $script:Interactive -or -not $script:Fancy) { return }
    try {
        $raw = $Host.UI.RawUI
        $max = $raw.MaxPhysicalWindowSize
        $c = [Math]::Min($Columns, $max.Width); $r = [Math]::Min($Rows, $max.Height)
        $buffer = $raw.BufferSize
        if ($buffer.Width -lt $c) { $buffer.Width = $c }
        if ($buffer.Height -lt $r) { $buffer.Height = $r }
        $raw.BufferSize = $buffer
        $window = $raw.WindowSize
        if ($window.Width -lt $c) { $window.Width = $c }
        if ($window.Height -lt $r) { $window.Height = $r }
        $raw.WindowSize = $window
    }
    catch { }
}

function Write-BoxTop([string]$Title) {
    $t = " $Title "
    Write-Seg @(('  ' + $script:Ch.TL + $script:Ch.H), 'Dim', $t, 'Orange', (($script:Ch.H * ($script:W - 1 - $t.Length)) + $script:Ch.TR), 'Dim')
}
function Write-BoxRow([object[]]$Parts) {
    $len = 0
    for ($i = 0; $i -lt $Parts.Count; $i += 2) { $len += ([string]$Parts[$i]).Length }
    $pad = [Math]::Max(0, $script:W - 2 - $len)
    Write-Seg (@(('  ' + $script:Ch.V + ' '), 'Dim') + $Parts + @(((' ' * $pad) + ' ' + $script:Ch.V), 'Dim'))
}
function Write-BoxBottom { Write-Seg @(('  ' + $script:Ch.BL + ($script:Ch.H * $script:W) + $script:Ch.BR), 'Dim') }

$script:Font = @{
    'S' = @(' ###', '#   ', ' ## ', '   #', '### ')
    'C' = @(' ###', '#   ', '#   ', '#   ', ' ###')
    'R' = @('### ', '#  #', '### ', '# # ', '#  #')
    'A' = @(' ## ', '#  #', '####', '#  #', '#  #')
    'P' = @('### ', '#  #', '### ', '#   ', '#   ')
    'M' = @('#   #', '## ##', '# # #', '#   #', '#   #')
    'E' = @('####', '#   ', '### ', '#   ', '####')
    'H' = @('#  #', '#  #', '####', '#  #', '#  #')
    'N' = @('#   #', '##  #', '# # #', '#  ##', '#   #')
    'I' = @('###', ' # ', ' # ', ' # ', '###')
    ' ' = @('  ', '  ', '  ', '  ', '  ')
}

function Show-Banner([switch]$Small) {
    Say ''
    if ($script:Fancy -and -not $Small -and (Get-ConsoleWidth) -ge 76) {
        for ($row = 0; $row -lt 5; $row++) {
            $line = '  '
            foreach ($letter in 'SCRAP MECHANIC'.ToCharArray()) { $line += $script:Font[[string]$letter][$row] + ' ' }
            Say ($line.Replace('#', $script:Ch.Block)) "G$row"
        }
    }
    else { Say '  SCRAP MECHANIC' 'Orange' }
    $label = ''; $world = ''
    if ($script:Config -and $script:Config.SaveName) { $label = '     world '; $world = [string]$script:Config.SaveName }
    Say ''
    Write-Seg @('  S A V E   S Y N C', 'Amber', $label, 'Dim', $world, 'Text', '     v', 'Dim', $script:Version, 'Dim', '     by ', 'Dim', 'Valtora', 'Orange')
    Say ''
}

function Show-Header([string]$Title) {
    Clear-Screen
    Say ''
    Write-Seg @("  $($script:Ch.Block)$($script:Ch.Block) ", 'Orange', $Title.ToUpperInvariant(), 'Amber')
    Say ('  ' + ($script:Ch.H * ($script:W + 2))) 'Dim'
    Say ''
}

# Demos and screenshots only: SMSYNC_KEYS is a comma-separated list of answers that are
# used up, in order, before the keyboard is read. "esc" and "enter" stand for those keys.
$script:FedKeys = New-Object 'System.Collections.Generic.Queue[string]'
if ($env:SMSYNC_KEYS) { foreach ($k in ($env:SMSYNC_KEYS -split ',')) { $script:FedKeys.Enqueue($k) } }

function Read-Key([string]$Valid, [switch]$Esc, [switch]$Enter) {
    # Waits for one of the characters in $Valid. With -Esc the Esc key returns 'ESC', and
    # with -Enter the Enter key returns 'ENTER'. Without a keyboard it reads lines instead:
    # the first letter of a line, the word esc, or an empty line for Enter.
    while ($true) {
        if ($script:FedKeys.Count -gt 0) {
            $c = $script:FedKeys.Dequeue().ToUpperInvariant()
            if ($c -eq 'ESC' -or $c -eq 'ENTER') { return $c }
        }
        elseif ($script:Interactive) {
            $key = [Console]::ReadKey($true)
            if ($Esc -and $key.Key -eq [ConsoleKey]::Escape) { return 'ESC' }
            if ($Enter -and $key.Key -eq [ConsoleKey]::Enter) { return 'ENTER' }
            $c = ([string]$key.KeyChar).ToUpperInvariant()
        }
        else {
            $line = [Console]::ReadLine()
            if ($null -eq $line) { if ($Esc) { return 'ESC' }; return 'Q' }
            $line = $line.Trim()
            if ($Esc -and $line -eq 'esc') { return 'ESC' }
            if (-not $line) { if ($Enter) { return 'ENTER' }; continue }
            $c = $line.Substring(0, 1).ToUpperInvariant()
        }
        if ($c.Length -eq 1 -and $Valid.Contains($c)) { return $c }
    }
}

function Read-Line([string]$Prompt) {
    Write-Seg @("  $Prompt ", 'Amber', '', 'Text') -NoNewline
    $line = [Console]::ReadLine()
    if ($null -eq $line) { return '' }
    return $line.Trim()
}

function Get-ClipboardText {
    if ($env:SMSYNC_NO_CLIPBOARD) { return '' }
    try { return [string](Get-Clipboard -Raw) } catch { return '' }
}

function Read-Text([string]$Prompt, [switch]$Mask) {
    # Like Read-Line, but with no length limit (Console.ReadLine stops at 254 characters on
    # Windows PowerShell, shorter than an invite code) and with -Mask to show stars.
    # Returns $null when the player presses Esc, so every prompt can be left.
    if ($script:FedKeys.Count -gt 0) {
        $fed = $script:FedKeys.Dequeue()
        Write-Seg @("  $Prompt ", 'Amber', $fed, 'Text')
        if ($fed -eq 'esc') { return $null }
        return $fed.Trim()
    }
    if (-not $script:Interactive) {
        Write-Seg @("  $Prompt ", 'Amber', '', 'Text') -NoNewline
        $line = [Console]::ReadLine()
        Write-Host ''
        if ($null -eq $line -or $line.Trim() -eq 'esc') { return $null }
        return $line.Trim()
    }
    Write-Seg @("  $Prompt ", 'Amber', '', 'Text') -NoNewline
    $typed = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) { break }
        if ($key.Key -eq [ConsoleKey]::Escape) { Write-Host ''; return $null }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($typed.Length -gt 0) { [void]$typed.Remove($typed.Length - 1, 1); Write-Host "`b `b" -NoNewline }
            continue
        }
        $chunk = ''
        # The classic console hands Ctrl+V to the program instead of pasting.
        if ($key.Key -eq [ConsoleKey]::V -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { $chunk = (Get-ClipboardText) -replace '[\r\n]+', '' }
        elseif (-not [char]::IsControl($key.KeyChar)) { $chunk = [string]$key.KeyChar }
        if ($chunk) {
            [void]$typed.Append($chunk)
            if ($Mask) { Write-Host ('*' * $chunk.Length) -NoNewline } else { Write-Host $chunk -NoNewline }
        }
    }
    Write-Host ''
    return $typed.ToString().Trim()
}

function Open-Link([string]$Url) {
    # Opens a web page in the default browser. Tests set SMSYNC_NO_LAUNCH.
    if ($env:SMSYNC_NO_LAUNCH) { Say-Step ("Would open " + $Url.Substring(0, [Math]::Min(90, $Url.Length))); return }
    try { Start-Process $Url } catch { Say-Warn "The browser could not be opened. The address is: $Url" }
}

function Wait-Key([string]$Text = 'Press any key to go back to the menu') {
    if (-not $script:Interactive) { return }
    Say ''
    Say "  $Text" 'Dim'
    [void][Console]::ReadKey($true)
}

function Confirm-Yes([string]$Question) {
    if ($script:AssumeYes) { return $true }
    if ($script:Unattended) { return $false }
    Say ''
    Write-Seg @("  $Question ", 'Amber', '[Y] yes   [N] no', 'Dim')
    return ((Read-Key 'YN') -eq 'Y')
}

function Read-LineTimeout([string]$Prompt, [int]$Seconds) {
    # Like Read-Line, but gives up after $Seconds without a keypress and returns what was typed.
    if (-not $script:Interactive) { return '' }
    Write-Seg @("  $Prompt ", 'Amber', '', 'Text') -NoNewline
    $typed = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 50; continue }
        $key = [Console]::ReadKey($true)
        $deadline = (Get-Date).AddSeconds($Seconds)
        if ($key.Key -eq [ConsoleKey]::Enter) { break }
        if ($key.Key -eq [ConsoleKey]::Escape) { [void]$typed.Clear(); break }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($typed.Length -gt 0) { [void]$typed.Remove($typed.Length - 1, 1); Write-Host "`b `b" -NoNewline }
            continue
        }
        if (-not [char]::IsControl($key.KeyChar) -and $typed.Length -lt 200) { [void]$typed.Append($key.KeyChar); Write-Host $key.KeyChar -NoNewline }
    }
    Write-Host ''
    return $typed.ToString().Trim()
}

function Show-Toast([string]$Title, [string]$Text) {
    # A Windows notification. Best effort: a failure here must never break a sync.
    if ($env:SMSYNC_NO_TOAST) { Write-Log "toast: $Text"; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        if (-not $script:Tray) {
            $script:Tray = New-Object System.Windows.Forms.NotifyIcon
            $script:Tray.Icon = [System.Drawing.SystemIcons]::Information
            $script:Tray.Text = 'Scrap Mechanic Sync'
            $script:Tray.Visible = $true
        }
        $script:Tray.ShowBalloonTip(10000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    }
    catch { Write-Log "toast failed: $($_.Exception.Message)" }
}

function Show-Progress([string]$Label, [long]$Done, [long]$Total, [datetime]$Start, [switch]$Final) {
    if (-not $script:Fancy) { return }
    if (-not $script:ProgressOpen) { Say '' }
    $fraction = 0.0
    if ($Total -gt 0) { $fraction = [Math]::Min(1.0, $Done / $Total) }
    if ($Final) { $fraction = 1.0; $Done = $Total }
    $width = 30
    $filled = [int][Math]::Floor($fraction * $width)
    $seconds = [Math]::Max(0.05, ((Get-Date) - $Start).TotalSeconds)
    if ($Final) { $tail = '{0,4:N0}%  {1:N1} MB in {2:N0}s          ' -f 100, ($Total / 1MB), $seconds }
    else { $tail = '{0,4:N0}%  {1:N1} / {2:N1} MB  {3:N1} MB/s   ' -f ($fraction * 100), ($Done / 1MB), ($Total / 1MB), ($Done / 1MB / $seconds) }
    Write-Host "`r$($script:E)[?25l" -NoNewline
    Write-Seg @(('  ' + $Label.PadRight(13)), 'Text', ($script:Ch.Block * $filled), 'Orange', ($script:Ch.Shade * ($width - $filled)), 'Dim', $tail, 'Text') -NoNewline
    $script:ProgressOpen = $true
    if ($Final) { Close-Progress }
}

function Close-Progress {
    if ($script:ProgressOpen) { Write-Host "$($script:E)[?25h"; $script:ProgressOpen = $false }
}

# ================================================================ errors and log

function Write-Log([string]$Text) {
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8
    }
    catch { }
}

function New-SyncError([string]$What, [string]$Fix, [switch]$Transient) {
    $ex = New-Object System.InvalidOperationException $What
    $ex.Data['Fix'] = $Fix
    if ($Transient) { $ex.Data['Transient'] = $true }
    return $ex
}

function Get-ExceptionChain($ErrorRecord) {
    $chain = @(); $e = $ErrorRecord.Exception
    while ($e) { $chain += $e; $e = $e.InnerException }
    return , $chain
}

function Get-SyncException($ErrorRecord) {
    foreach ($e in (Get-ExceptionChain $ErrorRecord)) { if ($e.Data -and $e.Data.Contains('Fix')) { return $e } }
    return $null
}

function Test-NetworkError($ErrorRecord) {
    foreach ($e in (Get-ExceptionChain $ErrorRecord)) {
        if ($e -is [System.Net.Http.HttpRequestException] -or $e -is [System.Net.WebException] -or
            $e -is [System.Net.Sockets.SocketException] -or $e -is [System.OperationCanceledException] -or
            $e -is [System.IO.IOException]) { return $true }
    }
    return $false
}

function Show-Error($ErrorRecord) {
    Close-Progress
    $chain = Get-ExceptionChain $ErrorRecord
    $root = $chain[$chain.Count - 1]
    $sync = Get-SyncException $ErrorRecord
    if ($sync) { $what = $sync.Message; $fix = [string]$sync.Data['Fix'] }
    elseif ($root -is [System.IO.IOException] -or $root -is [System.UnauthorizedAccessException]) {
        $what = "A file on this PC could not be read or written. $($root.Message)"
        $fix = 'Make sure Scrap Mechanic is fully closed and the disk is not full, then try again.'
    }
    else {
        $what = "Something unexpected went wrong. $($root.Message)"
        $fix = "Try again. If it keeps happening, send this file to whoever set this up for you: $script:LogPath"
    }
    Write-Log ("ERROR {0}: {1} | {2}" -f $root.GetType().Name, $what, ($ErrorRecord.ScriptStackTrace -replace '\s+', ' '))
    Say ''
    Say-Wrapped '  PROBLEM     ' 'Bad' $what
    Say-Wrapped '  WHAT TO DO  ' 'Amber' $fix
}

# ================================================================ small helpers

function ConvertTo-Hex([byte[]]$Bytes) { return ([BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant() }

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-Hex $sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}

function Get-FileSha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-HmacSha256([byte[]]$Key, [string]$Data) {
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, $Key)
    try { return , $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Data)) } finally { $hmac.Dispose() }
}

function ConvertTo-IsoString($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

function ConvertFrom-Iso([string]$Iso) {
    return [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Format-When([string]$Iso) {
    if (-not $Iso) { return 'never' }
    return (Format-LocalTime (ConvertFrom-Iso $Iso).ToLocalTime())
}

function Format-LocalTime([datetime]$Local) {
    $today = (Get-Date).Date
    if ($Local.Date -eq $today) { return 'today ' + $Local.ToString('HH:mm') }
    if ($Local.Date -eq $today.AddDays(-1)) { return 'yesterday ' + $Local.ToString('HH:mm') }
    return $Local.ToString('ddd d MMM HH:mm')
}

function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return 'less than a minute' }
    if ($Span.TotalHours -lt 1) { return ('{0}m' -f $Span.Minutes) }
    return ('{0}h {1:00}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes)
}

function Format-Ago([string]$Iso) {
    if (-not $Iso) { return '' }
    $span = [DateTime]::UtcNow - (ConvertFrom-Iso $Iso)
    if ($span.TotalMinutes -lt 2) { return 'just now' }
    if ($span.TotalMinutes -lt 90) { return ('{0:N0} min ago' -f $span.TotalMinutes) }
    if ($span.TotalHours -lt 36) { return ('{0:N0} hours ago' -f $span.TotalHours) }
    return ('{0:N0} days ago' -f $span.TotalDays)
}

function Format-Size([long]$Bytes) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }

# ================================================================ AWS Signature V4 (R2 speaks the S3 API)

function Get-SigV4Authorization {
    param(
        [string]$Method, [string]$CanonicalUri, [hashtable]$Headers, [string]$PayloadHash,
        [string]$AccessKey, [string]$SecretKey, [string]$Region, [string]$AmzDate,
        [string]$CanonicalQuery = ''
    )
    $lower = @{}
    foreach ($k in $Headers.Keys) { $lower[$k.ToLowerInvariant()] = ([string]$Headers[$k]).Trim() }
    $names = [string[]]@($lower.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)

    $canonicalHeaders = ''
    foreach ($n in $names) { $canonicalHeaders += $n + ':' + $lower[$n] + "`n" }
    $signedHeaders = $names -join ';'
    $canonicalRequest = @($Method, $CanonicalUri, $CanonicalQuery, $canonicalHeaders, $signedHeaders, $PayloadHash) -join "`n"

    $dateStamp = $AmzDate.Substring(0, 8)
    $scope = "$dateStamp/$Region/s3/aws4_request"
    $requestHash = Get-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonicalRequest))
    $stringToSign = @('AWS4-HMAC-SHA256', $AmzDate, $scope, $requestHash) -join "`n"

    $key = Get-HmacSha256 ([Text.Encoding]::UTF8.GetBytes('AWS4' + $SecretKey)) $dateStamp
    $key = Get-HmacSha256 $key $Region
    $key = Get-HmacSha256 $key 's3'
    $key = Get-HmacSha256 $key 'aws4_request'
    $signature = ConvertTo-Hex (Get-HmacSha256 $key $stringToSign)

    return "AWS4-HMAC-SHA256 Credential=$AccessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature"
}

function Invoke-SelfTest {
    # Published examples from the AWS S3 Signature V4 documentation.
    $cases = @(
        @{ Name = 'object with a Range header'; Uri = '/test.txt'; Query = ''; Range = 'bytes=0-9'
           Expected = 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41' }
        @{ Name = 'bucket listing with a query string'; Uri = '/'; Query = 'max-keys=2&prefix=J'; Range = ''
           Expected = '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7' }
    )
    $allPassed = $true
    foreach ($case in $cases) {
        $headers = @{
            'host'                 = 'examplebucket.s3.amazonaws.com'
            'x-amz-content-sha256' = $script:EmptyHash
            'x-amz-date'           = '20130524T000000Z'
        }
        if ($case.Range) { $headers['range'] = $case.Range }
        $auth = Get-SigV4Authorization -Method 'GET' -CanonicalUri $case.Uri -CanonicalQuery $case.Query -PayloadHash $script:EmptyHash `
            -AccessKey 'AKIAIOSFODNN7EXAMPLE' -SecretKey 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' `
            -Region 'us-east-1' -AmzDate '20130524T000000Z' -Headers $headers
        if (-not $auth.EndsWith("Signature=$($case.Expected)")) { $allPassed = $false; Say-Bad "Signing self-test FAILED for $($case.Name). Got: $auth" }
    }
    if ($allPassed) { Say-Good "Signing self-test passed (v$script:Version)." }
    return $allPassed
}
# ================================================================ remote storage

function Invoke-RemoteOnce {
    param([string]$Method, [string]$Key, [byte[]]$Body, [string]$InFile, [string]$OutFile, [string]$Label,
          [string]$IfMatch, [switch]$IfNoneMatch, [hashtable]$Query)

    $cfg = $script:Config
    $base = [Uri]($cfg.Endpoint.TrimEnd('/'))
    $encodedKey = (($Key -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $path = '/' + $cfg.Bucket + '/' + $encodedKey
    if (-not $Key) { $path = '/' + $cfg.Bucket }
    # Query parameters are part of what is signed: sorted by name, both sides URI-encoded.
    $canonicalQuery = ''
    if ($Query) {
        $queryNames = [string[]]@($Query.Keys)
        [Array]::Sort($queryNames, [StringComparer]::Ordinal)
        $canonicalQuery = ($queryNames | ForEach-Object { [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$Query[$_]) }) -join '&'
    }
    $urlQuery = ''
    if ($canonicalQuery) { $urlQuery = '?' + $canonicalQuery }

    if ($InFile)             { $payloadHash = Get-FileSha256 $InFile }
    elseif ($null -ne $Body) { $payloadHash = Get-Sha256Hex $Body }
    else                     { $payloadHash = $script:EmptyHash }

    $amzDate = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $auth = Get-SigV4Authorization -Method $Method -CanonicalUri $path -CanonicalQuery $canonicalQuery -PayloadHash $payloadHash `
        -AccessKey $cfg.AccessKeyId -SecretKey $cfg.SecretAccessKey -Region 'auto' -AmzDate $amzDate -Headers @{
            'host'                 = $base.Authority
            'x-amz-content-sha256' = $payloadHash
            'x-amz-date'           = $amzDate
        }

    $httpMethod = New-Object System.Net.Http.HttpMethod $Method
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList $httpMethod, ($base.GetLeftPart([UriPartial]::Authority) + $path + $urlQuery)
    $inStream = $null; $response = $null
    try {
        $total = 0L
        if ($InFile) {
            $inStream = [IO.File]::Open($InFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $total = $inStream.Length
            $request.Content = New-Object System.Net.Http.StreamContent -ArgumentList $inStream
        }
        elseif ($null -ne $Body) {
            $request.Content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $Body)
        }
        [void]$request.Headers.TryAddWithoutValidation('x-amz-date', $amzDate)
        [void]$request.Headers.TryAddWithoutValidation('x-amz-content-sha256', $payloadHash)
        [void]$request.Headers.TryAddWithoutValidation('Authorization', $auth)
        # Conditional writes: the storage refuses the PUT (412) if the object changed since we read it.
        if ($IfMatch) { [void]$request.Headers.TryAddWithoutValidation('If-Match', $IfMatch) }
        if ($IfNoneMatch) { [void]$request.Headers.TryAddWithoutValidation('If-None-Match', '*') }

        $start = Get-Date
        if ($Label -and -not $script:Fancy) { Say-Step "$Label ..." }
        $task = $script:Http.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if ($Label -and $inStream) {
            # The upload runs on a background thread. The file position shows how far it has read.
            while (-not $task.IsCompleted) {
                $position = $total
                try { $position = $inStream.Position } catch { }
                Show-Progress $Label $position $total $start
                Start-Sleep -Milliseconds 100
            }
        }
        $response = $task.GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $ok = ($status -ge 200 -and $status -lt 300)
        $text = ''
        $length = 0L
        if ($null -ne $response.Content.Headers.ContentLength) { $length = [long]$response.Content.Headers.ContentLength }
        $etag = ''
        if ($response.Headers.ETag) { $etag = $response.Headers.ETag.ToString() }

        if ($ok -and $OutFile) {
            $remote = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $out = [IO.File]::Create($OutFile)
            try {
                $buffer = New-Object byte[] 131072
                $done = 0L; $last = Get-Date
                while (($read = $remote.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $read)
                    $done += $read
                    if ($Label -and ((Get-Date) - $last).TotalMilliseconds -ge 100) { Show-Progress $Label $done $length $start; $last = Get-Date }
                }
                if ($Label) { Show-Progress $Label $done $done $start -Final }
            }
            finally { $out.Dispose(); $remote.Dispose() }
        }
        elseif ($Method -ne 'HEAD') {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        if ($ok -and $Label -and $InFile) { Show-Progress $Label $total $total $start -Final }

        if (-not $ok) {
            if ($status -eq 404 -and $Method -ne 'PUT' -and $text -notmatch 'NoSuchBucket') {
                return [pscustomobject]@{ Status = 404; Text = $text; Length = 0L }
            }
            Write-Log "HTTP $status on $Method $Key : $text"
            if ($status -eq 412 -or $status -eq 409) {
                $conflict = New-SyncError 'Someone else changed the shared world at the same moment.' 'Go back to the menu and look at the status box before doing anything else.'
                $conflict.Data['Conflict'] = $true
                throw $conflict
            }
            if ($status -ge 500 -or $status -eq 429) {
                throw (New-SyncError "The online storage is having trouble (code $status)." 'Wait a minute and try again. Nothing has been lost.' -Transient)
            }
            if ($text -match 'RequestTimeTooSkewed') {
                throw (New-SyncError 'The clock on this PC is wrong, so the storage refused the connection.' 'Open Windows Settings, Time and language, Date and time, and press "Sync now". Then try again.')
            }
            if ($text -match 'NoSuchBucket') {
                throw (New-SyncError "The storage has no bucket named '$($cfg.Bucket)'." 'Check the bucket name on the Cloudflare R2 page. To enter it again, open Worlds (M in the menu), remove this world and add it again.')
            }
            if ($status -eq 401 -or $status -eq 403) {
                throw (New-SyncError 'The storage rejected the access keys.' 'The API token must have the permission "Object Read & Write" for this bucket, and the clock on this PC must be correct. To enter the keys again, open Worlds (M in the menu), remove this world and add it again.')
            }
            throw (New-SyncError "The storage refused the request (code $status)." "Try again. If it keeps happening, send this file to whoever set this up: $script:LogPath")
        }
        return [pscustomobject]@{ Status = $status; Text = $text; Length = $length; ETag = $etag }
    }
    finally {
        Close-Progress
        if ($inStream) { $inStream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Invoke-Remote {
    param([string]$Method, [string]$Key, [byte[]]$Body, [string]$InFile, [string]$OutFile, [string]$Label,
          [string]$IfMatch, [switch]$IfNoneMatch, [hashtable]$Query)
    $max = 3
    # Quiet is set while the menu re-checks the status in the background: one try, no messages.
    if ($script:Quiet) { $max = 1 }
    for ($attempt = 1; ; $attempt++) {
        try { return (Invoke-RemoteOnce @PSBoundParameters) }
        catch {
            $sync = Get-SyncException $_
            $transient = ($sync -and $sync.Data.Contains('Transient')) -or ((-not $sync) -and (Test-NetworkError $_))
            if (-not $transient) { throw }
            $chain = Get-ExceptionChain $_
            Write-Log ("attempt $attempt of $Method $Key failed: " + $chain[$chain.Count - 1].Message)
            if ($attempt -ge $max) {
                if ($sync) { throw }
                throw (New-SyncError 'Could not reach the online storage.' 'Check your internet connection, then try again. Nothing has been lost, and if you had the world checked out you still do.')
            }
            Say-Warn "Connection problem. Trying again ($($attempt + 1) of $max) ..."
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Get-VersionKey([hashtable]$Entry) {
    $key = '{0}/v{1:D6}.db' -f $script:Prefix, $Entry.version
    if ($Entry.gz) { $key += '.gz' }
    return $key
}

function Test-Conflict($ErrorRecord) {
    $sync = Get-SyncException $ErrorRecord
    return [bool]($sync -and $sync.Data.Contains('Conflict'))
}

function Read-State {
    $r = Invoke-Remote -Method 'GET' -Key $script:StateKey
    if ($r.Status -eq 404) { return $null }
    $o = $r.Text | ConvertFrom-Json
    $min = [string]$o.minVersion
    if ($min -and ([version]$min -gt [version]$script:Version)) {
        throw (New-SyncError "This copy of the tool (v$script:Version) is too old for the shared world, which needs v$min or newer." 'Close this window and open the tool again so it can update. If it still says this, ask whoever set it up to send you a fresh copy.')
    }
    if ($o.deleted) {
        $gone = New-SyncError ("This shared world was deleted for everyone by {0} ({1})." -f [string]$o.deletedBy, (Format-When (ConvertTo-IsoString $o.deletedAt))) 'The save on this PC and its backups are untouched. Open Worlds (M in the menu) to remove this world from the tool.'
        $gone.Data['Deleted'] = $true
        throw $gone
    }
    $history = @()
    foreach ($h in @($o.history)) {
        if ($h) {
            $history += @{ version = [int]$h.version; sha256 = [string]$h.sha256; size = [long]$h.size; by = [string]$h.by; at = (ConvertTo-IsoString $h.at)
                gz = [bool]$h.gz; stored = [long]$h.stored; note = [string]$h.note; build = [string]$h.build; mods = (ConvertTo-ModList $h.mods) }
        }
    }
    $sessions = @()
    foreach ($x in @($o.sessions)) {
        if ($x) { $sessions += @{ by = [string]$x.by; at = (ConvertTo-IsoString $x.at); minutes = [int]$x.minutes; version = [int]$x.version; note = [string]$x.note } }
    }
    return @{
        sessions   = $sessions
        holderSteamId = [string]$o.holderSteamId
        type       = [string]$o.type
        owner      = [string]$o.owner
        ownerSteamId = [string]$o.ownerSteamId
        holder     = [string]$o.holder
        heldSince  = ConvertTo-IsoString $o.heldSince
        version    = [int]$o.version
        minVersion = $min
        history    = $history
        etag       = $r.ETag
    }
}

function Get-Current([hashtable]$State) { return $State.history[0] }

function Write-State([hashtable]$State) {
    # Survival, Creative or Custom. Kept as first recorded, so a wrongly set up copy cannot change it.
    $type = [string]$State.type
    if (-not $type) { $type = Get-WorldType }
    $min = $script:MinPeerVersion
    if ($State.minVersion -and ([version]$State.minVersion -gt [version]$min)) { $min = $State.minVersion }
    $doc = [ordered]@{
        holder = $State.holder; heldSince = $State.heldSince; version = $State.version; minVersion = $min
        writtenBy = "sm-sync $script:Version"
        type = $type
        history = @($State.history | ForEach-Object {
            [ordered]@{ version = $_.version; sha256 = $_.sha256; size = $_.size; by = $_.by; at = $_.at
                gz = [bool]$_.gz; stored = [long]$_.stored; note = [string]$_.note; build = [string]$_.build; mods = (ConvertTo-ModList $_.mods) } })
    }
    # The holder's Steam ID lets the other player's game connect straight to them.
    $doc.holderSteamId = ''
    if ($State.holder) { $doc.holderSteamId = [string]$State.holderSteamId }
    # Whoever first uploaded the world. Only they are offered "Delete for everyone".
    $doc.owner = [string]$State.owner
    $doc.ownerSteamId = [string]$State.ownerSteamId
    # The activity log. Copies older than 0.2.4 do not know it and drop it when they write.
    $doc.sessions = @($State.sessions | Where-Object { $_ } | ForEach-Object {
        [ordered]@{ by = $_.by; at = $_.at; minutes = [int]$_.minutes; version = [int]$_.version; note = [string]$_.note } })
    $json = ConvertTo-Json -InputObject $doc -Depth 8
    $body = [Text.Encoding]::UTF8.GetBytes($json)
    # Only write if the state is still the one we read. Two players acting in the same
    # second would otherwise both believe they had checked the world out.
    if ($State.etag) { $r = Invoke-Remote -Method 'PUT' -Key $script:StateKey -Body $body -IfMatch $State.etag }
    elseif ($State.isNew) { $r = Invoke-Remote -Method 'PUT' -Key $script:StateKey -Body $body -IfNoneMatch }
    else { $r = Invoke-Remote -Method 'PUT' -Key $script:StateKey -Body $body }
    $State.etag = $r.ETag
    $State.isNew = $false
}

# ================================================================ local setup

function Get-ConfigPath { return (Join-Path $PSScriptRoot 'sm-sync.config.json') }

# What belongs to one shared world. Every other setting applies to all of them.
$script:WorldFields = @('Endpoint', 'Bucket', 'AccessKeyId', 'SecretAccessKey', 'SaveName', 'SaveFolder')

function Get-WorldPrefix([string]$SaveName) { return ($SaveName -replace '[^A-Za-z0-9_-]', '_') }

function Use-Config($Cfg) {
    $script:Config = $Cfg
    $script:Prefix = Get-WorldPrefix ([string]$Cfg.SaveName)
    $script:StateKey = "$script:Prefix/state.json"
    if (-not $script:Http) {
        $script:Http = New-Object System.Net.Http.HttpClient
        $script:Http.Timeout = [TimeSpan]::FromMinutes(30)
    }
}

function Test-WorldComplete($W) {
    foreach ($field in 'Endpoint', 'Bucket', 'AccessKeyId', 'SecretAccessKey', 'SaveName') {
        $value = [string]$W[$field]
        if (-not $value -or $value -match 'YOUR_|PASTE_') { return $false }
    }
    return $true
}

function Save-Settings {
    Set-Content -LiteralPath (Get-ConfigPath) -Value (ConvertTo-Json -InputObject $script:Settings -Depth 4) -Encoding UTF8
}

function Read-Settings {
    # Loads sm-sync.config.json into $script:Settings: the settings that apply everywhere,
    # plus "Worlds", a list with one entry per shared world. A file written before 0.4.0
    # held one world at the top level. It is converted here, and that world's backups move
    # into a folder of their own.
    $script:Settings = [ordered]@{ Worlds = @() }
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw (New-SyncError 'The settings file sm-sync.config.json is damaged and cannot be read.' "Delete it from the tool's folder ($PSScriptRoot) and open the tool again, which starts the setup.") }
    $old = [ordered]@{}
    foreach ($p in $raw.PSObject.Properties) {
        if ($p.Name -eq 'Worlds') { continue }
        if ($script:WorldFields -contains $p.Name) { $old[$p.Name] = $p.Value } else { $script:Settings[$p.Name] = $p.Value }
    }
    $worlds = @()
    foreach ($w in @($raw.Worlds)) {
        if (-not $w) { continue }
        $entry = [ordered]@{}
        foreach ($p in $w.PSObject.Properties) { $entry[$p.Name] = $p.Value }
        if (Test-WorldComplete $entry) { $worlds += , $entry }
    }
    $convert = ($old.Count -gt 0) -and (Test-WorldComplete $old)
    if ($convert) { $worlds += , $old }
    $script:Settings.Worlds = $worlds
    if ($convert) {
        $script:Settings.LastWorld = [string]$old.SaveName
        $target = Join-Path $script:BackupRoot (Get-WorldPrefix ([string]$old.SaveName))
        [void](New-Item -ItemType Directory -Force -Path $target)
        Get-ChildItem -LiteralPath $script:BackupRoot -File -Filter '*.db' | Move-Item -Destination $target -Force
        Save-Settings
        Write-Log 'settings converted to the list-of-worlds format'
    }
}

function Get-Worlds { return , @($script:Settings.Worlds) }

function Find-World([string]$Name) {
    foreach ($w in (Get-Worlds)) { if ([string]$w.SaveName -eq $Name) { return $w } }
    return $null
}

function Get-WorldConfig($W) {
    # The flat settings the rest of the tool reads: the shared ones plus one world's.
    $merged = [ordered]@{}
    foreach ($k in @($script:Settings.Keys)) { if ($k -ne 'Worlds' -and $k -ne 'LastWorld') { $merged[$k] = $script:Settings[$k] } }
    if ($W) { foreach ($k in @($W.Keys)) { $merged[$k] = $W[$k] } }
    return [pscustomobject]$merged
}

function Use-NoWorld {
    $script:ActiveWorld = $null
    $script:Config = Get-WorldConfig $null
}

function Select-World($W, [switch]$Peek) {
    # Makes $W the world every later operation acts on. -Peek does not remember it as the
    # world used last.
    Use-Config (Get-WorldConfig $W)
    $script:ActiveWorld = $W
    $script:SavePath = $null
    $script:BackupDir = Join-Path $script:BackupRoot $script:Prefix
    [void](New-Item -ItemType Directory -Force -Path $script:BackupDir)
    if (-not $Peek -and [string]$script:Settings.LastWorld -ne [string]$W.SaveName) {
        $script:Settings.LastWorld = [string]$W.SaveName
        Save-Settings
    }
}

function Resolve-World {
    # The world for a command-line action: -World, else the one used last.
    $worlds = Get-Worlds
    if ($worlds.Count -eq 0) { throw (New-SyncError 'This copy has not been set up yet.' 'Double-click "Scrap Mechanic Sync.cmd" to run the setup.') }
    if ($World) {
        $w = Find-World $World
        if (-not $w) { throw (New-SyncError "No world named '$World' is set up on this PC." 'Check the name, or leave -World out to use the world you used last.') }
        return $w
    }
    $w = Find-World ([string]$script:Settings.LastWorld)
    if ($w) { return $w }
    return $worlds[0]
}

function Get-SaveRoot {
    if ($env:SMSYNC_SAVE_ROOT) { return $env:SMSYNC_SAVE_ROOT }   # tests only
    return (Join-Path $env:APPDATA 'Axolot Games\Scrap Mechanic\User')
}

function Initialize-Player {
    $file = Join-Path $script:HomeDir 'player.txt'
    $name = $env:SMSYNC_PLAYER
    if (-not $name -and (Test-Path -LiteralPath $file)) { $name = (Get-Content -LiteralPath $file -Raw).Trim() }
    if (-not $name) {
        Clear-Screen
        Show-Banner
        Say '  Welcome. This is the first run on this PC.' 'Amber'
        Say ''
        Say-Wrapped '  ' 'Text' 'What is your name? It is shown to your friend when you have the world, so pick something they will recognise. It must be different from theirs.'
        Say ''
        while (-not $name) { $name = Read-Line 'Your name:' ; if (-not $script:Interactive -and -not $name) { throw 'No player name given.' } }
    }
    Set-Content -LiteralPath $file -Value $name -Encoding UTF8
    $script:Player = $name
}

function Get-TypeOf($W) {
    # Survival, Creative or Custom. A world set up before 0.4.0 has no type and is Survival.
    $t = [string]$W.Type
    if ($t -eq 'Creative' -or $t -eq 'Custom') { return $t }
    return 'Survival'
}

function Get-WorldType { return (Get-TypeOf $script:Config) }

function Join-TypeFolder([string]$SaveBase, [string]$Type) {
    # The game keeps Survival worlds in Save\Survival, Custom games in Save\Custom and
    # Creative worlds in Save itself.
    if ($Type -eq 'Creative') { return $SaveBase }
    if ($Type -eq 'Custom') { return (Join-Path $SaveBase 'Custom') }
    return (Join-Path $SaveBase 'Survival')
}

function Get-SaveBase {
    # The Save folder of this player's Steam account: ...\User\User_<SteamId64>\Save.
    $cache = Join-Path $script:HomeDir 'savebase.txt'
    if (Test-Path -LiteralPath $cache) {
        $cached = (Get-Content -LiteralPath $cache -Raw).Trim()
        if ($cached -and (Test-Path -LiteralPath $cached)) { return $cached }
    }
    # Before 0.4.0 the tool remembered the Survival folder inside it.
    $old = Join-Path $script:HomeDir 'savefolder.txt'
    if (Test-Path -LiteralPath $old) {
        $parent = Split-Path -Parent ((Get-Content -LiteralPath $old -Raw).Trim())
        if ($parent -and (Test-Path -LiteralPath $parent)) { Set-Content -LiteralPath $cache -Value $parent -Encoding UTF8; return $parent }
    }
    $root = Get-SaveRoot
    $candidates = @()
    if (Test-Path -LiteralPath $root) {
        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'User_*' |
            ForEach-Object { Join-Path $_.FullName 'Save' } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    if ($candidates.Count -eq 0) {
        throw (New-SyncError 'Could not find the Scrap Mechanic save folder on this PC.' 'Start Scrap Mechanic once, create any world, quit the game, and open this tool again.')
    }
    $fileName = [string]$script:Config.SaveName + '.db'
    $withSave = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path (Join-TypeFolder $_ (Get-WorldType)) $fileName) })
    if ($withSave.Count -ge 1) { $candidates = $withSave }
    $base = $candidates[0]
    if ($candidates.Count -gt 1) {
        Say ''
        Say '  More than one Steam account has Scrap Mechanic saves on this PC. Which is yours?' 'Amber'
        for ($i = 0; $i -lt $candidates.Count; $i++) { Write-Seg @(("  [{0}] " -f ($i + 1)), 'Orange', $candidates[$i], 'Text') }
        $pick = 0
        while ($pick -lt 1 -or $pick -gt $candidates.Count) { [void][int]::TryParse((Read-Line 'Number:'), [ref]$pick) }
        $base = $candidates[$pick - 1]
    }
    Set-Content -LiteralPath $cache -Value $base -Encoding UTF8
    return $base
}

function Initialize-SavePath {
    $folder = [string]$script:Config.SaveFolder
    if (-not $folder) { $folder = Join-TypeFolder (Get-SaveBase) (Get-WorldType) }
    $script:SavePath = Join-Path $folder ([string]$script:Config.SaveName + '.db')
}

# ================================================================ mods

function Get-SteamLibraries {
    $libraries = @()
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libraries += $m.Groups[1].Value.Replace('\\', '\') }
        }
    }
    catch { }
    return , @($libraries | Select-Object -Unique)
}

function Get-WorkshopRoots {
    # Where Steam puts the Workshop items for Scrap Mechanic, one folder per item ID.
    if ($env:SMSYNC_WORKSHOP_ROOT) { return , @($env:SMSYNC_WORKSHOP_ROOT) }   # tests only
    return , @((Get-SteamLibraries) | ForEach-Object { Join-Path $_ ('steamapps\workshop\content\' + $script:SteamAppId) })
}

function Test-ModInstalled([string]$Id) {
    foreach ($root in (Get-WorkshopRoots)) { if (Test-Path -LiteralPath (Join-Path $root $Id)) { return $true } }
    return $false
}

function Get-ModName([string]$Id) {
    foreach ($root in (Get-WorkshopRoots)) {
        $file = Join-Path (Join-Path $root $Id) 'description.json'
        if (Test-Path -LiteralPath $file) {
            try { return [string]((Get-Content -LiteralPath $file -Raw) | ConvertFrom-Json).name } catch { }
        }
    }
    return ''
}

function ConvertTo-ModList($Value) {
    # The mods of one history entry as a list the state file can hold.
    $list = @()
    foreach ($m in @($Value)) { if ($m -and $m.id) { $list += , [ordered]@{ id = [string]$m.id; name = [string]$m.name } } }
    return , $list
}

function Get-ModLabel($Mod) {
    if ([string]$Mod.id -eq '0') { return 'a mod that is not from the Steam Workshop' }
    if ($Mod.name) { return [string]$Mod.name }
    return ('Workshop item ' + $Mod.id)
}

function Get-ModUrl($Mod) { return ('https://steamcommunity.com/sharedfiles/filedetails/?id=' + $Mod.id) }

function Get-WorldModIds([string]$Path) {
    # The Workshop IDs of the mods a world was made with, read from the "mods" column of its
    # Game table with the SQLite library that ships with Windows. That column is a 4-byte
    # count, then 24 bytes per mod: an 8-byte Workshop ID (0 for a local mod) and 16 more.
    # Returns an empty list when the file cannot be read: this must never block an upload.
    try {
        if (-not ('SmSyncSqlite' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class SmSyncSqlite {
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_open_v2")] public static extern int Open(byte[] path, out IntPtr db, int flags, IntPtr vfs);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_prepare_v2")] public static extern int Prepare(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_step")] public static extern int Step(IntPtr stmt);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_blob")] public static extern IntPtr Blob(IntPtr stmt, int col);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_bytes")] public static extern int Bytes(IntPtr stmt, int col);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_finalize")] public static extern int Finalize(IntPtr stmt);
  [DllImport("winsqlite3.dll", EntryPoint="sqlite3_close")] public static extern int Close(IntPtr db);
}
'@
        }
        $db = [IntPtr]::Zero
        # 1 = open read-only, so the save is never changed.
        if ([SmSyncSqlite]::Open([Text.Encoding]::UTF8.GetBytes($Path + [char]0), [ref]$db, 1, [IntPtr]::Zero) -ne 0) { throw 'open failed' }
        try {
            $stmt = [IntPtr]::Zero
            if ([SmSyncSqlite]::Prepare($db, [Text.Encoding]::UTF8.GetBytes('select mods from Game' + [char]0), -1, [ref]$stmt, [IntPtr]::Zero) -ne 0) { throw 'no Game table' }
            try {
                if ([SmSyncSqlite]::Step($stmt) -ne 100) { return , @() }
                $n = [SmSyncSqlite]::Bytes($stmt, 0)
                $b = New-Object byte[] $n
                if ($n -gt 0) { [Runtime.InteropServices.Marshal]::Copy([SmSyncSqlite]::Blob($stmt, 0), $b, 0, $n) }
            }
            finally { [void][SmSyncSqlite]::Finalize($stmt) }
        }
        finally { [void][SmSyncSqlite]::Close($db) }
        if ($n -lt 4) { return , @() }
        $count = ([int]$b[0] -shl 24) -bor ([int]$b[1] -shl 16) -bor ([int]$b[2] -shl 8) -bor [int]$b[3]
        if ($n -ne 4 + 24 * $count) { Write-Log "mods list has an unexpected layout ($n bytes for $count)"; return , @() }
        $ids = @()
        for ($i = 0; $i -lt $count; $i++) {
            [uint64]$id = 0
            for ($k = 0; $k -lt 8; $k++) { $id = ($id -shl 8) -bor [uint64]$b[4 + 24 * $i + $k] }
            $ids += [string]$id
        }
        return , $ids
    }
    catch {
        Write-Log ("could not read the mods of the world: " + $_.Exception.Message)
        return , @()
    }
}

function Get-ModsForUpload([string]$Path) {
    $mods = @()
    foreach ($id in (Get-WorldModIds $Path)) { $mods += , [ordered]@{ id = $id; name = (Get-ModName $id) } }
    return , $mods
}

function Get-MissingMods($Entry) {
    # The Workshop mods an uploaded version needs that this PC does not have.
    $missing = @()
    foreach ($m in @($Entry.mods)) {
        if ($m -and [string]$m.id -ne '0' -and -not (Test-ModInstalled ([string]$m.id))) { $missing += , $m }
    }
    return , $missing
}

function Confirm-ModsInstalled($Entry) {
    # Before a check-out: $true when every Workshop mod the world needs is installed. Until
    # then the game is not started, so a world is never opened, and uploaded, with parts missing.
    if (@(@($Entry.mods) | Where-Object { $_ -and [string]$_.id -eq '0' }).Count -gt 0) {
        Say-Warn 'This world also uses a mod that is not from the Steam Workshop. Every player must copy it into their own Mods folder. The tool cannot check that one.'
    }
    $missing = Get-MissingMods $Entry
    if ($missing.Count -eq 0) { return $true }
    $names = ($missing | ForEach-Object { Get-ModLabel $_ }) -join ', '
    if ($script:Unattended -or -not $script:Interactive) {
        throw (New-SyncError "This world needs mods that are not installed on this PC: $names." ('Subscribe to them in the Steam Workshop, let Steam download them, then try again. ' + (($missing | ForEach-Object { Get-ModUrl $_ }) -join ' ')))
    }
    Say-Bad ("This world needs {0} mod(s) from the Steam Workshop that are not installed on this PC:" -f $missing.Count)
    Say ''
    foreach ($m in $missing) { Say-Wrapped '      -  ' 'Orange' (Get-ModLabel $m) }
    Say ''
    Say-Wrapped '  ' 'Text' 'Nothing has been checked out. Press O to open each one in Steam, press Subscribe on its page, and wait until Steam has downloaded it. Then press R. Without them the game cannot open this world, or opens it with parts missing.'
    Say ''
    Write-Seg @('  [O] ', 'Orange', 'Open the Workshop pages   ', 'Text', '[R] ', 'Orange', 'Check again   ', 'Text', '[Esc] ', 'Orange', 'Cancel', 'Text')
    while ($true) {
        $k = Read-Key 'OR' -Esc
        if ($k -eq 'O') { foreach ($m in $missing) { Open-Link ('steam://url/CommunityFilePage/' + $m.id) }; continue }
        if ($k -eq 'R') {
            $missing = Get-MissingMods $Entry
            if ($missing.Count -eq 0) { Say-Good 'Every mod this world needs is installed.'; return $true }
            Say-Warn ('Still not installed: ' + (($missing | ForEach-Object { Get-ModLabel $_ }) -join ', ') + '. Steam may still be downloading. Press R again in a moment.')
            continue
        }
        Say-Step 'Cancelled. Nothing was checked out.'
        return $false
    }
}

function Test-GameRunning { return [bool](Get-Process -Name $script:GameProcess -ErrorAction SilentlyContinue) }

function Assert-GameClosed {
    if (Test-GameRunning) {
        throw (New-SyncError 'Scrap Mechanic is still running.' 'Quit the game completely (back to the desktop), then try again.')
    }
}

function Assert-SaveHealthy([string]$Path) {
    foreach ($suffix in '-journal', '-wal') {
        $side = $Path + $suffix
        if ((Test-Path -LiteralPath $side) -and (Get-Item -LiteralPath $side).Length -gt 0) {
            throw (New-SyncError 'The game did not close cleanly last time, so the save is not safe to upload yet.' 'Start Scrap Mechanic, load the world, then quit normally through the menu. After that choose Finish session.')
        }
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $head = New-Object byte[] 15; [void]$stream.Read($head, 0, 15) } finally { $stream.Dispose() }
    if ([Text.Encoding]::ASCII.GetString($head) -ne 'SQLite format 3') {
        throw (New-SyncError 'The save file does not look like a Scrap Mechanic world. It may be damaged.' 'Do not upload it. Use Restore a backup to bring back an earlier copy.')
    }
}

function Wait-FileUnlocked([string]$Path) {
    $deadline = (Get-Date).AddSeconds(30)
    while ($true) {
        try { ([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)).Dispose(); return }
        catch {
            if ((Get-Date) -gt $deadline) {
                throw (New-SyncError 'The save file is still being used by another program.' 'Make sure Scrap Mechanic is fully closed, wait a few seconds, and try again.')
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Backup-LocalSave([string]$Reason) {
    if (-not (Test-Path -LiteralPath $script:SavePath)) { return }
    $name = '{0}_{1}_{2}.db' -f $script:Config.SaveName, (Get-Date -Format 'yyyyMMdd-HHmmss'), $Reason
    Copy-Item -LiteralPath $script:SavePath -Destination (Join-Path $script:BackupDir $name)
    $keep = 10
    if ($script:Config.BackupsToKeep) { $keep = [int]$script:Config.BackupsToKeep }
    Get-ChildItem -LiteralPath $script:BackupDir -Filter '*.db' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $keep | Remove-Item -Force
}

# ================================================================ core operations

function Compress-File([string]$Source, [string]$Destination) {
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $out = [IO.File]::Create($Destination)
        try {
            $gz = New-Object System.IO.Compression.GZipStream -ArgumentList $out, ([System.IO.Compression.CompressionLevel]::Optimal)
            try { $in.CopyTo($gz) } finally { $gz.Dispose() }
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
}

function Expand-File([string]$Source, [string]$Destination) {
    $in = [IO.File]::OpenRead($Source)
    try {
        $gz = New-Object System.IO.Compression.GZipStream -ArgumentList $in, ([System.IO.Compression.CompressionMode]::Decompress)
        try {
            $out = [IO.File]::Create($Destination)
            try { $gz.CopyTo($out) } finally { $out.Dispose() }
        }
        finally { $gz.Dispose() }
    }
    finally { $in.Dispose() }
}

function Publish-Save([hashtable]$State) {
    # Uploads the local save as a new version and checks the world back in.
    if (-not (Test-Path -LiteralPath $script:SavePath)) {
        throw (New-SyncError 'There is no save on this PC to upload.' "Expected to find it at: $script:SavePath")
    }
    Wait-FileUnlocked $script:SavePath
    Assert-SaveHealthy $script:SavePath
    $hash = Get-FileSha256 $script:SavePath
    $size = (Get-Item -LiteralPath $script:SavePath).Length

    $history = @(); $version = 0; $min = ''; $etag = ''; $isNew = $true; $type = ''
    $owner = $script:Player; $ownerSteamId = Get-MySteamId
    if ($State) { $history = @($State.history); $version = $State.version; $min = $State.minVersion; $etag = $State.etag; $isNew = $false; $owner = $State.owner; $ownerSteamId = $State.ownerSteamId; $type = $State.type }
    $dropped = @()

    if ($history.Count -gt 0 -and $history[0].sha256 -eq $hash) {
        Say-Step 'The world has not changed since the last upload, so there is nothing to send.'
    }
    else {
        if ($history.Count -gt 0 -and $history[0].size -gt 1MB -and $size -lt ($history[0].size / 2)) {
            # A new world created under the same name, or a reset save, would otherwise
            # replace the shared world without anyone noticing.
            Say-Warn ("The save on this PC is much smaller than the shared world: {0} against {1}." -f (Format-Size $size), (Format-Size $history[0].size))
            Say-Wrapped '      ' 'Text' 'This usually means a NEW world was created with the same name, or the save was reset. Uploading it would replace the shared world for both of you.' 'Dim'
            if (-not (Confirm-Yes 'Upload this smaller world anyway?')) {
                throw (New-SyncError 'Nothing was uploaded, because the save on this PC looks like the wrong world.' 'The world is still checked out to you. Use Restore a backup to bring the right world back, then Finish session.')
            }
        }
        $version++
        $entry = @{ build = (Get-GameBuild); version = $version; sha256 = $hash; size = $size; by = $script:Player; at = [DateTime]::UtcNow.ToString('o'); gz = $true; stored = 0L; note = ''; mods = (Get-ModsForUpload $script:SavePath) }
        $packed = Join-Path $script:HomeDir 'upload.db.gz'
        Say-Step 'Packing the world ...'
        Compress-File $script:SavePath $packed
        try {
            $entry.stored = (Get-Item -LiteralPath $packed).Length
            $key = Get-VersionKey $entry
            [void](Invoke-Remote -Method 'PUT' -Key $key -InFile $packed -Label 'Uploading')
            $head = Invoke-Remote -Method 'HEAD' -Key $key
            if ($head.Status -ne 200 -or $head.Length -ne $entry.stored) {
                throw (New-SyncError 'The upload did not arrive in one piece.' 'The world is still checked out to you. Choose Finish session to send it again.')
            }
        }
        finally { Remove-Item -LiteralPath $packed -Force -ErrorAction SilentlyContinue }
        $history = @($entry) + $history
        if ($history.Count -gt $script:KeepOnline) {
            $dropped = @($history | Select-Object -Skip $script:KeepOnline)
            $history = @($history | Select-Object -First $script:KeepOnline)
        }
    }

    $sessions = @()
    if ($State -and $State.sessions) { $sessions = @($State.sessions) }
    if ($entry) {
        $sessions = @(@{ by = $script:Player; at = $entry.at; minutes = [int]$script:SessionMinutes; version = $version; note = '' }) + $sessions
        if ($sessions.Count -gt 20) { $sessions = @($sessions | Select-Object -First 20) }
        $script:SessionMinutes = 0
    }
    Write-State @{ type = $type; owner = $owner; ownerSteamId = $ownerSteamId; holder = ''; heldSince = ''; version = $version; minVersion = $min; history = $history; sessions = $sessions; etag = $etag; isNew = $isNew }
    Write-Log "published version $version ($size bytes) and checked the world in"
    foreach ($old in $dropped) {
        try { [void](Invoke-Remote -Method 'DELETE' -Key (Get-VersionKey $old)) }
        catch { Write-Log "could not delete old version $($old.version)" }
    }
    Remove-Orphans $history $version
    Say-Good 'The world is uploaded and available for the next player.'
    if ($entry) { Say ("      Version {0}: {1} sent, {2} unpacked." -f $entry.version, (Format-Size $entry.stored), (Format-Size $entry.size)) 'Dim' }
    Say '      It is safe to close this window or shut down the PC.' 'Dim'
}

function Receive-Save([hashtable]$Entry, [switch]$SkipNewerCheck) {
    # Makes the local save identical to one online version. Returns $false if the user cancels.
    $haveLocal = Test-Path -LiteralPath $script:SavePath
    if ($haveLocal -and (Get-FileSha256 $script:SavePath) -eq $Entry.sha256) {
        Say-Step 'This PC already has that version.'
        return $true
    }
    if ($haveLocal -and -not $SkipNewerCheck -and $Entry.at) {
        if ((Get-Item -LiteralPath $script:SavePath).LastWriteTimeUtc -gt (ConvertFrom-Iso $Entry.at).AddMinutes(2)) {
            Say-Warn 'The save on this PC is NEWER than the shared one.'
            Say-Wrapped '      ' 'Text' 'You may have played without uploading. Downloading replaces it. A backup is kept, and Restore a backup can bring it back.' 'Dim'
            if (-not (Confirm-Yes 'Replace the save on this PC with the shared one?')) { return $false }
        }
    }
    Backup-LocalSave 'before-download'
    # A friend who never played a Custom game has no Save\Custom folder yet.
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SavePath))
    $temp = $script:SavePath + '.download'
    $damaged = New-SyncError 'The download was damaged on the way.' 'Nothing on this PC was changed. Try again in a minute.'
    if ($Entry.gz) {
        $packed = Join-Path $script:HomeDir 'download.db.gz'
        try {
            [void](Invoke-Remote -Method 'GET' -Key (Get-VersionKey $Entry) -OutFile $packed -Label 'Downloading')
            try { Expand-File $packed $temp }
            catch { Write-Log "unpack failed: $($_.Exception.Message)"; Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw $damaged }
        }
        finally { Remove-Item -LiteralPath $packed -Force -ErrorAction SilentlyContinue }
    }
    else {
        [void](Invoke-Remote -Method 'GET' -Key (Get-VersionKey $Entry) -OutFile $temp -Label 'Downloading')
    }
    if ((Get-FileSha256 $temp) -ne $Entry.sha256) {
        Remove-Item -LiteralPath $temp -Force
        throw $damaged
    }
    Move-Item -LiteralPath $temp -Destination $script:SavePath -Force
    Write-Log "downloaded version $($Entry.version)"
    Say-Good 'Downloaded and checked.'
    return $true
}
function Get-OrSeedState {
    $state = Read-State
    if ($state) { return $state }
    Say-Warn 'Nothing has been shared yet. The online storage is empty.'
    if (-not (Test-Path -LiteralPath $script:SavePath)) {
        throw (New-SyncError "This PC has no '$($script:Config.SaveName)' world either." 'The player who has the world must open this tool and upload it first.')
    }
    if (-not (Confirm-Yes "Upload YOUR copy of '$($script:Config.SaveName)' as the starting point?")) { return $null }
    Publish-Save $null
    $script:Seeded = $true
    return (Read-State)
}

function Set-Holder([hashtable]$State) {
    $State.holder = $script:Player
    $State.heldSince = [DateTime]::UtcNow.ToString('o')
    $State.holderSteamId = Get-MySteamId
    if ($env:SMSYNC_TEST_CHECKOUT_DELAY) { Start-Sleep -Seconds ([int]$env:SMSYNC_TEST_CHECKOUT_DELAY) }   # tests only: lets a second player get in first
    Write-State $State
    Write-Log 'checked the world out'
}

function Enter-Turn([switch]$Override) {
    # Checks the world out to this player and brings the local save up to date.
    # Returns $true when it is safe to play.
    Assert-GameClosed
    Say-Step 'Checking who has the world ...'
    $state = Get-OrSeedState
    if (-not $state) { return $false }

    if ($state.holder -eq $script:Player) {
        Say-Step 'You already have the world checked out. Using the save on this PC.'
        return $true
    }
    if ($state.holder) {
        if (-not $Override) {
            Say-Bad ("{0} has the world checked out (since {1}, {2})." -f $state.holder, (Format-When $state.heldSince), (Format-Ago $state.heldSince))
            Say-Wrapped '      ' 'Text' 'They have the newest copy and have not uploaded it yet. If they are playing right now, you can join their game through Steam (J in the menu). Otherwise wait until they finish. If they forgot and cannot do it now, use "Force check-out" in the menu.' 'Dim'
            return $false
        }
        Say-Warn ("Forcing the check-out away from {0}. Anything they played since {1} is now out of sync." -f $state.holder, (Format-When (Get-Current $state).at))
        Write-Log "forced takeover from $($state.holder)"
    }
    $current = Get-Current $state
    if ($state.type -and $state.type -ne (Get-WorldType)) {
        throw (New-SyncError ("The shared world is a {0} world, but this PC has it set up as {1}." -f $state.type, (Get-WorldType)) 'Open Worlds (M), remove this world from this PC, and add it again with a new invite.')
    }
    if (-not (Confirm-ModsInstalled $current)) { return $false }
    $myBuild = Get-GameBuild
    if ($current.build -and $myBuild -and ([long]$myBuild -lt [long]$current.build)) {
        Say-Warn 'This save was made with a NEWER version of Scrap Mechanic than the one on this PC.'
        Say-Wrapped '      ' 'Text' 'An older game may not be able to open it. Let Steam update Scrap Mechanic first (Steam, Library, Scrap Mechanic, Update), then press 1 again.' 'Dim'
        if (-not (Confirm-Yes 'Check out and download anyway?')) { return $false }
    }
    if (-not (Receive-Save $current)) { return $false }
    try { Set-Holder $state }
    catch {
        if (-not (Test-Conflict $_)) { throw }
        Say-Bad 'Someone else checked the world out a moment before you.'
        Say-Wrapped '      ' 'Text' 'Nothing is lost. Go back to the menu and look at the status box.' 'Dim'
        return $false
    }
    Say-Good 'The world is now checked out to you.'
    if ($current.note) { Say ''; Say-Wrapped ("      Message from {0}: " -f $current.by) 'Dim' $current.note 'Amber' }
    return $true
}

function Exit-Turn([switch]$Override) {
    # One upload at a time on this PC: the menu window and the background watchdog can
    # both decide to finish the same session.
    $mutex = New-Object System.Threading.Mutex($false, ('SMSyncPublish_' + $script:Prefix))
    try { [void]$mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { }
    try { Exit-TurnCore -Override:$Override }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Add-SessionNote {
    # Attaches a short note to the version this player just uploaded. The upload has
    # already happened, so an unanswered prompt never delays the hand-over.
    if ($script:Unattended) { return }
    $text = $Note
    if (-not $text) {
        Say ''
        Say '      Leave a message about this save for the next player? For example what you built.' 'Dim'
        Say '      Enter saves it. Enter on an empty line skips. It closes after 60 seconds without typing.' 'Dim'
        Say ''
        $text = Read-LineTimeout 'Message:' 60
    }
    $text = ($text -replace '[\x00-\x1F]', ' ').Trim()
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
    if (-not $text) { return }
    for ($try = 1; $try -le 2; $try++) {
        $state = Read-State
        if (-not $state -or $state.history.Count -eq 0 -or $state.history[0].by -ne $script:Player) { return }
        $state.history[0].note = $text
        if ($state.sessions.Count -gt 0 -and $state.sessions[0].version -eq $state.history[0].version) { $state.sessions[0].note = $text }
        try { Write-State $state; Say-Good 'Message saved.'; return }
        catch {
            if ($try -lt 2 -and (Test-Conflict $_)) { continue }
            Write-Log "note not saved: $((Get-ExceptionChain $_)[-1].Message)"
            Say-Warn 'The message could not be saved. The world itself is uploaded.'
            return
        }
    }
}

function Exit-TurnCore([switch]$Override) {
    Assert-GameClosed
    $script:Seeded = $false
    $state = Get-OrSeedState
    if (-not $state -or $script:Seeded) { return }
    if ($state.holder -and $state.holder -ne $script:Player -and -not $Override) {
        Say-Bad ("{0} has the world checked out, so your copy cannot be uploaded." -f $state.holder)
        return
    }
    if (-not $state.holder) {
        if ((Test-Path -LiteralPath $script:SavePath) -and (Get-FileSha256 $script:SavePath) -eq (Get-Current $state).sha256) {
            Say-Step 'Nothing to do. The world is available and this PC already matches it.'
            return
        }
        Say-Warn 'You did not check the world out before playing.'
        if (-not (Confirm-Yes 'Upload your copy anyway and make it the shared world?')) { return }
    }
    Publish-Save $state
    Add-SessionNote
}

function Get-MySteamId {
    # Every save is under ...\User\User_<SteamId64>\Save, so the ID needs no Steam API.
    if ($env:SMSYNC_STEAM_ID) { return $env:SMSYNC_STEAM_ID }
    $m = [regex]::Match([string]$script:SavePath, 'User_(\d{17})\\')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Start-GameWith([string[]]$GameArguments) {
    # Starts the game through steam.exe with launch options. Returns $false when Steam
    # cannot be found, and the caller falls back to a plain launch.
    $steamExe = $null
    try { $steamExe = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamExe } catch { }
    if (-not $steamExe -or -not (Test-Path -LiteralPath $steamExe)) { return $false }
    Write-Log ("launching through steam.exe: " + ($GameArguments -join ' '))
    Start-Process -FilePath $steamExe -ArgumentList (@('-applaunch', $script:SteamAppId) + $GameArguments)
    return $true
}

function Start-Game {
    # Starts the game with "-open <save>", which loads the shared world and skips the main
    # menu. Set "OpenWorldDirectly": false in the settings file to go back to a plain
    # launch if a game update ever breaks that option.
    $direct = $true
    if ($null -ne $script:Config.OpenWorldDirectly) { $direct = [bool]$script:Config.OpenWorldDirectly }
    if ($direct -and (Start-GameWith @('-open', ('"{0}"' -f $script:SavePath)))) { return }
    Write-Log 'launching through the steam:// link (main menu)'
    Start-Process "steam://rungameid/$script:SteamAppId"
}
function Start-PlaySession {
    if (-not (Enter-Turn -Override:$Force)) { return }
    if ($NoLaunch -or $env:SMSYNC_NO_LAUNCH) { return }

    Say-Step 'Starting Scrap Mechanic ...'
    Start-Game
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-GameRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-GameRunning)) {
        Say-Warn 'The game did not start.'
        Say-Wrapped '      ' 'Text' 'The world is still checked out to you. Start the game yourself from Steam, and when you are done playing choose Finish session.' 'Dim'
        return
    }
    Say-Good 'The game is running.'
    Start-Watchdog
    Say ''
    Say '      LEAVE THIS WINDOW OPEN.' 'Amber'
    Say '      It uploads the world by itself when you quit the game.' 'Text'
    Say '      If this window gets closed, the upload still happens in the background.' 'Dim'
    Say '      If Steam asks about a Cloud conflict, choose the LOCAL files.' 'Dim'
    Say '      If Steam asks to "Launch Game with custom arguments", click Continue.' 'Dim'
    Say ''
    $start = Get-Date
    do {
        while (Test-GameRunning) {
            if ($script:Fancy) {
                $t = (Get-Date) - $start
                Write-Host "`r$($script:E)[?25l" -NoNewline
                Write-Seg @('      Playing  ', 'Dim', ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds), 'Orange') -NoNewline
            }
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Seconds 5
    } while (Test-GameRunning)
    if ($script:Fancy) { Write-Host "$($script:E)[?25h" }
    Say-Step ("The game has closed. You played {0}. Uploading the world ..." -f (Format-Duration ((Get-Date) - $start)))
    $script:SessionMinutes = [int][Math]::Round(((Get-Date) - $start).TotalMinutes)
    try { Exit-Turn }
    catch {
        Show-Error $_
        Say-Warn 'The world was NOT uploaded. It is still checked out to you. Choose Finish session to try again.'
    }
}

function Get-StatusModel {
    $m = @{ Online = $true; State = $null; Local = 'none'; GameRunning = (Test-GameRunning) }
    try { $m.State = Read-State }
    catch { $m.Online = $false; $m.Problem = $_; return $m }
    if (Test-Path -LiteralPath $script:SavePath) {
        if ($m.State -and (Get-FileSha256 $script:SavePath) -eq (Get-Current $m.State).sha256) { $m.Local = 'same' } else { $m.Local = 'different' }
    }
    return $m
}

function Get-StatusRows($Model) {
    # The rows of the status box. A $null row is a spacer that a short window may drop.
    $rows = @()
    $rows += , $null
    $rows += , @('You       ', 'Dim', $script:Player, 'Text')
    $rows += , $null
    $hint = ''; $hintColor = 'Text'
    if (-not $Model.Online) {
        $sync = Get-SyncException $Model.Problem
        $what = 'Could not reach the online storage.'; if ($sync) { $what = $sync.Message }
        if ($sync -and $sync.Data.Contains('Deleted')) {
            $rows += , @('World     ', 'Dim', 'DELETED', 'Bad')
            $hint = "$what"; $hintColor = 'Bad'
        }
        else {
            $rows += , @('World     ', 'Dim', 'UNKNOWN', 'Bad')
            $hint = "$what Press R to try again."; $hintColor = 'Bad'
        }
    }
    elseif (-not $Model.State) {
        $rows += , @('World     ', 'Dim', 'nothing shared yet', 'Amber')
        $hint = 'Press 2 to upload the world from this PC as the starting point.'
    }
    else {
        $s = $Model.State; $c = Get-Current $s
        $mods = @(@($c.mods) | Where-Object { $_ })
        $missingMods = Get-MissingMods $c
        if ($s.holder -eq $script:Player) {
            $rows += , @('World     ', 'Dim', 'CHECKED OUT BY YOU', 'Amber', ("   since {0} ({1})" -f (Format-When $s.heldSince), (Format-Ago $s.heldSince)), 'Dim')
            $hint = 'You have the newest copy. Press 1 to keep playing, or 2 to upload it and make it available.'
        }
        elseif ($s.holder) {
            $rows += , @('World     ', 'Dim', ("CHECKED OUT BY {0}" -f $s.holder.ToUpperInvariant()), 'Bad', ("   since {0} ({1})" -f (Format-When $s.heldSince), (Format-Ago $s.heldSince)), 'Dim')
            if (Test-HolderRecent $s) {
                $hint = "$($s.holder) is probably playing right now. To play together, press J: the game starts and joins $($s.holder). To play on your own, wait until this says AVAILABLE."
            }
            else {
                $hint = "$($s.holder) has had the world for a long time and may have forgotten to finish. Message them. Do not play on your own until this says AVAILABLE."
            }
            $hintColor = 'Amber'
        }
        else {
            $rows += , @('World     ', 'Dim', 'AVAILABLE', 'Good', '   nobody has it checked out', 'Dim')
            $hint = 'Ready. Press 1 to play.'; $hintColor = 'Good'
            if ($missingMods.Count -gt 0) { $hint = 'This world needs mods that are not installed on this PC. Press 1 to see which, and to open their Workshop pages.'; $hintColor = 'Amber' }
        }
        $rows += , $null
        $rows += , @('Last save ', 'Dim', ("version {0}" -f $c.version), 'Text', ("   {0} ({1}) by {2}   {3}" -f (Format-When $c.at), (Format-Ago $c.at), $c.by, (Format-Size $c.size)), 'Dim')
        if ($mods.Count -gt 0) {
            $names = ($mods | ForEach-Object { Get-ModLabel $_ }) -join ', '
            if ($names.Length -gt 36) { $names = $names.Substring(0, 33) + '...' }
            $rows += , $null
            if ($missingMods.Count -gt 0) { $rows += , @('Mods      ', 'Dim', $names, 'Text', ("   {0} missing on this PC" -f $missingMods.Count), 'Bad') }
            else { $rows += , @('Mods      ', 'Dim', $names, 'Text', '   installed', 'Good') }
        }
        if ($c.note) {
            $rows += , $null
            $rows += , @('Message about last save', 'Dim')
            foreach ($line in (Split-Wrap ('"' + $c.note + '"') ($script:W - 4))) { $rows += , @($line, 'Amber') }
        }
        $rows += , $null
        switch ($Model.Local) {
            'same'      { $rows += , @('This PC   ', 'Dim', 'up to date', 'Good') }
            'different' { $rows += , @('This PC   ', 'Dim', 'different from the shared world', 'Amber') }
            default     { $rows += , @('This PC   ', 'Dim', 'no copy yet', 'Dim') }
        }
    }
    $mine = $Model.Online -and $Model.State -and ($Model.State.holder -eq $script:Player)
    if ($Model.GameRunning -and -not $mine) {
        $hint = 'Scrap Mechanic is running, but the world is NOT checked out to you. Joining your friend as a guest is fine. If you are playing the shared world yourself, quit the game and press 1, or your progress will be out of sync.'
        $hintColor = 'Amber'
    }
    $rows += , @('', 'Text')
    foreach ($line in (Split-Wrap $hint ($script:W - 4))) { $rows += , @($line, $hintColor) }
    return , $rows
}

function Show-StatusBox($Model, [switch]$Compact) {
    Write-BoxTop 'WORLD STATUS'
    foreach ($row in (Get-StatusRows $Model)) {
        if ($null -eq $row) { if (-not $Compact) { Write-BoxRow @('', 'Text') } }
        else { Write-BoxRow $row }
    }
    Write-BoxBottom
}

function Show-StatusPlain {
    $m = Get-StatusModel
    if (-not $m.Online) { throw $m.Problem }
    Say "  You are:      $script:Player"
    if (-not $m.State) { Say '  Shared world: nothing uploaded yet' 'Amber'; return }
    $s = $m.State; $c = Get-Current $s
    if ($s.holder -eq $script:Player) { Say ("  World:        checked out by YOU (since {0})" -f (Format-When $s.heldSince)) 'Amber' }
    elseif ($s.holder) { Say ("  World:        checked out by {0} (since {1})" -f $s.holder, (Format-When $s.heldSince)) 'Bad' }
    else { Say '  World:        available' 'Good' }
    Say ("  Last upload:  {0} by {1} (version {2}, {3})" -f (Format-When $c.at), $c.by, $c.version, (Format-Size $c.size))
    Say ("  Online:       versions {0}" -f (($s.history | ForEach-Object { $_.version }) -join ', '))
    if ($c.note) { Say "  Message:      $($c.note)" }
    if (@($c.mods).Count -gt 0) { Say ("  Mods:         " + ((@($c.mods) | ForEach-Object { Get-ModLabel $_ }) -join ', ')) }
    Say "  Type:         $(Get-WorldType)"
    Say "  Your copy:    $($m.Local)"
}

function Restore-Backup {
    Assert-GameClosed
    $state = Read-State
    if ($state -and $state.holder -and $state.holder -ne $script:Player) {
        Say-Bad "$($state.holder) has the world checked out. You can restore when it is available or checked out to you."
        return
    }
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $script:BackupDir -Filter '*.db' | Sort-Object LastWriteTime -Descending)) {
        $items += @{ Where = 'this PC'; When = $f.LastWriteTime; Size = $f.Length; Note = ($f.BaseName -replace '^.*_\d{8}-\d{6}_', ''); File = $f.FullName }
    }
    if ($state) {
        foreach ($h in $state.history) {
            $label = "version $($h.version) by $($h.by)"
            if ($h.note) {
                $short = $h.note
                if ($short.Length -gt 40) { $short = $short.Substring(0, 37) + '...' }
                $label += '  "' + $short + '"'
            }
            $items += @{ Where = 'online'; When = (ConvertFrom-Iso $h.at).ToLocalTime(); Size = $h.size; Note = $label; Entry = $h }
        }
    }
    if ($items.Count -eq 0) { Say-Step 'There are no backups yet.'; return }
    $items = @($items | Sort-Object { $_.When } -Descending)
    Say '  Pick the copy to bring back. Newest first.' 'Text'
    Say ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        Write-Seg @(("  [{0,2}] " -f ($i + 1)), 'Orange', (Format-LocalTime $it.When).PadRight(17), 'Text', ("  {0,-8}" -f $it.Where), 'Amber', ("  {0,9}  " -f (Format-Size $it.Size)), 'Dim', $it.Note, 'Dim')
    }
    Say ''
    $pick = 0
    [void][int]::TryParse((Read-Line 'Number, then Enter (just Enter to cancel):'), [ref]$pick)
    if ($pick -lt 1 -or $pick -gt $items.Count) { Say-Step 'Cancelled. Nothing was changed.'; return }
    $chosen = $items[$pick - 1]
    if ($chosen.Entry) {
        if (-not (Receive-Save $chosen.Entry -SkipNewerCheck)) { return }
    }
    else {
        Backup-LocalSave 'before-restore'
        Copy-Item -LiteralPath $chosen.File -Destination $script:SavePath -Force
        (Get-Item -LiteralPath $script:SavePath).LastWriteTime = Get-Date
    }
    Write-Log "restored $($chosen.Where) copy from $($chosen.When)"
    if ($state -and -not $state.holder) { Set-Holder $state }
    Say-Good 'Restored on this PC, and the world is checked out to you.'
    Say-Wrapped '      ' 'Text' 'Press 1 to check it in the game. It becomes the shared world when you finish the session.' 'Dim'
}

function Show-Help {
    $pages = @(
        @('HOW IT WORKS', @(
            'There is ONE shared world, kept online. It works like a library book: one person checks it out, plays, and returns it.',
            'AVAILABLE means nobody has it. Press 1 and the newest copy is downloaded to this PC and checked out to you.',
            'CHECKED OUT BY a name means that person has the newest copy on their PC and has not uploaded it yet. Nobody else can play until they do.',
            'When you quit the game, this tool uploads your progress and the world becomes available again.',
            'If you both played at the same time there would be two different worlds, out of sync, and one would have to be thrown away. Checking out stops that from happening.')),
        @('THE MENU', @(
            'Move with the UP and DOWN arrow keys and press Enter, or press the key shown in brackets. Options that cannot be used right now are greyed out, with the reason beside them. The status box refreshes by itself every 30 seconds.',
            '[1] PLAY: the normal way to play. Gets the newest world, starts the game, waits, and uploads when you quit. Afterwards you can leave a short message for the next player.',
            '[2] FINISH SESSION: uploads your progress now and makes the world available. Use it if an upload failed or you played without pressing 1.',
            '[3] RESTORE A BACKUP: brings back an older copy, from this PC or from the last 5 uploads kept online.',
            '[4] FORCE CHECK-OUT: only when your friend forgot to finish and cannot do it. You get the last uploaded world. Whatever they played since then is out of sync and will not be in the shared world.',
            '[W] WAIT FOR WORLD TO BE UPLOADED: when your friend has it, leave this open. A Windows notification tells you the moment the world is available.',
            '[S] DESKTOP SHORTCUT: puts a shortcut to this tool on your desktop. Always start the game from it, not from Steam.',
            '[J] JOIN YOUR FRIEND: shown while your friend has the world. Starts the game and connects you to them as a guest. Nothing is checked out or uploaded by you.',
            '[A] ACTIVITY: who played when, for how long, and the message they left.',
            '[F] INVITE A FRIEND: shows the invite code for this world and copies a message you can send. Send it privately: the code is the key to the world.',
            '[M] WORLDS: the list of shared worlds on this PC. Switch to another one, add one with an invite or by sharing a world of your own, remove one from this PC, or delete one for everyone if you were the first to upload it.',
            '[D] DIAGNOSTICS: checks that everything is set up correctly and copies a report you can paste to whoever set this up. Names, keys and Steam IDs are taken out of it.',
            '[I] REPORT ISSUE: for a fault in the tool itself. Opens a new issue on GitHub in your browser with the same report filled in. You see it before anything is sent.')),
        @('PLAYING TOGETHER AT THE SAME TIME', @(
            'When you are both online you can still play together the normal way.',
            'ONE of you presses 1 here and hosts the world. The other opens this tool, sees CHECKED OUT BY the host, and presses J. That starts the game without checking anything out and connects it to the host, who must already be inside the world.',
            'Only the host has the world checked out, and only the host uploads at the end. The guest never needs to check anything out.',
            'Next time, either of you can be the one who presses 1.')),
        @('IF SOMETHING GOES WRONG', @(
            'Red or yellow text always says what happened and what to do next. Nothing is deleted without a backup first.',
            'NO INTERNET: the world stays checked out to you. Fix the connection and choose Finish session. Your friend just has to wait.',
            'YOU CLOSED THIS WINDOW WHILE PLAYING: the upload still happens in the background when you quit the game, and a Windows notification tells you how it went.',
            'STEAM CLOUD CONFLICT: when Steam asks, always choose the LOCAL files.',
            'MODS: a world made with Steam Workshop mods, which includes every Custom game, needs the same mods on every PC. Play lists any that are missing and opens their Workshop pages.',
            'YOU PLAYED WITHOUT THIS TOOL: open it and choose Finish session. It will warn you and ask before uploading.',
            "BACKUPS are in: $script:BackupDir",
            "A LOG of everything this tool did is in: $script:LogPath"))
    )
    for ($p = 0; $p -lt $pages.Count; $p++) {
        Show-Header ("Help {0} of {1}  -  {2}" -f ($p + 1), $pages.Count, $pages[$p][0])
        foreach ($para in $pages[$p][1]) { Say-Wrapped '  ' 'Text' $para; Say '' }
        if ($p -lt $pages.Count - 1) { Wait-Key 'Press any key for the next page' } else { Wait-Key }
    }
}

# ================================================================ background uploader, waiting, shortcut

function Start-Watchdog {
    # A hidden copy of this script that outlives the menu window. If the window is closed
    # while the game runs, it uploads the world when the game exits.
    try {
        $shell = (Get-Process -Id $PID).Path
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Action', 'watchdog', '-ParentPid', $PID, '-World', ('"{0}"' -f $script:Config.SaveName))
        Start-Process -FilePath $shell -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
    catch { Write-Log "could not start the background uploader: $($_.Exception.Message)" }
}

function Invoke-Watchdog {
    Write-Log "watchdog: started for window $ParentPid"
    while ($true) {
        do {
            while (Test-GameRunning) { Start-Sleep -Seconds 3 }
            Start-Sleep -Seconds 5
        } while (Test-GameRunning)
        # The game is closed. While the menu window lives, the upload is its job.
        $windowAlive = $false
        while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
            $windowAlive = $true
            if (Test-GameRunning) { Write-Log 'watchdog: a new session started from the window, leaving'; return }
            Start-Sleep -Seconds 2
        }
        if (-not (Test-GameRunning)) { break }
    }
    $state = Read-State
    if (-not $state -or $state.holder -ne $script:Player) { Write-Log 'watchdog: nothing to upload'; return }
    try {
        Exit-Turn
        Write-Log 'watchdog: uploaded after the window was closed'
        Show-Toast 'Scrap Mechanic Sync' 'The world is uploaded and available for the next player.'
    }
    catch {
        Write-Log ("watchdog: upload failed: " + (Get-ExceptionChain $_)[-1].Message)
        Show-Toast 'Scrap Mechanic Sync' 'The world was NOT uploaded. Open Scrap Mechanic Sync and press 2.'
    }
    Start-Sleep -Seconds 12
}

function Wait-ForAvailable {
    $interval = 60
    if ($env:SMSYNC_WAIT_SECONDS) { $interval = [int]$env:SMSYNC_WAIT_SECONDS }
    Say-Wrapped '  ' 'Text' 'Leave this window open. It looks once a minute and shows a Windows notification, with the usual notification sound, when the world has been uploaded. It does not check the world out for you.'
    $looks = 0
    while ($true) {
        $state = $null
        try { $state = Read-State } catch { Write-Log ("wait: " + (Get-ExceptionChain $_)[-1].Message) }
        $looks++
        if ($state -and -not $state.holder) {
            Show-Toast 'Scrap Mechanic Sync' 'The world is available. Open the menu and press 1 to play.'
            Say-Good 'The world is AVAILABLE. Go back to the menu and press 1 to play.'
            $c = Get-Current $state
            if ($c.note) { Say ''; Say-Wrapped ("      Message from {0}: " -f $c.by) 'Dim' $c.note 'Amber' }
            return
        }
        if ($state -and $state.holder -eq $script:Player) { Say-Step 'The world is already checked out to you.'; return }
        if (-not $script:Interactive -and $looks -ge 3) { Say-Step 'Still checked out. Stopped waiting.'; return }
        $who = 'unknown (no connection)'
        if ($state) { $who = "checked out by $($state.holder)" }
        Say ''
        Write-Seg @('      Waiting  ', 'Dim', $who, 'Bad', ("   last looked {0}   press any key to stop" -f (Get-Date -Format 'HH:mm:ss')), 'Dim')
        $until = (Get-Date).AddSeconds($interval)
        while ((Get-Date) -lt $until) {
            if ($script:Interactive -and [Console]::KeyAvailable) { [void][Console]::ReadKey($true); Say-Step 'Stopped waiting.'; return }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Find-GameExe {
    foreach ($library in (Get-SteamLibraries)) {
        $exe = Join-Path $library 'steamapps\common\Scrap Mechanic\Release\ScrapMechanic.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function New-DesktopShortcut {
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Scrap Mechanic - Sync.lnk'
    # The name used before 0.4.0.
    $old = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Scrap Mechanic (shared world).lnk'
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = Join-Path $PSScriptRoot 'Scrap Mechanic Sync.cmd'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = 'Play a shared Scrap Mechanic world'
    $exe = Find-GameExe
    if ($exe) { $shortcut.IconLocation = "$exe,0" }
    $shortcut.Save()
    Write-Log "desktop shortcut created: $path"
    return $path
}

function Request-ShortcutOnce {
    # Tests and the second-player simulator set SMSYNC_HOME, and must not touch the desktop.
    if ($env:SMSYNC_HOME -or -not $script:Interactive) { return }
    $marker = Join-Path $script:HomeDir 'shortcut-asked.txt'
    if (Test-Path -LiteralPath $marker) { return }
    Clear-Screen
    Show-Banner
    Say-Wrapped '  ' 'Text' 'To keep the shared world in sync, always start the game from this tool and never straight from Steam. A desktop shortcut makes that the easy thing to do.'
    if (Confirm-Yes 'Put a "Scrap Mechanic - Sync" shortcut on your desktop?') {
        try { [void](New-DesktopShortcut); Say-Good 'The shortcut is on your desktop.' } catch { Show-Error $_ }
        Wait-Key 'Press any key to continue'
    }
    Set-Content -LiteralPath $marker -Value (Get-Date -Format 'o') -Encoding ASCII
}

function Test-ConditionalWrites {
    # Writes a small object twice with "only if it does not exist". $true when the second
    # write is refused, which is what stops two players checking out at once. It also
    # proves the keys may write and delete.
    $key = "$script:Prefix/_doctor.txt"
    $body = [byte[]](120)
    try { [void](Invoke-Remote -Method 'DELETE' -Key $key) } catch { }
    [void](Invoke-Remote -Method 'PUT' -Key $key -Body $body -IfNoneMatch)
    $refused = $false
    try { [void](Invoke-Remote -Method 'PUT' -Key $key -Body $body -IfNoneMatch) }
    catch { if (Test-Conflict $_) { $refused = $true } else { throw } }
    [void](Invoke-Remote -Method 'DELETE' -Key $key)
    return $refused
}

function Invoke-Doctor {
    # Checks the things that cannot be seen from the menu.
    # Redacted on screen too: people post photos of this screen.
    Say-Step ("Version $script:Version. Save file: " + (Protect-Text $script:SavePath))
    [void](Read-State)
    Say-Good 'The online storage is reachable and the keys work.'
    $refused = Test-ConditionalWrites
    if ($refused) { Say-Good 'The storage honours conditional writes, so simultaneous check-outs are caught.' }
    else { Say-Bad 'The storage IGNORES conditional writes. Two players pressing Play in the same second would not be caught.' }
    try {
        $look = Get-NewerTag
        if ($look -eq 'off') { Say-Warn 'Automatic updates are switched off in the settings file.' }
        elseif ($look -eq 'dev') { Say-Step 'Developer copy (git repo): automatic updates are off.' }
        elseif ($look -eq 'current') { Say-Good 'The update check works. This is the newest version.' }
        else { Say-Warn "The update check works. Version $look installs at the next start." }
    }
    catch { Say-Bad ("The update check fails: " + (Get-ExceptionChain $_)[-1].Message) }
    $stored = Get-RemoteKeys
    Say-Good ("The storage holds {0} objects for this world." -f $stored.Count)
    $exe = Find-GameExe
    if ($exe) { Say-Good "Game found: $exe (build $(Get-GameBuild))" } else { Say-Warn 'Game not found through Steam. The desktop shortcut will use a plain icon.' }
}

# ================================================================ game version, storage listing, activity, diagnostics

function Get-GameBuild {
    # Steam's build number for the installed game. It only ever goes up, so it orders versions.
    if ($env:SMSYNC_GAME_BUILD) { return $env:SMSYNC_GAME_BUILD }
    try {
        $exe = Find-GameExe
        if (-not $exe) { return '' }
        # <library>\steamapps\common\Scrap Mechanic\Release\ScrapMechanic.exe
        $steamapps = Split-Path (Split-Path (Split-Path (Split-Path $exe)))
        $manifest = Join-Path $steamapps "appmanifest_$($script:SteamAppId).acf"
        if (Test-Path -LiteralPath $manifest) {
            $m = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"buildid"\s+"(\d+)"')
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    catch { }
    return ''
}

function Get-RemoteKeys {
    # Every object stored for this world.
    $keys = @(); $token = ''
    do {
        $query = @{ 'list-type' = '2'; 'prefix' = "$script:Prefix/" }
        if ($token) { $query['continuation-token'] = $token }
        $r = Invoke-Remote -Method 'GET' -Key '' -Query $query
        $xml = [xml]$r.Text
        foreach ($item in @($xml.ListBucketResult.Contents)) { if ($item) { $keys += [string]$item.Key } }
        $token = [string]$xml.ListBucketResult.NextContinuationToken
    } while ($token)
    return , $keys
}

function Remove-Orphans($History, [int]$Version) {
    # Deletes version files that the history no longer points at: leftovers from an upload
    # that failed half way, or from a delete that did not go through. Never fatal.
    try {
        $keep = @($History | ForEach-Object { Get-VersionKey $_ })
        foreach ($key in (Get-RemoteKeys)) {
            $m = [regex]::Match($key, '/v(\d{6})\.db(\.gz)?$')
            $stale = $m.Success -and ($keep -notcontains $key) -and ([int]$m.Groups[1].Value -le $Version)
            if ($stale -or $key.EndsWith('/_doctor.txt')) {
                [void](Invoke-Remote -Method 'DELETE' -Key $key)
                Write-Log "removed leftover object $key"
            }
        }
    }
    catch { Write-Log ("storage clean-up skipped: " + (Get-ExceptionChain $_)[-1].Message) }
}

function Show-Activity {
    $state = Read-State
    if (-not $state -or $state.sessions.Count -eq 0) { Say-Step 'No sessions have been recorded yet. They appear here after the next upload.'; return }
    Say '  The last sessions, newest first.' 'Dim'
    foreach ($s in $state.sessions) {
        $length = ''
        if ($s.minutes -gt 0) { $length = Format-Duration ([TimeSpan]::FromMinutes($s.minutes)) }
        Say ''
        Write-Seg @(('  ' + (Format-When $s.at).PadRight(20)), 'Text', $s.by.PadRight(16), 'Amber', $length.PadRight(10), 'Text', ("version {0}" -f $s.version), 'Dim')
        if ($s.note) { Say-Wrapped '      ' 'Text' ('"' + $s.note + '"') 'Dim' }
    }
}

function Protect-Text([string]$Text, [string[]]$Names) {
    # Removes what could identify a player or open the storage from text that is about to
    # leave this PC in a report: keys, the storage address, Steam IDs, the Windows user
    # name, player names, and the names of the world and the bucket.
    if (-not $Text) { return '' }
    $t = $Text
    $cfg = $script:Config
    foreach ($secret in @([string]$cfg.SecretAccessKey, [string]$cfg.AccessKeyId, [string]$cfg.GitHubToken)) {
        if ($secret -and $secret.Length -ge 8) { $t = $t.Replace($secret, '<key>') }
    }
    try { if ($cfg.Endpoint) { $t = $t.Replace(([Uri][string]$cfg.Endpoint).Host, '<storage address>') } } catch { }
    $t = [regex]::Replace($t, '(?i)(?<![0-9a-z])[0-9a-f]{32,}(?![0-9a-z])', '<hex>')
    $t = [regex]::Replace($t, 'User_\d{17}', 'User_<steam id>')
    $t = [regex]::Replace($t, '(?<!\d)7656\d{13}(?!\d)', '<steam id>')
    $t = [regex]::Replace($t, '(?i)([A-Z]:\\Users\\)[^\\"]+(?=\\)', '${1}<user>')
    # Whole words only, and nothing shorter than three characters, or ordinary text would be mangled.
    $words = @(
        @([string]$env:USERNAME, '<user>'), @([string]$env:COMPUTERNAME, '<pc>'),
        @([string]$cfg.SaveName, '<world>'), @([string]$script:Prefix, '<world>'), @([string]$cfg.Bucket, '<bucket>')
    )
    $n = 0
    foreach ($name in @($Names | Where-Object { $_ } | Select-Object -Unique)) { $n++; $words += , @([string]$name, "<player $n>") }
    foreach ($pair in $words) {
        if ($pair[0].Length -ge 3) { $t = [regex]::Replace($t, '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($pair[0]) + '(?![A-Za-z0-9])', $pair[1]) }
    }
    return $t
}

function Get-DiagnosticsReport {
    # Runs the checks on screen and returns the report with everything personal removed:
    # Head is the summary and the check results, Log the last lines of the log.
    $script:Transcript = New-Object 'System.Collections.Generic.List[string]'
    $names = @($script:Player)
    $world = 'unknown'
    try {
        Invoke-Doctor
        $state = Read-State
        if (-not $state) { $world = 'nothing uploaded yet' }
        elseif (-not $state.holder) { $world = 'available' }
        elseif ($state.holder -eq $script:Player) { $world = 'checked out by this player' }
        else { $world = 'checked out by another player' }
        if ($state) {
            $names += $state.holder
            foreach ($h in $state.history) { $names += $h.by }
            foreach ($s in $state.sessions) { $names += $s.by }
        }
    }
    catch { Show-Error $_; Add-Transcript ('XX  ' + (Get-ExceptionChain $_)[-1].Message) }
    $lines = @($script:Transcript)
    $script:Transcript = $null
    $console = 'classic console'; if ($env:WT_SESSION) { $console = 'Windows Terminal' }
    $head = @(
        "Scrap Mechanic Sync v$script:Version, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion), $console"
        "World: $world"
        ''
    ) + $lines
    $log = @(Get-Content -LiteralPath $script:LogPath -Tail 12 -ErrorAction SilentlyContinue)
    return @{
        Head = @($head | ForEach-Object { Protect-Text $_ $names })
        Log  = @($log | ForEach-Object { Protect-Text $_ $names })
    }
}

function Join-Report($Report, [string]$NewLine) {
    return ((@($Report.Head) + @('', 'Last log lines:') + @($Report.Log)) -join $NewLine)
}

function Copy-Report($Report) {
    # $true when the report reached the clipboard. Tests read it from SMSYNC_REPORT_FILE.
    $text = Join-Report $Report "`r`n"
    if ($env:SMSYNC_REPORT_FILE) { Set-Content -LiteralPath $env:SMSYNC_REPORT_FILE -Value $text -Encoding UTF8 }
    if ($env:SMSYNC_NO_CLIPBOARD) { return $false }
    try { Set-Clipboard -Value $text; return $true } catch { return $false }
}

function Show-Diagnostics {
    $report = Get-DiagnosticsReport
    if (Copy-Report $report) {
        Say-Good 'This report is copied. Paste it into a message to whoever set this up (Ctrl+V).'
        Say '      Names, keys, Steam IDs and your Windows user name have been taken out of it.' 'Dim'
    }
    elseif (-not $env:SMSYNC_NO_CLIPBOARD) { Say-Warn 'The report could not be copied. Take a photo of this window instead.' }
}

function Get-IssueUrl($Report) {
    # The new-issue page with the form already filled in. A link opened from Windows is cut
    # off at about 2,000 characters, so the oldest log lines are dropped until it fits.
    $repo = $script:DefaultRepo
    if ($script:Config.GitHubRepo) { $repo = [string]$script:Config.GitHubRepo }
    $base = "https://github.com/$repo/issues/new?template=bug_report.yml&version=" + [Uri]::EscapeDataString($script:Version) + '&diagnostics='
    $log = @($Report.Log)
    while ($true) {
        $text = (@($Report.Head) + @('', 'Last log lines:') + $log) -join "`n"
        $url = $base + [Uri]::EscapeDataString($text)
        if ($url.Length -le 1900 -or $log.Count -eq 0) { break }
        $log = @($log | Select-Object -Skip 1)
    }
    while ($url.Length -gt 1900) {
        $text = $text.Substring(0, $text.Length - 50)
        $url = $base + [Uri]::EscapeDataString($text)
    }
    return $url
}

function Send-IssueReport {
    Say-Wrapped '  ' 'Text' 'This runs the checks, builds a report and opens a new issue on GitHub in your browser with the report already filled in. Nothing is sent until you press the green button on that page. You need a GitHub account, which is free.'
    $report = Get-DiagnosticsReport
    Say ''
    Say '  THIS IS WHAT THE ISSUE WILL CONTAIN' 'Amber'
    Say ''
    foreach ($line in (@($report.Head) + @('', 'Last log lines:') + @($report.Log))) { Say-Wrapped '    ' 'Dim' $line 'Dim' }
    Say ''
    Say-Wrapped '  ' 'Text' 'Names, keys, Steam IDs, your Windows user name and the name of your world have been taken out. Read it through. The issue will be public.'
    $copied = Copy-Report $report
    if ($copied) { Say-Good 'The full report is also copied, in case the page shows it cut short (paste with Ctrl+V).' }
    if (-not (Confirm-Yes 'Open the issue page in your browser?')) { Say-Step 'Nothing was opened or sent.'; return }
    Write-Log 'opened the issue page'
    Open-Link (Get-IssueUrl $report)
    Say-Step 'On the page, describe what happened in your own words, then press "Create".'
}

# ================================================================ self-update

function Invoke-GitHub([string]$Path, [string]$OutFile) {
    # The repository is public, so no key is needed. A key left in an older settings file
    # is still sent, and dropped for the rest of this run once GitHub rejects it.
    $cfg = $script:Config
    $api = 'https://api.github.com'
    if ($cfg.GitHubApi) { $api = ([string]$cfg.GitHubApi).TrimEnd('/') }
    $repo = $script:DefaultRepo
    if ($cfg.GitHubRepo) { $repo = [string]$cfg.GitHubRepo }
    $token = [string]$cfg.GitHubToken
    if ($token -match 'PASTE_' -or $script:TokenRejected) { $token = '' }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    try {
        while ($true) {
            $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), "$api/repos/$repo$Path"
            try {
                [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'sm-sync')
                [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/vnd.github+json')
                if ($token) { [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $token") }
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -eq 401 -and $token) {
                    Write-Log 'the update key was rejected, carrying on without it'
                    $token = ''; $script:TokenRejected = $true
                    continue
                }
                if ($status -eq 403 -or $status -eq 429) { throw "GitHub is limiting requests from this connection (code $status). The next check will try again." }
                if ($status -eq 404) { throw "the update source $repo was not found (code 404)." }
                if ($status -lt 200 -or $status -ge 300) { throw "GitHub answered with code $status." }
                if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()); return $null }
                return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            finally { $request.Dispose() }
        }
    }
    finally { $client.Dispose() }
}

function Get-NewerTag {
    # Returns 'off', 'dev', 'current', or the name of a release tag newer than this copy.
    $cfg = $script:Config
    if ($null -ne $cfg.AutoUpdate -and -not [bool]$cfg.AutoUpdate) { return 'off' }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git')) { return 'dev' }

    $best = $null; $bestTag = ''
    # Assign first: Windows PowerShell 5.1 emits a JSON array as one object, and foreach unrolls it.
    $tags = (Invoke-GitHub '/tags?per_page=100') | ConvertFrom-Json
    foreach ($tag in $tags) {
        if ([string]$tag.name -match '^v(\d+\.\d+\.\d+)$') {
            $v = [version]$Matches[1]
            if (-not $best -or $v -gt $best) { $best = $v; $bestTag = [string]$tag.name }
        }
    }
    if (-not $best -or $best -le [version]$script:Version) { return 'current' }
    return $bestTag
}

function Update-Self {
    # Returns 'off', 'dev', 'current', or the tag name that was installed. Throws on failure.
    $bestTag = Get-NewerTag
    if ($bestTag -notmatch '^v\d') { return $bestTag }

    Say-Step "Updating to $bestTag ..."
    $work = Join-Path $script:HomeDir 'update'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $work)
    $zip = Join-Path $work 'update.zip'
    Invoke-GitHub "/zipball/$bestTag" $zip
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'files')
    $source = @(Get-ChildItem -LiteralPath (Join-Path $work 'files') -Directory)[0].FullName
    $newScript = Join-Path $source 'sm-sync.ps1'
    if (-not (Test-Path -LiteralPath $newScript)) { throw 'the downloaded update has no sm-sync.ps1 in it.' }

    # Never install a version that cannot at least load and pass its own self-test.
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($newScript, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "the downloaded update is broken (it does not load)." }
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoProfile -ExecutionPolicy Bypass -File $newScript -Action selftest -Plain | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'the downloaded update failed its self-test.' }

    # Only the files a player needs. README, dev scripts and git files stay in the repo.
    Get-ChildItem -LiteralPath $source -File |
        Where-Object { $_.Name -eq 'sm-sync.ps1' -or $_.Extension -in '.cmd', '.txt' } |
        Copy-Item -Destination $PSScriptRoot -Force
    Remove-Item -LiteralPath $work -Recurse -Force
    Write-Log "updated from $script:Version to $bestTag"
    return $bestTag
}

function Restart-Updated {
    # Hands over to the freshly installed script in this same window. It skips its own
    # launch check (it was just updated) but keeps checking while its menu is open.
    if ($script:Fancy) { Write-Host "$($script:E)[?25h" -NoNewline }
    & $PSCommandPath -UpdatedFrom $script:Version -Plain:$Plain
    exit $LASTEXITCODE
}

function Get-ChangesSince([string]$From) {
    # Reads CHANGES.txt: a version number alone on a line, then "- " lines describing it.
    $file = Join-Path $PSScriptRoot 'CHANGES.txt'
    $out = @()
    if (-not (Test-Path -LiteralPath $file)) { return , $out }
    $include = $false
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        if ($line -match '^(\d+\.\d+\.\d+)\s*$') {
            $v = [version]$Matches[1]
            $include = ($v -gt [version]$From) -and ($v -le [version]$script:Version)
            if ($include) { $out += "v$($Matches[1])" }
            continue
        }
        if ($include -and $line.Trim()) { $out += $line.Trim() }
    }
    return , $out
}

function Show-WhatsNew([string]$From) {
    Show-Header "Updated to version $script:Version"
    Say-Wrapped '  ' 'Text' "This tool has updated itself from version $From. Your world, your backups and your settings are untouched."
    $lines = Get-ChangesSince $From
    if ($lines.Count -gt 0) {
        Say ''
        Say '  WHAT IS NEW' 'Amber'
        foreach ($line in $lines) {
            if ($line -match '^v\d') { Say ''; Say "  $line" 'Orange' }
            else { Say-Wrapped '    -  ' 'Orange' ($line -replace '^-\s*', '') }
        }
    }
    Write-Log "showed what is new since $From"
    Wait-Key 'Press any key to continue'
}

function Invoke-UpdateCheck {
    # Returns the installed tag, or $null when nothing changed. Never throws.
    try {
        $result = Update-Self
        if ($result -match '^v\d') { return $result }
        if ($result -eq 'dev') { $script:Notice = 'Developer copy (git repo): automatic updates are off.' }
    }
    catch {
        $chain = Get-ExceptionChain $_
        $reason = $chain[$chain.Count - 1].Message
        Write-Log "update check failed: $reason"
        if (Test-NetworkError $_) { $script:Notice = 'Could not check for updates (no connection). Carrying on with this version.' }
        else { $script:Notice = "Update failed: $reason Carrying on with this version. Tell whoever set this up." }
    }
    return $null
}

# ================================================================ invite codes and setup

function New-InviteCode {
    # The storage settings as one line of text. Whoever has it can read and write the world.
    $c = $script:Config
    $bytes = [Text.Encoding]::UTF8.GetBytes((@([string]$c.Endpoint, [string]$c.Bucket, [string]$c.AccessKeyId, [string]$c.SecretAccessKey, [string]$c.SaveName, (Get-WorldType)) -join "`n"))
    $text = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return ('{0}:{1}:{2}' -f $script:InvitePrefix, $text, (Get-Sha256Hex $bytes).Substring(0, 6))
}

function Read-InviteCode([string]$Text) {
    # Finds an invite code anywhere in $Text, even when a chat app wrapped it over several
    # lines. Returns the world's settings, or $null when there is no complete code.
    if (-not $Text) { return $null }
    $m = [regex]::Match(($Text -replace '\s', ''), [regex]::Escape($script:InvitePrefix) + ':([A-Za-z0-9_-]+):([0-9a-f]{6})')
    if (-not $m.Success) { return $null }
    try {
        $b64 = $m.Groups[1].Value.Replace('-', '+').Replace('_', '/')
        $b64 += '=' * ((4 - $b64.Length % 4) % 4)
        $bytes = [Convert]::FromBase64String($b64)
        if ((Get-Sha256Hex $bytes).Substring(0, 6) -ne $m.Groups[2].Value) { return $null }
        $parts = [Text.Encoding]::UTF8.GetString($bytes) -split "`n"
        # Codes from 0.3.0 have no sixth part, the world type, and were always Survival.
        if ($parts.Count -lt 5 -or $parts.Count -gt 6) { return $null }
        $type = 'Survival'
        if ($parts.Count -eq 6) { $type = Get-TypeOf @{ Type = $parts[5] } }
        return [ordered]@{ Endpoint = $parts[0]; Bucket = $parts[1]; AccessKeyId = $parts[2]; SecretAccessKey = $parts[3]; SaveName = $parts[4]; Type = $type }
    }
    catch { return $null }
}

function Get-InviteMessage([string]$Code, $Mods) {
    $repo = $script:DefaultRepo
    if ($script:Config.GitHubRepo) { $repo = [string]$script:Config.GitHubRepo }
    $workshop = @(@($Mods) | Where-Object { $_ -and [string]$_.id -ne '0' })
    $lines = @(
        ("Join my shared Scrap Mechanic world ""{0}"" ({1}) with Scrap Mechanic Sync:" -f $script:Config.SaveName, (Get-WorldType))
        ''
        "1. Download https://github.com/$repo/releases/latest/download/Scrap-Mechanic-Sync.zip"
        '2. Right-click the zip, choose Extract All, and open the extracted folder.'
    )
    $n = 3
    if ($workshop.Count -gt 0) {
        $lines += "$n. This world needs these mods from the Steam Workshop. Open each link, press Subscribe, and let Steam download it:"
        foreach ($m in $workshop) { $lines += ('   - {0}: {1}' -f (Get-ModLabel $m), (Get-ModUrl $m)) }
        $n++
    }
    $lines += "$n. Double-click ""Scrap Mechanic Sync""."
    $lines += ("{0}. Copy this whole message, then press 1 for ""I have an invite code""." -f ($n + 1))
    $lines += @('', $Code, '', 'Keep this message private. The code is the key to our world.')
    return ($lines -join "`r`n")
}

function Show-Invite {
    # Shows the invite for the current world and waits for a key: Ctrl+C copies the whole
    # message, T writes it to a text file, anything else goes back.
    $code = New-InviteCode
    # The mods come from the last upload, so the message can list their Workshop pages.
    $mods = @()
    $script:Quiet = $true
    try { $st = Read-State; if ($st -and $st.history.Count -gt 0) { $mods = @((Get-Current $st).mods) } }
    catch { }
    finally { $script:Quiet = $false }
    $message = Get-InviteMessage $code $mods
    Say-Wrapped '  ' 'Text' 'An invite lets a friend join this shared world. They never need a Cloudflare account.'
    Say ''
    # One unbroken line, so it selects and pastes as one line however the window wraps it.
    Say "  $code" 'Orange'
    Say ''
    Say-Wrapped '  ' 'Text' 'Anyone who has this code can download, replace or delete the shared world. Send it in a private message, never in a public channel or a screenshot.' 'Amber'
    Say ''
    Write-Seg @('  [Ctrl+C] ', 'Orange', 'Copy the invite message   ', 'Text', '[T] ', 'Orange', 'Save it as a text file   ', 'Text', '[Esc] ', 'Orange', 'Back', 'Text')
    Say ''
    $what = 'the download link, the steps and the code'
    if (@($mods | Where-Object { $_ -and [string]$_.id -ne '0' }).Count -gt 0) { $what = 'the download link, the steps, the Workshop links for the mods this world needs, and the code' }
    Say-Wrapped '  ' 'Dim' "The message holds $what. Your friend copies the whole message and the tool finds the code in it." 'Dim'
    $previous = $false
    if ($script:Interactive) { $previous = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true }
    try {
        while ($true) {
            $choice = ''
            if ($script:Interactive) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::C) { $choice = 'C' } elseif ($key.Key -eq [ConsoleKey]::T) { $choice = 'T' }
            }
            else {
                $line = [Console]::ReadLine()
                if ($null -ne $line -and $line.Trim()) { $choice = $line.Trim().Substring(0, 1).ToUpperInvariant() }
            }
            if ($choice -eq 'C') {
                $copied = $false
                if (-not $env:SMSYNC_NO_CLIPBOARD) { try { Set-Clipboard -Value $message; $copied = $true } catch { } }
                if ($copied) { Say-Good 'Copied. Paste it into a private message to your friend (Ctrl+V).' }
                else { Say-Warn 'The message could not be copied. Press T to save it as a text file instead.' }
            }
            elseif ($choice -eq 'T') {
                $path = Join-Path $PSScriptRoot ("Invite - {0}.txt" -f $script:Prefix)
                Set-Content -LiteralPath $path -Value $message -Encoding UTF8
                Write-Log 'wrote the invite text file'
                Say-Good "Saved as: $path"
                Say '      It holds the key to the world. Keep it private and delete it when you no longer need it.' 'Dim'
                if (-not $env:SMSYNC_NO_LAUNCH) { try { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $path) } catch { } }
            }
            else { return }
        }
    }
    finally { if ($script:Interactive) { [Console]::TreatControlCAsInput = $previous } }
}

function Get-LocalWorlds {
    # Every Survival, Creative and Custom world on this PC, newest first.
    $root = Get-SaveRoot
    $found = @()
    if (Test-Path -LiteralPath $root) {
        foreach ($user in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'User_*')) {
            $base = Join-Path $user.FullName 'Save'
            foreach ($type in 'Survival', 'Creative', 'Custom') {
                $folder = Join-TypeFolder $base $type
                if (-not (Test-Path -LiteralPath $folder)) { continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.db' | Where-Object { $_.Extension -eq '.db' })) {
                    $f | Add-Member -NotePropertyName WorldType -NotePropertyValue $type -Force
                    $found += $f
                }
            }
        }
    }
    return , @($found | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
}

function ConvertTo-Endpoint([string]$Text) {
    # Accepts the S3 address Cloudflare shows (with or without a path), or the bare account ID.
    $t = $Text.Trim().Trim('"').Trim("'")
    if ($t -match '^[0-9a-fA-F]{32}$') { return ('https://{0}.r2.cloudflarestorage.com' -f $t.ToLowerInvariant()) }
    if ($t -notmatch '^https?://') {
        if ($t -match '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}') { $t = "https://$t" } else { return '' }
    }
    try { return ([Uri]$t).GetLeftPart([UriPartial]::Authority) } catch { return '' }
}

function Test-KeyValue([string]$Value, [int]$Length, [string]$Name) {
    # '' when $Value has the shape of a Cloudflare key, otherwise what is wrong with it.
    if ($Value -match '^[0-9a-fA-F]+$' -and $Value.Length -eq $Length) { return '' }
    if ($Value -match '^https?://') { return "That is a web address, which goes in the last box. This box needs the $Name." }
    if ($Length -eq 32 -and $Value -match '^[0-9a-fA-F]{64}$') { return 'That is the Secret Access Key (64 characters). This box needs the Access Key ID, the shorter value above it on the Cloudflare page.' }
    if ($Length -eq 64 -and $Value -match '^[0-9a-fA-F]{32}$') { return 'That is the Access Key ID (32 characters). This box needs the Secret Access Key, the longer value below it on the Cloudflare page.' }
    if ($Value.Length -lt 8) { return ("That has {0} character(s), so it looks typed, not pasted. The {1} has {2}. Copy it on the Cloudflare page and paste it here." -f $Value.Length, $Name, $Length) }
    if ($Value.Length -ne $Length) { return ("That has {0} characters and the {1} has {2}. If it is the 'Token value', that one is not needed. Copy the {1} and paste it here." -f $Value.Length, $Name, $Length) }
    return "The $Name is made of the digits 0-9 and the letters a-f only. Copy it again from the Cloudflare page."
}

function Test-EndpointValue([string]$Value) {
    $endpoint = ConvertTo-Endpoint $Value
    if (-not $endpoint) { return 'That is not a web address. It is the line under "Use jurisdiction-specific endpoints for S3 clients" and starts with https://.' }
    if ($endpoint -match 'cloudflare\.com' -and $endpoint -notmatch 'r2\.cloudflarestorage\.com$') { return 'That is a Cloudflare page, not the storage address. The one needed ends in r2.cloudflarestorage.com.' }
    return ''
}

function Say-Refused([string]$Why) { Say ''; Say-Wrapped '  !!  ' 'Amber' $Why 'Amber'; Say '' }

function Read-SetupValue([string]$Prompt, [scriptblock]$Check, [switch]$Mask) {
    # Asks until $Check accepts the entry: it returns '' to accept, or the reason it
    # refuses. Returns the entry, or $null when the player presses Esc.
    while ($true) {
        $value = Read-Text $Prompt -Mask:$Mask
        if ($null -eq $value) { return $null }
        if (-not $value) { Say-Refused 'Nothing was entered. Paste the value and press Enter, or press Esc to go back.'; continue }
        $why = & $Check $value
        if (-not $why) { return $value }
        Say-Refused $why
    }
}

function Say-Steps([string[]]$Steps) {
    $n = 0
    foreach ($step in $Steps) { $n++; Say-Wrapped ("    {0}.  " -f $n) 'Orange' $step; Say '' }
}

function Show-SetupHeader([int]$Step, [string]$Title) { Show-Header ("Setup {0} of 5  -  {1}" -f $Step, $Title) }

function Read-SetupKey([string]$Url) {
    # [O] opens $Url, [C] carries on, Esc goes back. Returns 'C' or 'ESC'.
    Write-Seg @('  [O] ', 'Orange', 'Open that page in your browser   ', 'Text', '[C] ', 'Orange', 'Continue   ', 'Text', '[Esc] ', 'Orange', 'Back', 'Text')
    while ($true) {
        $k = Read-Key 'OC' -Esc
        if ($k -eq 'O') { Open-Link $Url; continue }
        if ($k -eq 'C') { return 'C' }
        return 'ESC'
    }
}

function Select-SetupWorld {
    # Step 1 for a host. Returns the chosen save file, or $null when the player presses Esc.
    while ($true) {
        Show-SetupHeader 1 'Which world do you want to share?'
        $worlds = Get-LocalWorlds
        if ($worlds.Count -eq 0) {
            Say-Wrapped '  ' 'Text' 'No world was found on this PC. Start Scrap Mechanic, create a Survival, Creative or Custom world, quit the game, then look again.'
            Say ''
            Write-Seg @('  [R] ', 'Orange', 'Look again   ', 'Text', '[Esc] ', 'Orange', 'Back', 'Text')
            if ((Read-Key 'R' -Esc) -ne 'R') { return $null }
            continue
        }
        Say-Wrapped '  ' 'Text' 'These are the Survival, Creative and Custom worlds on this PC, the one played most recently first. Pick the one you and your friends will share. Your other worlds are not touched.'
        Say ''
        $pad = 2 + ($worlds | ForEach-Object { $_.BaseName.Length } | Measure-Object -Maximum).Maximum
        for ($i = 0; $i -lt $worlds.Count; $i++) {
            $detail = '{0,9}   last played {1}' -f (Format-Size $worlds[$i].Length), (Format-LocalTime $worlds[$i].LastWriteTime)
            $kind = ([string]$worlds[$i].WorldType).PadRight(10)
            if (Find-World $worlds[$i].BaseName) { Write-Seg @(("  [{0,2}] " -f ($i + 1)), 'Dim', $worlds[$i].BaseName.PadRight($pad), 'Dim', $kind, 'Dim', 'a shared world with this name is set up already', 'Dim') }
            else { Write-Seg @(("  [{0,2}] " -f ($i + 1)), 'Orange', $worlds[$i].BaseName.PadRight($pad), 'Text', $kind, 'Amber', $detail, 'Dim') }
        }
        Say ''
        Say '  Esc goes back.' 'Dim'
        Say ''
        while ($true) {
            $answer = Read-Text 'Number of the world:'
            if ($null -eq $answer) { return $null }
            $pick = 0
            if (-not ([int]::TryParse($answer, [ref]$pick)) -or $pick -lt 1 -or $pick -gt $worlds.Count) { Say-Refused ("Type a number from 1 to {0} and press Enter, or press Esc to go back." -f $worlds.Count); continue }
            if (Find-World $worlds[$pick - 1].BaseName) { Say-Refused 'A shared world with that name is already set up on this PC. Pick another one, or rename this world in the game first.'; continue }
            return $worlds[$pick - 1]
        }
    }
}

function Test-StorageSetup {
    # Throws with an explanation when the storage cannot be used with the settings in
    # $script:Config. Returns the world's state, or $null when nothing is stored yet.
    Say-Step 'Connecting to the storage ...'
    $state = $null
    try { $state = Read-State }
    catch {
        $sync = Get-SyncException $_
        if (-not ($sync -and $sync.Data.Contains('Deleted'))) { throw }
        # A world of this name was deleted here before. Clear the marker and start again.
        [void](Invoke-Remote -Method 'DELETE' -Key $script:StateKey)
        Say-Step 'A deleted world of the same name was cleared away.'
    }
    Say-Good 'The storage accepted the keys.'
    if (Test-ConditionalWrites) { Say-Good 'The keys can write, and the storage catches two players checking out at once.' }
    else { Say-Warn 'The keys can write, but this storage does not catch two players checking out in the same second. Cloudflare R2 does.' }
    return $state
}

function Get-KnownStorages {
    # One entry per distinct storage already set up on this PC, for a host adding another world.
    $seen = @{}; $out = @()
    foreach ($w in (Get-Worlds)) {
        $id = ([string]$w.Endpoint + '|' + [string]$w.Bucket).ToLowerInvariant()
        if (-not $seen[$id]) { $seen[$id] = $true; $out += , $w }
    }
    return , $out
}

function Invoke-HostSetup {
    # Walks a host through sharing a world. Returns the new world's settings once they are
    # saved, or $null when the player leaves. Esc goes back one stage.
    $w = [ordered]@{ Endpoint = ''; Bucket = ''; AccessKeyId = ''; SecretAccessKey = ''; SaveName = ''; Type = 'Survival'; SaveFolder = '' }
    $known = Get-KnownStorages
    $reused = $false
    $stage = 'world'
    while ($true) {
        if ($stage -eq 'world') {
            $file = Select-SetupWorld
            if (-not $file) {
                if (Confirm-Yes 'Leave the setup? Nothing has been saved.') { return $null }
                continue
            }
            $w.SaveName = $file.BaseName
            $w.Type = [string]$file.WorldType
            $w.SaveFolder = $file.DirectoryName
            if ($known.Count -gt 0) { $stage = 'storage' } else { $stage = 'bucket' }
        }
        elseif ($stage -eq 'storage') {
            Show-SetupHeader 2 'Where should it be kept?'
            Say-Wrapped '  ' 'Text' 'You already have storage set up. The new world can go in the same place, which skips every Cloudflare step.'
            Say ''
            for ($i = 0; $i -lt $known.Count; $i++) {
                Write-Seg @(("  [{0}] " -f ($i + 1)), 'Orange', ("The same storage as '{0}'" -f $known[$i].SaveName), 'Text', ("   bucket {0}" -f $known[$i].Bucket), 'Dim')
            }
            Write-Seg @('  [N] ', 'Orange', 'New storage', 'Text', '   a separate bucket and keys, about 10 minutes', 'Dim')
            Say ''
            Say-Wrapped '  ' 'Dim' 'Friends invited to either world then hold the same keys, so someone technical could reach both. Choose new storage to keep two groups fully apart.' 'Dim'
            Say ''
            Say '  Esc goes back.' 'Dim'
            $digits = ''; for ($i = 1; $i -le [Math]::Min(9, $known.Count); $i++) { $digits += [string]$i }
            $k = Read-Key ($digits + 'N') -Esc
            if ($k -eq 'ESC' -or $k -eq 'Q') { $stage = 'world' }
            elseif ($k -eq 'N') { $reused = $false; $stage = 'bucket' }
            else {
                $from = $known[[int]$k - 1]
                foreach ($field in 'Endpoint', 'Bucket', 'AccessKeyId', 'SecretAccessKey') { $w[$field] = [string]$from[$field] }
                $reused = $true; $stage = 'test'
            }
        }
        elseif ($stage -eq 'bucket') {
            Show-SetupHeader 2 'Create the online storage'
            Say-Wrapped '  ' 'Text' 'The world is kept in Cloudflare R2, an online storage service. Only you need an account. Your friends get an invite from you.'
            Say ''
            Say-Steps @(
                'Sign in at dash.cloudflare.com, or create a free account there.'
                'In the menu on the left, open "R2 Object Storage". The first time, Cloudflare asks for a payment card to switch R2 on. A shared world stays far inside the free allowance of 10 GB.'
                'Press "Create bucket". Name it scrap-mechanic, leave every other setting as it is, and create it.'
            )
            $back = 'world'; if ($known.Count -gt 0) { $back = 'storage' }
            if ((Read-SetupKey 'https://dash.cloudflare.com/?to=/:account/r2/overview') -ne 'C') { $stage = $back; continue }
            Say ''
            $name = $null
            while ($true) {
                $name = Read-Text 'Name of the bucket (Enter for scrap-mechanic, Esc to go back):'
                if ($null -eq $name) { break }
                if (-not $name) { $name = 'scrap-mechanic' }
                if ($name -cmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$') { break }
                Say-Refused 'A bucket name has 3 to 63 characters: small letters, digits and hyphens only. Type it exactly as Cloudflare shows it.'
            }
            if ($null -eq $name) { continue }
            $w.Bucket = $name
            $stage = 'keys'
        }
        elseif ($stage -eq 'keys') {
            Show-SetupHeader 3 'Create the keys'
            Say-Wrapped '  ' 'Text' 'The tool needs keys that can read and write that one bucket and nothing else in your account.'
            Say ''
            Say-Steps @(
                'On the "R2 Object Storage" page, look at the bottom right and press "Manage" beside "API Tokens". Then press "Create User API token".'
                'Change the token name to sm-sync-token.'
                'Permissions: choose "Object Read & Write".'
                ('Specify bucket(s): choose "Apply to specific buckets only" and pick ' + $w.Bucket + '.')
                'TTL: leave it on "Forever". Client IP Address Filtering: leave it empty.'
                'Press "Create User API Token". Cloudflare now shows the values ONCE. Copy these three into Notepad before you leave that page: the Access Key ID, the Secret Access Key, and the address under "Use jurisdiction-specific endpoints for S3 clients".'
                'Paste them below one at a time. Afterwards keep them only somewhere safe, such as a password manager, and close Notepad without saving.'
            )
            if ((Read-SetupKey 'https://dash.cloudflare.com/?to=/:account/r2/api-tokens') -ne 'C') { $stage = 'bucket'; continue }
            Say ''
            Say '  Paste with Ctrl+V or a right-click, then press Enter. Esc goes back.' 'Dim'
            Say ''
            $id = Read-SetupValue 'Access Key ID:' { param($v) Test-KeyValue $v 32 'Access Key ID' }
            if ($null -eq $id) { $stage = 'bucket'; continue }
            $secret = Read-SetupValue 'Secret Access Key:' { param($v) Test-KeyValue $v 64 'Secret Access Key' } -Mask
            if ($null -eq $secret) { $stage = 'bucket'; continue }
            $address = Read-SetupValue 'S3 address (starts with https://):' { param($v) Test-EndpointValue $v }
            if ($null -eq $address) { $stage = 'bucket'; continue }
            $w.AccessKeyId = $id; $w.SecretAccessKey = $secret; $w.Endpoint = ConvertTo-Endpoint $address
            $stage = 'test'
        }
        else {
            Show-SetupHeader 4 'Test the connection'
            Use-Config (Get-WorldConfig $w)
            try {
                $state = Test-StorageSetup
                if ($state) { Say-Warn "This storage already holds a world named '$($w.SaveName)'. Yours will not replace it. If that is a friend's world, leave the setup and use an invite code instead." }
                $script:Settings.Worlds = @((Get-Worlds)) + , $w
                Save-Settings
                Write-Log 'setup finished as host'
                Say-Good 'The settings are saved.'
                Wait-Key 'Press any key to continue'
                return $w
            }
            catch {
                Show-Error $_
                Say ''
                Write-Seg @('  [K] ', 'Orange', 'Enter the keys again   ', 'Text', '[B] ', 'Orange', 'Change the bucket name   ', 'Text', '[T] ', 'Orange', 'Test again   ', 'Text', '[Esc] ', 'Orange', 'Back', 'Text')
                $k = Read-Key 'KBT' -Esc
                if ($k -eq 'K') { $stage = 'keys' }
                elseif ($k -eq 'B') { $stage = 'bucket' }
                elseif ($k -ne 'T') { if ($reused) { $stage = 'storage' } else { $stage = 'keys' } }
            }
        }
    }
}

function Invoke-JoinSetup {
    # Adds a world from a friend's invite code. Returns its settings once saved, or $null.
    Show-Header 'Setup  -  Join with an invite code'
    $w = Read-InviteCode (Get-ClipboardText)
    if ($w) { Say-Good 'Found an invite code in your clipboard.' }
    else {
        Say-Wrapped '  ' 'Text' 'Copy the message your friend sent you, the whole of it. Then paste it here with Ctrl+V or a right-click and press Enter.'
        Say ''
        Say '  Esc goes back.' 'Dim'
        Say ''
        $text = Read-SetupValue 'Invite code:' { param($v) if (Read-InviteCode $v) { '' } else { 'That is not a complete invite code. It starts with ' + $script:InvitePrefix + ': and is one long line. Copy all of it and paste again.' } }
        if ($null -eq $text) { return $null }
        $w = Read-InviteCode $text
    }
    $existing = Find-World ([string]$w.SaveName)
    if ($existing) {
        if ([string]$existing.Endpoint -eq [string]$w.Endpoint -and [string]$existing.Bucket -eq [string]$w.Bucket) { Say-Step "The world '$($w.SaveName)' is already set up on this PC. Nothing was changed." }
        else { Say-Refused "A different shared world named '$($w.SaveName)' is already set up on this PC. The tool holds one shared world per name, so this one was not added. Ask your friend to rename their world in the game and share it again." }
        Wait-Key 'Press any key to go back'
        return $null
    }
    Use-Config (Get-WorldConfig $w)
    try {
        Say-Step 'Connecting to the storage ...'
        $state = Read-State
        if ($state) { Say-Good ("Connected. The shared world is '{0}', a {1} world, version {2}." -f $w.SaveName, (Get-TypeOf $w), $state.version) }
        else { Say-Warn "Connected, but nothing has been uploaded yet. Your friend has to upload '$($w.SaveName)' first." }
    }
    catch {
        Show-Error $_
        Say-Refused 'The code was read correctly but the storage did not accept it. Ask your friend for a new invite. Nothing was saved.'
        Use-NoWorld
        Wait-Key 'Press any key to go back'
        return $null
    }
    $script:Settings.Worlds = @((Get-Worlds)) + , $w
    Save-Settings
    Write-Log 'setup finished with an invite code'
    Say-Good 'The settings are saved.'
    Wait-Key 'Press any key to continue'
    return $w
}

function Complete-HostSetup {
    # The last step for a host, once the player name and the save path are known.
    Show-SetupHeader 5 'Upload the world and invite your friends'
    Say-Wrapped '  ' 'Text' "Your copy of '$($script:Config.SaveName)' is uploaded now as the starting point. From then on, every player starts the game from this tool."
    try { Exit-Turn }
    catch { Show-Error $_; Say-Refused 'You can upload later with [2] Finish session in the menu.' }
    Say ''
    Say ('  ' + ($script:Ch.H * ($script:W + 2))) 'Dim'
    Say ''
    Show-Invite
}

function Add-WorldInteractive([switch]$First) {
    # The welcome screen on a first run, and "Add a world" afterwards. Returns the world
    # that was added, already selected, or $null when the player backs out.
    while ($true) {
        if ((Get-Worlds).Count -ge 9) { Show-Header 'Add a world'; Say-Refused 'Nine shared worlds is the most one copy holds. Remove one first.'; Wait-Key; return $null }
        Use-NoWorld
        Clear-Screen
        Show-Banner
        if ($First) { Say '  Welcome. This copy is not set up yet.' 'Amber' } else { Say '  ADD A SHARED WORLD' 'Amber' }
        Say ''
        $hint = 'a friend already shares a world and sent me an invite'
        if (Read-InviteCode (Get-ClipboardText)) { $hint = 'an invite is in your clipboard, ready to use' }
        Write-Seg @('  [1] ', 'Orange', 'I have an invite code       ', 'Text', $hint, 'Dim')
        Write-Seg @('  [2] ', 'Orange', 'Set up a new shared world   ', 'Text', 'share one of my worlds with my friends', 'Dim')
        Say ''
        if ($First) { Write-Seg @('  [H] ', 'Orange', 'How this works   ', 'Text', '[Q] ', 'Orange', 'Quit', 'Text') }
        else { Write-Seg @('  [H] ', 'Orange', 'How this works   ', 'Text', '[Esc] ', 'Orange', 'Back', 'Text') }
        Say ''
        $k = Read-Key '12HQ' -Esc
        $added = $null; $isHost = $false
        if ($k -eq '1') { $added = Invoke-JoinSetup }
        elseif ($k -eq '2') { $added = Invoke-HostSetup; $isHost = $true }
        elseif ($k -eq 'H') { Show-Help; continue }
        else { return $null }
        if (-not $added) { continue }
        Initialize-Player
        Select-World $added
        Initialize-SavePath
        if ($isHost) { Complete-HostSetup }
        return $added
    }
}

# ================================================================ worlds

function Get-WorldStatus($W) {
    # One line for the Worlds screen: text and colour. Leaves $W selected.
    Select-World $W -Peek
    $script:Quiet = $true
    try {
        $state = Read-State
        if (-not $state) { return @('nothing uploaded yet', 'Amber') }
        if (-not $state.holder) { return @('AVAILABLE', 'Good') }
        if ($state.holder -eq $script:Player) { return @('CHECKED OUT BY YOU', 'Amber') }
        return @(("CHECKED OUT BY {0}" -f $state.holder.ToUpperInvariant()), 'Bad')
    }
    catch {
        $sync = Get-SyncException $_
        if ($sync -and $sync.Data.Contains('Deleted')) { return @('DELETED for everyone', 'Bad') }
        return @('could not be reached', 'Dim')
    }
    finally { $script:Quiet = $false }
}

function Test-WorldOwner($State) {
    # A world uploaded before 0.4.0 has no owner on record, and then anyone may delete it.
    if (-not $State.owner) { return $true }
    if ($State.owner -ne $script:Player) { return $false }
    $mine = ''
    if ($script:SavePath) { $mine = Get-MySteamId }
    return (-not $State.ownerSteamId -or -not $mine -or $State.ownerSteamId -eq $mine)
}

function Remove-WorldLocal($W, [switch]$KeepBackups) {
    $name = [string]$W.SaveName
    $script:Settings.Worlds = @((Get-Worlds) | Where-Object { [string]$_.SaveName -ne $name })
    if ([string]$script:Settings.LastWorld -eq $name) { $script:Settings.LastWorld = '' }
    Save-Settings
    $folder = Join-Path $script:BackupRoot (Get-WorldPrefix $name)
    if (-not $KeepBackups -and (Test-Path -LiteralPath $folder)) { Remove-Item -LiteralPath $folder -Recurse -Force }
    $invite = Join-Path $PSScriptRoot ("Invite - {0}.txt" -f (Get-WorldPrefix $name))
    if (Test-Path -LiteralPath $invite) { Remove-Item -LiteralPath $invite -Force }
    Write-Log 'removed a world from this PC'
}

function Confirm-WorldName($W, [string]$Action) {
    Say ''
    $typed = Read-Text ("Type the world's name ({0}) and press Enter to {1}. Esc cancels:" -f $W.SaveName, $Action)
    if ($null -ne $typed -and $typed -eq [string]$W.SaveName) { return $true }
    Say-Step 'Cancelled. Nothing was changed.'
    return $false
}

function Remove-WorldInteractive {
    $worlds = Get-Worlds
    Show-Header 'Remove or delete a world'
    for ($i = 0; $i -lt $worlds.Count; $i++) { Write-Seg @(("  [{0}] " -f ($i + 1)), 'Orange', [string]$worlds[$i].SaveName, 'Text') }
    Say ''
    Say '  Press the number of the world. Esc goes back.' 'Dim'
    $digits = ''; for ($i = 1; $i -le $worlds.Count; $i++) { $digits += [string]$i }
    $k = Read-Key $digits -Esc
    if ($k -notmatch '^\d$') { return }
    $w = $worlds[[int]$k - 1]
    $name = [string]$w.SaveName
    Select-World $w -Peek
    try { $script:Quiet = $true; Initialize-SavePath } catch { } finally { $script:Quiet = $false }
    $state = $null; $problem = ''
    $script:Quiet = $true
    try { $state = Read-State }
    catch {
        $sync = Get-SyncException $_
        if ($sync -and $sync.Data.Contains('Deleted')) { $problem = 'deleted' } else { $problem = 'offline' }
    }
    finally { $script:Quiet = $false }

    $mine = ($state -and $state.holder -eq $script:Player)
    $whyNotRemove = ''
    if ($mine) { $whyNotRemove = 'not now: it is checked out to you. Finish the session first.' }
    $whyNotDelete = ''
    if ($problem -eq 'deleted') { $whyNotDelete = 'it has already been deleted' }
    elseif ($problem -eq 'offline') { $whyNotDelete = 'not now: the storage could not be reached' }
    elseif (-not $state) { $whyNotDelete = 'nothing has been uploaded' }
    elseif ($state.holder) { $whyNotDelete = "not now: it is checked out by $($state.holder)" }
    elseif (-not (Test-WorldOwner $state)) { $whyNotDelete = "only $($state.owner), who first uploaded it, can do this" }

    Show-Header "World: $name"
    if ($whyNotRemove) { Write-Seg @('  [1] ', 'Dim', 'Remove it from this PC   ', 'Dim', $whyNotRemove, 'Dim') }
    else { Write-Seg @('  [1] ', 'Orange', 'Remove it from this PC   ', 'Text', 'forgets its keys and deletes its backups on this PC', 'Dim') }
    if ($whyNotDelete) { Write-Seg @('  [2] ', 'Dim', 'Delete it for everyone   ', 'Dim', $whyNotDelete, 'Dim') }
    else { Write-Seg @('  [2] ', 'Orange', 'Delete it for everyone   ', 'Text', 'removes the shared world from the online storage', 'Dim') }
    Say ''
    Say '  Esc goes back.' 'Dim'
    $valid = ''
    if (-not $whyNotRemove) { $valid += '1' }
    if (-not $whyNotDelete) { $valid += '2' }
    $k = Read-Key $valid -Esc
    if ($k -eq '1') {
        Say ''
        Say-Wrapped '  ' 'Text' "This forgets the keys for '$name' and deletes this PC's backups of it. The save in the game stays where it is. Nothing online is touched, and your friends are not affected. To get it back you need a new invite."
        if ($problem -eq 'offline') { Say-Refused 'The storage could not be reached, so the tool cannot check whether the world is checked out to you. If it is, your friends stay locked out until someone forces the check-out.' }
        if (Confirm-WorldName $w 'remove it from this PC') { Remove-WorldLocal $w; Say-Good "'$name' was removed from this PC." }
        Wait-Key 'Press any key to continue'
    }
    elseif ($k -eq '2') {
        Say ''
        Say-Wrapped '  ' 'Text' "This deletes '$name' from the online storage for EVERY player: all uploaded versions and the activity list. It cannot be undone." 'Amber'
        Say ''
        Say-Wrapped '  ' 'Text' 'The save in the game on each PC stays, and so do the backups on this PC. Every other player is told the world was deleted the next time they open the tool.'
        if (Confirm-WorldName $w 'delete it for everyone') {
            try {
                Remove-WorldOnline $state
                Remove-WorldLocal $w -KeepBackups
                Say-Good "'$name' was deleted from the online storage and removed from this tool."
                Say ("      Your backups of it are still in: " + (Join-Path $script:BackupRoot (Get-WorldPrefix $name))) 'Dim'
            }
            catch { Show-Error $_ }
        }
        Wait-Key 'Press any key to continue'
    }
}

function Remove-WorldOnline($State) {
    # First replaces the state with a marker, on condition that nobody changed it since it
    # was read, so a player who checked out a moment ago is never cut off. Then deletes
    # the stored versions.
    $doc = [ordered]@{ deleted = $true; deletedBy = $script:Player; deletedAt = [DateTime]::UtcNow.ToString('o')
        minVersion = '0.4.0'; writtenBy = "sm-sync $script:Version"; holder = ''; version = $State.version; history = @() }
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $doc -Depth 3))
    [void](Invoke-Remote -Method 'PUT' -Key $script:StateKey -Body $body -IfMatch $State.etag)
    Write-Log 'deleted the world online'
    Say-Step 'Deleting the stored versions ...'
    foreach ($key in (Get-RemoteKeys)) {
        if ($key -eq $script:StateKey) { continue }
        try { [void](Invoke-Remote -Method 'DELETE' -Key $key) } catch { Write-Log "could not delete $key" }
    }
}

function Show-Worlds {
    # The list of shared worlds. Returns the world to open, or $null to quit.
    while ($true) {
        $worlds = Get-Worlds
        if ($worlds.Count -eq 0) { return $null }
        Use-NoWorld
        Clear-Screen
        Show-Banner
        Say '  YOUR SHARED WORLDS' 'Amber'
        Say ''
        $last = 0
        for ($i = 0; $i -lt $worlds.Count; $i++) { if ([string]$worlds[$i].SaveName -eq [string]$script:Settings.LastWorld) { $last = $i } }
        $pad = 3 + ($worlds | ForEach-Object { ([string]$_.SaveName).Length } | Measure-Object -Maximum).Maximum
        for ($i = 0; $i -lt $worlds.Count; $i++) {
            $status = Get-WorldStatus $worlds[$i]
            $label = "[{0}] {1}{2}" -f ($i + 1), ([string]$worlds[$i].SaveName).PadRight($pad), (Get-TypeOf $worlds[$i]).PadRight(9)
            if ($i -eq $last -and $script:Interactive) { Write-Seg @('  ', 'Text', $label, 'Sel', ('  ' + $status[0]), $status[1]) }
            else { Write-Seg @('  ', 'Text', $label, 'Text', ('  ' + $status[0]), $status[1]) }
            Say ''
        }
        Use-NoWorld
        Write-Seg @('  [N] ', 'Orange', 'Add a world   ', 'Text', '[X] ', 'Orange', 'Remove or delete a world   ', 'Text', '[Q] ', 'Orange', 'Quit', 'Text')
        Say ''
        Say '  Press the number of a world, or Enter for the highlighted one.' 'Dim'
        $digits = ''; for ($i = 1; $i -le $worlds.Count; $i++) { $digits += [string]$i }
        $k = Read-Key ($digits + 'NXQ') -Enter
        if ($k -eq 'ENTER') { return $worlds[$last] }
        if ($k -match '^\d$') { return $worlds[[int]$k - 1] }
        if ($k -eq 'N') { $added = Add-WorldInteractive; if ($added) { return $added } }
        elseif ($k -eq 'X') { Remove-WorldInteractive }
        else { return $null }
    }
}

# ================================================================ menu

function Invoke-Screen([string]$Title, [scriptblock]$Body) {
    Show-Header $Title
    try { & $Body }
    catch { Show-Error $_ }
    Wait-Key
}

function Test-HolderRecent($State) {
    # True when the world was checked out within the last 12 hours, so its holder is
    # probably still playing and can be joined, not someone who forgot to finish.
    if (-not $State -or -not $State.holder -or -not $State.heldSince) { return $false }
    return (([DateTime]::UtcNow - (ConvertFrom-Iso $State.heldSince)).TotalHours -lt 12)
}

function Join-FriendGame {
    # Starts the game without a check-out and connects it to the holder's session.
    $state = Read-State
    $name = 'your friend'; $steamId = ''
    if ($state -and $state.holder -and $state.holder -ne $script:Player) { $name = $state.holder; $steamId = [string]$state.holderSteamId }
    $direct = $steamId -match '^\d{17}$'
    Say-Wrapped '  ' 'Text' "This starts Scrap Mechanic WITHOUT checking the world out. You play as a guest inside $name's game, and only $name uploads at the end."
    Say ''
    if ($state -and $state.history.Count -gt 0) {
        $missing = Get-MissingMods (Get-Current $state)
        if ($missing.Count -gt 0) {
            Say-Warn ('This world uses mods that are not installed on this PC: ' + (($missing | ForEach-Object { Get-ModLabel $_ }) -join ', ') + '.')
            Say-Wrapped '      ' 'Text' 'If the game will not let you join, subscribe to them in the Steam Workshop first, let Steam download them, and press J again:' 'Dim'
            foreach ($m in $missing) { Say ('      ' + (Get-ModUrl $m)) 'Dim' }
            Say ''
        }
    }
    if ($direct) {
        Say-Wrapped '  ' 'Text' "The game will connect to $name by itself. $name must already be inside the world for that to work."
        Say ''
        Say '  If you end up at the main menu instead:' 'Amber'
    }
    else { Say '  When the game is open:' 'Amber' }
    Say-Wrapped '    1.  ' 'Orange' 'Press Shift+Tab to open the Steam overlay, or open your Steam friends list.'
    Say-Wrapped '    2.  ' 'Orange' "Find $name, click the arrow beside their name and choose Join Game."
    Say ''
    Say-Wrapped '  ' 'Text' 'If Steam asks to "Launch Game with custom arguments", click Continue. That is this tool telling the game who to join.' 'Dim'
    Say-Wrapped '  ' 'Text' "Do not load the shared world yourself from the game's own menu. Right now only $name's copy is the real one." 'Dim'
    # The status box would otherwise warn about a game running without a check-out.
    $script:WarnedOutside = $true
    if (Test-GameRunning) { Say-Step 'Scrap Mechanic is already running. Join through the Steam friends list.'; return }
    if ($env:SMSYNC_NO_LAUNCH) { if ($direct) { Say-Step "Connecting to $name (Steam ID $steamId) ..." }; return }
    Say-Step "Starting Scrap Mechanic and connecting to $name ..."
    # Both options together, as the game's own documentation shows: the first joins a
    # session they host, the second a session they are in.
    if ($direct -and (Start-GameWith @('-connect_steam_id', $steamId, '-friend_steam_id', $steamId))) { return }
    Write-Log "launching as a guest of $name without a direct connection"
    Start-Process "steam://rungameid/$script:SteamAppId"
}
function Get-MenuItems($Model) {
    # The rows of the main menu for the current status. A row with a Why cannot be chosen.
    $other = ''
    if ($Model.Online -and $Model.State -and $Model.State.holder -and $Model.State.holder -ne $script:Player) { $other = $Model.State.holder }
    $why = ''
    if (-not $Model.Online) { $why = 'not now: no connection to the online storage' }
    elseif ($other) { $why = "not now: $other has the world checked out" }
    $items = @(
        @{ Key = '1'; Label = 'Play'; Desc = 'get the newest world, start the game, upload when you quit'; Why = $why }
        @{ Key = '2'; Label = 'Finish session'; Desc = 'upload your progress and make the world available'; Why = $why }
        @{ Key = '3'; Label = 'Restore a backup'; Desc = 'bring back an older copy of the world'; Why = $why }
    )
    if ($other) {
        $items += @{ Key = 'J'; Label = "Join $other in their game"; Desc = 'start the game and connect to them as a guest'; Why = '' }
        $items += @{ Key = 'W'; Label = 'Wait for world to be uploaded'; Desc = "notify me when $other has finished"; Why = '' }
        $items += @{ Key = '4'; Label = 'Force check-out'; Desc = 'if they forgot to finish (their progress goes out of sync)'; Why = '' }
    }
    return , $items
}

function Get-ModelSignature($Model) {
    # Anything that changes what the menu shows. A different value triggers a redraw.
    $game = [string]$Model.GameRunning
    if (-not $Model.Online) { return "offline|$game" }
    if (-not $Model.State) { return "empty|$($Model.Local)|$game" }
    $c = Get-Current $Model.State
    return ($Model.State.holder, $Model.State.heldSince, $c.version, $c.note, $Model.Local, $game) -join '|'
}
function Write-MenuBlock($Items, [int]$Selected, [switch]$Again) {
    # Draws the menu rows and the footer. With -Again it first moves the cursor back up
    # and draws over the previous copy, so moving the highlight does not redraw the screen.
    $footerLines = 5
    if ($Again -and $script:Fancy) { Write-Host "$($script:E)[$($Items.Count + $footerLines)A`r" -NoNewline }
    $pad = 2 + ($Items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum
    # Every row must fit on one line, or the cursor arithmetic above would be wrong.
    $room = [Math]::Max(10, (Get-ConsoleWidth) - 8 - $pad)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        $tail = $it.Desc; if ($it.Why) { $tail = $it.Why }
        if ($tail.Length -gt $room) { $tail = $tail.Substring(0, $room - 3) + '...' }
        if ($it.Why) { Write-Seg @("  [$($it.Key)] ", 'Dim', $it.Label.PadRight($pad), 'Dim', $tail, 'Dim') }
        elseif ($i -eq $Selected -and $script:Interactive) { Write-Seg @('  ', 'Text', ("[$($it.Key)] " + $it.Label.PadRight($pad - 2)), 'Sel', ('  ' + $tail), 'Text') }
        else { Write-Seg @("  [$($it.Key)] ", 'Orange', $it.Label.PadRight($pad), 'Text', $tail, 'Dim') }
    }
    Say ''
    Write-Seg @('  [A] ', 'Orange', 'Activity   ', 'Text', '[F] ', 'Orange', 'Invite a friend   ', 'Text', '[D] ', 'Orange', 'Diagnostics   ', 'Text', '[I] ', 'Orange', 'Report issue', 'Text')
    Write-Seg @('  [M] ', 'Orange', 'Worlds   ', 'Text', '[S] ', 'Orange', 'Shortcut   ', 'Text', '[R] ', 'Orange', 'Refresh   ', 'Text', '[H] ', 'Orange', 'Help   ', 'Text', '[Q] ', 'Orange', 'Quit', 'Text')
    Say ''
    if ($script:Interactive) { Say '  Up and Down arrows then Enter, or press a key.' 'Dim' } else { Say '  Press a key:' 'Amber' }
}

function Read-MenuChoice($Items, [int]$Selected, [string]$Signature) {
    # Returns the key of the chosen row or hotkey, or 'REFRESH' when the status changed.
    $keys = (($Items | Where-Object { -not $_.Why } | ForEach-Object { $_.Key }) -join '') + 'ADFIMSRHQ'
    if (-not $script:Interactive) { return (Read-Key $keys) }
    $nextLook = (Get-Date).AddSeconds(30)
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
                $step = 1; if ($key.Key -eq [ConsoleKey]::UpArrow) { $step = -1 }
                $next = $Selected
                for ($n = 0; $n -lt $Items.Count; $n++) {
                    $next = ($next + $step + $Items.Count) % $Items.Count
                    if (-not $Items[$next].Why) { break }
                }
                if ($next -ne $Selected -and -not $Items[$next].Why) { $Selected = $next; Write-MenuBlock $Items $Selected -Again }
            }
            elseif ($key.Key -eq [ConsoleKey]::Enter) {
                if ($Selected -ge 0 -and -not $Items[$Selected].Why) { return $Items[$Selected].Key }
            }
            else {
                $c = ([string]$key.KeyChar).ToUpperInvariant()
                if ($c.Length -eq 1 -and $keys.Contains($c)) { return $c }
            }
            continue
        }
        if ((Get-Date) -ge $nextLook) {
            $script:Quiet = $true
            try { $fresh = Get-StatusModel } finally { $script:Quiet = $false }
            if ((Get-ModelSignature $fresh) -ne $Signature) { return 'REFRESH' }
            $nextLook = (Get-Date).AddSeconds(30)
        }
        if (-not $NoUpdate -and -not $script:UpdatesOff -and (Get-Date) -ge $script:NextUpdateLook) {
            # A window left open still picks up a new release, within 15 minutes of it.
            $script:NextUpdateLook = (Get-Date).AddMinutes(15)
            $newer = ''
            try { $newer = Get-NewerTag } catch { Write-Log ("update look failed: " + (Get-ExceptionChain $_)[-1].Message) }
            if ($newer -match '^v\d') { return 'UPDATE' }
            if ($newer -eq 'off' -or $newer -eq 'dev') { $script:UpdatesOff = $true }
        }
        Start-Sleep -Milliseconds 80
    }
}

function Show-Menu {
    Request-ConsoleSize 120 42
    $script:NextUpdateLook = (Get-Date).AddMinutes(15)
    while ($true) {
        Update-Width
        $script:Quiet = $true
        try { $model = Get-StatusModel } finally { $script:Quiet = $false }
        $outside = $model.GameRunning -and -not ($model.Online -and $model.State -and ($model.State.holder -eq $script:Player))
        if ($outside -and -not $script:WarnedOutside) {
            Write-Log 'the game is running without a check-out'
            Show-Toast 'Scrap Mechanic Sync' 'The game is running but the world is not checked out to you. Fine as a guest, otherwise quit and press 1.'
        }
        $script:WarnedOutside = $outside
        $items = Get-MenuItems $model
        # Fit the window: drop the spacer rows in the status box first, then the big banner.
        $rows = Get-StatusRows $model
        $spacers = 0; foreach ($row in $rows) { if ($null -eq $row) { $spacers++ } }
        $rest = 1 + $items.Count + 5 + 1
        if ($script:Notice) { $rest += 1 + (Split-Wrap $script:Notice ($script:W - 2)).Count }
        $height = Get-ConsoleHeight
        $compact = (9 + $rows.Count + 2 + $rest) -gt $height
        $small = $compact -and ((9 + $rows.Count + 2 - $spacers + $rest) -gt $height)
        Clear-Screen
        Show-Banner -Small:$small
        if ($script:Notice) { Say-Wrapped '  ' 'Text' $script:Notice 'Amber'; Say '' }
        Show-StatusBox $model -Compact:$compact
        Say ''
        # Start on the row most likely wanted: Wait when a friend has the world, else the first usable one.
        $selected = -1
        for ($i = 0; $i -lt $items.Count; $i++) { if (-not $items[$i].Why) { $selected = $i; break } }
        $preferred = 'W'
        if ($model.State -and (Test-HolderRecent $model.State)) { $preferred = 'J' }
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].Key -eq $preferred) { $selected = $i } }
        if ($script:Fancy) { Write-Host "$($script:E)[?25l" -NoNewline }
        Write-MenuBlock $items $selected
        try { $choice = Read-MenuChoice $items $selected (Get-ModelSignature $model) }
        finally { if ($script:Fancy) { Write-Host "$($script:E)[?25h" -NoNewline } }
        switch ($choice) {
            '1' { Invoke-Screen 'Play' { Start-PlaySession } }
            '2' { Invoke-Screen 'Finish session' { Exit-Turn } }
            '3' { Invoke-Screen 'Restore a backup' { Restore-Backup } }
            '4' {
                Invoke-Screen 'Force check-out' {
                    Say-Wrapped '  ' 'Text' 'This is for when your friend has the world checked out, forgot to finish, and cannot do it now. You get the last uploaded world. Anything they played since then is out of sync and will not be in the shared world.' 'Amber'
                    Say ''
                    if ((Read-Line 'Type YES and press Enter to force the check-out:') -ceq 'YES') { [void](Enter-Turn -Override) }
                    else { Say-Step 'Cancelled. Nothing was changed.' }
                }
            }
            'W' { Invoke-Screen 'Wait for world to be uploaded' { Wait-ForAvailable } }
            'S' { Invoke-Screen 'Desktop shortcut' { $made = New-DesktopShortcut; Say-Good 'The shortcut is on your desktop.'; Say "      $made" 'Dim' } }
            'J' { Invoke-Screen 'Join your friend' { Join-FriendGame } }
            'A' { Invoke-Screen 'Activity' { Show-Activity } }
            'D' { Invoke-Screen 'Diagnostics' { Show-Diagnostics } }
            'F' { Show-Header 'Invite a friend'; try { Show-Invite } catch { Show-Error $_; Wait-Key } }
            'M' { $script:Notice = ''; return 'worlds' }
            'I' { Invoke-Screen 'Report an issue' { Send-IssueReport } }
            'H' { Show-Help }
            'R' { $script:Notice = '' }
            'UPDATE' {
                Show-Header 'Update'
                Say-Step 'A new version of this tool is available.'
                if (Invoke-UpdateCheck) { Restart-Updated }
            }
            'Q' { return 'quit' }
        }
    }
}

function Start-MenuLoop {
    # Opens a world's menu, and the Worlds screen between worlds. One world opens
    # directly. Two or more start on the Worlds screen, unless -World names one.
    $next = $null
    $showWorlds = $false
    if ($World) { $next = Resolve-World }
    while ($true) {
        $fresh = $false
        if (-not $next) {
            $worlds = Get-Worlds
            # The Worlds screen compares each world's holder with this player's name.
            if ($worlds.Count -gt 0) { Initialize-Player }
            if ($worlds.Count -eq 0) { $next = Add-WorldInteractive -First; $fresh = $true }
            elseif ($worlds.Count -eq 1 -and -not $showWorlds) { $next = $worlds[0] }
            else {
                $next = Show-Worlds
                if (-not $next -and (Get-Worlds).Count -eq 0) { continue }
            }
            if (-not $next) { return }
        }
        Initialize-Player
        Select-World $next
        Initialize-SavePath
        Request-ShortcutOnce
        $next = $null
        if ((Show-Menu) -ne 'worlds') { return }
        $showWorlds = $true
    }
}

# ================================================================ entry point

$exitCode = 0
try {
    if ($Action -eq 'selftest') { if (Invoke-SelfTest) { exit 0 } else { exit 1 } }
    try { $Host.UI.RawUI.WindowTitle = 'Scrap Mechanic Sync' } catch { }
    Write-Log "start v$script:Version action=$Action"
    Read-Settings
    Use-NoWorld

    if ($Action -eq 'update') {
        $result = Update-Self
        Say-Step "Update result: $result"
        exit 0
    }
    if ($Action -eq 'menu' -and -not $NoUpdate -and -not $UpdatedFrom) {
        if (Invoke-UpdateCheck) { Restart-Updated }
    }
    if ($UpdatedFrom) {
        if ($UpdatedFrom -eq $script:Version) {
            # The release did not carry a new version number. Stop checking, or this window
            # would install the same thing every 15 minutes.
            $script:UpdatesOff = $true
            $script:Notice = 'An update was installed but its version number did not change. Tell whoever set this up.'
        }
        else { Show-WhatsNew $UpdatedFrom }
    }

    if ($Action -eq 'setup') {
        # Adds a world, then carries on into the menu.
        $Action = 'menu'
        if ((Get-Worlds).Count -gt 0) {
            $added = Add-WorldInteractive
            if ($added) { $World = [string]$added.SaveName }
        }
    }
    if ($Action -eq 'menu') { Start-MenuLoop }
    else {
        $target = Resolve-World
        Initialize-Player
        Select-World $target
        Initialize-SavePath
        switch ($Action) {
            'wait'   { Wait-ForAvailable }
            'watchdog' { Invoke-Watchdog }
            'doctor' { Invoke-Doctor }
            'play'   { Start-PlaySession }
            'finish' { Exit-Turn -Override:$Force }
            'status' { Show-StatusPlain }
            'take'   { [void](Enter-Turn -Override) }
        }
    }
}
catch {
    Show-Error $_
    if ($Action -eq 'menu') { Wait-Key 'Press any key to close' }
    $exitCode = 1
}
finally {
    Close-Progress
    if ($script:Tray) { $script:Tray.Dispose() }
    if ($Action -eq 'menu') { Reset-Console }
}
exit $exitCode
