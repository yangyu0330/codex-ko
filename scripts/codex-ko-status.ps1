[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$FixStaleLock
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$Root = Get-CodexKoRoot
$BinDir = Join-Path $Root "bin"
$ExePath = Join-Path $BinDir "codex.exe"
$PendingExePath = Join-Path $BinDir "codex.exe.next"
$LauncherPath = Join-Path $BinDir "codex.ps1"
$StatePath = Join-Path $Root "state.json"
$TranslationsDir = Join-Path $Root "translations"
$CachePath = Join-Path $TranslationsDir "dynamic-cache.json"
$OverridesPath = Join-Path $TranslationsDir "ko-overrides.json"
$GlossaryPath = Join-Path $TranslationsDir "glossary.json"
$StatusPath = Join-Path $TranslationsDir "dynamic-status.json"
$LockPath = Join-Path $TranslationsDir "dynamic-translate.lock"
$PendingPath = Join-Path $TranslationsDir "pending\dynamic-pending.jsonl"
$ErrorLogPath = Join-Path $Root "logs\dynamic-translate-errors.log"

function Read-KoJson {
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

function Get-Sha256Hex {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-VersionText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) {
        return ""
    }
    try {
        $output = (& $Path --version 2>$null) -join "`n"
        if ($output -match '(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)') {
            return $Matches[1]
        }
        return $output.Trim()
    }
    catch {
        return ""
    }
}

function Get-ObjectPropertyCount {
    param($Object)
    if (-not $Object) {
        return 0
    }
    return @($Object.PSObject.Properties).Count
}

function Get-CacheEntryCount {
    $cache = Read-KoJson $CachePath
    if ($cache -and $cache.entries) {
        return Get-ObjectPropertyCount $cache.entries
    }
    return 0
}

function Get-OverrideEntryCount {
    $overrides = Read-KoJson $OverridesPath
    if ($overrides -and $overrides.entries) {
        return @($overrides.entries).Count
    }
    return 0
}

function Get-GlossaryTermCount {
    $glossary = Read-KoJson $GlossaryPath
    if ($glossary -and $glossary.terms) {
        return Get-ObjectPropertyCount $glossary.terms
    }
    return 0
}

function Get-PendingRecords {
    $records = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $PendingPath)) {
        return $records
    }
    foreach ($line in [System.IO.File]::ReadLines($PendingPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $record = $line | ConvertFrom-Json
        }
        catch {
            continue
        }
        $kind = [string]$record.kind
        $sourceId = [string]$record.source_id
        $original = [string]$record.original_text
        if ([string]::IsNullOrWhiteSpace($kind) -or [string]::IsNullOrWhiteSpace($original)) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($sourceId)) {
            $sourceId = "unknown"
        }
        $sha = if ($record.sha256) { [string]$record.sha256 } else { Get-Sha256Hex $original.Trim() }
        $key = if ($record.key) { [string]$record.key } else { "$kind|$sourceId|$sha" }
        $records.Add([pscustomobject]@{
            key = $key
            kind = $kind
            source_id = $sourceId
            sha256 = $sha
            original_text = $original.Trim()
        })
    }
    return $records
}

function New-TranslationIndex {
    $index = [ordered]@{
        keys = @{}
        kind_sha = @{}
        sha = @{}
    }

    $cache = Read-KoJson $CachePath
    if ($cache -and $cache.entries) {
        foreach ($prop in $cache.entries.PSObject.Properties) {
            $entry = $prop.Value
            $index.keys[$prop.Name] = $true
            if ($entry.kind -and $entry.sha256) {
                $index.kind_sha["$($entry.kind)|$($entry.sha256)"] = $true
            }
        }
    }

    $overrides = Read-KoJson $OverridesPath
    if ($overrides -and $overrides.entries) {
        foreach ($entry in @($overrides.entries)) {
            $kind = [string]$entry.kind
            $sourceId = [string]$entry.source_id
            $original = [string]$entry.original_text
            if ([string]::IsNullOrWhiteSpace($original)) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($kind)) {
                $kind = "*"
            }
            if ([string]::IsNullOrWhiteSpace($sourceId)) {
                $sourceId = "override"
            }
            $sha = if ($entry.sha256) { [string]$entry.sha256 } else { Get-Sha256Hex $original.Trim() }
            if ($kind -ne "*") {
                $index.kind_sha["$kind|$sha"] = $true
                $index.keys["$kind|$sourceId|$sha"] = $true
            }
            $index.sha[$sha] = $true
        }
    }
    return $index
}

