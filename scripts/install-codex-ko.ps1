[CmdletBinding()]
param(
    [string]$Repo = "",
    [string]$CodexVersion = "",
    [string]$InstallDir = "",
    [switch]$BuildIfMissing,
    [switch]$NoPath,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$DefaultRoot = Get-CodexKoRoot
$Root = if ($InstallDir) {
    [System.IO.Path]::GetFullPath($InstallDir)
}
else {
    $DefaultRoot
}

$BinDir = Join-Path $Root "bin"
$FinalExe = Join-Path $BinDir "codex.exe"
$NextExe = Join-Path $BinDir "codex.exe.next"
$PreviousExe = Join-Path $BinDir "codex.exe.previous"
$StatePath = Join-Path $Root "state.json"
$Updater = Join-Path $Root "scripts\update-codex-ko.ps1"
$SwitchScript = Join-Path $Root "scripts\switch-codex-ko.ps1"
$Launcher = Join-Path $Root "bin\codex-ko-launch.ps1"

function Write-InstallStep {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[codex-ko] $Message"
}

function Get-VersionFromText {
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)') {
        return $Matches[1]
    }
    return ""
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $Path
    return $hash.Hash.ToLowerInvariant()
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
        if ($source.StartsWith($BinDir, [System.StringComparison]::OrdinalIgnoreCase)) {
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

function Get-InstalledKoreanVersion {
    if (-not (Test-Path $FinalExe)) {
        return ""
    }
    try {
        return Get-VersionFromText ((& $FinalExe --version 2>$null) -join "`n")
    }
    catch {
        return ""
    }
}

function Resolve-GitHubRepo {
    if ($Repo) {
        return $Repo.Trim()
    }
    if ($env:CODEX_KO_REPO) {
        return $env:CODEX_KO_REPO.Trim()
    }
    try {
        $remote = (& git -C $Root remote get-url origin 2>$null) -join ""
        if ($remote -match 'github\.com[:/](?<owner>[^/\s:]+)/(?<repo>[^/\s]+?)(?:\.git)?$') {
            return "$($Matches.owner)/$($Matches.repo)"
        }
    }
    catch {
    }
    return ""
}

function Assert-RepoShape {
    if ((Test-Path $Launcher) -and (Test-Path $Updater)) {
        return
    }
    if ($DryRun) {
        Write-InstallStep "DRY-RUN: 설치 폴더가 아직 준비되지 않아 구조 검사를 건너뜁니다: $Root"
        return
    }
    if (-not (Test-Path $Launcher)) {
        throw "설치 폴더에 launcher가 없습니다: $Launcher"
    }
    throw "설치 폴더에 update 스크립트가 없습니다: $Updater"
}

function Install-CodexKoBinary {
    param(
        [Parameter(Mandatory = $true)][string]$BuiltExe,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$InstallMethod,
        [string]$ReleaseRepo = "",
        [string]$ReleaseTag = "",
        [string]$ReleaseAsset = "",
        [string]$SourceRef = ""
    )

    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $tempExe = "$FinalExe.tmp"
    Copy-Item -LiteralPath $BuiltExe -Destination $tempExe -Force

    $installed = $false
    $pending = $false
    $pendingReason = ""
    try {
        if (Test-Path $FinalExe) {
            Remove-Item -LiteralPath $PreviousExe -Force -ErrorAction SilentlyContinue
            [System.IO.File]::Replace($tempExe, $FinalExe, $PreviousExe, $true)
            Remove-Item -LiteralPath $PreviousExe -Force -ErrorAction SilentlyContinue
        }
        else {
            Move-Item -LiteralPath $tempExe -Destination $FinalExe -Force
        }
        Remove-Item -LiteralPath $NextExe -Force -ErrorAction SilentlyContinue
        $installed = $true
    }
    catch {
        $pendingReason = $_.Exception.Message
        Copy-Item -LiteralPath $BuiltExe -Destination $NextExe -Force
        Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue
        $pending = $true
    }

    $state = [ordered]@{
        version = $Version
        sourceRef = $SourceRef
        builtAt = (Get-Date).ToString("o")
        binary = $FinalExe
        installed = $installed
        pending = $pending
        pendingBinary = if ($pending) { $NextExe } else { "" }
        pendingReason = $pendingReason
        installMethod = $InstallMethod
        releaseRepo = $ReleaseRepo
        releaseTag = $ReleaseTag
        releaseAsset = $ReleaseAsset
        appliedAt = if ($installed) { (Get-Date).ToString("o") } else { "" }
    } | ConvertTo-Json -Depth 8
    Write-CodexKoUtf8NoBom $StatePath ($state + "`n")

    if ($installed) {
        Write-InstallStep "한국어 Codex 바이너리를 설치했습니다: $FinalExe"
    }
    elseif ($pending) {
        Write-InstallStep "현재 codex.exe를 교체하지 못해 다음 실행용으로 저장했습니다: $NextExe"
    }
}

function Invoke-ReleaseDownloadInstall {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepo,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $tag = "codex-ko-v$Version"
    $asset = "codex-ko-windows-x64-$Version.zip"
    $assetSha = "$asset.sha256"
    $baseUrl = "https://github.com/$TargetRepo/releases/download/$tag"
    $assetUrl = "$baseUrl/$asset"
    $assetShaUrl = "$baseUrl/$assetSha"

    if ($DryRun) {
        Write-InstallStep "DRY-RUN: 설치 폴더: $Root"
        Write-InstallStep "DRY-RUN: Codex 버전: $Version"
        Write-InstallStep "DRY-RUN: GitHub 저장소: $TargetRepo"
        Write-InstallStep "DRY-RUN: Release tag: $tag"
        Write-InstallStep "DRY-RUN: 다운로드 URL: $assetUrl"
        return $true
    }

    $tempRoot = Join-Path $env:TEMP ("codex-ko-release-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $zipPath = Join-Path $tempRoot $asset
    $shaPath = Join-Path $tempRoot $assetSha
    $extractPath = Join-Path $tempRoot "extract"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-InstallStep "Release 다운로드: $assetUrl"
        Invoke-WebRequest -Uri $assetUrl -OutFile $zipPath -UseBasicParsing

        $hasZipChecksum = $false
        try {
            Invoke-WebRequest -Uri $assetShaUrl -OutFile $shaPath -UseBasicParsing
            $hasZipChecksum = $true
        }
        catch {
            Write-InstallStep "ZIP checksum asset을 확인하지 못했습니다. ZIP 내부 checksum으로 계속 검증합니다."
        }
        if ($hasZipChecksum) {
            $expectedZipHash = ((Get-Content -LiteralPath $shaPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
            $actualZipHash = Get-FileSha256Hex $zipPath
            if ($expectedZipHash -and $expectedZipHash -ne $actualZipHash) {
                throw "ZIP SHA256 mismatch. expected=$expectedZipHash actual=$actualZipHash"
            }
            Write-InstallStep "ZIP SHA256 검증 완료."
        }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        $releasedExe = Join-Path $extractPath "codex.exe"
        if (-not (Test-Path $releasedExe)) {
            throw "Release ZIP 안에서 codex.exe를 찾지 못했습니다."
        }

        $innerSha = Join-Path $extractPath "SHA256SUMS.txt"
        if (Test-Path $innerSha) {
            $line = @(Get-Content -LiteralPath $innerSha | Where-Object { $_ -match '\bcodex\.exe$' })[0]
            if ($line) {
                $expectedExeHash = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
                $actualExeHash = Get-FileSha256Hex $releasedExe
                if ($expectedExeHash -and $expectedExeHash -ne $actualExeHash) {
                    throw "codex.exe SHA256 mismatch. expected=$expectedExeHash actual=$actualExeHash"
                }
                Write-InstallStep "codex.exe SHA256 검증 완료."
            }
        }

        $versionText = (& $releasedExe --version 2>$null) -join "`n"
        $releasedVersion = Get-VersionFromText $versionText
        if ($releasedVersion -ne $Version) {
            throw "Release codex.exe 버전이 맞지 않습니다. expected=$Version actual=$releasedVersion"
        }

        $versionJsonPath = Join-Path $extractPath "VERSION.json"
        $sourceRef = "rust-v$Version"
        if (Test-Path $versionJsonPath) {
            try {
                $versionJson = Get-Content -LiteralPath $versionJsonPath -Raw | ConvertFrom-Json
                if ($versionJson.sourceRef) {
                    $sourceRef = [string]$versionJson.sourceRef
                }
            }
            catch {
            }
        }

        Install-CodexKoBinary -BuiltExe $releasedExe -Version $Version -InstallMethod "release" -ReleaseRepo $TargetRepo -ReleaseTag $tag -ReleaseAsset $asset -SourceRef $sourceRef
        return $true
    }
    catch {
        Write-InstallStep "Release 설치 실패: $($_.Exception.Message)"
        return $false
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-RepoShape

$targetVersion = if ($CodexVersion) { $CodexVersion.TrimStart("v") } else { Get-OriginalCodexVersion }
if (-not $targetVersion) {
    throw "공식 Codex 버전을 확인하지 못했습니다. Codex CLI를 먼저 설치하거나 -CodexVersion을 지정하세요."
}

$targetRepo = Resolve-GitHubRepo
if (-not $targetRepo) {
    throw "GitHub 저장소를 확인하지 못했습니다. git remote origin을 설정하거나 -Repo owner/repo 또는 CODEX_KO_REPO를 지정하세요."
}

$currentVersion = Get-InstalledKoreanVersion
if (-not $Force -and $currentVersion -eq $targetVersion -and -not (Test-Path $NextExe)) {
    Write-InstallStep "이미 같은 버전의 한국어 Codex가 설치되어 있습니다: $currentVersion"
    if (-not $NoPath -and -not $DryRun) {
        & $SwitchScript
    }
    exit 0
}

$installedFromRelease = Invoke-ReleaseDownloadInstall -TargetRepo $targetRepo -Version $targetVersion
if (-not $installedFromRelease) {
    if ($BuildIfMissing) {
        if ($DryRun) {
            Write-InstallStep "DRY-RUN: Release가 없으면 로컬 Rust 빌드를 실행합니다: $Updater -Version $targetVersion"
        }
        else {
            Write-InstallStep "사전 빌드 Release가 없어 로컬 Rust 빌드로 진행합니다."
            & $Updater -Version $targetVersion -SkipMetadataSync
            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
        }
    }
    else {
        Write-Host ""
        Write-Host "해당 Codex 버전의 사전 빌드 파일이 아직 없습니다: $targetVersion" -ForegroundColor Yellow
        Write-Host "GitHub Release가 올라온 뒤 다시 실행하거나, 직접 빌드하려면 -BuildIfMissing을 붙이세요."
        Write-Host "  $PSCommandPath -Repo $targetRepo -CodexVersion $targetVersion -BuildIfMissing"
        exit 1
    }
}

if (-not $NoPath -and -not $DryRun) {
    & $SwitchScript
}

Write-InstallStep "설치 흐름이 완료되었습니다."
exit 0
