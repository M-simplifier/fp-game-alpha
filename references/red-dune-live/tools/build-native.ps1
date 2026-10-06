param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo '.build\red-dune-native' }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
Push-Location $repo
try {
    & cabal build --offline --project-file=cabal.project.red-dune-native exe:red-dune
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
    $binary = (& cabal list-bin --project-file=cabal.project.red-dune-native exe:red-dune).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate native executable' }
    New-Item -ItemType Directory -Force -Path (Join-Path $output 'assets') | Out-Null
    Copy-Item -LiteralPath $binary -Destination (Join-Path $output 'Red Dune.exe')
    $source = (Get-ChildItem -LiteralPath (Join-Path $repo 'references\red-dune-live\native') -Filter '*.hs' -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
    $glyphs = -join ($source.ToCharArray() | Where-Object { [int]$_ -gt 126 } | Sort-Object -Unique)
    [System.IO.File]::WriteAllText((Join-Path $output 'assets\glyphs.txt'), $glyphs, [System.Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $repo 'references\red-dune-live\LICENSE') -Destination (Join-Path $output 'LICENSE.RedDune.txt')
    Copy-Item -LiteralPath (Join-Path $repo 'references\red-dune-live\ASSETS.md') -Destination (Join-Path $output 'ASSETS.md')
    Copy-Item -LiteralPath (Join-Path $repo 'references\red-dune-live\docs\WINDOWS-PLAY.md') -Destination (Join-Path $output '遊び方.md')
    & python (Join-Path $PSScriptRoot 'native_notices.py') (Join-Path $output 'THIRD-PARTY-NOTICES.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Dependency notice collection failed' }
    Write-Output (Join-Path $output 'Red Dune.exe')
} finally { Pop-Location }