function Get-UncachedPendingCount {
    $index = New-TranslationIndex
    $seen = @{}
    $uncached = 0
    foreach ($record in @(Get-PendingRecords)) {
        if ($seen.ContainsKey($record.key)) {
            continue
        }
        $seen[$record.key] = $true
        if (
            -not $index.keys.ContainsKey($record.key) -and
            -not $index.kind_sha.ContainsKey("$($record.kind)|$($record.sha256)") -and
            -not $index.sha.ContainsKey($record.sha256)
        ) {
            $uncached++
        }
    }
    return $uncached
}

function Get-WatcherInfo {
    $info = [ordered]@{
        lock_exists = Test-Path $LockPath
        pid = 0
        alive = $false
        stale_lock_removed = $false
    }
    if (-not $info.lock_exists) {
        return $info
    }
    try {
        $pidText = [System.IO.File]::ReadAllText($LockPath).Trim()
        if ($pidText) {
            $info.pid = [int]$pidText
            $info.alive = [bool](Get-Process -Id $info.pid -ErrorAction SilentlyContinue)
        }
    }
    catch {
    }
    if ($FixStaleLock -and -not $info.alive) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        $info.lock_exists = $false
        $info.stale_lock_removed = $true
    }
    return $info
}

function Get-FirstCodexCommand {
    $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        return ""
    }
    return [string]$commands[0].Source
}

$warnings = New-Object System.Collections.Generic.List[string]
$errors = New-Object System.Collections.Generic.List[string]

$state = Read-KoJson $StatePath
$dynamicStatus = Read-KoJson $StatusPath
$watcher = Get-WatcherInfo
$firstCodexCommand = Get-FirstCodexCommand
$exeVersion = Get-VersionText $ExePath
$pendingVersion = if ((Test-Path $PendingExePath) -and $state -and $state.version) { [string]$state.version } else { "" }
$cacheCount = Get-CacheEntryCount
$overrideCount = Get-OverrideEntryCount
$glossaryCount = Get-GlossaryTermCount
$pendingRecords = @(Get-PendingRecords)
$pendingTotal = $pendingRecords.Count
$pendingUncached = Get-UncachedPendingCount
$authMode = if ($env:CODEX_KO_TRANSLATE_AUTH) { $env:CODEX_KO_TRANSLATE_AUTH } else { "codex" }

