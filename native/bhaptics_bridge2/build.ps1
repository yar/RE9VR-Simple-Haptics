param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$OutDir = Join-Path $Root "reframework\plugins"
$BuildDir = Join-Path $PSScriptRoot "build"
$DepsDir = Join-Path $PSScriptRoot ".deps"
$ReframeworkDir = Join-Path $DepsDir "REFramework"
$ObjectDir = Join-Path $BuildDir "obj"
$DllPath = Join-Path $OutDir "bhaptics_bridge2.dll"

New-Item -ItemType Directory -Force -Path $OutDir, $BuildDir, $DepsDir, $ObjectDir | Out-Null

if (!(Test-Path -LiteralPath (Join-Path $ReframeworkDir "include\reframework\API.h"))) {
    if (Test-Path -LiteralPath $ReframeworkDir) {
        Remove-Item -LiteralPath $ReframeworkDir -Recurse -Force
    }
    git clone --depth 1 --filter=blob:none --sparse https://github.com/praydog/REFramework.git $ReframeworkDir
    Push-Location $ReframeworkDir
    git sparse-checkout set include dependencies/lua
    Pop-Location
}

$VsWhere = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($VsWhere -eq $null) {
    throw "Visual Studio vswhere.exe was not found."
}

$VsInstall = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($VsInstall)) {
    throw "Visual Studio C++ build tools were not found."
}

$VcVars = Join-Path $VsInstall "VC\Auxiliary\Build\vcvars64.bat"
if (!(Test-Path -LiteralPath $VcVars)) {
    throw "vcvars64.bat was not found at $VcVars"
}

$LuaDir = Join-Path $ReframeworkDir "dependencies\lua\src"
$ApiInclude = Join-Path $ReframeworkDir "include"
$Source = Join-Path $PSScriptRoot "bhaptics_bridge2.cpp"

$LuaSources = Get-ChildItem -LiteralPath $LuaDir -Filter "*.c" |
    Where-Object { $_.Name -notin @("lua.c", "luac.c", "onelua.c") } |
    Sort-Object Name

$LuaObjectCommands = foreach ($src in $LuaSources) {
    $obj = Join-Path $ObjectDir ($src.BaseName + ".obj")
    "cl /nologo /O2 /MT /TC /c /I`"$LuaDir`" /Fo`"$obj`" `"$($src.FullName)`""
}

$CppObj = Join-Path $ObjectDir "bhaptics_bridge2.obj"
$CompileCpp = "cl /nologo /O2 /MT /EHsc /std:c++20 /I`"$ApiInclude`" /I`"$LuaDir`" /c /Fo`"$CppObj`" `"$Source`""
$LuaObjs = ($LuaSources | ForEach-Object { '"' + (Join-Path $ObjectDir ($_.BaseName + ".obj")) + '"' }) -join " "
$Link = "link /nologo /DLL /OPT:REF /OPT:ICF /OUT:`"$DllPath`" `"$CppObj`" $LuaObjs winhttp.lib"

$CmdPath = Join-Path $BuildDir "build.cmd"
$Commands = @(
    "@echo off",
    "call `"$VcVars`" >nul",
    "if errorlevel 1 exit /b 1"
) + $LuaObjectCommands + @(
    $CompileCpp,
    $Link
)
Set-Content -LiteralPath $CmdPath -Encoding ASCII -Value $Commands

cmd /d /c "`"$CmdPath`""
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

Get-Item -LiteralPath $DllPath
