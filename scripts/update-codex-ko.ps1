[CmdletBinding()]
param(
    [string]$Version = "",
    [switch]$Latest,
    [switch]$AllowMain,
    [switch]$FatLto,
    [switch]$SkipBuild,
    [switch]$SkipMetadataSync
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib-codex-ko.ps1"

$Root = Get-CodexKoRoot
$CargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
if (Test-Path $CargoBin) {
    $env:PATH = "$CargoBin;$env:PATH"
}
$TranslationPath = Join-Path $Root "translations\ko.toml"
$PatchRoot = Join-Path $Root "patches"
$SourceCache = Join-Path $Root "source\codex"
$WorkRoot = Join-Path $Root "work"
$BinDir = Join-Path $Root "bin"
$StatePath = Join-Path $Root "state.json"
$LogDir = Join-Path $Root "logs"
$LogPath = Join-Path $LogDir ("update-" + (Get-CodexKoTimestamp) + ".log")

New-Item -ItemType Directory -Force -Path $WorkRoot, $BinDir, $LogDir | Out-Null

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Invoke-CodexKoNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $PWD.Path
    )
    Write-Step ("RUN " + $FilePath + " " + ($Arguments -join " "))
    Push-Location $WorkingDirectory
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $FilePath @Arguments *>&1 |
            ForEach-Object {
                $line = [string]$_
                Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
                Write-Host $line
            }
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldErrorActionPreference
        if ($exitCode -ne 0) {
            throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        Pop-Location
    }
}

function Install-CodexKoBuiltBinary {
    param(
        [Parameter(Mandatory = $true)][string]$BuiltExe,
        [Parameter(Mandatory = $true)][string]$FinalExe
    )

    $tempExe = "$FinalExe.tmp"
    $nextExe = "$FinalExe.next"
    $previousExe = "$FinalExe.previous"

    Copy-Item -LiteralPath $BuiltExe -Destination $tempExe -Force

    try {
        if (Test-Path $FinalExe) {
            Remove-Item -LiteralPath $previousExe -Force -ErrorAction SilentlyContinue
            [System.IO.File]::Replace($tempExe, $FinalExe, $previousExe, $true)
            Remove-Item -LiteralPath $previousExe -Force -ErrorAction SilentlyContinue
        }
        else {
            Move-Item -LiteralPath $tempExe -Destination $FinalExe -Force
        }

        Remove-Item -LiteralPath $nextExe -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            installed = $true
            pending = $false
            path = $FinalExe
            reason = ""
        }
    }
    catch {
        $reason = $_.Exception.Message
        Copy-Item -LiteralPath $BuiltExe -Destination $nextExe -Force
        Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue
        Write-Step "Existing codex.exe could not be replaced now: $reason"
        Write-Step "Saved pending binary for next Codex launch: $nextExe"
        return [pscustomobject]@{
            installed = $false
            pending = $true
            path = $nextExe
            reason = $reason
        }
    }
}

function Get-InstalledCodexVersion {
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        return ""
    }
    try {
        $output = (& $codexCommand.Source --version 2>$null) -join "`n"
        if ($output -match '(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)') {
            return $Matches[1]
        }
    }
    catch {
    }
    return ""
}

function Get-NpmCodexVersion {
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $npmCommand = (Get-Command npm.cmd -ErrorAction SilentlyContinue)
        if ($npmCommand) {
            $output = (& $npmCommand.Source view "@openai/codex" version --silent *>&1) -join "`n"
        }
        else {
            $output = (& npm view "@openai/codex" version --silent *>&1) -join "`n"
        }
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldErrorActionPreference
        if ($exitCode -ne 0) {
            return ""
        }
        if ($output -match '(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)') {
            return $Matches[1]
        }
    }
    catch {
        $ErrorActionPreference = $oldErrorActionPreference
        return ""
    }
    $ErrorActionPreference = $oldErrorActionPreference
    return ""
}

function Assert-RustBuildTools {
    if ($SkipBuild) {
        return
    }
    $missing = @()
    foreach ($tool in @("rustc", "cargo")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            $missing += $tool
        }
    }
    if ($missing.Count -gt 0) {
        $message = @"
Rust build tools are missing: $($missing -join ", ")

Install Rust and MSVC build tools, then run this script again.

Recommended commands:
  winget install Rustlang.Rustup
  winget install Microsoft.VisualStudio.2022.BuildTools

After installing, open a new PowerShell window and check:
  rustc --version
  cargo --version
"@
        throw $message
    }
}

