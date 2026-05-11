[CmdletBinding()]
param(
    [ValidateSet("auto", "codex", "api")]
    [string]$Auth = "codex",
    [int]$MaxItems = 20,
    [switch]$Watch,
    [int]$IntervalSeconds = 30,
    [int]$ParentPid = 0,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$Root = Get-CodexKoRoot
$TranslationsDir = Join-Path $Root "translations"
$PendingDir = Join-Path $TranslationsDir "pending"
$PendingPath = Join-Path $PendingDir "dynamic-pending.jsonl"
$CachePath = Join-Path $TranslationsDir "dynamic-cache.json"
$LogDir = Join-Path $Root "logs"
$LogPath = Join-Path $LogDir "dynamic-translate.log"
$ErrorLogPath = Join-Path $LogDir "dynamic-translate-errors.log"
$LockPath = Join-Path $TranslationsDir "dynamic-translate.lock"
$StatusPath = Join-Path $TranslationsDir "dynamic-status.json"
$OverridesPath = Join-Path $TranslationsDir "ko-overrides.json"
$GlossaryPath = Join-Path $TranslationsDir "glossary.json"

New-Item -ItemType Directory -Force -Path $TranslationsDir, $PendingDir, $LogDir | Out-Null

if (-not $PSBoundParameters.ContainsKey("Auth") -and $env:CODEX_KO_TRANSLATE_AUTH) {
    $envAuth = $env:CODEX_KO_TRANSLATE_AUTH.ToLowerInvariant()
    if (@("auto", "codex", "api") -contains $envAuth) {
        $Auth = $envAuth
    }
}

function Write-TranslateLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    if (-not $Quiet) {
        Write-Host $line
    }
}

function Read-CodexKoJson {
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

function Get-CacheEntryCount {
    $json = Read-CodexKoJson $CachePath
    if ($json -and $json.entries) {
        return @($json.entries.PSObject.Properties).Count
    }
    return 0
}

function Get-PendingLineCount {
    if (-not (Test-Path $PendingPath)) {
        return 0
    }
    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($PendingPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $count++
        }
    }
    return $count
}

function Write-TranslateErrorLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message"
    Add-Content -LiteralPath $ErrorLogPath -Value $line -Encoding UTF8
}

function Write-TranslateStatus {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [string]$LastError = "",
        [int]$Processed = 0,
        [int]$Cached = 0,
        [int]$Alias = 0,
        [int]$Override = 0
    )

    $now = (Get-Date).ToString("o")
    $existing = Read-CodexKoJson $StatusPath
    $lastSuccessAt = ""
    $lastErrorAt = ""
    $lastErrorText = ""

    if ($existing) {
        if ($existing.last_success_at) { $lastSuccessAt = [string]$existing.last_success_at }
        if ($existing.last_error_at) { $lastErrorAt = [string]$existing.last_error_at }
        if ($existing.last_error) { $lastErrorText = [string]$existing.last_error }
    }

    if ($State -eq "success") {
        $lastSuccessAt = $now
        $lastErrorAt = ""
        $lastErrorText = ""
    }
    elseif ($LastError) {
        $lastErrorAt = $now
        $lastErrorText = $LastError
    }

    $payload = [ordered]@{
        version = 1
        updated_at = $now
        state = $State
        auth = $Auth
        watcher = [bool]$Watch
        pid = $PID
        parent_pid = $ParentPid
        cache_count = Get-CacheEntryCount
        pending_count = Get-PendingLineCount
        pending_uncached_count = Get-UncachedPendingLineCount
        processed_count = $Processed
        cached_count = $Cached
        alias_count = $Alias
        override_count = $Override
        last_success_at = $lastSuccessAt
        last_error_at = $lastErrorAt
        last_error = $lastErrorText
        lock_path = $LockPath
        cache_path = $CachePath
        pending_path = $PendingPath
    }
    Write-CodexKoUtf8NoBom $StatusPath (($payload | ConvertTo-Json -Depth 8) + "`n")
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

function New-DynamicCache {
    return [ordered]@{
        version = 1
        entries = [ordered]@{}
    }
}

