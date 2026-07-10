# Codex Korean UI Customizer

Codex CLI의 명령어 이름은 영어 그대로 유지하고, 화면에 보이는 설명과 도움말을 한국어로 보여주기 위한 Windows용 로컬 커스터마이저입니다.

이 프로젝트는 원본 Codex 설치본을 직접 수정하지 않습니다. 사용자의 PC에는 한국어 패치된 `codex.exe`를 별도로 설치하고, PATH shim으로 `codex` 명령이 한국어 launcher를 먼저 실행하게 만듭니다.

## 주요 기능

- `/model`, `/status`, `/diff`, `/review` 같은 slash 명령 설명을 한국어로 표시합니다.
- `/help-ko` 명령으로 초보자용 한국어 도움말을 볼 수 있습니다.
- `/plan`을 언제 쓰면 좋은지와 단계별 작업 흐름을 한국어 도움말에서 안내합니다.
- 앱/커넥터/MCP 도구처럼 실행 중에 들어오는 영어 설명을 Codex OAuth로 한 번 번역하고 캐시에 재사용합니다.
- Codex 업데이트를 감지하면 먼저 GitHub Release의 사전 빌드 파일을 내려받습니다.
- 빌드 중인 파일, 로그, 캐시, 개인 상태 파일은 Git에 올리지 않도록 분리합니다.

## 빠른 설치

먼저 공식 Codex CLI를 설치하고 로그인해 둡니다.

```powershell
codex --version
codex login
```

방법 A. `install.ps1`만 내려받아 설치합니다.

```powershell
$repo = "yangyu0330/codex-ko"
$installer = Join-Path $env:TEMP "install-codex-ko.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/$repo/main/install.ps1" -OutFile $installer
powershell -ExecutionPolicy Bypass -File $installer -Repo $repo
```

이 방식은 설치 스크립트 묶음을 `$env:USERPROFILE\.codex-ko`로 내려받은 뒤, 현재 Codex 버전에 맞는 Release 파일을 설치합니다.

방법 B. 저장소를 직접 clone한 뒤 설치합니다.

```powershell
git clone https://github.com/yangyu0330/codex-ko.git $env:USERPROFILE\.codex-ko
```

설치 프로그램을 실행합니다.

```powershell
$env:USERPROFILE\.codex-ko\install.ps1
```

설치 프로그램은 현재 설치된 Codex 버전을 확인하고, 같은 버전의 한국어 사전 빌드 파일을 GitHub Release에서 다운로드합니다. 성공하면 Rust를 설치하지 않아도 됩니다.

`codex`와 `codex-ko` 명령이 한국어 launcher를 사용하도록 PATH도 자동으로 설정합니다. PowerShell 창을 새로 열면 적용됩니다.

GitHub 저장소를 자동으로 찾지 못하면 `-Repo`를 지정합니다.

```powershell
$env:USERPROFILE\.codex-ko\install.ps1 -Repo yangyu0330/codex-ko
```

기본 브랜치가 `main`이 아니라면 `-Ref`를 지정합니다.

```powershell
$env:USERPROFILE\.codex-ko\install.ps1 -Repo yangyu0330/codex-ko -Ref master
```

## 직접 빌드

GitHub Release에 현재 Codex 버전의 사전 빌드 파일이 없을 때만 직접 빌드가 필요합니다.

Rust와 MSVC 빌드 도구가 있는지 확인합니다.

```powershell
rustc --version
cargo --version
```

없다면 설치합니다.

```powershell
winget install Rustlang.Rustup
winget install Microsoft.VisualStudio.2022.BuildTools
```

직접 빌드 fallback까지 허용하려면 다음처럼 실행합니다.

```powershell
$env:USERPROFILE\.codex-ko\install.ps1 -BuildIfMissing
```

기존 빌드 스크립트를 직접 실행할 수도 있습니다.

```powershell
$env:USERPROFILE\.codex-ko\scripts\update-codex-ko.ps1
```

## GitHub Release 만들기

저장소 관리자는 GitHub Actions에서 사전 빌드 파일을 만들 수 있습니다.

1. 이 저장소를 GitHub에 push합니다.
2. GitHub의 `Actions` 탭에서 `Build Codex Korean Release` workflow를 선택합니다.
3. `Run workflow`를 누르고 `codex_version`에 공식 Codex 버전을 입력합니다. 예: `0.129.0`
4. workflow가 성공하면 `codex-ko-v0.129.0` 같은 tag와 Release가 만들어집니다.
5. Release에는 `codex-ko-windows-x64-0.129.0.zip`과 checksum 파일이 올라갑니다.

사용자의 `install.ps1`은 이 Release 파일을 먼저 찾습니다. 같은 버전의 Release가 있으면 Rust 없이 다운로드 설치가 끝납니다.

## Rust가 필요한 이유

Codex CLI의 TUI 설명은 실행 파일 안에 들어 있습니다. 단순 설정 파일만 바꿔서는 `/` 메뉴와 선택창 설명을 한국어로 바꾸기 어렵습니다.

그래서 이 프로젝트는 관리자가 GitHub Actions에서 미리 빌드한 `codex.exe`를 Release로 제공합니다. 사용자는 보통 이 파일을 다운로드만 하면 됩니다. 사전 빌드가 없는 버전은 Codex Rust 소스를 로컬에 내려받고 한국어 설명 패치를 적용한 뒤 `cargo build`로 직접 빌드할 수 있습니다.

## 업데이트 방식

