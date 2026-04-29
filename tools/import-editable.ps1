[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [string]$TargetDir = "",
    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-JavaUnicodeEscapes {
    param([string]$Text)

    $builder = [System.Text.StringBuilder]::new($Text.Length)
    foreach ($char in $Text.ToCharArray()) {
        $code = [int][char]$char
        if ($code -le 0x7F) {
            [void]$builder.Append($char)
        } else {
            [void]$builder.Append(("\u{0:X4}" -f $code))
        }
    }

    return $builder.ToString()
}

if (-not $SourceDir) {
    $SourceDir = Join-Path $PSScriptRoot "..\editable\ru_RU"
}

if (-not $TargetDir) {
    $TargetDir = Join-Path $PSScriptRoot "..\translations\ru_RU"
}

$source = Resolve-FullPath $SourceDir
$target = Resolve-FullPath $TargetDir

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Editable directory not found: $source"
}

if (-not $SkipValidation) {
    & (Join-Path $PSScriptRoot "validate-translations.ps1") -EditableDir $source -TranslationDir $target
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$files = @(Get-ChildItem -LiteralPath $source -Filter "*.properties" -File | Sort-Object Name)

if ($files.Count -eq 0) {
    throw "No .properties files found in: $source"
}

foreach ($file in $files) {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    $encoded = ConvertTo-JavaUnicodeEscapes $text
    $outputPath = Join-Path $target $file.Name
    [System.IO.File]::WriteAllText($outputPath, $encoded, $utf8NoBom)
}

Write-Host "Imported $($files.Count) files into COMSOL-ready Java-escaped format:"
Write-Host $target
