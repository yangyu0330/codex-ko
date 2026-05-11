[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$Root = Get-CodexKoRoot
$BinDir = Join-Path $Root "bin"
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @($UserPath -split ';' | Where-Object { $_ -and $_.Trim() -and $_ -ne $BinDir })
$newPath = $parts -join ';'
[Environment]::SetEnvironmentVariable("Path", $newPath, "User")

Write-Host "사용자 PATH에서 제거했습니다: $BinDir"
Write-Host "새 PowerShell 창을 열면 'codex'가 원본 설치본을 다시 사용합니다."
