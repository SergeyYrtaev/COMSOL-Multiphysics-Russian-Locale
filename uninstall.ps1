[CmdletBinding()]
param(
    [string]$StatePath = "",
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProgressActivity = "Откат отдельного ru_RU языка COMSOL"

function Write-RollbackProgress {
    param([int]$Percent, [string]$Status)
    Write-Progress -Activity $script:ProgressActivity -Status $Status -PercentComplete ([Math]::Min(100, [Math]::Max(0, $Percent)))
}

function Complete-RollbackProgress {
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
        throw "Закройте COMSOL перед откатом. Запущенные процессы: $names"
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

    $backupPath = "$cachePath.bak-ru-RU-language-uninstall-$Timestamp"
    Move-Item -LiteralPath $cachePath -Destination $backupPath -Force
    return $backupPath
}

function Restore-FileFromBackup {
    param([string]$Path, [string]$Backup, [string]$Timestamp)

    if (-not (Test-Path -LiteralPath $Backup)) {
        throw "Backup не найден: $Backup"
    }

    if (Test-Path -LiteralPath $Path) {
        Move-Item -LiteralPath $Path -Destination "$Path.ru-RU-language-removed-$Timestamp" -Force
    }
    Copy-Item -LiteralPath $Backup -Destination $Path -Force
}

$script:ExitCode = 0

try {
    Write-RollbackProgress -Percent 5 -Status "Проверка прав администратора"
    if (-not (Test-Administrator)) {
        throw "Запустите PowerShell от имени администратора."
    }

    if (-not $StatePath) {
        $StatePath = Join-Path $PSScriptRoot "install-state.json"
    }
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "Файл состояния не найден: $StatePath"
    }

    Write-RollbackProgress -Percent 15 -Status "Чтение состояния"
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $root = [string]$state.comsolRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) {
        throw "Некорректный путь COMSOL в state-файле: $root"
    }

    Write-RollbackProgress -Percent 25 -Status "Проверка, что COMSOL закрыт"
    Assert-ComsolIsClosed -Root $root

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    $resourceJars = @($state.resourceJars)
    $resourceCount = [Math]::Max(1, $resourceJars.Count)
    $index = 0
    foreach ($item in $resourceJars) {
        $index += 1
        Write-RollbackProgress -Percent (30 + [int](($index - 1) * (25 / $resourceCount))) -Status "Восстановление ресурсов"
        Restore-FileFromBackup -Path ([string]$item.Jar) -Backup ([string]$item.Backup) -Timestamp $timestamp
    }

    $utilJars = @($state.utilJars)
    $utilCount = [Math]::Max(1, $utilJars.Count)
    $index = 0
    foreach ($item in $utilJars) {
        $index += 1
        Write-RollbackProgress -Percent (58 + [int](($index - 1) * (25 / $utilCount))) -Status "Восстановление списка языков"
        Restore-FileFromBackup -Path ([string]$item.Jar) -Backup ([string]$item.Backup) -Timestamp $timestamp
    }

    foreach ($item in @($state.prefs)) {
        Write-RollbackProgress -Percent 84 -Status "Восстановление prefs"
        Restore-FileFromBackup -Path ([string]$item.Path) -Backup ([string]$item.Backup) -Timestamp $timestamp
    }

    Write-RollbackProgress -Percent 92 -Status "Сброс кэша интерфейса"
    $cacheBackup = Move-OsGiCache -Root $root -Timestamp $timestamp

    Write-RollbackProgress -Percent 100 -Status "Готово"
    Complete-RollbackProgress

    Write-Host ""
    Write-Host "Готово: русский язык ru_RU удален, исходные файлы восстановлены." -ForegroundColor Green
    if ($cacheBackup) {
        Write-Host "Кэш OSGi перенесен сюда: $cacheBackup"
    }
    Write-Host "Перезапустите COMSOL."
} catch {
    $script:ExitCode = 1
    Complete-RollbackProgress
    Write-Host ""
    Write-Host "Ошибка отката ru_RU." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    Pause-AtEnd
}

exit $script:ExitCode
