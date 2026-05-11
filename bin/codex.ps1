#!/usr/bin/env pwsh
$launcher = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "codex-ko-launch.ps1"
& $launcher @args
exit $LASTEXITCODE
