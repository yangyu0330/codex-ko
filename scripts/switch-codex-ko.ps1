[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$Root = Get-CodexKoRoot
$BinDir = Join-Path $Root "bin"
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @($UserPath -split ';' | Where-Object { $_ -and $_.Trim() })

if ($parts -notcontains $BinDir) {
    $newPath = (@($BinDir) + $parts) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "사용자 PATH 앞쪽에 추가했습니다: $BinDir"
}
else {
    Write-Host "이미 PATH에 들어 있습니다: $BinDir"
}

Write-Host "새 PowerShell 창을 열면 'codex'와 'codex-ko'가 한국어 launcher를 사용합니다."
