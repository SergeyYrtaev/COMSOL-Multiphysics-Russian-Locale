[CmdletBinding()]
param(
    [string]$ComsolRoot = "",
    [string]$TranslationDir = "",
    [switch]$NoCacheClear,
    [switch]$DoNotSetCurrent,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:ProgressActivity = "Добавление русского языка COMSOL"
$script:TargetLocale = "ru_RU"
$script:ProbeLocale = "en_US"

function Write-SetupProgress {
    param([int]$Percent, [string]$Status)
    Write-Progress -Activity $script:ProgressActivity -Status $Status -PercentComplete ([Math]::Min(100, [Math]::Max(0, $Percent)))
}

function Complete-SetupProgress {
    Write-Progress -Activity $script:ProgressActivity -Completed
}

function Pause-AtEnd {
    if ($NoPause) {
        return
    }

    if ($Host.Name -eq "ConsoleHost") {
        Write-Host ""
        $null = Read-Host "Нажмите Enter, чтобы закрыть окно"
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ComsolRootCandidate {
    param([string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (Test-Path -LiteralPath (Join-Path $resolved "plugins")) {
        return $resolved
    }

    $nested = Join-Path $resolved "Multiphysics"
    if (Test-Path -LiteralPath (Join-Path $nested "plugins")) {
        return $nested
    }

    return $null
}

function Find-ComsolRoot {
    param([string]$RequestedRoot)

    if ($RequestedRoot) {
        $root = Resolve-ComsolRootCandidate -Path $RequestedRoot
        if ($root) {
            return [string]$root
        }
        throw "COMSOL Multiphysics не найден здесь: $RequestedRoot"
    }

    $bases = @()
    if ($env:ProgramFiles) {
        $bases += (Join-Path $env:ProgramFiles "COMSOL")
    }
    if (${env:ProgramFiles(x86)}) {
        $bases += (Join-Path ${env:ProgramFiles(x86)} "COMSOL")
    }

    $candidates = @()
    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base)) {
            continue
        }

        foreach ($versionDir in @(Get-ChildItem -LiteralPath $base -Directory)) {
            $root = Resolve-ComsolRootCandidate -Path $versionDir.FullName
            if ($root) {
                $candidates += [string]$root
            }
        }
    }

    $candidates = @($candidates | Sort-Object -Descending -Unique)
    if ($candidates.Count -lt 1) {
        throw "COMSOL Multiphysics не найден в Program Files. Запустите с -ComsolRoot."
    }

    return [string]$candidates[0]
}

function Assert-ComsolIsClosed {
    param([string]$Root)

    $running = @()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null
        try {
            $path = $process.Path
        } catch {
            $path = $null
        }

        if ($process.ProcessName -like "comsol*" -or ($path -and $path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase))) {
            $running += $process
        }
    }

    if ($running.Count -gt 0) {
        $names = ($running | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ", "
        throw "Закройте COMSOL перед установкой. Запущенные процессы: $names"
    }
}

function Get-ComsolUserVersion {
    param([string]$Root)

    $match = [regex]::Match($Root, "COMSOL(?<version>\d+)")
    if ($match.Success) {
        return "v$($match.Groups["version"].Value)"
    }
    return $null
}

function Get-TranslationFiles {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        throw "Папка перевода не найдена: $Directory"
    }

    $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter "*_$($script:TargetLocale).properties")
    if ($files.Count -lt 1) {
        throw "В папке нет файлов *_$($script:TargetLocale).properties: $Directory"
    }

    $map = @{}
    foreach ($file in $files) {
        $map[$file.Name] = $file.FullName
    }
    return $map
}

function Find-ResourceJars {
    param([string]$Root)

    $folders = @(
        (Join-Path $Root "plugins"),
        (Join-Path $Root "web\plugins"),
        (Join-Path $Root "apiplugins")
    )

    $jars = @()
    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath $folder) {
            $jars += @(Get-ChildItem -LiteralPath $folder -File -Filter "com.comsol.resources_*.jar" | ForEach-Object { $_.FullName })
        }
    }

    $jars = @($jars | Sort-Object -Unique)
    if ($jars.Count -lt 1) {
        throw "Не найдены com.comsol.resources_*.jar в COMSOL."
    }
    return $jars
}

