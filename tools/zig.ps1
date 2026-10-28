$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$zig = Join-Path $root '.tools/zig/zig.exe'
if (!(Test-Path $zig)) { throw 'Run .\tools\setup.ps1 first.' }
Push-Location $root
try {
    & $zig @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
