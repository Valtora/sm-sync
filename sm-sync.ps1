<#
sm-sync.ps1 - share one Scrap Mechanic survival save between players, one at a time.

The save lives in a Cloudflare R2 bucket as numbered versions, next to a state file that
records who holds the turn. Only the turn holder may play and upload.

Runs on Windows PowerShell 5.1 and PowerShell 7.
KEEP THIS FILE ASCII ONLY: Windows PowerShell 5.1 misreads UTF-8 without a BOM. Box and
block characters are built at runtime from their code points.

Normal use is the menu (double-click "Scrap Mechanic Sync.cmd").
Without the menu:  sm-sync.ps1 -Action play|finish|status|take|update|selftest
#>
[CmdletBinding()]
param(
    [ValidateSet('menu', 'play', 'finish', 'status', 'take', 'update', 'selftest')]
    [string]$Action = 'menu',
    [switch]$NoLaunch,     # play: take the turn and download, but do not start the game
    [switch]$Force,        # play/finish: override the other player's turn
    [switch]$Yes,          # answer yes to every confirmation
    [switch]$Plain,        # no colours, boxes or progress bars
    [switch]$NoUpdate,     # skip the update check
    [string]$UpdatedFrom   # set by the updater when it relaunches the new version
)

$ErrorActionPreference = 'Stop'

# Bump Version for every release and tag the commit v<Version>.
# Bump MinPeerVersion only when older copies must not touch the shared state any more.
$script:Version        = '0.1.0'
$script:MinPeerVersion = '0.1.0'

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
$script:BackupDir = Join-Path $script:HomeDir 'backups'
$script:LogPath = Join-Path $script:HomeDir 'sm-sync.log'
[void](New-Item -ItemType Directory -Force -Path $script:BackupDir)

# ================================================================ console

$script:Interactive = -not [Console]::IsInputRedirected
$script:Fancy = (-not $Plain) -and $Host.UI.SupportsVirtualTerminal -and ((-not [Console]::IsOutputRedirected) -or $env:SMSYNC_FORCE_FANCY)
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
            [void]$sb.Append("$($script:E)[38;2;$($script:Rgb[$Parts[$i + 1]])m").Append([string]$Parts[$i])
        }
        [void]$sb.Append("$($script:E)[K")
        Write-Host $sb.ToString() -NoNewline:$NoNewline
    }
    else {
        for ($i = 0; $i -lt $Parts.Count; $i += 2) {
            Write-Host ([string]$Parts[$i]) -NoNewline -ForegroundColor $script:Basic[$Parts[$i + 1]]
        }
        if (-not $NoNewline) { Write-Host '' }
    }
}

function Say([string]$Text = '', [string]$Color = 'Text') { Write-Seg @($Text, $Color) }
function Say-Step([string]$Text) { Write-Seg @('  > ', 'Orange', $Text, 'Text') }
function Say-Good([string]$Text) { Write-Seg @('  OK  ', 'Good', $Text, 'Text') }
function Say-Warn([string]$Text) { Write-Seg @('  !!  ', 'Amber', $Text, 'Amber') }
function Say-Bad([string]$Text)  { Write-Seg @('  XX  ', 'Bad', $Text, 'Bad') }

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
    if ($script:Fancy) { Write-Host "$($script:E)[48;2;$($script:Rgb.Bg)m$($script:E)[2J$($script:E)[3J$($script:E)[H" -NoNewline }
    else { Say ''; Say ('=' * 60) 'Dim' }
}

function Reset-Console {
    if ($script:Fancy) { Write-Host "$($script:E)[?25h$($script:E)[0m$($script:E)[2J$($script:E)[H" -NoNewline }
}

function Get-ConsoleWidth { try { return [Console]::WindowWidth } catch { return 100 } }

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

function Show-Banner {
    Say ''
    if ($script:Fancy -and (Get-ConsoleWidth) -ge 76) {
        for ($row = 0; $row -lt 5; $row++) {
            $line = '  '
            foreach ($letter in 'SCRAP MECHANIC'.ToCharArray()) { $line += $script:Font[[string]$letter][$row] + ' ' }
            Say ($line.Replace('#', $script:Ch.Block)) "G$row"
        }
    }
    else { Say '  SCRAP MECHANIC' 'Orange' }
    $world = '?'; if ($script:Config) { $world = $script:Config.SaveName }
    Write-Seg @('  S A V E   S Y N C', 'Amber', '     world ', 'Dim', $world, 'Text', '     v', 'Dim', $script:Version, 'Dim')
    Say ''
}

