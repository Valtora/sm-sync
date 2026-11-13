<#
Builds the download attached to a GitHub release: the player files of one tagged release,
in a folder named "Scrap Mechanic Sync". It holds no settings and no keys, so it is safe to
publish. Each player's copy gets its settings from the first-run setup.

    dev\make-release-zip.ps1              # newest vX.Y.Z tag
    dev\make-release-zip.ps1 -Tag v0.3.0  # a specific release

Output: dist\Scrap-Mechanic-Sync.zip (untracked). The README and the invite message link to
releases/latest/download/Scrap-Mechanic-Sync.zip, so keep that file name.
#>
param([string]$Tag)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if (-not $Tag) {
    $Tag = git -C $repo tag --list 'v*' --sort=-v:refname | Select-Object -First 1
    if (-not $Tag) { throw 'There is no release tag yet. Tag a commit first, for example: git tag v0.3.0' }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("sm-sync-pack-" + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'Scrap Mechanic Sync'
[void](New-Item -ItemType Directory -Path $stage)
try {
    $archive = Join-Path $work 'release.zip'
    # Only the files that exist in that release: older tags lack some of them.
    $inTag = git -C $repo ls-tree --name-only $Tag
    $files = @('sm-sync.ps1', 'Scrap Mechanic Sync.cmd', 'FRIEND-INSTRUCTIONS.txt', 'CHANGES.txt', 'LICENSE') | Where-Object { $inTag -contains $_ }
    git -C $repo archive --format=zip -o $archive $Tag -- $files
    if ($LASTEXITCODE -ne 0) { throw "git archive failed for $Tag." }
    Expand-Archive -LiteralPath $archive -DestinationPath $stage
    if (Test-Path -LiteralPath (Join-Path $stage 'sm-sync.config.json')) { throw 'The settings file must never be in a release zip.' }

    $dist = Join-Path $repo 'dist'
    [void](New-Item -ItemType Directory -Force -Path $dist)
    $zip = Join-Path $dist 'Scrap-Mechanic-Sync.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    Compress-Archive -Path $stage -DestinationPath $zip
    Write-Host "Built $zip from $Tag"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force }
