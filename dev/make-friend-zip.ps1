<#
Builds the zip you send to the other player: the files of one tagged release plus your
sm-sync.config.json (R2 keys and the GitHub read token).

    dev\make-friend-zip.ps1              # newest vX.Y.Z tag
    dev\make-friend-zip.ps1 -Tag v0.1.0  # a specific release

Output: dist\Scrap Mechanic Sync.zip (untracked). It contains secrets, so send it privately.
#>
param([string]$Tag)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if (-not $Tag) {
    $Tag = git -C $repo tag --list 'v*' --sort=-v:refname | Select-Object -First 1
    if (-not $Tag) { throw 'There is no release tag yet. Tag a commit first, for example: git tag v0.1.0' }
}

$configPath = Join-Path $repo 'sm-sync.config.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
foreach ($field in 'Endpoint', 'Bucket', 'AccessKeyId', 'SecretAccessKey', 'SaveName', 'GitHubRepo', 'GitHubToken') {
    if (-not $config.$field -or "$($config.$field)" -match 'YOUR_|PASTE_') {
        throw "sm-sync.config.json: '$field' is not filled in. The other player's copy needs every value."
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("sm-sync-pack-" + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'Scrap Mechanic Sync'
[void](New-Item -ItemType Directory -Path $stage)
try {
    $archive = Join-Path $work 'release.zip'
    git -C $repo archive --format=zip -o $archive $Tag -- 'sm-sync.ps1' 'Scrap Mechanic Sync.cmd' 'FRIEND-INSTRUCTIONS.txt' 'CHANGES.txt'
    if ($LASTEXITCODE -ne 0) { throw "git archive failed for $Tag." }
    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    Copy-Item -LiteralPath $configPath -Destination $stage

    $dist = Join-Path $repo 'dist'
    [void](New-Item -ItemType Directory -Force -Path $dist)
    $zip = Join-Path $dist 'Scrap Mechanic Sync.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    Compress-Archive -Path $stage -DestinationPath $zip
    Write-Host "Built $zip from $Tag"
    Write-Host 'It contains the storage keys. Send it privately and do not post it anywhere.'
}
finally { Remove-Item -LiteralPath $work -Recurse -Force }
