$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root '.cache'
New-Item -ItemType Directory -Force $cache, (Join-Path $root '.tools'), (Join-Path $root 'vendor/sqlite'), (Join-Path $root 'vendor/webview2') | Out-Null

function Get-VerifiedArchive($Name, $Url, $Hash) {
    $path = Join-Path $cache "$Name.zip"
    if (!(Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing
    }
    if ((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        throw "Checksum mismatch: $Name"
    }
    return $path
}

if (!(Test-Path (Join-Path $root '.tools/zig/zig.exe'))) {
    $zig = Get-VerifiedArchive 'zig-wheel' 'https://files.pythonhosted.org/packages/b9/6b/8ab0853a312108b4089747486366b824b5da89773cb56f661f9994de17db/ziglang-0.15.2-py3-none-win_amd64.whl' 'ca80dc9c70dbdfdd9ee51d000de3501a95d33d9782ab9ab9b56f700484ebcd83'
    Expand-Archive -Path $zig -DestinationPath (Join-Path $root '.tools/zig-package') -Force
    Move-Item (Join-Path $root '.tools/zig-package/ziglang') (Join-Path $root '.tools/zig')
}
$version = & (Join-Path $root '.tools/zig/zig.exe') version
if ($LASTEXITCODE -ne 0 -or $version -ne '0.15.2') { throw 'Expected Zig 0.15.2. Check .tools/zig.' }
$sqlite = Get-VerifiedArchive 'sqlite' 'https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip' '0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9'
Expand-Archive -Path $sqlite -DestinationPath $cache -Force
Copy-Item (Join-Path $cache 'sqlite-amalgamation-3540100/sqlite3.c'), (Join-Path $cache 'sqlite-amalgamation-3540100/sqlite3.h') (Join-Path $root 'vendor/sqlite') -Force
$webview = Get-VerifiedArchive 'webview2' 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.3537.50/microsoft.web.webview2.1.0.3537.50.nupkg' '5ea526bbd728adda0da4d31219267e96460494a427e4894c4e09d9f320f4b9aa'
Expand-Archive -Path $webview -DestinationPath (Join-Path $root 'vendor/webview2') -Force
& (Join-Path $root '.tools/zig/zig.exe') version
if ($LASTEXITCODE -ne 0) { throw 'Zig toolchain check failed' }
Write-Host 'Dependencies ready. Run: .\tools\zig.ps1 build test'
