[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [string]$TargetDir = "",
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertFrom-JavaUnicodeEscapes {
    param([string]$Text)

    return [regex]::Replace(
        $Text,
        "\\u([0-9a-fA-F]{4})",
        {
            param($Match)
            return [string][char][Convert]::ToInt32($Match.Groups[1].Value, 16)
        }
    )
}

if (-not $SourceDir) {
    $SourceDir = Join-Path $PSScriptRoot "..\translations\ru_RU"
}

if (-not $TargetDir) {
    $TargetDir = Join-Path $PSScriptRoot "..\editable\ru_RU"
}

$source = Resolve-FullPath $SourceDir
$target = Resolve-FullPath $TargetDir

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Source directory not found: $source"
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

if ($Clean) {
    Get-ChildItem -LiteralPath $target -Filter "*.properties" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

$utf8WithBom = [System.Text.UTF8Encoding]::new($true)
$files = @(Get-ChildItem -LiteralPath $source -Filter "*.properties" -File | Sort-Object Name)

if ($files.Count -eq 0) {
    throw "No .properties files found in: $source"
}

foreach ($file in $files) {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    $decoded = ConvertFrom-JavaUnicodeEscapes $text
    $outputPath = Join-Path $target $file.Name
    [System.IO.File]::WriteAllText($outputPath, $decoded, $utf8WithBom)
}

Write-Host "Exported $($files.Count) files to human-readable UTF-8:"
Write-Host $target
