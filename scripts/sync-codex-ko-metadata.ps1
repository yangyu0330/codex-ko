[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$Root = Get-CodexKoRoot
$TranslationPath = Join-Path $Root "translations\ko.toml"
$PendingDir = Join-Path $Root "translations\pending"

$SkillDescriptions = Read-CodexKoTomlSection $TranslationPath "skill_description"
$SkillPrompts = Read-CodexKoTomlSection $TranslationPath "skill_default_prompt"
$PluginDescriptions = Read-CodexKoTomlSection $TranslationPath "plugin_description"
$PluginPrompts = Read-CodexKoTomlSection $TranslationPath "plugin_default_prompt"

$CodexHome = Join-Path $env:USERPROFILE ".codex"
$BackupRoot = Join-Path $Root ("backups\metadata-" + (Get-CodexKoTimestamp))
$ScanRoots = @(
    (Join-Path $CodexHome "skills"),
    (Join-Path $CodexHome "plugins\cache")
) | Where-Object { Test-Path $_ }

$pending = New-Object System.Collections.Generic.List[string]
$changed = 0
$seen = 0

function Backup-CodexKoFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($DryRun) {
        return
    }
    $relative = $Path
    if ($relative.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($env:USERPROFILE.Length).TrimStart('\', '/')
    }
    $backupPath = Join-Path $BackupRoot $relative
    $backupDir = Split-Path -Parent $backupPath
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    if (-not (Test-Path $backupPath)) {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }
}

function Get-SkillIdFromOpenAiYaml {
    param([Parameter(Mandatory = $true)][string]$Path)
    $agentsDir = Split-Path -Parent $Path
    $rootDir = Split-Path -Parent $agentsDir
    $pluginJson = Join-Path $rootDir ".codex-plugin\plugin.json"
    if (Test-Path $pluginJson) {
        try {
            $json = [System.IO.File]::ReadAllText($pluginJson) | ConvertFrom-Json
            if ($json.name) {
                return [string]$json.name
            }
        }
        catch {
            # Fall back to the directory name below and let pending translations record it.
        }
    }
    return (Split-Path -Leaf $rootDir)
}

function Set-YamlStringValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $yamlValue = ConvertTo-CodexKoYamlString $Value
    $pattern = "(?m)^(\s*$([regex]::Escape($Key))\s*:\s*).*$"
    if ([regex]::IsMatch($Text, $pattern)) {
        return [regex]::Replace($Text, $pattern, "`${1}$yamlValue", 1)
    }
    if ([regex]::IsMatch($Text, '(?m)^interface:\s*$')) {
        return [regex]::Replace($Text, '(?m)^interface:\s*$', "interface:`n  ${Key}: $yamlValue", 1)
    }
    return $Text + "`ninterface:`n  ${Key}: $yamlValue`n"
}

function Update-OpenAiYaml {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:seen++
    $id = Get-SkillIdFromOpenAiYaml $Path
    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $original = $text

    if ($SkillDescriptions.Contains($id)) {
        $text = Set-YamlStringValue $text "short_description" $SkillDescriptions[$id]
    }
    elseif ($PluginDescriptions.Contains($id)) {
        $text = Set-YamlStringValue $text "short_description" $PluginDescriptions[$id]
    }
    else {
        $pending.Add("openai_yaml.$id = `"$(($Path -replace '\\', '/'))`"")
    }

    if ($SkillPrompts.Contains($id)) {
        $text = Set-YamlStringValue $text "default_prompt" $SkillPrompts[$id]
    }
    elseif ($PluginPrompts.Contains($id)) {
        $text = Set-YamlStringValue $text "default_prompt" $PluginPrompts[$id]
    }

    if ($text -ne $original) {
        $script:changed++
        if (-not $DryRun) {
            Backup-CodexKoFile $Path
            Write-CodexKoUtf8NoBom $Path $text
        }
        if (-not $Quiet) {
            Write-Host "Updated openai.yaml: $id"
        }
    }
}

function Update-PluginJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:seen++
    $raw = [System.IO.File]::ReadAllText($Path)
    $json = $raw | ConvertFrom-Json
    $id = [string]$json.name
    if (-not $id) {
        $pending.Add("plugin_json.unknown = `"$(($Path -replace '\\', '/'))`"")
        return
    }

    $wasChanged = $false
    if ($PluginDescriptions.Contains($id)) {
        $desc = $PluginDescriptions[$id]
        if ($json.PSObject.Properties.Name -contains "description") {
            if ([string]$json.description -ne $desc) {
                $json.description = $desc
                $wasChanged = $true
            }
        }
        if ($json.interface) {
            if ($json.interface.PSObject.Properties.Name -contains "shortDescription") {
                if ([string]$json.interface.shortDescription -ne $desc) {
                    $json.interface.shortDescription = $desc
                    $wasChanged = $true
                }
            }
            if ($json.interface.PSObject.Properties.Name -contains "longDescription") {
                if ([string]$json.interface.longDescription -ne $desc) {
                    $json.interface.longDescription = $desc
                    $wasChanged = $true
                }
            }
        }
    }
    else {
        $pending.Add("plugin_json.$id = `"$(($Path -replace '\\', '/'))`"")
    }

    if ($PluginPrompts.Contains($id) -and $json.interface) {
        $prompt = $PluginPrompts[$id]
        if ($json.interface.PSObject.Properties.Name -contains "defaultPrompt") {
            $currentPrompt = @($json.interface.defaultPrompt) -join "`n"
            if ($currentPrompt -ne $prompt) {
                $json.interface.defaultPrompt = @($prompt)
                $wasChanged = $true
            }
        }
    }

    if ($wasChanged) {
        $script:changed++
        if (-not $DryRun) {
            Backup-CodexKoFile $Path
            $updated = $json | ConvertTo-Json -Depth 32
            Write-CodexKoUtf8NoBom $Path ($updated + "`n")
        }
        if (-not $Quiet) {
            Write-Host "Updated plugin.json: $id"
        }
    }
}

foreach ($rootPath in $ScanRoots) {
    Get-ChildItem -LiteralPath $rootPath -Recurse -Force -Filter "openai.yaml" |
        ForEach-Object { Update-OpenAiYaml $_.FullName }
    Get-ChildItem -LiteralPath $rootPath -Recurse -Force -Filter "plugin.json" |
        Where-Object { $_.FullName -like "*\.codex-plugin\plugin.json" } |
        ForEach-Object { Update-PluginJson $_.FullName }
}

if ($pending.Count -gt 0) {
    $pendingPath = Join-Path $PendingDir ("metadata-" + (Get-CodexKoTimestamp) + ".toml")
    $content = "# Add Korean descriptions for these new or unknown metadata entries.`n" + (($pending | Sort-Object -Unique) -join "`n") + "`n"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $PendingDir | Out-Null
        Write-CodexKoUtf8NoBom $pendingPath $content
    }
    if (-not $Quiet) {
        Write-Host "Pending translations: $pendingPath"
    }
}

if (-not $Quiet) {
    Write-Host "Scanned metadata entries: $seen"
    Write-Host "Changed metadata entries: $changed"
}
