$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$swi = Join-Path $project '.runtime\swipl'
$ray = Join-Path $project '.runtime\raylib\raylib-6.2_win64_msvc16'
$out = Join-Path $project '.runtime\bin'
if (!(Test-Path -LiteralPath "$swi\include\SWI-Prolog.h")) { throw 'Run scripts\setup.ps1 first.' }
$vsRoot = Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio'
$compiler = Get-ChildItem -LiteralPath $vsRoot -Filter cl.exe -Recurse -File |
    Where-Object { $_.FullName -like '*\bin\Hostx64\x64\cl.exe' } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (!$compiler) { throw 'Build requires Visual Studio C++ x64 build tools. The prepared runtime can still be launched.' }
$msvc = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $compiler.FullName)))
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkVersion = Get-ChildItem -LiteralPath "$sdkRoot\Include" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (!$sdkVersion) { throw 'Windows SDK headers were not found.' }
New-Item -ItemType Directory -Path $out -Force | Out-Null
if (Test-Path -LiteralPath "$out\prolog_raylib.dll") {
    try {
        $probe=[System.IO.File]::Open("$out\prolog_raylib.dll",'Open','ReadWrite','None')
        $probe.Dispose()
    } catch { throw 'Close the running game or Prolog session before rebuilding the native bridge.' }
}
$oldInclude = $env:INCLUDE
$oldLib = $env:LIB
try {
    $env:INCLUDE = "$msvc\include;$($sdkVersion.FullName)\ucrt;$($sdkVersion.FullName)\shared;$($sdkVersion.FullName)\um"
    $env:LIB = "$msvc\lib\x64;$sdkRoot\Lib\$($sdkVersion.Name)\ucrt\x64;$sdkRoot\Lib\$($sdkVersion.Name)\um\x64"
    # SWI's generic registration API intentionally accepts all predicate pointer
    # signatures (C4152); other warnings remain enabled. Static CRT avoids an
    # extra Visual C++ runtime prerequisite for this small bridge.
    & $compiler.FullName /nologo /LD /O2 /W4 /wd4152 /MT /std:c11 "/I$swi\include" "/I$ray\include" "/Fo$out\ray_bridge.obj" (Join-Path $project 'native\ray_bridge.c') /link "/OUT:$out\prolog_raylib.dll" "/IMPLIB:$out\prolog_raylib.lib" "$swi\bin\libswipl.lib" "$ray\lib\raylibdll.lib"
    if ($LASTEXITCODE -ne 0) { throw 'Native bridge build failed.' }
    $raySource="$ray\lib\raylib.dll"
    $rayTarget="$out\raylib.dll"
    if (!(Test-Path -LiteralPath $rayTarget) -or
        (Get-FileHash -LiteralPath $raySource).Hash -ne (Get-FileHash -LiteralPath $rayTarget).Hash) {
        Copy-Item -LiteralPath $raySource -Destination $rayTarget -Force
    }
} finally { $env:INCLUDE=$oldInclude; $env:LIB=$oldLib }
Write-Host "Ready: $out\prolog_raylib.dll"
