<#
.SYNOPSIS
    Draws the group cards, docs/images/group-*.png, from their SVG sources, or checks that they are current.

.DESCRIPTION
    Each docs/images/group-{family}.svg is a 1600-pixel-wide card for one family of the DEMA Tools: the family name
    and purpose over the project cards embedded from docs/images/projects/ (the Continuous Compliance card also
    draws the pipeline of its tools). Every card is kept beside the PNG it draws (matching base names), uses the
    visual language of the README hero (docs/images/hero.svg), and is drawn with "dotnet canvasnet" from the tool
    manifest. The project cards in docs/images/projects/ have no PNGs: the group cards embed their SVGs, and the
    strict render of a group card fails if an embedded card is not valid.

    Without -Check it draws every card over its PNG. Commit the changed PNGs with the change to the SVG that made
    them differ.

    With -Check it draws every card into a temporary folder and compares it with the committed PNG using
    "canvasnet compare ... --threshold rmse=1 --threshold diff-ratio=0.001". It changes nothing in the repository,
    and exits 1 when a committed PNG is missing, has another size, or differs by more than the tolerance. The
    tolerance is not zero on purpose: a drawing is not bit-for-bit the same on every operating system (a font or
    a last-bit difference in floating point may move a few anti-aliased pixels), but any change of text, color,
    or layout is far above it.

    Run it from anywhere; paths are taken from the repository the script is in.

.PARAMETER Check
    Compare fresh drawings with the committed card PNGs instead of replacing them.
#>
[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$images = 'docs/images'

Push-Location $repo
try {
    $sources = @(Get-ChildItem -LiteralPath $images -Filter 'group-*.svg' | Sort-Object Name | ForEach-Object Name)
    if ($sources.Count -eq 0) {
        throw "no $images/group-*.svg files found"
    }

    dotnet tool restore | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet tool restore failed with exit code $LASTEXITCODE"
    }

    if (-not $Check) {
        foreach ($name in $sources) {
            $source = "$images/$name"
            $committed = [System.IO.Path]::ChangeExtension($source, 'png')
            dotnet canvasnet render $source --strict --width 1600 -o $committed
            if ($LASTEXITCODE -ne 0) {
                throw "canvasnet render of $source failed with exit code $LASTEXITCODE"
            }
        }
        exit 0
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('render-groups-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $failed = $false
    try {
        foreach ($name in $sources) {
            $source = "$images/$name"
            $committed = [System.IO.Path]::ChangeExtension($source, 'png')
            if (-not (Test-Path -LiteralPath $committed)) {
                $failed = $true
                Write-Host "FAIL  ${committed}: the committed image is missing (run docs/images/render-groups.ps1)"
                continue
            }

            $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $fresh = Join-Path $work "$base.png"
            dotnet canvasnet render $source --strict --width 1600 -o $fresh | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "canvasnet render of $source failed with exit code $LASTEXITCODE"
            }

            $json = dotnet canvasnet compare $committed $fresh --threshold 'rmse=1' --threshold 'diff-ratio=0.001' `
                --side-by-side (Join-Path $work "$base-compare.png") --json 2>$null
            $exit = $LASTEXITCODE
            $result = $null
            try { $result = ($json | Out-String) | ConvertFrom-Json } catch { $result = $null }

            if ($exit -eq 0) {
                Write-Host ("ok    {0}: rmse {1:N3}, differing pixels {2:P3}" -f `
                        $committed, $result.metrics.rmse, $result.metrics.diffPixelRatio)
            }
            else {
                $failed = $true
                $reason = if ($result -and $result.PSObject.Properties['error'] -and $result.error) {
                    $result.error.message
                }
                else {
                    "it differs from a fresh drawing of $source (canvasnet compare exited with code $exit)"
                }
                Write-Host "FAIL  ${committed}: $reason"
                if ($result -and $result.PSObject.Properties['metrics']) {
                    Write-Host ("      rmse {0:N3}, differing pixels {1:P3}" -f `
                            $result.metrics.rmse, $result.metrics.diffPixelRatio)
                }
            }
        }

        if ($failed) {
            Write-Host '      If the change is intended, run: pwsh docs/images/render-groups.ps1 and commit the images.'
            Write-Host "      The fresh images and side-by-side comparisons are kept in $work"
        }
        else {
            Write-Host 'The committed group images are current.'
        }
    }
    finally {
        if (-not $failed) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    exit ($failed ? 1 : 0)
}
finally {
    Pop-Location
}