function Ensure-CodexSourceCache {
    if (Test-Path (Join-Path $SourceCache ".git")) {
        Invoke-CodexKoNative "git" @("-C", $SourceCache, "fetch", "--tags", "--force", "--prune") $Root
        return
    }
    $parent = Split-Path -Parent $SourceCache
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Invoke-CodexKoNative "git" @("clone", "https://github.com/openai/codex.git", $SourceCache) $Root
}

function Get-CodexRefForVersion {
    param([Parameter(Mandatory = $true)][string]$TargetVersion)
    $tag = "rust-v$TargetVersion"
    $tagExists = (& git -C $SourceCache tag --list $tag) -join ""
    if ($tagExists -eq $tag) {
        return $tag
    }
    if ($AllowMain) {
        return "origin/main"
    }
    throw "Cannot find Codex source tag '$tag'. Use -AllowMain only if you intentionally want an unreleased main build."
}

function New-CodexWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [Parameter(Mandatory = $true)][string]$TargetVersion
    )
    $safeVersion = $TargetVersion -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $WorkRoot ("codex-$safeVersion-" + (Get-CodexKoTimestamp))
    Invoke-CodexKoNative "git" @("-C", $SourceCache, "worktree", "add", "--detach", $path, $Ref) $Root
    return $path
}

function Replace-Once {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $index = $Text.IndexOf($Needle, [System.StringComparison]::Ordinal)
    if ($index -lt 0) {
        throw "Patch marker not found: $Label"
    }
    return $Text.Substring(0, $index) + $Replacement + $Text.Substring($index + $Needle.Length)
}

function Get-SlashCommandVariants {
    param([Parameter(Mandatory = $true)][string]$Text)
    $match = [regex]::Match($Text, '(?s)pub enum SlashCommand \{(?<body>.*?)\n\}')
    if (-not $match.Success) {
        throw "Cannot find SlashCommand enum body."
    }
    $variants = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($match.Groups["body"].Value -split "`n")) {
        $trim = $line.Trim()
        if ($trim.Length -eq 0 -or $trim.StartsWith("//") -or $trim.StartsWith("#[")) {
            continue
        }
        if ($trim -match '^([A-Za-z][A-Za-z0-9]*)\s*,') {
            $variants.Add($Matches[1])
        }
    }
    return $variants.ToArray()
}

function Assert-KnownSlashCommandShape {
    param([Parameter(Mandatory = $true)][string]$Text)
    $expected = @(
        "Model", "Ide", "Permissions", "Keymap", "Vim", "ElevateSandbox", "SandboxReadRoot",
        "Experimental", "AutoReview", "Memories", "Skills", "Hooks", "Review", "Rename",
        "New", "Resume", "Fork", "Init", "Compact", "Plan", "Goal", "Collab", "Agent",
        "Side", "Copy", "Raw", "Diff", "Mention", "Status", "DebugConfig", "Title",
        "Statusline", "Theme", "Mcp", "Apps", "Plugins", "Logout", "Quit", "Exit",
        "Feedback", "Rollout", "Ps", "Stop", "Clear", "Personality", "Realtime",
        "Settings", "TestApproval", "MultiAgents", "MemoryDrop", "MemoryUpdate"
    )
    $actual = Get-SlashCommandVariants $Text
    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expected -notcontains $_ -and $_ -ne "Fast" })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        throw "SlashCommand structure changed. Missing=[$($missing -join ', ')] Extra=[$($extra -join ', ')]. Update translations and patch script before building."
    }
    return $actual
}

