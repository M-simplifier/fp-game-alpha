$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'test-platform.ps1')
$gameTests=Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\test-game.ps1'
if(!(Test-Path -LiteralPath $gameTests)) { throw 'Game test entrypoint tests\test-game.ps1 is missing.' }
& $gameTests