function Read-DynamicCache {
    $cache = New-DynamicCache
    if (-not (Test-Path $CachePath)) {
        return $cache
    }
    try {
        $raw = [System.IO.File]::ReadAllText($CachePath)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $cache
        }
        $json = $raw | ConvertFrom-Json
        if ($json.version) {
            $cache.version = [int]$json.version
        }
        if ($json.entries) {
            foreach ($prop in $json.entries.PSObject.Properties) {
                $cache.entries[$prop.Name] = $prop.Value
            }
        }
    }
    catch {
        $backup = "$CachePath.bak-$(Get-CodexKoTimestamp)"
        Copy-Item -LiteralPath $CachePath -Destination $backup -Force
        Write-TranslateLog "Cache was unreadable; backed up to $backup"
    }
    return $cache
}

function Save-DynamicCache {
    param([Parameter(Mandatory = $true)]$Cache)
    $tmp = "$CachePath.tmp"
    $text = $Cache | ConvertTo-Json -Depth 12
    Write-CodexKoUtf8NoBom $tmp ($text + "`n")
    Move-Item -LiteralPath $tmp -Destination $CachePath -Force
}

function Get-PendingRecords {
    param([Parameter(Mandatory = $true)]$Cache)
    $records = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $PendingPath)) {
        return $records
    }

    $cachedByKindSha = @{}
    foreach ($entryProperty in $Cache.entries.GetEnumerator()) {
        $entry = $entryProperty.Value
        if ($entry.kind -and $entry.sha256) {
            $cachedByKindSha["$($entry.kind)|$($entry.sha256)"] = $true
        }
    }

    $seen = @{}
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
        $sha = if ($record.sha256) { [string]$record.sha256 } else { Get-Sha256Hex $original }
        $key = if ($record.key) { [string]$record.key } else { "$kind|$sourceId|$sha" }
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if (-not $Force -and ($Cache.entries.Contains($key) -or $cachedByKindSha.ContainsKey("$kind|$sha"))) {
            continue
        }
        $records.Add([pscustomobject]@{
            key = $key
            kind = $kind
            source_id = $sourceId
            sha256 = $sha
            original_text = $original
        })
        if ($records.Count -ge $MaxItems) {
            break
        }
    }
    return $records
}

function ConvertFrom-ModelJson {
    param([Parameter(Mandatory = $true)][string]$Text)
    $trimmed = $Text.Trim()
    if ($trimmed -match '(?s)^```(?:json)?\s*(.*?)\s*```$') {
        $trimmed = $Matches[1].Trim()
    }
    if (-not $trimmed.StartsWith("{")) {
        $match = [regex]::Match($trimmed, '(?s)\{.*\}')
        if ($match.Success) {
            $trimmed = $match.Value
        }
    }
    return $trimmed | ConvertFrom-Json
}