function New-SlashDescriptionFunction {
    param([Parameter(Mandatory = $true)][string[]]$Variants)
    $slash = Read-CodexKoTomlSection $TranslationPath "slash_description"
    $order = @(
        "Feedback", "New", "Init", "Compact", "Review", "Rename", "Resume", "Clear",
        "Fork", "Quit", "Exit", "Copy", "Raw", "Diff", "Mention", "Skills", "Hooks",
        "Status", "DebugConfig", "Title", "Statusline", "Theme", "Ps", "Stop",
        "MemoryDrop", "MemoryUpdate", "Model", "Fast", "HelpKo", "Ide", "Personality",
        "Realtime", "Settings", "Plan", "Goal", "Collab", "Agent", "MultiAgents",
        "Side", "Permissions", "Keymap", "Vim", "ElevateSandbox", "SandboxReadRoot",
        "Experimental", "AutoReview", "Memories", "Mcp", "Apps", "Plugins", "Logout",
        "Rollout", "TestApproval"
    )
    $present = @($Variants + "HelpKo")
    $arms = New-Object System.Collections.Generic.List[string]
    foreach ($variant in $order) {
        if ($present -notcontains $variant) {
            continue
        }
        if (-not $slash.Contains($variant)) {
            throw "Missing slash translation for $variant in $TranslationPath"
        }
        $escaped = ConvertTo-CodexKoRustString $slash[$variant]
        if ($variant -eq "Quit") {
            continue
        }
        if ($variant -eq "Agent") {
            $arms.Add("            SlashCommand::Agent | SlashCommand::MultiAgents => `"$escaped`",")
            continue
        }
        if ($variant -eq "MultiAgents") {
            continue
        }
        if ($variant -eq "Exit") {
            $escapedQuit = ConvertTo-CodexKoRustString $slash["Quit"]
            $arms.Add("            SlashCommand::Quit | SlashCommand::Exit => `"$escapedQuit`",")
            continue
        }
        $arms.Add("            SlashCommand::$variant => `"$escaped`",")
    }

    return @"
    /// User-visible description shown in the popup.
    pub fn description(self) -> &'static str {
        match self {
$($arms -join "`n")
        }
    }
"@
}

function New-CodexKoHelpMethod {
    $lines = @(
        "Codex 한국어 도움말",
        "",
        "/model - 모델과 reasoning effort를 바꿉니다. 복잡한 코딩/디버깅은 강한 모델과 high 이상, 간단한 질문은 빠른 설정이 좋습니다.",
        "/status - 현재 모델, 권한, 작업 폴더, 토큰 사용량을 확인합니다. 이상할 때 먼저 보는 기본 점검 명령입니다.",
        "/diff - Codex가 바꾼 파일 차이를 봅니다. 적용 전 검토하거나 PR 올리기 전에 확인할 때 씁니다.",
        "/review - 현재 변경사항에서 버그, 위험한 동작, 빠진 테스트를 찾습니다. 커밋 전 점검용으로 좋습니다.",
        "/compact - 긴 대화를 요약해 컨텍스트를 줄입니다. 오래 작업해서 답변이 느려지거나 맥락이 길어졌을 때 사용합니다.",
        "/permissions - Codex가 명령을 자동 실행할지, 매번 물어볼지, 파일 접근을 어디까지 허용할지 정합니다.",
        "/init - 현재 프로젝트에 AGENTS.md를 만듭니다. 프로젝트 규칙, 테스트 명령, 코딩 스타일을 Codex에게 알려줄 때 씁니다.",
        "/skills - 문서, PDF, 브라우저, GitHub 같은 작업별 전문 기능을 찾습니다. 작업 종류가 명확하면 스킬을 쓰는 편이 좋습니다.",
        "/apps - GitHub, Notion 같은 앱 커넥터를 확인합니다. 계정이나 외부 서비스와 연결되는 기능입니다.",
        "/plugins - 설치 가능한 플러그인을 탐색합니다. 새 기능을 추가했을 때 여기서 상태를 확인합니다.",
        "/mcp verbose - 연결된 MCP 서버와 도구를 자세히 봅니다. 원격 도구가 안 보일 때 점검용으로 씁니다.",
        "동적 번역 - 원격 앱/커넥터 설명은 처음 본 원문만 번역 대기열에 넣고, 번역 후에는 캐시를 계속 재사용합니다.",
        "번역 캐시 - $env:USERPROFILE\.codex-ko\translations\dynamic-cache.json 파일을 사용합니다.",
        "/new - 현재 터미널에서 새 대화를 시작합니다. 이전 대화와 맥락을 섞고 싶지 않을 때 씁니다.",
        "/resume - 이전에 저장된 대화를 다시 엽니다. 하던 작업을 이어갈 때 사용합니다.",
        "/quit - Codex를 종료합니다.",
        "",
        "처음 사용할 때 추천 흐름: /status로 현재 상태 확인, 작업 전 /init으로 프로젝트 규칙 만들기, 수정 후 /diff와 /review로 검토하기.",
        "명령어 이름은 영어 그대로 입력합니다. 설명과 도움말만 한국어로 바꾼 커스텀 빌드입니다."
    )
    $rustLines = $lines | ForEach-Object {
        '            ratatui::text::Line::from("' + (ConvertTo-CodexKoRustString $_) + '"),'
    }
    return @"
    fn add_codex_ko_help_output(&mut self) {
        let lines = vec![
$($rustLines -join "`n")
        ];
        self.add_to_history(history_cell::PlainHistoryCell::new(lines));
        self.request_redraw();
    }

"@
}

function Patch-SlashCommandSource {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    $slashPath = Join-Path $SourceRoot "codex-rs\tui\src\slash_command.rs"
    $text = [System.IO.File]::ReadAllText($slashPath) -replace "`r`n", "`n"

    $variants = Assert-KnownSlashCommandShape $text
    if ($text.Contains("HelpKo")) {
        throw "SlashCommand already contains HelpKo. This source may already be patched."
    }

    $text = Replace-Once $text "    Model,`n" "    Model,`n    HelpKo,`n" "insert HelpKo enum variant"
    $descriptionFunction = New-SlashDescriptionFunction $variants
    $pattern = "(?s)    /// User-visible description shown in the popup\.`n    pub fn description\(self\) -> &'static str \{`n        match self \{`n.*?`n        \}`n    \}"
    $text = [regex]::Replace(
        $text,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $descriptionFunction },
        1
    )
    if (-not $text.Contains("SlashCommand::HelpKo =>")) {
        throw "Failed to replace SlashCommand::description with Korean descriptions."
    }
    $text = Replace-Once $text "            SlashCommand::Copy`n                | SlashCommand::Raw" "            SlashCommand::HelpKo`n                | SlashCommand::Copy`n                | SlashCommand::Raw" "side conversation availability"
    $text = Replace-Once $text "            SlashCommand::Diff`n            | SlashCommand::Copy" "            SlashCommand::HelpKo`n            | SlashCommand::Diff`n            | SlashCommand::Copy" "during-task availability"
    Write-CodexKoUtf8NoBom $slashPath $text
}

