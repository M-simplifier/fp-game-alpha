param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GameArgs)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$swi = Join-Path $project '.runtime\swipl\bin\swipl.exe'
if (!(Test-Path -LiteralPath $swi)) { throw 'Local SWI-Prolog is missing. Run scripts\setup.ps1 first.' }
if (!(Test-Path -LiteralPath "$project\.runtime\bin\prolog_raylib.dll")) { throw 'Native bridge is missing. Run scripts\build.ps1 first.' }
$oldPath=$env:PATH
try {
    $env:PATH="$project\.runtime\bin;$project\.runtime\swipl\bin;$oldPath"
    & $swi -q -s (Join-Path $project 'src\main.pl') -- @GameArgs
    if ($LASTEXITCODE -ne 0) { throw "Game exited with code $LASTEXITCODE. See the message above." }
} finally { $env:PATH=$oldPath }
