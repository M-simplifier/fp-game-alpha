$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$swi = if ($env:PROLOG_FALL_SWIPL) { $env:PROLOG_FALL_SWIPL } else { Join-Path $project '.runtime\swipl\bin\swipl.exe' }
& $swi -q -s (Join-Path $project 'src\examples.pl')
if ($LASTEXITCODE -ne 0) { throw 'Query demonstrations failed.' }
