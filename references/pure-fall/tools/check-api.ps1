param()
$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scratch = Join-Path $project '.runtime/api-probes'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$probes = @(
    @{ Name='game-field'; Text="module Attack where`nimport PureFall.Core`ncorrupt :: Game -> Game`ncorrupt value = value { rawScore = -1 }`n"; Expected='rawScore' },
    @{ Name='game-read'; Text="module Attack where`nimport PureFall.Core`ncorrupt :: Game`ncorrupt = read `"malformed`"`n"; Expected='Read Game' },
    @{ Name='board-constructor'; Text="module Attack where`nimport PureFall.Core`ncorrupt = Board undefined`n"; Expected='Board' },
    @{ Name='session-field'; Text="module Attack where`nimport PureFall.Session`ncorrupt :: Session -> Session`ncorrupt value = value { internalDebt = -1 }`n"; Expected='internalDebt' }
)
Push-Location $project
try {
    foreach ($probe in $probes) {
        $path = Join-Path $scratch ($probe.Name+'.hs')
        [IO.File]::WriteAllText($path,$probe.Text,[Text.UTF8Encoding]::new($false))
        $output = & ghc -fno-code -XGHC2021 -isrc -ivendor/game-transition/src -ivendor/game-arena/src $path 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $output -notmatch [regex]::Escape($probe.Expected)) {
            throw "Boundary attack did not fail at intended restriction: $($probe.Name) $output"
        }
        [IO.File]::WriteAllText((Join-Path $scratch ($probe.Name+'.txt')),$output,[Text.UTF8Encoding]::new($false))
        Write-Output "PASS $($probe.Name) rejected at $($probe.Expected)"
    }
} finally { Pop-Location }