function Get-GlossaryPrompt {
    $json = Read-CodexKoJson $GlossaryPath
    if (-not $json -or -not $json.terms) {
        return ""
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $json.terms.PSObject.Properties) {
        $source = [string]$prop.Name
        $target = [string]$prop.Value
        if ($source -and $target) {
            $lines.Add("- $source => $target")
        }
    }
    if ($lines.Count -eq 0) {
        return ""
    }
    return "Use this glossary consistently:`n$($lines -join "`n")"
}

function Get-OverrideEntries {
    $entries = New-Object System.Collections.Generic.List[object]
    $json = Read-CodexKoJson $OverridesPath
    if (-not $json -or -not $json.entries) {
        return $entries
    }

    foreach ($entry in @($json.entries)) {
        $kind = [string]$entry.kind
        $sourceId = [string]$entry.source_id
        $original = [string]$entry.original_text
        $ko = [string]$entry.ko_text
        if ([string]::IsNullOrWhiteSpace($kind)) {
            $kind = "*"
        }
        if ([string]::IsNullOrWhiteSpace($sourceId)) {
            $sourceId = "override"
        }
        if ([string]::IsNullOrWhiteSpace($original) -or [string]::IsNullOrWhiteSpace($ko)) {
            continue
        }
        $sha = if ($entry.sha256) { [string]$entry.sha256 } else { Get-Sha256Hex $original.Trim() }
        $entries.Add([pscustomobject]@{
            kind = $kind
            source_id = $sourceId
            sha256 = $sha
            original_text = $original.Trim()
            ko_text = $ko.Trim()
        })
    }
    return $entries
}

function Add-OverrideCacheEntries {
    param([Parameter(Mandatory = $true)]$Cache)
    if (-not (Test-Path $PendingPath)) {
        return 0
    }

    $overrides = @(Get-OverrideEntries)
    if ($overrides.Count -eq 0) {
        return 0
    }

    $byKindSha = @{}
    $bySha = @{}
    foreach ($override in $overrides) {
        if ($override.kind -ne "*") {
            $byKindSha["$($override.kind)|$($override.sha256)"] = $override
        }
        if (-not $bySha.ContainsKey($override.sha256)) {
            $bySha[$override.sha256] = $override
        }
    }

    $now = (Get-Date).ToString("o")
    $added = 0
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
        if ($Cache.entries.Contains($key)) {
            continue
        }

        $override = $null
        $kindSha = "$kind|$sha"
        if ($byKindSha.ContainsKey($kindSha)) {
            $override = $byKindSha[$kindSha]
        }
        elseif ($bySha.ContainsKey($sha)) {
            $override = $bySha[$sha]
        }
        if (-not $override) {
            continue
        }

        $Cache.entries[$key] = [ordered]@{
            kind = $kind
            source_id = $sourceId
            sha256 = $sha
            original_text = $original.Trim()
            ko_text = [string]$override.ko_text
            auth = "override"
            model = ""
            created_at = $now
            last_used_at = $now
            override = $true
        }
        $added++
    }
    return $added
}

function Invoke-CodexOAuthTranslation {
    param([Parameter(Mandatory = $true)][object[]]$Records)
    $codexExe = Join-Path $Root "bin\codex.exe"
    if (-not (Test-Path $codexExe)) {
        throw "codex.exe not found for Codex OAuth translation: $codexExe"
    }

    $idToKey = @{}
    $index = 0
    $items = $Records | ForEach-Object {
        $id = "item_$index"
        $idToKey[$id] = $_.key
        $index++
        [ordered]@{
            id = $id
            text = $_.original_text
        }
    }
    $itemsJson = $items | ConvertTo-Json -Depth 8
    $glossary = Get-GlossaryPrompt
    $prompt = @"
You are a Korean UI localization engine for Codex.

Translate each English UI/tool description into natural Korean for a beginner Codex user.
Keep command names, tool names, API names, file paths, code identifiers, and placeholders exactly as-is.
Make short descriptions more concrete when that helps a new user, but do not invent behavior.
Do not call tools. Return only valid JSON in this shape:
{"translations":[{"id":"same id","ko_text":"Korean translation"}]}

$glossary

Items:
$itemsJson
"@

    $tmpRoot = Join-Path $env:TEMP ("codex-ko-translate-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $promptPath = Join-Path $tmpRoot "prompt.txt"
    $outputPath = Join-Path $tmpRoot "output.json"
    $execLogPath = Join-Path $tmpRoot "codex-exec.log"
    try {
        Write-CodexKoUtf8NoBom $promptPath $prompt
        $args = @(
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--disable",
            "shell_tool",
            "--sandbox",
            "read-only",
            "--output-last-message",
            $outputPath
        )
        if ($env:CODEX_KO_TRANSLATE_MODEL) {
            $args += @("--model", $env:CODEX_KO_TRANSLATE_MODEL)
        }
        $args += "-"

        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            Get-Content -LiteralPath $promptPath -Raw | & $codexExe @args *> $execLogPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($exitCode -ne 0) {
            $log = if (Test-Path $execLogPath) { [System.IO.File]::ReadAllText($execLogPath) } else { "" }
            throw "codex exec translation failed with exit code $exitCode. $log"
        }
        $text = [System.IO.File]::ReadAllText($outputPath)
        $result = ConvertFrom-ModelJson $text
        foreach ($translation in @($result.translations)) {
            $id = [string]$translation.id
            if ($idToKey.ContainsKey($id)) {
                $translation.id = $idToKey[$id]
            }
        }
        return $result
    }
    finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ApiTranslation {
    param([Parameter(Mandatory = $true)][object[]]$Records)
    $apiKey = if ($env:CODEX_KO_OPENAI_API_KEY) { $env:CODEX_KO_OPENAI_API_KEY } else { $env:OPENAI_API_KEY }
    if (-not $apiKey) {
        throw "No API key found in CODEX_KO_OPENAI_API_KEY or OPENAI_API_KEY."
    }
    $model = if ($env:CODEX_KO_TRANSLATE_MODEL) { $env:CODEX_KO_TRANSLATE_MODEL } else { "gpt-5-nano" }
    $idToKey = @{}
    $index = 0
    $items = $Records | ForEach-Object {
        $id = "item_$index"
        $idToKey[$id] = $_.key
        $index++
        [ordered]@{
            id = $id
            text = $_.original_text
        }
    }
    $itemsJson = $items | ConvertTo-Json -Depth 8
    $glossary = Get-GlossaryPrompt
    $prompt = @"
Translate these Codex UI/tool descriptions into beginner-friendly Korean.
Keep command names, tool names, API names, file paths, code identifiers, and placeholders exactly as-is.
Make terse descriptions clearer for a new Codex user, but do not invent behavior.
Return only JSON: {"translations":[{"id":"same id","ko_text":"Korean translation"}]}

$glossary

$itemsJson
"@
    $body = @{
        model = $model
        input = $prompt
    } | ConvertTo-Json -Depth 8
    $response = Invoke-RestMethod -Method Post -Uri "https://api.openai.com/v1/responses" -ContentType "application/json" -Headers @{
        Authorization = "Bearer $apiKey"
    } -Body $body

    $text = ""
    if ($response.output_text) {
        $text = [string]$response.output_text
    }
    elseif ($response.output) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $response.output) {
            foreach ($content in @($item.content)) {
                if ($content.text) {
                    $parts.Add([string]$content.text)
                }
            }
        }
        $text = ($parts -join "`n")
    }
    if (-not $text) {
        throw "API response did not contain output text."
    }
    $result = ConvertFrom-ModelJson $text
    foreach ($translation in @($result.translations)) {
        $id = [string]$translation.id
        if ($idToKey.ContainsKey($id)) {
            $translation.id = $idToKey[$id]
        }
    }
    return $result
}

