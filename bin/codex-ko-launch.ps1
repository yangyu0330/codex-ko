#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

$binDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root = Split-Path -Parent $binDir
$exe = Join-Path $binDir "codex.exe"
$pendingExe = Join-Path $binDir "codex.exe.next"
$statePath = Join-Path $root "state.json"
$updater = Join-Path $root "scripts\update-codex-ko.ps1"
$installer = Join-Path $root "scripts\install-codex-ko.ps1"
$metadataSync = Join-Path $root "scripts\sync-codex-ko-metadata.ps1"
$translationSync = Join-Path $root "scripts\translate-codex-ko-pending.ps1"
$dynamicStatusPath = Join-Path $root "translations\dynamic-status.json"
$dynamicAlertPath = Join-Path $root "translations\dynamic-alert.json"
$env:CODEX_KO_ROOT = $root

function Install-PendingCodexBinary {
    if (-not (Test-Path $pendingExe)) {
        return
    }

    $previousExe = Join-Path $binDir "codex.exe.previous"
    try {
        if (Test-Path $exe) {
            Remove-Item -LiteralPath $previousExe -Force -ErrorAction SilentlyContinue
            [System.IO.File]::Replace($pendingExe, $exe, $previousExe, $true)
            Remove-Item -LiteralPath $previousExe -Force -ErrorAction SilentlyContinue
        }
        else {
            Move-Item -LiteralPath $pendingExe -Destination $exe -Force
        }
        try {
            $state = [ordered]@{}
            if (Test-Path $statePath) {
                $stateObject = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($true)) | ConvertFrom-Json
                foreach ($property in $stateObject.PSObject.Properties) {
                    $state[$property.Name] = $property.Value
                }
            }
            $state["installed"] = $true
            $state["pending"] = $false
            $state["pendingBinary"] = ""
            $state["pendingReason"] = ""
            $state["appliedAt"] = (Get-Date).ToString("o")
            $json = $state | ConvertTo-Json -Depth 8
            [System.IO.File]::WriteAllText($statePath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
        }
        catch {
        }
        Write-Host "대기 중이던 한국어 Codex 바이너리를 적용했습니다." -ForegroundColor Green
    }
    catch {
        Write-Host "새 한국어 Codex 바이너리가 준비되어 있지만 아직 적용하지 못했습니다." -ForegroundColor Yellow
        Write-Host "다른 Codex 창을 종료한 뒤 다시 실행하면 자동으로 적용됩니다."
        Write-Host $_.Exception.Message
    }
}

function Remove-PreviousCodexBinary {
    $previousExe = Join-Path $binDir "codex.exe.previous"
    Remove-Item -LiteralPath $previousExe -Force -ErrorAction SilentlyContinue
}

function Get-VersionFromText {
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)') {
        return $Matches[1]
    }
    return ""
}

function Get-BuiltVersion {
    if (Test-Path $statePath) {
        try {
            $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($true)) | ConvertFrom-Json
            if ($state.version) {
                return [string]$state.version
            }
        }
        catch {
        }
    }
    if (Test-Path $exe) {
        try {
            return Get-VersionFromText ((& $exe --version 2>$null) -join "`n")
        }
        catch {
        }
    }
    return ""
}

function Test-CodexKoShimCommand {
    param([Parameter(Mandatory = $true)][string]$Path)
    $commandDir = Split-Path -Parent $Path
    if (-not $commandDir) {
        return $false
    }
    return (Test-Path (Join-Path $commandDir "codex-ko-launch.ps1"))
}

function Get-OriginalCodexCommand {
    $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    foreach ($cmd in $commands) {
        $source = [string]$cmd.Source
        if (-not $source) {
            continue
        }
        if ($source.StartsWith($binDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (Test-CodexKoShimCommand $source) {
            continue
        }
        return $source
    }
    return ""
}

function Get-OriginalCodexVersion {
    $original = Get-OriginalCodexCommand
    if (-not $original) {
        return ""
    }
    try {
        return Get-VersionFromText ((& $original --version 2>$null) -join "`n")
    }
    catch {
        return ""
    }
}

function Read-LaunchJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($true))
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return $raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-LaunchJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-LaunchWarningOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($env:CODEX_KO_NOTIFY -eq "0") {
        return
    }

    $now = Get-Date
    $alert = Read-LaunchJson $dynamicAlertPath
    if ($alert -and $alert.id -eq $Id -and $alert.last_shown_at) {
        try {
            $lastShown = [datetime]::Parse([string]$alert.last_shown_at)
            if (($now - $lastShown).TotalMinutes -lt 60) {
                return
            }
        }
        catch {
        }
    }

    Write-Host $Message -ForegroundColor Yellow
    Write-LaunchJson $dynamicAlertPath ([ordered]@{
        id = $Id
        message = $Message
        last_shown_at = $now.ToString("o")
    })
}

