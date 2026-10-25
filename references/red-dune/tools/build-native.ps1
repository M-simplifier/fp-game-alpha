param([string]$OutputDirectory, [string]$BuildDirectory)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo '.build\red-dune-native' }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
Push-Location $repo
try {
    $component = @('--project-file=cabal.project.red-dune-native')
    if ($BuildDirectory) { $component += '--builddir=' + [System.IO.Path]::GetFullPath($BuildDirectory) }
    & cabal build --offline @component exe:red-dune
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
    $binary = (& cabal list-bin @component exe:red-dune).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate native executable' }
    New-Item -ItemType Directory -Force -Path (Join-Path $output 'assets') | Out-Null
    & python (Join-Path $PSScriptRoot 'native_icon.py') (Join-Path $output 'assets')
    if ($LASTEXITCODE -ne 0) { throw 'Icon generation failed' }
    Copy-Item -LiteralPath $binary -Destination (Join-Path $output 'Red Dune.exe')
    $source = (Get-ChildItem -LiteralPath (Join-Path $repo 'references\red-dune\native') -Filter '*.hs' -Recurse -File | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
    $glyphs = -join ($source.ToCharArray() | Where-Object { [int]$_ -gt 126 } | Sort-Object -Unique)
    [System.IO.File]::WriteAllText((Join-Path $output 'assets\glyphs.txt'), $glyphs, [System.Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $repo 'references\red-dune\LICENSE') -Destination (Join-Path $output 'LICENSE.RedDune.txt')
    Copy-Item -LiteralPath (Join-Path $repo 'references\red-dune\ASSETS.md') -Destination (Join-Path $output 'ASSETS.md')
    Copy-Item -LiteralPath (Join-Path $repo 'references\red-dune\docs\WINDOWS-PLAY.md') -Destination (Join-Path $output '遊び方.md')
    $noticeArguments = @((Join-Path $output 'THIRD-PARTY-NOTICES.txt'))
    if ($BuildDirectory) { $noticeArguments += @('--plan', (Join-Path ([System.IO.Path]::GetFullPath($BuildDirectory)) 'cache\plan.json')) }
    & python (Join-Path $PSScriptRoot 'native_notices.py') @noticeArguments
    if ($LASTEXITCODE -ne 0) { throw 'Dependency notice collection failed' }
    Write-Output (Join-Path $output 'Red Dune.exe')
} finally { Pop-Location }
