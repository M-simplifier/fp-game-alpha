$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$ray = Join-Path $project '.runtime\raylib\raylib-6.2_win64_msvc16'
$out = Join-Path $project '.runtime\bin'
if (!(Test-Path -LiteralPath "$ray\include\raylib.h")) { throw 'Run tools\setup.ps1 first.' }
$vsRoot = Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio'
$compiler = Get-ChildItem -LiteralPath $vsRoot -Filter cl.exe -Recurse -File |
    Where-Object { $_.FullName -like '*\bin\Hostx64\x64\cl.exe' } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (!$compiler) { throw 'Building requires Visual Studio C++ x64 build tools. A prepared runtime can still launch.' }
$msvc = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $compiler.FullName)))
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkVersion = Get-ChildItem -LiteralPath "$sdkRoot\Include" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (!$sdkVersion) { throw 'Windows SDK headers were not found.' }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$oldInclude=$env:INCLUDE; $oldLib=$env:LIB
try {
    $env:INCLUDE="$msvc\include;$($sdkVersion.FullName)\ucrt;$($sdkVersion.FullName)\shared;$($sdkVersion.FullName)\um"
    $env:LIB="$msvc\lib\x64;$sdkRoot\Lib\$($sdkVersion.Name)\ucrt\x64;$sdkRoot\Lib\$($sdkVersion.Name)\um\x64"
    & $compiler.FullName /nologo /O2 /W4 /MT /std:c11 "/I$ray\include" "/Fo$out\array_host.obj" (Join-Path $project 'host\array_host.c') /link "/OUT:$out\array-host.exe" "$ray\lib\raylibdll.lib" user32.lib shell32.lib
    if ($LASTEXITCODE -ne 0) { throw 'Native array host build failed.' }
    Copy-Item -LiteralPath "$ray\lib\raylib.dll" -Destination "$out\raylib.dll" -Force
} finally { $env:INCLUDE=$oldInclude; $env:LIB=$oldLib }
Write-Host "Ready: $out\array-host.exe"