function Show-TranslationStatusWarning {
    $status = Read-LaunchJson $dynamicStatusPath
    if (-not $status) {
        return
    }
    if ($status.last_error) {
        Write-LaunchWarningOnce "translation-error" "한국어 동적 번역에서 최근 오류가 있었습니다. 자세한 내용은 scripts\codex-ko-status.ps1로 확인하세요."
        return
    }
    $pendingUncached = 0
    if ($status.pending_uncached_count -ne $null) {
        $pendingUncached = [int]$status.pending_uncached_count
    }
    if ($pendingUncached -gt 0 -and $status.state -eq "stopped") {
        Write-LaunchWarningOnce "translation-stopped" "번역 watcher가 꺼져 있어 새 설명 일부가 영어로 보일 수 있습니다."
    }
}

Install-PendingCodexBinary
Remove-PreviousCodexBinary

$originalVersion = Get-OriginalCodexVersion

if (-not (Test-Path $exe)) {
    if ($env:CODEX_KO_NO_RELEASE_INSTALL -ne "1" -and (Test-Path $installer)) {
        Write-Host "한국어 커스텀 Codex 바이너리가 없어 GitHub Release 설치를 먼저 시도합니다." -ForegroundColor Yellow
        $installParams = @{
            NoPath = $true
        }
        if ($originalVersion) {
            $installParams.CodexVersion = $originalVersion
        }
        if ($env:CODEX_KO_REPO) {
            $installParams.Repo = $env:CODEX_KO_REPO
        }
        & $installer @installParams
        if ($LASTEXITCODE -eq 0 -and (Test-Path $exe)) {
            Write-Host "GitHub Release에서 한국어 Codex 바이너리를 설치했습니다." -ForegroundColor Green
        }
    }
}

if (-not (Test-Path $exe)) {
    Write-Host "한국어 커스텀 Codex 바이너리가 아직 없습니다." -ForegroundColor Yellow
    Write-Host "먼저 실행하세요:"
    Write-Host "  $installer"
    Write-Host "사전 빌드 Release가 없으면 직접 빌드하세요:"
    Write-Host "  $installer -BuildIfMissing"
    exit 1
}

$builtVersion = Get-BuiltVersion

if ($env:CODEX_KO_NO_AUTO_UPDATE -ne "1" -and $builtVersion -and $originalVersion -and $builtVersion -ne $originalVersion) {
    Write-Host "원본 Codex 버전이 바뀌었습니다: $builtVersion -> $originalVersion" -ForegroundColor Yellow
    if ($env:CODEX_KO_NO_RELEASE_INSTALL -ne "1" -and (Test-Path $installer)) {
        Write-Host "먼저 GitHub Release 사전 빌드 설치를 시도합니다."
        $installParams = @{
            NoPath = $true
            CodexVersion = $originalVersion
        }
        if ($env:CODEX_KO_REPO) {
            $installParams.Repo = $env:CODEX_KO_REPO
        }
        & $installer @installParams
        if ($LASTEXITCODE -ne 0) {
            Write-Host "사전 빌드 설치에 실패했습니다. 기존 한국어 빌드로 계속 실행합니다." -ForegroundColor Yellow
            Write-Host "직접 빌드하려면 실행하세요: $installer -CodexVersion $originalVersion -BuildIfMissing"
        }
    }
    else {
        Write-Host "한국어 패치를 자동으로 다시 적용합니다."
        & $updater -Version $originalVersion -SkipMetadataSync
        if ($LASTEXITCODE -ne 0) {
            Write-Host "자동 업데이트에 실패했습니다. 기존 한국어 빌드로 계속 실행합니다." -ForegroundColor Yellow
        }
    }
}

if ($env:CODEX_KO_SKIP_METADATA_SYNC -ne "1" -and (Test-Path $metadataSync)) {
    try {
        & $metadataSync -Quiet
    }
    catch {
        Write-Host "스킬/플러그인 설명 자동 동기화에 실패했습니다. Codex는 계속 실행합니다." -ForegroundColor Yellow
        Write-Host $_.Exception.Message
    }
}

if ($env:CODEX_KO_TRANSLATE -ne "0" -and $env:CODEX_KO_SKIP_TRANSLATE_WATCHER -ne "1" -and (Test-Path $translationSync)) {
    try {
        $powershell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $powershell) {
            $powershell = (Get-Command powershell -ErrorAction SilentlyContinue).Source
        }
        if ($powershell) {
            $translationArgs = @(
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                $translationSync,
                "-Watch",
                "-ParentPid",
                [string]$PID,
                "-Quiet"
            )
            if ($env:CODEX_KO_TRANSLATE_AUTH) {
                $translationArgs += @("-Auth", $env:CODEX_KO_TRANSLATE_AUTH)
            }
            else {
                $translationArgs += @("-Auth", "codex")
            }
            Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList $translationArgs | Out-Null
        }
    }
    catch {
        Write-Host "동적 번역 watcher 시작에 실패했습니다. Codex는 계속 실행합니다." -ForegroundColor Yellow
        Write-Host $_.Exception.Message
    }
}

Show-TranslationStatusWarning

& $exe @args
exit $LASTEXITCODE
