param([string]$OutputDirectory, [string]$BuildDirectory, [string]$CabalConfig)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo '.build\afterlight-native' }
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $repo '.build\afterlight-native-dist' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$dist = [IO.Path]::GetFullPath($BuildDirectory)
if (Test-Path -LiteralPath $output) { throw "Choose a fresh package directory: $output" }
$cabalOptions = @()
if ($CabalConfig) { $cabalOptions += '--config-file=' + (Resolve-Path -LiteralPath $CabalConfig).Path }

Push-Location $repo
try {
    $cache = (& cabal @cabalOptions path --ignore-project --output-format=json | ConvertFrom-Json).'remote-repo-cache'
    if ($LASTEXITCODE) { throw 'Cabal archive cache lookup failed' }
    $archive = Join-Path $cache 'hackage.haskell.org/splitmix/0.1.3.2/splitmix-0.1.3.2.tar.gz'
    $splitmixOptions = @()
    if (Test-Path -LiteralPath $archive) { $splitmixOptions += @('--archive', $archive) }
    & python (Join-Path $PSScriptRoot 'prepare-splitmix.py') @splitmixOptions
    if ($LASTEXITCODE) { throw 'SplitMix preparation failed' }
    & python (Join-Path $PSScriptRoot 'prepare-native.py')
    if ($LASTEXITCODE) { throw 'Font preparation failed' }

    & cabal @cabalOptions build --project-file=cabal.project.gameio-afterlight "--builddir=$dist" `
        exe:afterlight-native exe:afterlight-audio exe:gameio-audio-worker
    if ($LASTEXITCODE) { throw 'Afterlight native build failed' }

    $plan = Get-Content -LiteralPath (Join-Path $dist 'cache/plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $app = ($plan.'install-plan' | Where-Object { $_.'component-name' -eq 'exe:afterlight-native' }).'bin-file'
    $generator = ($plan.'install-plan' | Where-Object { $_.'component-name' -eq 'exe:afterlight-audio' }).'bin-file'
    $worker = $plan.'install-plan' | Where-Object { $_.'component-name' -eq 'exe:gameio-audio-worker' }
    $pin = $worker.'pkg-src'.'source-repo'.tag
    $sdk = Get-ChildItem -LiteralPath (Join-Path $dist 'src') -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'haskell-game-io.cabal')) -and
            $pin -eq (& git -C $_.FullName rev-parse HEAD)
    } | Select-Object -First 1
    if (-not $pin -or -not $sdk) { throw 'The pinned Game IO license sources are missing' }

    $game = Split-Path -Parent $PSScriptRoot
    $fonts = Join-Path $output 'assets/fonts'
    New-Item -ItemType Directory -Path $fonts -Force | Out-Null
    foreach ($name in @('NotoSansCJKjp-Regular.otf', 'LICENSE-NotoSansCJK.txt', 'glyphs.txt')) {
        Copy-Item -LiteralPath (Join-Path $game "assets/fonts/$name") -Destination $fonts
    }
    Copy-Item -LiteralPath (Join-Path $game 'LICENSE'), (Join-Path $game 'THIRD-PARTY.md'), $worker.'bin-file' -Destination $output
    Copy-Item -LiteralPath (Join-Path $sdk.FullName 'LICENSE') -Destination (Join-Path $output 'LICENSE.GameIO.txt')
    Copy-Item -LiteralPath (Join-Path $sdk.FullName 'licenses/audio-codecs.txt') -Destination (Join-Path $output 'LICENSE.GameIO-Audio.txt')
    Push-Location $output
    try {
        & $generator
        if ($LASTEXITCODE) { throw 'WAV generation failed' }
    } finally { Pop-Location }
    $binary = Join-Path $output 'Afterlight.exe'
    Copy-Item -LiteralPath $app -Destination $binary
    Write-Output $binary
} finally { Pop-Location }