function Show-Header([string]$Title) {
    Clear-Screen
    Say ''
    Write-Seg @("  $($script:Ch.Block)$($script:Ch.Block) ", 'Orange', $Title.ToUpperInvariant(), 'Amber')
    Say ('  ' + ($script:Ch.H * ($script:W + 2))) 'Dim'
    Say ''
}

function Read-Key([string]$Valid) {
    while ($true) {
        if ($script:Interactive) { $c = ([string][Console]::ReadKey($true).KeyChar).ToUpperInvariant() }
        else {
            $line = [Console]::ReadLine()
            if ($null -eq $line) { return 'Q' }
            $line = $line.Trim()
            if (-not $line) { continue }
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

function Wait-Key([string]$Text = 'Press any key to go back to the menu') {
    if (-not $script:Interactive) { return }
    Say ''
    Say "  $Text" 'Dim'
    [void][Console]::ReadKey($true)
}

function Confirm-Yes([string]$Question) {
    if ($script:AssumeYes) { return $true }
    Write-Seg @("  $Question ", 'Amber', '[Y] yes   [N] no', 'Dim')
    return ((Read-Key 'YN') -eq 'Y')
}

function Show-Progress([string]$Label, [long]$Done, [long]$Total, [datetime]$Start, [switch]$Final) {
    if (-not $script:Fancy) { return }
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
    return (ConvertFrom-Iso $Iso).ToLocalTime().ToString('ddd d MMM HH:mm')
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
        [string]$AccessKey, [string]$SecretKey, [string]$Region, [string]$AmzDate
    )
    $lower = @{}
    foreach ($k in $Headers.Keys) { $lower[$k.ToLowerInvariant()] = ([string]$Headers[$k]).Trim() }
    $names = [string[]]@($lower.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)

    $canonicalHeaders = ''
    foreach ($n in $names) { $canonicalHeaders += $n + ':' + $lower[$n] + "`n" }
    $signedHeaders = $names -join ';'
    $canonicalRequest = @($Method, $CanonicalUri, '', $canonicalHeaders, $signedHeaders, $PayloadHash) -join "`n"

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
    # Published example from the AWS S3 Signature V4 documentation (GET object with a Range header).
    $auth = Get-SigV4Authorization -Method 'GET' -CanonicalUri '/test.txt' -PayloadHash $script:EmptyHash `
        -AccessKey 'AKIAIOSFODNN7EXAMPLE' -SecretKey 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' `
        -Region 'us-east-1' -AmzDate '20130524T000000Z' -Headers @{
            'host'                 = 'examplebucket.s3.amazonaws.com'
            'range'                = 'bytes=0-9'
            'x-amz-content-sha256' = $script:EmptyHash
            'x-amz-date'           = '20130524T000000Z'
        }
    $expected = 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41'
    if ($auth.EndsWith("Signature=$expected")) { Say-Good "Signing self-test passed (v$script:Version)."; return $true }
    Say-Bad "Signing self-test FAILED. Got: $auth"
    return $false
}

# ================================================================ remote storage

function Invoke-RemoteOnce {
    param([string]$Method, [string]$Key, [byte[]]$Body, [string]$InFile, [string]$OutFile, [string]$Label)

    $cfg = $script:Config
    $base = [Uri]($cfg.Endpoint.TrimEnd('/'))
    $encodedKey = (($Key -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $path = '/' + $cfg.Bucket + '/' + $encodedKey

    if ($InFile)             { $payloadHash = Get-FileSha256 $InFile }
    elseif ($null -ne $Body) { $payloadHash = Get-Sha256Hex $Body }
    else                     { $payloadHash = $script:EmptyHash }

    $amzDate = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $auth = Get-SigV4Authorization -Method $Method -CanonicalUri $path -PayloadHash $payloadHash `
        -AccessKey $cfg.AccessKeyId -SecretKey $cfg.SecretAccessKey -Region 'auto' -AmzDate $amzDate -Headers @{
            'host'                 = $base.Authority
            'x-amz-content-sha256' = $payloadHash
            'x-amz-date'           = $amzDate
        }

    $httpMethod = New-Object System.Net.Http.HttpMethod $Method
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList $httpMethod, ($base.GetLeftPart([UriPartial]::Authority) + $path)
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
            if ($status -ge 500 -or $status -eq 429) {
                throw (New-SyncError "The online storage is having trouble (code $status)." 'Wait a minute and try again. Nothing has been lost.' -Transient)
            }
            if ($text -match 'RequestTimeTooSkewed') {
                throw (New-SyncError 'The clock on this PC is wrong, so the storage refused the connection.' 'Open Windows Settings, Time and language, Date and time, and press "Sync now". Then try again.')
            }
            if ($text -match 'NoSuchBucket') {
                throw (New-SyncError 'The storage bucket named in sm-sync.config.json does not exist.' 'Check the "Bucket" value in sm-sync.config.json.')
            }
            if ($status -eq 401 -or $status -eq 403) {
                throw (New-SyncError 'The storage rejected the access keys.' 'Check AccessKeyId and SecretAccessKey in sm-sync.config.json, and that the clock on this PC is correct.')
            }
            throw (New-SyncError "The storage refused the request (code $status)." "Try again. If it keeps happening, send this file to whoever set this up: $script:LogPath")
        }
        return [pscustomobject]@{ Status = $status; Text = $text; Length = $length }
    }
    finally {
        Close-Progress
        if ($inStream) { $inStream.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Invoke-Remote {
    param([string]$Method, [string]$Key, [byte[]]$Body, [string]$InFile, [string]$OutFile, [string]$Label)
    $max = 3
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
                throw (New-SyncError 'Could not reach the online storage.' 'Check your internet connection, then try again. Nothing has been lost, and if you had the turn you still have it.')
            }
            Say-Warn "Connection problem. Trying again ($($attempt + 1) of $max) ..."
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Get-VersionKey([int]$Version) { return ('{0}/v{1:D6}.db' -f $script:Prefix, $Version) }

function Read-State {
    $r = Invoke-Remote -Method 'GET' -Key $script:StateKey
    if ($r.Status -eq 404) { return $null }
    $o = $r.Text | ConvertFrom-Json
    $min = [string]$o.minVersion
    if ($min -and ([version]$min -gt [version]$script:Version)) {
        throw (New-SyncError "This copy of the tool (v$script:Version) is too old for the shared world, which needs v$min or newer." 'Close this window and open the tool again so it can update. If it still says this, ask whoever set it up to send you a fresh copy.')
    }
    $history = @()
    foreach ($h in @($o.history)) {
        if ($h) {
            $history += @{ version = [int]$h.version; sha256 = [string]$h.sha256; size = [long]$h.size; by = [string]$h.by; at = (ConvertTo-IsoString $h.at) }
        }
    }
    return @{
        holder     = [string]$o.holder
        heldSince  = ConvertTo-IsoString $o.heldSince
        version    = [int]$o.version
        minVersion = $min
        history    = $history
    }
}

function Get-Current([hashtable]$State) { return $State.history[0] }

function Write-State([hashtable]$State) {
    $min = $script:MinPeerVersion
    if ($State.minVersion -and ([version]$State.minVersion -gt [version]$min)) { $min = $State.minVersion }
    $doc = [ordered]@{
        holder = $State.holder; heldSince = $State.heldSince; version = $State.version; minVersion = $min
        writtenBy = "sm-sync $script:Version"
        history = @($State.history | ForEach-Object { [ordered]@{ version = $_.version; sha256 = $_.sha256; size = $_.size; by = $_.by; at = $_.at } })
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 5
    [void](Invoke-Remote -Method 'PUT' -Key $script:StateKey -Body ([Text.Encoding]::UTF8.GetBytes($json)))
}

# ================================================================ local setup

function Initialize-Config {
    $path = Join-Path $PSScriptRoot 'sm-sync.config.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw (New-SyncError 'The settings file sm-sync.config.json is missing.' "It must sit in the same folder as this tool ($PSScriptRoot). If you set this up yourself, copy sm-sync.config.example.json to that name and fill it in. Otherwise ask whoever set it up to send the file again.")
    }
    try { $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw (New-SyncError 'The settings file sm-sync.config.json is damaged and cannot be read.' 'Ask whoever set this up to send the file again, and replace yours with it.') }
    foreach ($field in 'Endpoint', 'Bucket', 'AccessKeyId', 'SecretAccessKey', 'SaveName') {
        $value = [string]$cfg.$field
        if (-not $value -or $value -match 'YOUR_|PASTE_') {
            throw (New-SyncError "The settings file is not finished: '$field' has not been filled in." 'Open sm-sync.config.json in Notepad and paste the missing value in.')
        }
    }
    $script:Config = $cfg
    $script:Prefix = ($cfg.SaveName -replace '[^A-Za-z0-9_-]', '_')
    $script:StateKey = "$script:Prefix/state.json"
    $script:Http = New-Object System.Net.Http.HttpClient
    $script:Http.Timeout = [TimeSpan]::FromMinutes(30)
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

function Initialize-SavePath {
    $fileName = $script:Config.SaveName + '.db'
    $folder = [string]$script:Config.SaveFolder
    $cache = Join-Path $script:HomeDir 'savefolder.txt'
    if (-not $folder -and (Test-Path -LiteralPath $cache)) {
        $cached = (Get-Content -LiteralPath $cache -Raw).Trim()
        if (Test-Path -LiteralPath $cached) { $folder = $cached }
    }
    if (-not $folder) {
        $root = Join-Path $env:APPDATA 'Axolot Games\Scrap Mechanic\User'
        $candidates = @()
        if (Test-Path -LiteralPath $root) {
            $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'User_*' |
                ForEach-Object { Join-Path $_.FullName 'Save\Survival' } |
                Where-Object { Test-Path -LiteralPath $_ })
        }
        if ($candidates.Count -eq 0) {
            throw (New-SyncError 'Could not find the Scrap Mechanic save folder on this PC.' 'Start Scrap Mechanic once, create any Survival world, quit the game, and open this tool again.')
        }
        $withSave = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ $fileName) })
        if ($withSave.Count -ge 1) { $candidates = $withSave }
        if ($candidates.Count -eq 1) { $folder = $candidates[0] }
        else {
            Say ''
            Say '  More than one Steam account has Scrap Mechanic saves on this PC. Which is yours?' 'Amber'
            for ($i = 0; $i -lt $candidates.Count; $i++) { Write-Seg @(("  [{0}] " -f ($i + 1)), 'Orange', $candidates[$i], 'Text') }
            $pick = 0
            while ($pick -lt 1 -or $pick -gt $candidates.Count) { [void][int]::TryParse((Read-Line 'Number:'), [ref]$pick) }
            $folder = $candidates[$pick - 1]
        }
        Set-Content -LiteralPath $cache -Value $folder -Encoding UTF8
    }
    $script:SavePath = Join-Path $folder $fileName
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

function Publish-Save([hashtable]$State) {
    # Uploads the local save as a new version and frees the turn.
    if (-not (Test-Path -LiteralPath $script:SavePath)) {
        throw (New-SyncError 'There is no save on this PC to upload.' "Expected to find it at: $script:SavePath")
    }
    Wait-FileUnlocked $script:SavePath
    Assert-SaveHealthy $script:SavePath
    $hash = Get-FileSha256 $script:SavePath
    $size = (Get-Item -LiteralPath $script:SavePath).Length

    $history = @(); $version = 0; $min = ''
    if ($State) { $history = @($State.history); $version = $State.version; $min = $State.minVersion }
    $dropped = @()

    if ($history.Count -gt 0 -and $history[0].sha256 -eq $hash) {
        Say-Step 'The world has not changed since the last upload, so there is nothing to send.'
    }
    else {
        $version++
        $key = Get-VersionKey $version
        [void](Invoke-Remote -Method 'PUT' -Key $key -InFile $script:SavePath -Label 'Uploading')
        $head = Invoke-Remote -Method 'HEAD' -Key $key
        if ($head.Status -ne 200 -or $head.Length -ne $size) {
            throw (New-SyncError 'The upload did not arrive in one piece.' 'You still have the turn. Choose Finish session to send it again.')
        }
        $entry = @{ version = $version; sha256 = $hash; size = $size; by = $script:Player; at = [DateTime]::UtcNow.ToString('o') }
        $history = @($entry) + $history
        if ($history.Count -gt $script:KeepOnline) {
            $dropped = @($history | Select-Object -Skip $script:KeepOnline)
            $history = @($history | Select-Object -First $script:KeepOnline)
        }
    }

    Write-State @{ holder = ''; heldSince = ''; version = $version; minVersion = $min; history = $history }
    Write-Log "published version $version ($size bytes) and freed the turn"
    foreach ($old in $dropped) {
        try { [void](Invoke-Remote -Method 'DELETE' -Key (Get-VersionKey $old.version)) }
        catch { Write-Log "could not delete old version $($old.version)" }
    }
    Say-Good 'The world is uploaded and the turn is free.'
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
    $temp = $script:SavePath + '.download'
    [void](Invoke-Remote -Method 'GET' -Key (Get-VersionKey $Entry.version) -OutFile $temp -Label 'Downloading')
    if ((Get-FileSha256 $temp) -ne $Entry.sha256) {
        Remove-Item -LiteralPath $temp -Force
        throw (New-SyncError 'The download was damaged on the way.' 'Nothing on this PC was changed. Try again in a minute.')
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
    return (Read-State)
}

function Set-Holder([hashtable]$State) {
    $State.holder = $script:Player
    $State.heldSince = [DateTime]::UtcNow.ToString('o')
    Write-State $State
    Write-Log 'took the turn'
}

function Enter-Turn([switch]$Override) {
    # Takes the turn and brings the local save up to date. Returns $true when it is safe to play.
    Assert-GameClosed
    Say-Step 'Checking who has the world ...'
    $state = Get-OrSeedState
    if (-not $state) { return $false }

    if ($state.holder -eq $script:Player) {
        Say-Step 'You already have the turn. Using the save on this PC.'
        return $true
    }
    if ($state.holder) {
        if (-not $Override) {
            Say-Bad ("{0} has the world (since {1}, {2})." -f $state.holder, (Format-When $state.heldSince), (Format-Ago $state.heldSince))
            Say-Wrapped '      ' 'Text' 'Wait until they finish. If they forgot and cannot do it now, use "Take over the turn" in the menu.' 'Dim'
            return $false
        }
        Say-Warn ("Taking the turn away from {0}. Anything they played since {1} is left out of the shared world." -f $state.holder, (Format-When (Get-Current $state).at))
        Write-Log "forced takeover from $($state.holder)"
    }
    if (-not (Receive-Save (Get-Current $state))) { return $false }
    Set-Holder $state
    Say-Good 'You now have the turn.'
    return $true
}

function Exit-Turn([switch]$Override) {
    Assert-GameClosed
    $state = Get-OrSeedState
    if (-not $state) { return }
    if ($state.holder -and $state.holder -ne $script:Player -and -not $Override) {
        Say-Bad ("{0} has the turn, so your copy cannot be uploaded." -f $state.holder)
        return
    }
    if (-not $state.holder) {
        if ((Test-Path -LiteralPath $script:SavePath) -and (Get-FileSha256 $script:SavePath) -eq (Get-Current $state).sha256) {
            Say-Step 'Nothing to do. The turn is free and this PC matches the shared world.'
            return
        }
        Say-Warn 'You did not take the turn before playing.'
        if (-not (Confirm-Yes 'Upload your copy anyway and make it the shared world?')) { return }
    }
    Publish-Save $state
}

function Start-PlaySession {
    if (-not (Enter-Turn -Override:$Force)) { return }
    if ($NoLaunch) { return }

    Say ''
    Say-Step 'Starting Scrap Mechanic ...'
    Start-Process "steam://rungameid/$script:SteamAppId"
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-GameRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-GameRunning)) {
        Say-Warn 'The game did not start.'
        Say-Wrapped '      ' 'Text' 'You still have the turn. Start the game yourself from Steam, and when you are done playing choose Finish session.' 'Dim'
        return
    }
    Say ''
    Say-Good 'The game is running.'
    Say ''
    Say '      LEAVE THIS WINDOW OPEN.' 'Amber'
    Say '      It uploads the world by itself when you quit the game.' 'Text'
    Say '      If Steam asks about a Cloud conflict, choose the LOCAL files.' 'Dim'
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
    Say ''
    Say-Step 'The game has closed. Uploading the world ...'
    try { Exit-Turn }
    catch {
        Show-Error $_
        Say ''
        Say-Warn 'The world was NOT uploaded. You still have the turn. Choose Finish session to try again.'
    }
}

function Get-StatusModel {
    $m = @{ Online = $true; State = $null; Local = 'none' }
    try { $m.State = Read-State }
    catch { $m.Online = $false; $m.Problem = $_; return $m }
    if (Test-Path -LiteralPath $script:SavePath) {
        if ($m.State -and (Get-FileSha256 $script:SavePath) -eq (Get-Current $m.State).sha256) { $m.Local = 'same' } else { $m.Local = 'different' }
    }
    return $m
}

function Show-StatusBox($Model) {
    Write-BoxTop 'WORLD STATUS'
    Write-BoxRow @('You       ', 'Dim', $script:Player, 'Text')
    $hint = ''; $hintColor = 'Text'
    if (-not $Model.Online) {
        $sync = Get-SyncException $Model.Problem
        $what = 'Could not reach the online storage.'; if ($sync) { $what = $sync.Message }
        Write-BoxRow @('Turn      ', 'Dim', 'UNKNOWN', 'Bad')
        $hint = "$what Press R to try again."; $hintColor = 'Bad'
    }
    elseif (-not $Model.State) {
        Write-BoxRow @('Turn      ', 'Dim', 'nothing shared yet', 'Amber')
        $hint = 'Press 2 to upload the world from this PC as the starting point.'
    }
    else {
        $s = $Model.State; $c = Get-Current $s
        if ($s.holder -eq $script:Player) {
            Write-BoxRow @('Turn      ', 'Dim', 'YOU have the world', 'Amber', ("   since {0} ({1})" -f (Format-When $s.heldSince), (Format-Ago $s.heldSince)), 'Dim')
            $hint = 'Press 1 to keep playing, or 2 to upload and hand the world over.'
        }
        elseif ($s.holder) {
            Write-BoxRow @('Turn      ', 'Dim', ("{0} has the world" -f $s.holder.ToUpperInvariant()), 'Bad', ("   since {0} ({1})" -f (Format-When $s.heldSince), (Format-Ago $s.heldSince)), 'Dim')
            $hint = "Wait for $($s.holder) to finish. Do not play until the turn is free."; $hintColor = 'Bad'
        }
        else {
            Write-BoxRow @('Turn      ', 'Dim', 'FREE', 'Good')
            $hint = 'Ready. Press 1 to play.'; $hintColor = 'Good'
        }
        Write-BoxRow @('Shared    ', 'Dim', ("version {0}" -f $c.version), 'Text', ("   {0} ({1}) by {2}   {3}" -f (Format-When $c.at), (Format-Ago $c.at), $c.by, (Format-Size $c.size)), 'Dim')
        switch ($Model.Local) {
            'same'      { Write-BoxRow @('This PC   ', 'Dim', 'up to date', 'Good') }
            'different' { Write-BoxRow @('This PC   ', 'Dim', 'different from the shared world', 'Amber') }
            default     { Write-BoxRow @('This PC   ', 'Dim', 'no copy yet', 'Dim') }
        }
    }
    Write-BoxRow @('', 'Text')
    foreach ($line in (Split-Wrap $hint ($script:W - 4))) { Write-BoxRow @($line, $hintColor) }
    Write-BoxBottom
}

function Show-StatusPlain {
    $m = Get-StatusModel
    if (-not $m.Online) { throw $m.Problem }
    Say "  You are:      $script:Player"
    if (-not $m.State) { Say '  Shared world: nothing uploaded yet' 'Amber'; return }
    $s = $m.State; $c = Get-Current $s
    if ($s.holder -eq $script:Player) { Say ("  Turn:         YOU hold it (since {0})" -f (Format-When $s.heldSince)) 'Amber' }
    elseif ($s.holder) { Say ("  Turn:         {0} holds it (since {1})" -f $s.holder, (Format-When $s.heldSince)) 'Bad' }
    else { Say '  Turn:         free' 'Good' }
    Say ("  Last upload:  {0} by {1} (version {2}, {3})" -f (Format-When $c.at), $c.by, $c.version, (Format-Size $c.size))
    Say ("  Online:       versions {0}" -f (($s.history | ForEach-Object { $_.version }) -join ', '))
    Say "  Your copy:    $($m.Local)"
}

function Restore-Backup {
    Assert-GameClosed
    $state = Read-State
    if ($state -and $state.holder -and $state.holder -ne $script:Player) {
        Say-Bad "$($state.holder) has the turn. You can restore when the turn is free or yours."
        return
    }
    $items = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $script:BackupDir -Filter '*.db' | Sort-Object LastWriteTime -Descending)) {
        $items += @{ Where = 'this PC'; When = $f.LastWriteTime; Size = $f.Length; Note = ($f.BaseName -replace '^.*_\d{8}-\d{6}_', ''); File = $f.FullName }
    }
    if ($state) {
        foreach ($h in $state.history) {
            $items += @{ Where = 'online'; When = (ConvertFrom-Iso $h.at).ToLocalTime(); Size = $h.size; Note = "version $($h.version) by $($h.by)"; Entry = $h }
        }
    }
    if ($items.Count -eq 0) { Say-Step 'There are no backups yet.'; return }
    $items = @($items | Sort-Object { $_.When } -Descending)
    Say '  Pick the copy to bring back. Newest first.' 'Text'
    Say ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        Write-Seg @(("  [{0,2}] " -f ($i + 1)), 'Orange', $it.When.ToString('ddd dd MMM HH:mm'), 'Text', ("  {0,-8}" -f $it.Where), 'Amber', ("  {0,9}  " -f (Format-Size $it.Size)), 'Dim', $it.Note, 'Dim')
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
    Say-Good 'Restored on this PC, and you have the turn.'
    Say-Wrapped '      ' 'Text' 'Press 1 to check it in the game. It becomes the shared world when you finish the session.' 'Dim'
}

function Show-Help {
    $pages = @(
        @('HOW IT WORKS', @(
            'There is ONE copy of the world, kept online. Think of it as a physical save disk that you and your friend pass back and forth.',
            'Whoever has the disk has "the turn". Only that person can play. When they finish, the disk goes back online and the turn is free.',
            'This tool does the passing for you. Play fetches the newest world and takes the turn. When you quit the game it sends the world back.',
            'If you both played at the same time there would be two different worlds and one would have to be thrown away. The turn stops that from happening.')),
        @('THE MENU', @(
            '[1] PLAY: the normal way to play. Gets the newest world, starts the game, waits, and uploads when you quit. Leave the window open.',
            '[2] FINISH SESSION: uploads now and frees the turn. Use it if the window was closed while you played, or if an upload failed.',
            '[3] RESTORE A BACKUP: brings back an older copy, from this PC or from the last 5 uploads kept online.',
            '[4] TAKE OVER THE TURN: only when your friend forgot to finish and cannot do it. Whatever they played and did not upload is left out.')),
        @('IF SOMETHING GOES WRONG', @(
            'Red or yellow text always says what happened and what to do next. Nothing is deleted without a backup first.',
            'NO INTERNET: you keep the turn. Fix the connection and choose Finish session. Your friend just has to wait.',
            'STEAM CLOUD CONFLICT: when Steam asks, always choose the LOCAL files.',
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

# ================================================================ self-update

function Invoke-GitHub([string]$Path, [string]$OutFile) {
    $cfg = $script:Config
    $api = 'https://api.github.com'
    if ($cfg.GitHubApi) { $api = ([string]$cfg.GitHubApi).TrimEnd('/') }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $request = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), "$api/repos/$($cfg.GitHubRepo)$Path"
    try {
        [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'sm-sync')
        [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/vnd.github+json')
        [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($cfg.GitHubToken)")
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -eq 401 -or $status -eq 403 -or $status -eq 404) { throw "the update key was rejected (code $status). It may have expired." }
        if ($status -lt 200 -or $status -ge 300) { throw "GitHub answered with code $status." }
        if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()); return $null }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally { $request.Dispose(); $client.Dispose() }
}

function Update-Self {
    # Returns 'off', 'dev', 'current', or the tag name that was installed. Throws on failure.
    $cfg = $script:Config
    if (-not $cfg.GitHubRepo -or -not $cfg.GitHubToken -or ([string]$cfg.GitHubToken) -match 'PASTE_') { return 'off' }
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

    Copy-Item -Path (Join-Path $source '*') -Destination $PSScriptRoot -Recurse -Force
    Remove-Item -LiteralPath $work -Recurse -Force
    Write-Log "updated from $script:Version to $bestTag"
    return $bestTag
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

# ================================================================ menu

function Invoke-Screen([string]$Title, [scriptblock]$Body) {
    Show-Header $Title
    try { & $Body }
    catch { Show-Error $_ }
    Wait-Key
}

function Show-Menu {
    while ($true) {
        Clear-Screen
        Show-Banner
        if ($script:Notice) { Say-Wrapped '  ' 'Text' $script:Notice 'Amber'; Say '' }
        Show-StatusBox (Get-StatusModel)
        Say ''
        Write-Seg @('  [1] ', 'Orange', 'Play                ', 'Text', 'get the newest world, start the game, upload when you quit', 'Dim')
        Write-Seg @('  [2] ', 'Orange', 'Finish session      ', 'Text', 'upload now and free the turn', 'Dim')
        Write-Seg @('  [3] ', 'Orange', 'Restore a backup    ', 'Text', 'bring back an older copy of the world', 'Dim')
        Write-Seg @('  [4] ', 'Orange', 'Take over the turn  ', 'Text', 'only if your friend forgot to finish', 'Dim')
        Say ''
        Write-Seg @('  [R] ', 'Orange', 'Refresh   ', 'Text', '[H] ', 'Orange', 'Help   ', 'Text', '[Q] ', 'Orange', 'Quit', 'Text')
        Say ''
        Write-Seg @('  Press a key: ', 'Amber', '', 'Text') -NoNewline
        $choice = Read-Key '1234RHQ'
        Say ''
        switch ($choice) {
            '1' { Invoke-Screen 'Play' { Start-PlaySession } }
            '2' { Invoke-Screen 'Finish session' { Exit-Turn } }
            '3' { Invoke-Screen 'Restore a backup' { Restore-Backup } }
            '4' {
                Invoke-Screen 'Take over the turn' {
                    Say-Wrapped '  ' 'Text' 'This is for when your friend forgot to finish their session and cannot do it now. Anything they played and did not upload will be left out of the shared world.' 'Amber'
                    Say ''
                    if ((Read-Line 'Type YES and press Enter to take over:') -ceq 'YES') { [void](Enter-Turn -Override) }
                    else { Say-Step 'Cancelled. Nothing was changed.' }
                }
            }
            'H' { Show-Help }
            'R' { $script:Notice = '' }
            'Q' { return }
        }
    }
}

# ================================================================ entry point

$exitCode = 0
try {
    if ($Action -eq 'selftest') { if (Invoke-SelfTest) { exit 0 } else { exit 1 } }
    try { $Host.UI.RawUI.WindowTitle = 'Scrap Mechanic Sync' } catch { }
    Write-Log "start v$script:Version action=$Action"
    Initialize-Config

    if ($Action -eq 'update') {
        $result = Update-Self
        Say-Step "Update result: $result"
        exit 0
    }
    if ($Action -eq 'menu' -and -not $NoUpdate) {
        $installed = Invoke-UpdateCheck
        if ($installed) {
            & $PSCommandPath -UpdatedFrom $script:Version -NoUpdate -Plain:$Plain
            exit $LASTEXITCODE
        }
    }
    if ($UpdatedFrom) { $script:Notice = "Updated from v$UpdatedFrom to v$script:Version." }

    Initialize-Player
    Initialize-SavePath
    switch ($Action) {
        'menu'   { Show-Menu }
        'play'   { Start-PlaySession }
        'finish' { Exit-Turn -Override:$Force }
        'status' { Show-StatusPlain }
        'take'   { [void](Enter-Turn -Override) }
    }
}
catch {
    Show-Error $_
    if ($Action -eq 'menu') { Wait-Key 'Press any key to close' }
    $exitCode = 1
}
finally {
    Close-Progress
    if ($Action -eq 'menu') { Reset-Console }
}
exit $exitCode
