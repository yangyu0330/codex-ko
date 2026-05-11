$ErrorActionPreference = "Stop"

function Get-CodexKoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path (Join-Path $scriptDir "..")).Path
}

function Write-CodexKoUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Read-CodexKoTomlSection {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Section
    )
    if (-not (Test-Path $Path)) {
        throw "Translation file not found: $Path"
    }

    $map = [ordered]@{}
    $active = $false
    foreach ($raw in [System.IO.File]::ReadLines($Path)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) {
            continue
        }
        if ($line -match '^\[(.+)\]$') {
            $active = ($Matches[1] -eq $Section)
            continue
        }
        if (-not $active) {
            continue
        }
        if ($line -match '^(?:"([^"]+)"|([A-Za-z0-9_.@-]+))\s*=\s*"(.*)"\s*$') {
            $key = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            $value = $Matches[3]
            $value = $value -replace '\\n', "`n"
            $value = $value -replace '\\"', '"'
            $value = $value -replace '\\\\', '\'
            $map[$key] = $value
        }
    }
    return $map
}

function ConvertTo-CodexKoRustString {
    param([AllowEmptyString()][string]$Value)
    return ($Value -replace '\\', '\\' -replace '"', '\"')
}

function ConvertTo-CodexKoYamlString {
    param([AllowEmptyString()][string]$Value)
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Get-CodexKoTimestamp {
    return (Get-Date).ToString("yyyyMMdd-HHmmss")
}

function Test-CodexKoCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    $null = Get-Command $Name -ErrorAction SilentlyContinue
    return $?
}
