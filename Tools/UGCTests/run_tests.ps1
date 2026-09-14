$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$LuaSource = Join-Path $Root "Plugins\UnLua\Source\ThirdParty\Lua\lua-5.4.4\src"
$ToolDir = Join-Path $Root "Temp\LuaTools"
$LuaExe = Join-Path $ToolDir "lua54.exe"

if (-not (Test-Path -LiteralPath $LuaExe)) {
    New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
    $VsWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    $VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $VsPath) { throw "Visual Studio C++ toolchain not found" }
    $VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars64.bat"
    $Command = ('"{0}" >nul && cd /d "{1}" && cl /nologo /O2 onelua.c /Fe:"{2}" /link /OUT:"{2}"' -f $VcVars, $LuaSource, $LuaExe)
    cmd.exe /d /s /c $Command
    if ($LASTEXITCODE -ne 0) { throw "Failed to build temporary Lua 5.4 interpreter" }
}

$Checker = Join-Path $PSScriptRoot "check_syntax.lua"
$LuaFiles = Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script\Gameplay\UGC") -Recurse -File -Filter *.lua
$LuaFiles += Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script\System\UI\UGC") -Recurse -File -Filter *.lua
foreach ($File in $LuaFiles) {
    & $LuaExe $Checker $File.FullName
    if ($LASTEXITCODE -ne 0) { throw "Lua syntax failure: $($File.FullName)" }
}
Write-Output "Lua syntax OK: $($LuaFiles.Count) UGC files"

$RootLua = $Root -replace '\\','/'
& $LuaExe (Join-Path $PSScriptRoot "run.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_scene.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_registry.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_llm_gateway.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$TestData = Join-Path $Root "Temp\UGCTestData"
New-Item -ItemType Directory -Force -Path $TestData | Out-Null
& $LuaExe (Join-Path $PSScriptRoot "run_persistence.lua") $RootLua ($TestData -replace '\\','/')
exit $LASTEXITCODE