function Find-UtilJars {
    param([string]$Root)

    $folders = @(
        (Join-Path $Root "plugins"),
        (Join-Path $Root "web\plugins"),
        (Join-Path $Root "apiplugins")
    )

    $jars = @()
    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath $folder) {
            $jars += @(Get-ChildItem -LiteralPath $folder -File -Filter "com.comsol.util_*.jar" | ForEach-Object { $_.FullName })
        }
    }

    $jars = @($jars | Sort-Object -Unique)
    if ($jars.Count -lt 1) {
        throw "Не найдены com.comsol.util_*.jar в COMSOL."
    }
    return $jars
}

function Copy-ZipEntryContent {
    param(
        [System.IO.Compression.ZipArchiveEntry]$SourceEntry,
        [System.IO.Compression.ZipArchiveEntry]$TargetEntry
    )

    $inStream = $SourceEntry.Open()
    try {
        $outStream = $TargetEntry.Open()
        try {
            $inStream.CopyTo($outStream)
        } finally {
            $outStream.Dispose()
        }
    } finally {
        $inStream.Dispose()
    }
}

function Write-BytesToEntry {
    param(
        [byte[]]$Bytes,
        [System.IO.Compression.ZipArchiveEntry]$TargetEntry
    )

    $outStream = $TargetEntry.Open()
    try {
        $outStream.Write($Bytes, 0, $Bytes.Length)
    } finally {
        $outStream.Dispose()
    }
}

function Update-ResourcesJarWithRuLocale {
    param(
        [string]$JarPath,
        [hashtable]$Translations,
        [string]$Timestamp
    )

    $backupPath = "$JarPath.ru-RU-language-backup-$Timestamp"
    Copy-Item -LiteralPath $JarPath -Destination $backupPath -Force

    $tempPath = "$JarPath.tmp-ru-RU-$Timestamp"
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    $replacements = @{}
    $sourceZip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        foreach ($name in $Translations.Keys) {
            $probeName = $name -replace "_$($script:TargetLocale)\.properties$", "_$($script:ProbeLocale).properties"
            $probeEntry = @($sourceZip.Entries | Where-Object { [IO.Path]::GetFileName($_.FullName) -eq $probeName } | Select-Object -First 1)
            if ($probeEntry.Count -lt 1) {
                throw "Не найден путь-образец для $name в $JarPath"
            }

            $targetEntryPath = $probeEntry[0].FullName -replace "_$($script:ProbeLocale)\.properties$", "_$($script:TargetLocale).properties"
            $replacements[$targetEntryPath] = [IO.File]::ReadAllBytes($Translations[$name])
        }

        $writtenCount = 0
        $targetZip = [System.IO.Compression.ZipFile]::Open($tempPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $written = @{}
            foreach ($entry in $sourceZip.Entries) {
                $newEntry = $targetZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                $newEntry.LastWriteTime = $entry.LastWriteTime
                if ($replacements.ContainsKey($entry.FullName)) {
                    Write-BytesToEntry -Bytes $replacements[$entry.FullName] -TargetEntry $newEntry
                    $written[$entry.FullName] = $true
                } else {
                    Copy-ZipEntryContent -SourceEntry $entry -TargetEntry $newEntry
                }
            }

            foreach ($targetEntryPath in $replacements.Keys) {
                if ($written.ContainsKey($targetEntryPath)) {
                    continue
                }
                $newEntry = $targetZip.CreateEntry($targetEntryPath, [System.IO.Compression.CompressionLevel]::Optimal)
                Write-BytesToEntry -Bytes $replacements[$targetEntryPath] -TargetEntry $newEntry
                $written[$targetEntryPath] = $true
            }

            $writtenCount = $written.Count
        } finally {
            $targetZip.Dispose()
        }
    } finally {
        $sourceZip.Dispose()
    }

    Move-Item -LiteralPath $tempPath -Destination $JarPath -Force

    return [pscustomobject]@{
        Jar = $JarPath
        Backup = $backupPath
        AddedOrUpdated = $writtenCount
    }
}

function Read-U2 {
    param([byte[]]$Bytes, [int]$Offset)
    return ((([int]$Bytes[$Offset]) -shl 8) -bor ([int]$Bytes[$Offset + 1]))
}

