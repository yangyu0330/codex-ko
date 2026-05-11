[CmdletBinding()]
param(
    [string]$Repo = "",
    [string]$Ref = "main",
    [string]$CodexVersion = "",
    [string]$InstallDir = "",
    [switch]$BuildIfMissing,
    [switch]$NoPath,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$SourceRoot = $PSScriptRoot
$HasRepoShape = Test-Path (Join-Path $SourceRoot "scripts\install-codex-ko.ps1")
$TargetRoot = if ($InstallDir) {
    [System.IO.Path]::GetFullPath($InstallDir)
}
elseif ($HasRepoShape) {
    $SourceRoot
}
else {
    Join-Path $env:USERPROFILE ".codex-ko"
}

function Resolve-BootstrapRepo {
    if ($Repo) {
        return $Repo.Trim()
    }
    if ($env:CODEX_KO_REPO) {
        return $env:CODEX_KO_REPO.Trim()
    }
    try {
        $remote = (& git -C $SourceRoot remote get-url origin 2>$null) -join ""
        if ($remote -match 'github\.com[:/](?<owner>[^/\s:]+)/(?<repo>[^/\s]+?)(?:\.git)?$') {
            return "$($Matches.owner)/$($Matches.repo)"
        }
    }
    catch {
    }
    return ""
}

function Copy-CodexKoPublicFiles {
    param(
        [Parameter(Mandatory = $true)][string]$FromRoot,
        [Parameter(Mandatory = $true)][string]$ToRoot
    )

    $files = @(
        ".gitignore",
        "LICENSE",
        "README.md",
        "install.ps1",
        "bin\codex.ps1",
        "bin\codex-ko.ps1",
        "bin\codex-ko-launch.ps1",
        "scripts\codex-ko-status.ps1",
        "scripts\install-codex-ko.ps1",
        "scripts\lib-codex-ko.ps1",
        "scripts\switch-codex-ko.ps1",
        "scripts\switch-codex-original.ps1",
        "scripts\sync-codex-ko-metadata.ps1",
        "scripts\translate-codex-ko-pending.ps1",
        "scripts\update-codex-ko.ps1",
        "patches\codex_ko_translate.rs",
        "translations\glossary.json",
        "translations\ko-overrides.json",
        "translations\ko.toml"
    )

    foreach ($file in $files) {
        $source = Join-Path $FromRoot $file
        if (-not (Test-Path $source)) {
            continue
        }
        $target = Join-Path $ToRoot $file
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

function Install-CodexKoRepositoryFromGitHub {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepo,
        [Parameter(Mandatory = $true)][string]$TargetRef,
        [Parameter(Mandatory = $true)][string]$ToRoot
    )

    $tempRoot = Join-Path $env:TEMP ("codex-ko-source-" + [guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot "source.zip"
    $extractPath = Join-Path $tempRoot "extract"
    $sourceZipUrl = "https://github.com/$TargetRepo/archive/refs/heads/$TargetRef.zip"

    try {
        New-Item -ItemType Directory -Force -Path $tempRoot, $extractPath | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "[codex-ko] 설치 스크립트 묶음을 다운로드합니다: $sourceZipUrl"
        Invoke-WebRequest -Uri $sourceZipUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $repoRoot = @(Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1)[0].FullName
        if (-not $repoRoot -or -not (Test-Path (Join-Path $repoRoot "scripts\install-codex-ko.ps1"))) {
            throw "다운로드한 저장소 ZIP에서 설치 스크립트를 찾지 못했습니다."
        }

        New-Item -ItemType Directory -Force -Path $ToRoot | Out-Null
        Copy-CodexKoPublicFiles -FromRoot $repoRoot -ToRoot $ToRoot
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $HasRepoShape) {
    $bootstrapRepo = Resolve-BootstrapRepo
    if (-not $bootstrapRepo) {
        throw "install.ps1만 단독으로 실행할 때는 -Repo owner/repo 또는 CODEX_KO_REPO가 필요합니다."
    }
    $Repo = $bootstrapRepo

    if ($DryRun) {
        $sourceZipUrl = "https://github.com/$Repo/archive/refs/heads/$Ref.zip"
        Write-Host "DRY-RUN: install.ps1 단독 실행 모드입니다."
        Write-Host "DRY-RUN: 설치 스크립트 묶음 다운로드 URL: $sourceZipUrl"
        Write-Host "DRY-RUN: 공개용 파일을 복사할 위치: $TargetRoot"
        if ($CodexVersion) {
            $version = $CodexVersion.TrimStart("v")
            Write-Host "DRY-RUN: Release 다운로드 URL: https://github.com/$Repo/releases/download/codex-ko-v$version/codex-ko-windows-x64-$version.zip"
        }
        exit 0
    }

    Install-CodexKoRepositoryFromGitHub -TargetRepo $Repo -TargetRef $Ref -ToRoot $TargetRoot
    $SourceRoot = $TargetRoot
    $HasRepoShape = Test-Path (Join-Path $SourceRoot "scripts\install-codex-ko.ps1")
}

if ($TargetRoot -ne $SourceRoot) {
    if ($DryRun) {
        Write-Host "DRY-RUN: 공개용 파일을 복사할 위치: $TargetRoot"
    }
    else {
        New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
        Copy-CodexKoPublicFiles -FromRoot $SourceRoot -ToRoot $TargetRoot
    }
}

$Installer = Join-Path $TargetRoot "scripts\install-codex-ko.ps1"
if ($DryRun -and $TargetRoot -ne $SourceRoot) {
    $Installer = Join-Path $SourceRoot "scripts\install-codex-ko.ps1"
}
if (-not (Test-Path $Installer)) {
    throw "설치 스크립트를 찾지 못했습니다: $Installer"
}

$installerParams = @{
    InstallDir = $TargetRoot
}
if ($Repo) { $installerParams.Repo = $Repo }
if ($CodexVersion) { $installerParams.CodexVersion = $CodexVersion }
if ($BuildIfMissing) { $installerParams.BuildIfMissing = $true }
if ($NoPath) { $installerParams.NoPath = $true }
if ($Force) { $installerParams.Force = $true }
if ($DryRun) { $installerParams.DryRun = $true }

& $Installer @installerParams
exit $LASTEXITCODE