function Invoke-TranslationBatch {
    param([Parameter(Mandatory = $true)][object[]]$Records)
    if ($Auth -eq "codex" -or $Auth -eq "auto") {
        try {
            return Invoke-CodexOAuthTranslation $Records
        }
        catch {
            if ($Auth -eq "codex") {
                throw
            }
            Write-TranslateLog "Codex OAuth translation failed; trying API fallback. $($_.Exception.Message)"
        }
    }
    return Invoke-ApiTranslation $Records
}

function Add-PendingCacheAliases {
    param([Parameter(Mandatory = $true)]$Cache)
    if (-not (Test-Path $PendingPath)) {
        return 0
    }

    $byKindSha = @{}
    foreach ($entryProperty in $Cache.entries.GetEnumerator()) {
        $entry = $entryProperty.Value
        if ($entry.kind -and $entry.sha256 -and $entry.ko_text) {
            $byKindSha["$($entry.kind)|$($entry.sha256)"] = $entry
        }
    }

    $now = (Get-Date).ToString("o")
    $added = 0
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
        $sha = if ($record.sha256) { [string]$record.sha256 } else { Get-Sha256Hex $original }
        $key = if ($record.key) { [string]$record.key } else { "$kind|$sourceId|$sha" }
        if ($Cache.entries.Contains($key)) {
            continue
        }
        $aliasSource = $byKindSha["$kind|$sha"]
        if (-not $aliasSource) {
            continue
        }
        $Cache.entries[$key] = [ordered]@{
            kind = $kind
            source_id = $sourceId
            sha256 = $sha
            original_text = $original
            ko_text = [string]$aliasSource.ko_text
            auth = if ($aliasSource.auth) { [string]$aliasSource.auth } else { "cache-alias" }
            model = if ($aliasSource.model) { [string]$aliasSource.model } else { "" }
            created_at = $now
            last_used_at = $now
            alias = $true
        }
        $added++
    }
    return $added
}