function Patch-FlLocaleClassBytes {
    param([byte[]]$Bytes)

    if ((Read-U2 -Bytes $Bytes -Offset 0) -ne 0xCAFE -or (Read-U2 -Bytes $Bytes -Offset 2) -ne 0xBABE) {
        throw "FlLocale.class имеет неожиданный заголовок."
    }

    $constantPoolCount = Read-U2 -Bytes $Bytes -Offset 8
    $offset = 10
    $changed = 0

    for ($i = 1; $i -lt $constantPoolCount; $i++) {
        $tag = $Bytes[$offset]
        $offset += 1

        switch ($tag) {
            1 {
                $length = Read-U2 -Bytes $Bytes -Offset $offset
                $textOffset = $offset + 2
                $text = [Text.Encoding]::UTF8.GetString($Bytes, $textOffset, $length)

                if ($text -eq "sv") {
                    $replacement = [Text.Encoding]::UTF8.GetBytes("ru")
                    [Array]::Copy($replacement, 0, $Bytes, $textOffset, $replacement.Length)
                    $changed += 1
                } elseif ($text -eq "SE") {
                    $replacement = [Text.Encoding]::UTF8.GetBytes("RU")
                    [Array]::Copy($replacement, 0, $Bytes, $textOffset, $replacement.Length)
                    $changed += 1
                }

                $offset += 2 + $length
            }
            { $_ -in 3, 4 } { $offset += 4 }
            { $_ -in 5, 6 } { $offset += 8; $i += 1 }
            { $_ -in 7, 8, 16, 19, 20 } { $offset += 2 }
            { $_ -in 9, 10, 11, 12, 18 } { $offset += 4 }
            15 { $offset += 3 }
            default { throw "Неизвестный constant-pool tag $tag в FlLocale.class." }
        }
    }

    return [pscustomobject]@{
        Bytes = $Bytes
        Changed = $changed
    }
}

function Update-UtilJarLanguageCandidate {
    param([string]$JarPath, [string]$Timestamp)

    $entryName = "com/comsol/util/methods/FlLocale.class"
    $backupPath = "$JarPath.ru-RU-language-backup-$Timestamp"
    Copy-Item -LiteralPath $JarPath -Destination $backupPath -Force

    $tempPath = "$JarPath.tmp-ru-RU-$Timestamp"
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    $changed = 0
    $sourceZip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        $targetZip = [System.IO.Compression.ZipFile]::Open($tempPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $sourceZip.Entries) {
                $newEntry = $targetZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                $newEntry.LastWriteTime = $entry.LastWriteTime

                if ($entry.FullName -eq $entryName) {
                    $stream = $entry.Open()
                    try {
                        $memory = [IO.MemoryStream]::new()
                        try {
                            $stream.CopyTo($memory)
                            $patched = Patch-FlLocaleClassBytes -Bytes $memory.ToArray()
                            Write-BytesToEntry -Bytes $patched.Bytes -TargetEntry $newEntry
                            $changed = $patched.Changed
                        } finally {
                            $memory.Dispose()
                        }
                    } finally {
                        $stream.Dispose()
                    }
                } else {
                    Copy-ZipEntryContent -SourceEntry $entry -TargetEntry $newEntry
                }
            }
        } finally {
            $targetZip.Dispose()
        }
    } finally {
        $sourceZip.Dispose()
    }

    Move-Item -LiteralPath $tempPath -Destination $JarPath -Force

    return [pscustomobject]@{
        Jar = $JarPath
        Backup = $backupPath
        PatchedConstants = $changed
    }
}

function Move-OsGiCache {
    param([string]$Root, [string]$Timestamp)

    $userVersion = Get-ComsolUserVersion -Root $Root
    if (-not $userVersion) {
        return $null
    }

    $cachePath = Join-Path $env:USERPROFILE ".comsol\$userVersion\configuration\comsol\org.eclipse.osgi"
    if (-not (Test-Path -LiteralPath $cachePath)) {
        return $null
    }

    $backupPath = "$cachePath.bak-ru-RU-language-$Timestamp"
    Move-Item -LiteralPath $cachePath -Destination $backupPath -Force
    return $backupPath
}

function Set-PreferenceLocale {
    param([string]$PrefsPath, [string]$Timestamp)

    if (-not (Test-Path -LiteralPath $PrefsPath)) {
        return $null
    }

    $backupPath = "$PrefsPath.ru-RU-language-backup-$Timestamp"
    Copy-Item -LiteralPath $PrefsPath -Destination $backupPath -Force

    $lines = @(Get-Content -LiteralPath $PrefsPath -Encoding UTF8)
    $found = $false
    $updated = @()
    foreach ($line in $lines) {
        if ($line -match "^general\.language\.language=") {
            $updated += "general.language.language=$($script:TargetLocale)"
            $found = $true
        } else {
            $updated += $line
        }
    }
    if (-not $found) {
        $updated += "general.language.language=$($script:TargetLocale)"
    }

    $updated | Set-Content -LiteralPath $PrefsPath -Encoding UTF8
    return [pscustomobject]@{
        Path = $PrefsPath
        Backup = $backupPath
    }
}