function Patch-SlashDispatchSource {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    $path = Join-Path $SourceRoot "codex-rs\tui\src\chatwidget\slash_dispatch.rs"
    $text = [System.IO.File]::ReadAllText($path) -replace "`r`n", "`n"

    $helpMethod = New-CodexKoHelpMethod
    $text = Replace-Once $text "    pub(super) fn dispatch_command(&mut self, cmd: SlashCommand) {`n" ($helpMethod + "    pub(super) fn dispatch_command(&mut self, cmd: SlashCommand) {`n") "insert /help-ko output method"
    $modelArmPattern = "(?m)^            SlashCommand::Model => \{`n                self\.open_model_popup\(\);`n            \}"
    if (-not [regex]::IsMatch($text, $modelArmPattern)) {
        throw "Patch marker not found: dispatch /help-ko"
    }
    $helpArm = (@(
        "            SlashCommand::Model => {",
        "                self.open_model_popup();",
        "            }",
        "            SlashCommand::HelpKo => {",
        "                self.add_codex_ko_help_output();",
        "            }"
    ) -join "`n")
    $text = [regex]::Replace($text, $modelArmPattern, $helpArm, 1)
    if ($text.Contains("            SlashCommand::Fast`n            | SlashCommand::Ide")) {
        $text = Replace-Once $text "            SlashCommand::Fast`n            | SlashCommand::Ide" "            SlashCommand::HelpKo`n            | SlashCommand::Fast`n            | SlashCommand::Ide" "queued drain /help-ko"
    }
    else {
        $text = Replace-Once $text "            SlashCommand::Ide`n            | SlashCommand::Status" "            SlashCommand::Ide`n            | SlashCommand::HelpKo`n            | SlashCommand::Status" "queued drain /help-ko"
    }
    Write-CodexKoUtf8NoBom $path $text
}

