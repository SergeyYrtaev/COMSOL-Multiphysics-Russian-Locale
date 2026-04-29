[CmdletBinding()]
param(
    [string]$EditableDir = "",
    [string]$TranslationDir = "",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-PropertyKeys {
    param([string]$Path)

    $keys = [ordered]@{}
    $lineNumber = 0

    foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
        $lineNumber++
        $trimmed = $line.TrimStart()

        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#") -or $trimmed.StartsWith("!")) {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -lt 0) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        if ($key.Length -eq 0) {
            continue
        }

        if (-not $keys.Contains($key)) {
            $keys[$key] = $lineNumber
        }
    }

    return $keys
}

if (-not $EditableDir) {
    $EditableDir = Join-Path $PSScriptRoot "..\editable\ru_RU"
}

if (-not $TranslationDir) {
    $TranslationDir = Join-Path $PSScriptRoot "..\translations\ru_RU"
}

$editable = Resolve-FullPath $EditableDir
$translations = Resolve-FullPath $TranslationDir

if (-not (Test-Path -LiteralPath $editable -PathType Container)) {
    throw "Editable directory not found: $editable"
}

if (-not (Test-Path -LiteralPath $translations -PathType Container)) {
    throw "Translation directory not found: $translations"
}

$editableFiles = @(Get-ChildItem -LiteralPath $editable -Filter "*.properties" -File | Sort-Object Name)
$translationFiles = @(Get-ChildItem -LiteralPath $translations -Filter "*.properties" -File | Sort-Object Name)

if ($editableFiles.Count -eq 0) {
    throw "No editable .properties files found in: $editable"
}

$editableNames = @($editableFiles | ForEach-Object { $_.Name })
$translationNames = @($translationFiles | ForEach-Object { $_.Name })

$missingEditable = @($translationNames | Where-Object { $_ -notin $editableNames })
$extraEditable = @($editableNames | Where-Object { $_ -notin $translationNames })

if ($missingEditable.Count -gt 0) {
    throw "Editable directory is missing files: $($missingEditable -join ', ')"
}

if ($extraEditable.Count -gt 0) {
    throw "Editable directory has unexpected files: $($extraEditable -join ', ')"
}

$checkedKeys = 0

foreach ($file in $editableFiles) {
    $translationPath = Join-Path $translations $file.Name
    $editableKeys = Get-PropertyKeys -Path $file.FullName
    $translationKeys = Get-PropertyKeys -Path $translationPath

    $missingKeys = @($translationKeys.Keys | Where-Object { $_ -notin $editableKeys.Keys })
    $extraKeys = @($editableKeys.Keys | Where-Object { $_ -notin $translationKeys.Keys })

    if ($missingKeys.Count -gt 0) {
        throw "$($file.Name) is missing keys: $($missingKeys -join ', ')"
    }

    if ($extraKeys.Count -gt 0) {
        throw "$($file.Name) has unexpected keys: $($extraKeys -join ', ')"
    }

    $checkedKeys += $editableKeys.Count
}

if (-not $Quiet) {
    Write-Host "Validation OK: $($editableFiles.Count) files, $checkedKeys keys."
}