function Get-UncachedPendingLineCount {
    if (-not (Test-Path $PendingPath)) {
        return 0
    }

    $cache = Read-DynamicCache
    $cachedKeys = @{}
    $cachedKindSha = @{}
    foreach ($entryProperty in $cache.entries.GetEnumerator()) {
        $cachedKeys[$entryProperty.Key] = $true
        $entry = $entryProperty.Value
        if ($entry.kind -and $entry.sha256) {
            $cachedKindSha["$($entry.kind)|$($entry.sha256)"] = $true
        }
    }

    $overrideKindSha = @{}
    $overrideSha = @{}
    foreach ($override in @(Get-OverrideEntries)) {
        if ($override.kind -ne "*") {
            $overrideKindSha["$($override.kind)|$($override.sha256)"] = $true
        }
        $overrideSha[$override.sha256] = $true
    }

    $seen = @{}
    $count = 0
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
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if (
            -not $cachedKeys.ContainsKey($key) -and
            -not $cachedKindSha.ContainsKey("$kind|$sha") -and
            -not $overrideKindSha.ContainsKey("$kind|$sha") -and
            -not $overrideSha.ContainsKey($sha)
        ) {
            $count++
        }
    }
    return $count
}

function Invoke-OnePass {
    Write-TranslateStatus "running"
    $cache = Read-DynamicCache
    $overrideCount = Add-OverrideCacheEntries $cache
    $aliasCount = Add-PendingCacheAliases $cache
    $records = @(Get-PendingRecords $cache)
    if ($records.Count -eq 0) {
        if ($overrideCount -gt 0 -or $aliasCount -gt 0) {
            Save-DynamicCache $cache
            Write-TranslateLog "Cached $overrideCount override translation(s), plus $aliasCount alias translation(s)."
        }
        Write-TranslateStatus "success" -Override $overrideCount -Alias $aliasCount
        return
    }
    if ($overrideCount -gt 0 -or $aliasCount -gt 0) {
        Save-DynamicCache $cache
    }
    Write-TranslateLog "Translating $($records.Count) pending description(s) using auth=$Auth."
    $result = Invoke-TranslationBatch $records
    $translations = @($result.translations)
    $byId = @{}
    foreach ($translation in $translations) {
        $id = [string]$translation.id
        $ko = [string]$translation.ko_text
        if ($id -and $ko) {
            $byId[$id] = $ko
        }
    }
    $now = (Get-Date).ToString("o")
    $updated = 0
    foreach ($record in $records) {
        if (-not $byId.ContainsKey($record.key)) {
            continue
        }
        $cache.entries[$record.key] = [ordered]@{
            kind = $record.kind
            source_id = $record.source_id
            sha256 = $record.sha256
            original_text = $record.original_text
            ko_text = $byId[$record.key]
            auth = $Auth
            model = if ($env:CODEX_KO_TRANSLATE_MODEL) { $env:CODEX_KO_TRANSLATE_MODEL } else { "" }
            created_at = $now
            last_used_at = $now
        }
        $updated++
    }
    if ($updated -gt 0 -or $aliasCount -gt 0) {
        Save-DynamicCache $cache
    }
    Write-TranslateLog "Cached $updated Korean translation(s), plus $overrideCount override and $aliasCount alias translation(s)."
    Write-TranslateStatus "success" -Processed $records.Count -Cached $updated -Override $overrideCount -Alias $aliasCount
}

function Test-ParentAlive {
    if ($ParentPid -le 0) {
        return $true
    }
    return [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}

if ($env:CODEX_KO_TRANSLATE -eq "0") {
    exit 0
}

if ($Watch) {
    if (Test-Path $LockPath) {
        try {
            $existingPid = [int]([System.IO.File]::ReadAllText($LockPath).Trim())
            if (Get-Process -Id $existingPid -ErrorAction SilentlyContinue) {
                exit 0
            }
        }
        catch {
        }
    }
    Write-CodexKoUtf8NoBom $LockPath ([string]$PID)
}

try {
    do {
        try {
            Invoke-OnePass
        }
        catch {
            $message = $_.Exception.Message
            Write-TranslateLog "Translation pass failed: $message"
            Write-TranslateErrorLog $message
            Write-TranslateStatus "error" -LastError $message
        }
        if (-not $Watch) {
            break
        }
        Start-Sleep -Seconds ([Math]::Max(5, $IntervalSeconds))
    } while (Test-ParentAlive)
}
finally {
    if ($Watch) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        Write-TranslateStatus "stopped"
    }
}
