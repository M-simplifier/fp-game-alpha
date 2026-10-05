# One explicit build, then use .build/tools/fp-game.exe directly. No Python required.
[CmdletBinding()]
param([switch]$Download, [switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Download -and $Check) { Write-Error 'Choose either -Download or -Check.'; exit 2 }
$missing = $false
foreach ($tool in @('ghc', 'cabal')) {
    $command = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        [Console]::Error.WriteLine("$tool is missing from PATH.")
        $missing = $true
    } else {
        $version = & $command.Source --numeric-version
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("$tool was found but its version check failed.")
            $missing = $true
        } else { [Console]::Error.WriteLine("${tool}: $version") }
    }
}
if ($missing) {
    [Console]::Error.WriteLine('Install the chosen GHC/Cabal explicitly: https://www.haskell.org/ghcup/install/')
    exit 1
}
if ($Check) { exit 0 }
$root = Split-Path -Parent $PSScriptRoot
$state = Join-Path $root '.build'
$bin = Join-Path $state 'tools'
$build = Join-Path $state 'native-tool'
foreach ($path in @($state, $bin, $build)) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing a linked bootstrap output directory.'
    }
}
$project = Join-Path $root 'tools/haskell'
if (-not (Test-Path -LiteralPath (Join-Path $project 'cabal.project') -PathType Leaf)) {
    throw 'Missing tools/haskell/cabal.project. Restore the complete tooling source.'
}
$destination = Join-Path $bin 'fp-game.exe'
function Assert-ExecutableDestination {
    $item = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw 'Refusing a linked or non-file bootstrap executable destination.'
    }
}
Assert-ExecutableDestination
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Push-Location -LiteralPath $project
try {
    if ($Download) {
        & cabal update
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    $options = @('build', 'exe:fp-game', "--builddir=$build")
    if (-not $Download) { $options += '--offline' }
    & cabal @options
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $source = & cabal list-bin exe:fp-game --offline "--builddir=$build"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $source = ($source -join "`n").Trim()
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Cabal did not identify the built executable.' }
    $temporary = Join-Path $bin ('.fp-game-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
        Copy-Item -LiteralPath $source -Destination $temporary
        # Windows may refuse replacement while this executable is running.
        # Report that failure; never rebuild or replace it on every CLI command.
        Assert-ExecutableDestination
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
    [Console]::Error.WriteLine("Ready: $destination")
} finally { Pop-Location }
