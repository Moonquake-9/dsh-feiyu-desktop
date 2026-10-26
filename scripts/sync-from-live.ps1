# Sync the live working copies into this repository.
#
#   pwsh -File scripts\sync-from-live.ps1
#
# The widget runs from a live folder (with its runtime state: positions, logs, memory)
# and the bridge plugin is installed from another folder. This script copies only the
# files that belong in the repository, normalising line endings to LF in the process.
# Afterwards open GitHub Desktop, review the diff and push.

param(
    [string]$WidgetDir = 'D:\Desktop\DSH\feiyu-desktop',
    [string]$BridgeDir = 'D:\Desktop\DSH\dsh-feiyu-bridge'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)      # no BOM (git friendly)
$utf8bom = New-Object System.Text.UTF8Encoding($true)    # PowerShell 5.1 needs the BOM

function Copy-Text([string]$src, [string]$dst, [switch]$Bom) {
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "missing: $src"; return }
    $text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
    $text = $text -replace "`r`n", "`n"
    $enc = if ($Bom) { $utf8bom } else { $utf8 }
    [System.IO.File]::WriteAllText($dst, $text, $enc)
    Write-Host "  $([System.IO.Path]::GetFileName($dst))"
}

function Copy-Binary([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "missing: $src"; return }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "  $([System.IO.Path]::GetFileName($dst))"
}

Write-Host 'widget/'
Copy-Text  (Join-Path $WidgetDir 'FeiyuMoodDesktop.ps1') (Join-Path $repo 'widget\FeiyuMoodDesktop.ps1') -Bom
Copy-Text  (Join-Path $WidgetDir 'launch.vbs')           (Join-Path $repo 'widget\launch.vbs')
Copy-Text  (Join-Path $WidgetDir 'pet-settings.json')    (Join-Path $repo 'widget\pet-settings.json')
Copy-Text  (Join-Path $WidgetDir 'version.json')         (Join-Path $repo 'widget\version.json')
foreach ($img in 'feiyu.png', 'face-great.png', 'face-good.png', 'face-ok.png', 'face-worry.png', 'face-sad.png') {
    Copy-Binary (Join-Path $WidgetDir "assets\$img") (Join-Path $repo "widget\assets\$img")
}

Write-Host 'bridge/'
foreach ($f in 'index.js', 'emotion.js', 'memory.js', 'package.json', 'cordis.patch.yml', 'README.md') {
    Copy-Text (Join-Path $BridgeDir $f) (Join-Path $repo "bridge\$f")
}

Write-Host 'docs/'
foreach ($f in 'preview.png', 'preview-chat2.png', 'preview-settings.png', 'preview-stack.png') {
    Copy-Binary (Join-Path $WidgetDir $f) (Join-Path $repo "docs\$f")
}

Write-Host ''
Write-Host 'Done. Now open GitHub Desktop, review the changes and push.'