if (-not (Test-Path $ExePath)) {
    $errors.Add("한국어 Codex 실행 파일이 없습니다: $ExePath")
}
if (Test-Path $PendingExePath) {
    $warnings.Add("새 바이너리가 codex.exe.next로 대기 중입니다. Codex를 완전히 종료한 뒤 다시 열면 적용됩니다.")
}
if ($state -and $state.pending) {
    $warnings.Add("state.json 기준으로 아직 대기 중인 빌드가 있습니다.")
}
if ($watcher.lock_exists -and -not $watcher.alive) {
    $warnings.Add("번역 watcher lock 파일이 남아 있지만 프로세스는 실행 중이 아닙니다. -FixStaleLock으로 정리할 수 있습니다.")
}
if ($pendingUncached -gt 0 -and -not $watcher.alive -and $env:CODEX_KO_TRANSLATE -ne "0") {
    $warnings.Add("아직 캐시되지 않은 설명 $pendingUncached개가 있지만 번역 watcher가 실행 중이 아닙니다.")
}
if ($env:CODEX_KO_TRANSLATE -eq "0") {
    $warnings.Add("CODEX_KO_TRANSLATE=0 이라 동적 번역이 꺼져 있습니다.")
}
if ($firstCodexCommand -and -not $firstCodexCommand.StartsWith($BinDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    $warnings.Add("PATH에서 먼저 잡히는 codex가 한국어 launcher가 아닙니다: $firstCodexCommand")
}
if ($dynamicStatus -and $dynamicStatus.last_error) {
    $warnings.Add("최근 번역 오류: $($dynamicStatus.last_error)")
}

$recentErrors = @()
if (Test-Path $ErrorLogPath) {
    $recentErrors = @(Get-Content -LiteralPath $ErrorLogPath -Encoding UTF8 -Tail 5)
}

$payload = [ordered]@{
    root = $Root
    binary = [ordered]@{
        path = $ExePath
        exists = Test-Path $ExePath
        version = $exeVersion
        pending_path = $PendingExePath
        pending_exists = Test-Path $PendingExePath
        pending_version = $pendingVersion
        state_pending = if ($state) { [bool]$state.pending } else { $false }
        state_version = if ($state -and $state.version) { [string]$state.version } else { "" }
    }
    path = [ordered]@{
        first_codex = $firstCodexCommand
        launcher = $LauncherPath
    }
    translation = [ordered]@{
        auth = $authMode
        enabled = ($env:CODEX_KO_TRANSLATE -ne "0")
        cache_count = $cacheCount
        override_count = $overrideCount
        glossary_count = $glossaryCount
        pending_total = $pendingTotal
        pending_uncached = $pendingUncached
        status = $dynamicStatus
        watcher = $watcher
    }
    warnings = @($warnings)
    errors = @($errors)
    recent_errors = $recentErrors
}

if ($Json) {
    $payload | ConvertTo-Json -Depth 12
}
else {
    $currentBinaryText = if (Test-Path $ExePath) { "$ExePath ($exeVersion)" } else { "없음" }
    $pendingBinaryText = if (Test-Path $PendingExePath) { "$PendingExePath ($pendingVersion)" } else { "없음" }
    $pathText = if ($firstCodexCommand) { $firstCodexCommand } else { "codex 명령을 찾지 못함" }
    $translationEnabledText = if ($env:CODEX_KO_TRANSLATE -eq "0") { "꺼짐" } else { "켜짐" }
    $watcherText = if ($watcher.alive) {
        "실행 중(PID $($watcher.pid))"
    }
    elseif ($watcher.lock_exists) {
        "꺼짐, lock 남음(PID $($watcher.pid))"
    }
    else {
        "꺼짐"
    }
    $lastSuccessText = if ($dynamicStatus -and $dynamicStatus.last_success_at) { [string]$dynamicStatus.last_success_at } else { "없음" }
    $lastErrorText = if ($dynamicStatus -and $dynamicStatus.last_error) { [string]$dynamicStatus.last_error } else { "없음" }

    Write-Host "Codex 한국어 상태"
    Write-Host "Root: $Root"
    Write-Host ""
    Write-Host "바이너리"
    Write-Host "  현재:  $currentBinaryText"
    Write-Host "  대기:  $pendingBinaryText"
    Write-Host "  PATH:  $pathText"
    Write-Host ""
    Write-Host "번역"
    Write-Host "  인증 방식: $authMode"
    Write-Host "  동적 번역: $translationEnabledText"
    Write-Host "  캐시/고정사전/용어집: $cacheCount / $overrideCount / $glossaryCount"
    Write-Host "  pending 전체/미캐시: $pendingTotal / $pendingUncached"
    Write-Host "  watcher: $watcherText"
    if ($dynamicStatus) {
        Write-Host "  마지막 성공: $lastSuccessText"
        Write-Host "  마지막 오류: $lastErrorText"
    }
    if ($watcher.stale_lock_removed) {
        Write-Host "  오래된 watcher lock을 정리했습니다."
    }
    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "경고"
        foreach ($warning in $warnings) {
            Write-Host "  - $warning"
        }
    }
    if ($errors.Count -gt 0) {
        Write-Host ""
        Write-Host "오류"
        foreach ($errorMessage in $errors) {
            Write-Host "  - $errorMessage"
        }
    }
}

if ($errors.Count -gt 0) {
    exit 2
}
if ($warnings.Count -gt 0) {
    exit 1
}
exit 0