$script:ExitCode = 0

try {
    Write-SetupProgress -Percent 5 -Status "Проверка прав администратора"
    if (-not (Test-Administrator)) {
        throw "Запустите PowerShell от имени администратора."
    }

    if (-not $TranslationDir) {
        $TranslationDir = Join-Path $PSScriptRoot "translations\$($script:TargetLocale)"
    }

    Write-SetupProgress -Percent 12 -Status "Поиск COMSOL"
    $root = Find-ComsolRoot -RequestedRoot $ComsolRoot

    Write-SetupProgress -Percent 18 -Status "Проверка, что COMSOL закрыт"
    Assert-ComsolIsClosed -Root $root

    Write-SetupProgress -Percent 25 -Status "Загрузка ru_RU переводов"
    $translations = Get-TranslationFiles -Directory $TranslationDir
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    Write-SetupProgress -Percent 35 -Status "Добавление ru_RU ресурсов"
    $resourceResults = @()
    foreach ($jar in Find-ResourceJars -Root $root) {
        $resourceResults += Update-ResourcesJarWithRuLocale -JarPath $jar -Translations $translations -Timestamp $timestamp
    }

    Write-SetupProgress -Percent 62 -Status "Добавление ru_RU в список языков"
    $utilResults = @()
    foreach ($jar in Find-UtilJars -Root $root) {
        $utilResults += Update-UtilJarLanguageCandidate -JarPath $jar -Timestamp $timestamp
    }

    $prefResults = @()
    if (-not $DoNotSetCurrent) {
        Write-SetupProgress -Percent 78 -Status "Выбор ru_RU в настройках"
        $userVersion = Get-ComsolUserVersion -Root $root
        if ($userVersion) {
            $prefResults += Set-PreferenceLocale -PrefsPath (Join-Path $env:USERPROFILE ".comsol\$userVersion\comsol.prefs") -Timestamp $timestamp
            $prefResults += Set-PreferenceLocale -PrefsPath (Join-Path $env:USERPROFILE ".comsol\$userVersion\comsolserver.prefs") -Timestamp $timestamp
        }
        $prefResults += Set-PreferenceLocale -PrefsPath (Join-Path $root "comsol.prefs") -Timestamp $timestamp
        $prefResults = @($prefResults | Where-Object { $_ -ne $null })
    }

    $cacheBackup = $null
    if (-not $NoCacheClear) {
        Write-SetupProgress -Percent 88 -Status "Сброс кэша интерфейса"
        $cacheBackup = Move-OsGiCache -Root $root -Timestamp $timestamp
    }

    Write-SetupProgress -Percent 95 -Status "Сохранение состояния"
    $statePath = Join-Path $PSScriptRoot "install-state.json"
    $state = [ordered]@{
        installedAt = (Get-Date).ToString("s")
        comsolRoot = $root
        locale = $script:TargetLocale
        translationDir = (Resolve-Path -LiteralPath $TranslationDir).Path
        resourceJars = $resourceResults
        utilJars = $utilResults
        prefs = $prefResults
        cacheBackup = $cacheBackup
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-SetupProgress -Percent 100 -Status "Готово"
    Complete-SetupProgress

    Write-Host ""
    Write-Host "Готово: добавлен отдельный язык ru_RU." -ForegroundColor Green
    Write-Host "В списке языков должен появиться Russian/Русский, отдельный от штатных языков." -ForegroundColor Green
    Write-Host "Ресурсные JAR обновлены: $($resourceResults.Count)"
    Write-Host "JAR со списком языков пропатчены: $($utilResults.Count)"
    Write-Host "Файл состояния: $statePath"
    Write-Host "Перезапустите COMSOL и проверьте Language."
} catch {
    $script:ExitCode = 1
    Complete-SetupProgress
    Write-Host ""
    Write-Host "Ошибка добавления ru_RU." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    Pause-AtEnd
}

exit $script:ExitCode