launcher는 원본 Codex 버전이 바뀌었는지 확인합니다. 버전이 바뀌면 먼저 `scripts\install-codex-ko.ps1`로 같은 버전의 GitHub Release 사전 빌드를 설치하려고 시도합니다.

사전 빌드가 없으면 기존 한국어 빌드를 계속 사용하고, 직접 빌드를 안내합니다.

Windows에서는 실행 중인 `codex.exe`를 바로 덮어쓸 수 없습니다. 이 경우 새 파일은 `bin\codex.exe.next`로 저장되고, Codex를 모두 종료한 뒤 다시 실행하면 launcher가 자동으로 적용합니다.

자동 업데이트를 끄려면 Codex 실행 전에 다음을 설정합니다.

```powershell
$env:CODEX_KO_NO_AUTO_UPDATE = "1"
```

## 한국어 번역 방식

기본 slash 명령 설명은 `translations\ko.toml`과 패치 스크립트를 통해 빌드 시 고정 한국어 문구로 들어갑니다.

계획이 필요한 작업은 `/plan`으로 먼저 범위, 수정 순서, 검증 방법을 정리한 뒤 시작하는 흐름을 권장합니다. 큰 작업은 1단계로 목표와 범위를 정하고, 2단계로 작은 변경을 적용한 뒤, 각 단계가 끝날 때 `/diff`와 `/review`로 확인하면 초보자도 흐름을 놓치기 쉽지 않습니다.

자주 나오는 선택창 설명은 `translations\ko-overrides.json`을 먼저 사용합니다. 이 파일에 있는 설명은 AI 번역을 기다리지 않고 바로 한국어로 표시됩니다.

앱/커넥터/MCP 도구 설명처럼 실행 중에 처음 보이는 원격 설명은 `translations\pending\dynamic-pending.jsonl`에 대기열로 저장됩니다. 백그라운드 watcher가 Codex OAuth를 사용해 한 번만 번역하고, 결과를 `translations\dynamic-cache.json`에 저장합니다.

기본 인증 방식은 Codex OAuth입니다. 이미 `codex login`으로 로그인되어 있다면 OpenAI API 키가 필요하지 않습니다.

```powershell
$env:CODEX_KO_TRANSLATE_AUTH = "codex"
```

API 키 fallback까지 허용하려면 `auto`를 사용할 수 있습니다.

```powershell
$env:CODEX_KO_TRANSLATE_AUTH = "auto"
```

동적 번역을 끄려면 다음을 설정합니다.

```powershell
$env:CODEX_KO_TRANSLATE = "0"
```

watcher 자동 실행만 끄려면 다음을 설정합니다.

```powershell
$env:CODEX_KO_SKIP_TRANSLATE_WATCHER = "1"
```

수동으로 대기열을 번역하려면 다음을 실행합니다.

```powershell
$env:USERPROFILE\.codex-ko\scripts\translate-codex-ko-pending.ps1 -Auth codex
```

## 상태 확인

문제가 있는지 확인하려면 다음을 실행합니다.

```powershell
$env:USERPROFILE\.codex-ko\scripts\codex-ko-status.ps1
```

이 명령은 현재 한국어 바이너리 버전, `codex.exe.next` 대기 여부, 번역 캐시 수, 미번역 대기열 수, watcher 실행 여부, 최근 오류를 보여줍니다.

자동화에서 사용하려면 JSON으로 출력할 수 있습니다.

```powershell
$env:USERPROFILE\.codex-ko\scripts\codex-ko-status.ps1 -Json
```

watcher가 비정상 종료되어 lock 파일만 남았을 때는 다음처럼 정리합니다.

```powershell
$env:USERPROFILE\.codex-ko\scripts\codex-ko-status.ps1 -FixStaleLock
```

## 문제 해결

`한국어 커스텀 Codex 바이너리가 아직 없습니다`가 나오면 먼저 설치해야 합니다.

```powershell
$env:USERPROFILE\.codex-ko\install.ps1
```

사전 빌드 Release가 없다면 직접 빌드 fallback을 사용합니다.

```powershell
$env:USERPROFILE\.codex-ko\install.ps1 -BuildIfMissing
```

`codex.exe.next`가 계속 남아 있으면 실행 중인 Codex 창이 파일을 잡고 있는 상태입니다. Codex 창을 모두 닫고 새 PowerShell에서 다시 실행하면 적용됩니다.

Rust 명령을 찾지 못하면 Rust 설치 후 새 PowerShell 창을 열어야 PATH가 반영됩니다.

원격 앱/커넥터 설명이 처음에 영어로 보일 수 있습니다. watcher가 번역을 끝낸 뒤 다음 표시부터 한국어 캐시가 적용됩니다.

## Git에 올리지 않는 파일

다음 파일과 폴더는 개인 PC의 빌드 산출물, 로그, 캐시, 상태 파일입니다. GitHub에 올리지 않습니다.

```text
bin/*.exe
bin/*.next
bin/*.previous
source/
work/
backups/
logs/
state.json
translations/dynamic-cache.json
translations/dynamic-status.json
translations/dynamic-alert.json
translations/dynamic-translate.lock
translations/pending/
dist/
release/
artifacts/
*.zip
*.sha256
```

공개 저장소에는 스크립트, 패치 파일, 고정 번역 데이터만 포함합니다.

## 원본 Codex로 복구

한국어 launcher를 PATH에서 제거하려면 다음을 실행합니다.

```powershell
$env:USERPROFILE\.codex-ko\scripts\switch-codex-original.ps1
```

PowerShell 창을 새로 열면 원본 Codex 설치본이 다시 사용됩니다.

## 라이선스

MIT License를 사용합니다.