function Patch-CodexKoDynamicTranslationSource {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    Write-Step "Patching Codex source for dynamic Korean display translation cache."

    $templatePath = Join-Path $PatchRoot "codex_ko_translate.rs"
    if (-not (Test-Path $templatePath)) {
        throw "Missing patch template: $templatePath"
    }

    $modulePath = Join-Path $SourceRoot "codex-rs\tui\src\codex_ko_translate.rs"
    Copy-Item -LiteralPath $templatePath -Destination $modulePath -Force

    $libPath = Join-Path $SourceRoot "codex-rs\tui\src\lib.rs"
    $libText = [System.IO.File]::ReadAllText($libPath) -replace "`r`n", "`n"
    if (-not $libText.Contains("mod codex_ko_translate;")) {
        $libText = Replace-Once $libText "mod clipboard_paste;`n" "mod clipboard_paste;`nmod codex_ko_translate;`n" "insert codex_ko_translate module"
        Write-CodexKoUtf8NoBom $libPath $libText
    }

    $cargoPath = Join-Path $SourceRoot "codex-rs\tui\Cargo.toml"
    $cargoText = [System.IO.File]::ReadAllText($cargoPath) -replace "`r`n", "`n"
    if (-not $cargoText.Contains("sha2 = { workspace = true }")) {
        $cargoText = Replace-Once $cargoText "serde_json = { workspace = true, features = [`"preserve_order`"] }`n" "serde_json = { workspace = true, features = [`"preserve_order`"] }`nsha2 = { workspace = true }`n" "add sha2 dependency to tui"
        Write-CodexKoUtf8NoBom $cargoPath $cargoText
    }

    $selectionPath = Join-Path $SourceRoot "codex-rs\tui\src\bottom_pane\selection_popup_common.rs"
    $selectionText = [System.IO.File]::ReadAllText($selectionPath) -replace "`r`n", "`n"
    $selectionOld = @'
    let combined_description = match (&row.description, &row.disabled_reason) {
        (Some(desc), Some(reason)) => Some(format!("{desc} (disabled: {reason})")),
        (Some(desc), None) => Some(desc.clone()),
        (None, Some(reason)) => Some(format!("disabled: {reason}")),
        (None, None) => None,
    };
'@
    $selectionNew = @'
    let combined_description = match (&row.description, &row.disabled_reason) {
        (Some(desc), Some(reason)) => Some(format!("{desc} (disabled: {reason})")),
        (Some(desc), None) => Some(desc.clone()),
        (None, Some(reason)) => Some(format!("disabled: {reason}")),
        (None, None) => None,
    };
    let combined_description = combined_description.as_ref().map(|description| {
        crate::codex_ko_translate::translate_for_display(
            "selection_description",
            &row.name,
            description,
        )
    });
'@
    if (-not $selectionText.Contains("codex_ko_translate::translate_for_display")) {
        $selectionText = Replace-Once $selectionText $selectionOld $selectionNew "translate selection popup descriptions"
        Write-CodexKoUtf8NoBom $selectionPath $selectionText
    }

    $historyPath = Join-Path $SourceRoot "codex-rs\tui\src\history_cell.rs"
    $historyText = [System.IO.File]::ReadAllText($historyPath) -replace "`r`n", "`n"
    $historyOld = @'
        let mut names = status
            .map(|status| status.tools.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        names.sort();
        if names.is_empty() {
            lines.push("    • Tools: (none)".into());
        } else {
            lines.push(vec!["    • Tools: ".into(), names.join(", ").into()].into());
        }
'@
    $historyNew = @'
        let mut tool_entries = status
            .map(|status| status.tools.iter().collect::<Vec<_>>())
            .unwrap_or_default();
        tool_entries.sort_by(|(left, _), (right, _)| left.cmp(right));
        let names = tool_entries
            .iter()
            .map(|(name, _)| (*name).clone())
            .collect::<Vec<_>>();
        if tool_entries.is_empty() {
            lines.push("    • Tools: (none)".into());
        } else if matches!(detail, McpServerStatusDetail::Full) {
            lines.push("    • Tools:".into());
            for (name, tool) in tool_entries {
                let source_id = format!("{server}.{name}");
                if let Some(description) = tool
                    .description
                    .as_deref()
                    .map(str::trim)
                    .filter(|description| !description.is_empty())
                {
                    let description = crate::codex_ko_translate::translate_for_display(
                        "mcp_tool_description",
                        &source_id,
                        description,
                    );
                    lines.push(
                        vec![
                            "      - ".into(),
                            name.clone().into(),
                            ": ".into(),
                            description.dim(),
                        ]
                        .into(),
                    );
                } else {
                    lines.push(vec!["      - ".into(), name.clone().into()].into());
                }
            }
        } else {
            lines.push(vec!["    • Tools: ".into(), names.join(", ").into()].into());
        }
'@
    if (-not $historyText.Contains('"mcp_tool_description"')) {
        $historyText = Replace-Once $historyText $historyOld $historyNew "render and translate MCP tool descriptions"
        Write-CodexKoUtf8NoBom $historyPath $historyText
    }
}

function Patch-CodexSource {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    Write-Step "Patching Codex source for Korean slash descriptions and /help-ko."
    Patch-SlashCommandSource $SourceRoot
    Patch-SlashDispatchSource $SourceRoot
    Patch-CodexKoDynamicTranslationSource $SourceRoot
}

try {
    Write-Step "Starting Codex Korean updater."
    $installed = Get-InstalledCodexVersion
    $npmLatest = Get-NpmCodexVersion

    if (-not $Version) {
        if ($Latest -and $npmLatest) {
            $Version = $npmLatest
        }
        elseif ($npmLatest) {
            $Version = $npmLatest
        }
        elseif ($installed) {
            $Version = $installed
        }
        else {
            throw "Cannot determine Codex version. Pass -Version explicitly."
        }
    }

    Write-Step "Installed Codex version: $installed"
    Write-Step "NPM latest Codex version: $npmLatest"
    Write-Step "Target Codex version: $Version"

    if (-not $SkipMetadataSync) {
        & "$PSScriptRoot\sync-codex-ko-metadata.ps1"
        if ($LASTEXITCODE -ne 0) {
            throw "Metadata sync failed."
        }
    }

    Assert-RustBuildTools
    Ensure-CodexSourceCache
    $ref = Get-CodexRefForVersion $Version
    Write-Step "Using source ref: $ref"
    $worktree = New-CodexWorktree $ref $Version
    Patch-CodexSource $worktree

    if ($SkipBuild) {
        Write-Step "SkipBuild was set. Source patched at: $worktree"
        exit 0
    }

    $cargoRoot = Join-Path $worktree "codex-rs"
    $oldReleaseLto = $env:CARGO_PROFILE_RELEASE_LTO
    $oldReleaseCodegenUnits = $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS
    if (-not $FatLto) {
        # The upstream release profile uses fat LTO. On Windows this can make the final
        # codex.exe link take a very long time, while the Korean UI patch does not need
        # maximum binary optimization. Keep release optimizations but disable LTO for
        # local custom builds unless -FatLto is explicitly requested.
        $env:CARGO_PROFILE_RELEASE_LTO = "false"
        $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16"
        Write-Step "Using fast local release build: CARGO_PROFILE_RELEASE_LTO=false, CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16"
    }
    try {
        Invoke-CodexKoNative "cargo" @("build", "--release", "-p", "codex-cli", "--bin", "codex") $cargoRoot
    }
    finally {
        $env:CARGO_PROFILE_RELEASE_LTO = $oldReleaseLto
        $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = $oldReleaseCodegenUnits
    }

    $builtExe = Join-Path $cargoRoot "target\release\codex.exe"
    if (-not (Test-Path $builtExe)) {
        throw "Build completed but codex.exe was not found at $builtExe"
    }

    $versionOutput = (& $builtExe --version 2>&1) -join "`n"
    Write-Step "Built binary version: $versionOutput"
    if ($versionOutput -notmatch [regex]::Escape($Version)) {
        throw "Built binary version does not match target version $Version"
    }

    $finalExe = Join-Path $BinDir "codex.exe"
    $installResult = Install-CodexKoBuiltBinary -BuiltExe $builtExe -FinalExe $finalExe
    $state = [ordered]@{
        version = $Version
        sourceRef = $ref
        builtAt = (Get-Date).ToString("o")
        binary = $finalExe
        installed = [bool]$installResult.installed
        pending = [bool]$installResult.pending
        pendingBinary = if ($installResult.pending) { [string]$installResult.path } else { "" }
        pendingReason = [string]$installResult.reason
    } | ConvertTo-Json -Depth 8
    Write-CodexKoUtf8NoBom $StatePath ($state + "`n")
    if ($installResult.installed) {
        Write-Step "Installed Korean Codex binary: $finalExe"
    }
    else {
        Write-Step "Korean Codex binary will be installed on the next launcher start."
    }
    $statusScript = Join-Path $PSScriptRoot "codex-ko-status.ps1"
    if (Test-Path $statusScript) {
        Write-Step "Running Korean Codex status self-check."
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $statusScript -Json *>&1 |
                ForEach-Object {
                    $line = [string]$_
                    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
                    Write-Host $line
                }
            $statusExit = $LASTEXITCODE
            $ErrorActionPreference = $oldErrorActionPreference
            if ($statusExit -eq 0) {
                Write-Step "Status self-check completed without warnings."
            }
            elseif ($statusExit -eq 1) {
                Write-Step "Status self-check completed with warnings. See output above."
            }
            else {
                Write-Step "Status self-check reported errors. See output above."
            }
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
    }
    Write-Step "Done."
}
catch {
    Write-Host ""
    Write-Host "Codex Korean update failed." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host "Log: $LogPath"
    exit 1
}
