# Sync the live working copies into this repository.
#
#   pwsh -File scripts\sync-from-live.ps1
#
# The widget runs from a live folder (with its runtime state: positions, logs, memory)
# and the bridge plugin is installed from another folder. This script copies only the
# files that belong in the repository, normalising line endings to LF in the process.
# Afterwards open GitHub Desktop, review the diff and push.

param(
    [string]$WidgetDir = $env:FEIYU_WIDGET_DIR,
    [string]$BridgeDir = $env:FEIYU_BRIDGE_SRC
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$parent = Split-Path -Parent $repo
# Default layout used while developing: the live widget + bridge sit next to this repository.
if (-not $WidgetDir) { $WidgetDir = Join-Path $parent 'feiyu-desktop' }
if (-not $BridgeDir) { $BridgeDir = Join-Path $parent 'dsh-feiyu-bridge' }
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
foreach ($f in 'index.js', 'emotion.js', 'memory.js', 'package.json', 'README.md') {
    Copy-Text (Join-Path $BridgeDir $f) (Join-Path $repo "bridge\$f")
}

# The bundle patch carries machine-specific absolute paths, so scrub them on the way in.
$patchSrc = Join-Path $BridgeDir 'cordis.patch.yml'
if (Test-Path -LiteralPath $patchSrc) {
    $text = [System.IO.File]::ReadAllText($patchSrc, [System.Text.Encoding]::UTF8)
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace [regex]::Escape($WidgetDir.Replace('\', '/')), 'C:/apps/feiyu-desktop'
    $text = $text -replace [regex]::Escape($WidgetDir), 'C:\apps\feiyu-desktop'
    # Keep the three paths visible (the bridge needs them) but make it obvious to a first-time
    # installer that they point at a sample folder and must be edited.
    $note = '# 安装时把 dir / widgetVbs / widgetPid 三行改成你自己的挂件目录（下面是示例路径）'
    if ($text -notmatch [regex]::Escape($note)) {
        $text = $text -replace '(?m)^(\s*)(dir:\s*''[^'']*''\s*)$', ('$1' + $note + "`n" + '$1$2')
    }
    [System.IO.File]::WriteAllText((Join-Path $repo 'bridge\cordis.patch.yml'), $text, $utf8)
    Write-Host '  cordis.patch.yml (paths scrubbed, install note added)'
}

# docs/ is curated inside the repository — do not copy the live previews over it.

Write-Host ''
Write-Host 'Done. Now open GitHub Desktop, review the changes and push.'
