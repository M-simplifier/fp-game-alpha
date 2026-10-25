# One explicit build, then use .build/tools/fp-game.exe directly. No Python required.
[CmdletBinding()]
param([switch]$Download, [switch]$Check, [string]$CompilerPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Download -and $Check) { Write-Error 'Choose either -Download or -Check.'; exit 2 }
# Resolve an explicitly chosen compiler from the caller's location, before any
# build-directory writes or Push-Location. Keep wrapper/symlink identity intact.
$compiler = $null
if ($PSBoundParameters.ContainsKey('CompilerPath')) {
    if ([string]::IsNullOrWhiteSpace($CompilerPath) -or $CompilerPath -match '[\x00-\x1f]') {
        throw 'CompilerPath must name an existing compiler executable.'
    }
    $compiler = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CompilerPath)
    $item = Get-Item -LiteralPath $compiler -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.PSProvider.Name -ne 'FileSystem') {
        throw 'CompilerPath must name an existing compiler executable.'
    }
}
$missing = $false
foreach ($tool in @('ghc', 'cabal')) {
    # PATH may contain multiple spellings of the same application directory.
    # Get-Command can return several matches; invoke one checked application.
    $command = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $application = if ($tool -eq 'ghc' -and $null -ne $compiler) { $compiler } elseif ($null -ne $command) { $command.Source } else { $null }
    if ($null -eq $application) {
        [Console]::Error.WriteLine("$tool is missing from PATH.")
        $missing = $true
    } else {
        $version = & $application --numeric-version
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("$tool was found but its version check failed.")
            $missing = $true
        } else {
            if ($tool -eq 'ghc' -and $null -ne $compiler) {
                if (($version -join "`n").Trim() -notmatch '^\d+(\.\d+)+$') {
                    throw 'CompilerPath did not report a numeric GHC version.'
                }
                [Console]::Error.WriteLine("Explicit compiler: $compiler")
            }
            [Console]::Error.WriteLine("${tool}: $version")
        }
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
$cabalBuild = Join-Path $state 'windows-console'
foreach ($path in @($state, $bin, $build, $cabalBuild)) {
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
    param([string]$destination)
    $item = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw 'Refusing a linked or non-file bootstrap executable destination.'
    }
}
Assert-ExecutableDestination $destination
New-Item -ItemType Directory -Path $bin -Force | Out-Null
function Install-BuiltTool {
    param([string]$command, [string]$target, [string]$projectFile,
          [string]$buildDirectory, [string]$destination, [string[]]$prefixArguments = @())
    Assert-ExecutableDestination $destination
    $options = @('build', $target, "--project-file=$projectFile", "--builddir=$buildDirectory")
    if (-not $Download) { $options += '--offline' }
    if ($null -ne $compiler) { $options += "--with-compiler=$compiler" }
    & $command @prefixArguments @options
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    # plan.json is UTF-8 even when the bootstrap Cabal's console output uses
    # an ANSI code page. Do not decode a Unicode list-bin path as console text.
    $plan = Get-Content -LiteralPath (Join-Path $buildDirectory 'cache/plan.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $units = @($plan.'install-plan' | Where-Object { $_.PSObject.Properties['component-name'] -and $_.'component-name' -eq $target })
    if ($units.Count -ne 1) { throw "Expected one built $target in Cabal plan.json." }
    $source = $units[0].'bin-file'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Cabal did not identify the built executable.' }
    $temporary = Join-Path $bin ('.fp-game-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
        Copy-Item -LiteralPath $source -Destination $temporary
        Assert-ExecutableDestination $destination
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}
Push-Location -LiteralPath $project
try {
    if ($Download) {
        & cabal update
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    $cabalExecutable = Join-Path $bin 'fp-game-console.exe'
    $cabalProject = Join-Path $root 'tools/windows-console/cabal.project'
    Install-BuiltTool 'cabal' 'exe:fp-game-console' $cabalProject $cabalBuild $cabalExecutable
    Install-BuiltTool $cabalExecutable 'exe:fp-game' (Join-Path $project 'cabal.project') $build $destination @('cabal')
    [Console]::Error.WriteLine("Ready: $destination")
} finally { Pop-Location }
