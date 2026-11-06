[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = '1.0.0',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = Join-Path $projectRoot 'release'
$packageName = "PURE-FALL-win64-$Version"
$stage = Join-Path $releaseRoot $packageName
$zip = Join-Path $releaseRoot ($packageName + '.zip')
$runtimeRoot = Join-Path $projectRoot '.runtime\package-verification'
New-Item -ItemType Directory -Force -Path $releaseRoot,$runtimeRoot | Out-Null

function Assert-Contained([string]$Candidate, [string]$Root) {
    $resolvedCandidate = [IO.Path]::GetFullPath($Candidate)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $resolvedCandidate.StartsWith($resolvedRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing file operation outside intended root: $resolvedCandidate"
    }
}

function Invoke-BoundedSmoke([string]$GamePath,[string]$Name) {
    $target = Join-Path $runtimeRoot $Name
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $priorPath = $env:PATH
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
        $arguments = '--smoke --fixture FourLine --frames 90 --data-dir "' + (Join-Path $target 'user-data') + '" --shots "' + $target + '"'
        $gameProcess = Start-Process -FilePath $GamePath -ArgumentList $arguments -WorkingDirectory $env:TEMP `
            -RedirectStandardOutput (Join-Path $target 'stdout.log') -RedirectStandardError (Join-Path $target 'stderr.log') -WindowStyle Hidden -PassThru
        if (-not $gameProcess.WaitForExit(30000)) { Stop-Process -Id $gameProcess.Id; throw 'Package smoke exceeded 30 seconds.' }
        $gameProcess.Refresh()
        if ($gameProcess.ExitCode -ne 0) { throw "Package smoke failed: $($gameProcess.ExitCode)" }
        if (-not (Test-Path -LiteralPath (Join-Path $target '03-clear.png'))) { throw 'Packaged game did not render its four-line clear.' }
        $report = Get-Content -LiteralPath (Join-Path $target 'native-report.txt') -Raw
        if ($report -notmatch 'lines=4') { throw 'The packaged production kernel did not clear four lines.' }
        return $report
    }
    finally { $env:PATH = $priorPath }
}

Push-Location -LiteralPath $projectRoot
try {
    if (-not $SkipBuild) {
        & cabal build exe:pure-fall --offline
        if ($LASTEXITCODE -ne 0) { throw 'Cabal build failed.' }
    }
    $executable = (& cabal list-bin exe:pure-fall --offline --verbose=0 | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable)) { throw 'The game executable is missing.' }
    $generate = Start-Process -FilePath $executable -ArgumentList '--generate-audio --audio-dir assets/audio' -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru
    if (-not $generate.WaitForExit(20000)) { Stop-Process -Id $generate.Id; throw 'Audio generation timed out.' }
    $generate.Refresh()
    if ($generate.ExitCode -ne 0) { throw 'Audio generation failed.' }
    Assert-Contained $stage $releaseRoot
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -LiteralPath $executable -Destination (Join-Path $stage 'PURE-FALL.exe')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'assets') -Destination (Join-Path $stage 'assets') -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses') -Destination (Join-Path $stage 'licenses') -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'AUDIO-PROVENANCE.txt') -Destination (Join-Path $stage 'assets/PROVENANCE.txt')
    foreach ($name in @('README_PLAY.txt','LICENSE','THIRD_PARTY_NOTICES.md')) {
        $source = Join-Path $projectRoot $name
        if (-not (Test-Path -LiteralPath $source)) { throw "Required distribution notice is missing: $name" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name)
    }
    $launcher = "@echo off`r`ncd /d `"%~dp0`"`r`nstart `"`" `"%~dp0PURE-FALL.exe`"`r`n"
    [IO.File]::WriteAllText((Join-Path $stage 'Play.cmd'),$launcher,[Text.ASCIIEncoding]::new())

    $objdump = 'C:\ghcup\ghc\9.14.1\mingw\bin\objdump.exe'
    if (-not (Test-Path -LiteralPath $objdump)) { throw 'Expected GHC PE dependency inspector is unavailable.' }
    $knownRoots = @((Split-Path -Parent $executable),'C:\ghcup\ghc\9.14.1\mingw\bin','C:\ghcup\msys64\mingw64\bin')
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue((Join-Path $stage 'PURE-FALL.exe'))
    $inspected = @{}
    $audit = [Collections.Generic.List[string]]::new()
    while ($queue.Count -gt 0) {
        $binary = $queue.Dequeue()
        foreach ($match in (& $objdump -p $binary | Select-String 'DLL Name:\s*(.+)$')) {
            $dll = $match.Matches[0].Groups[1].Value.Trim()
            if ($inspected.ContainsKey($dll.ToLowerInvariant())) { continue }
            $inspected[$dll.ToLowerInvariant()] = $true
            if ($dll -match '^(api-ms-win-|ext-ms-win-)' -or (Test-Path -LiteralPath (Join-Path "$env:SystemRoot\System32" $dll))) {
                $audit.Add("SYSTEM $dll")
                continue
            }
            $found = $null
            foreach ($root in $knownRoots) {
                $candidate = Join-Path $root $dll
                if (Test-Path -LiteralPath $candidate) { $found=$candidate; break }
            }
            if (-not $found) { throw "Unresolved non-system DLL: $dll" }
            $destination = Join-Path $stage $dll
            Copy-Item -LiteralPath $found -Destination $destination
            $queue.Enqueue($destination)
            $audit.Add("BUNDLED $dll FROM $found")
        }
    }
    Set-Content -LiteralPath (Join-Path $runtimeRoot 'dll-audit.txt') -Value $audit -Encoding utf8
    $stageReport = Invoke-BoundedSmoke (Join-Path $stage 'PURE-FALL.exe') 'staged'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
    $extraction = Join-Path $runtimeRoot 'extracted'
    Assert-Contained $extraction $runtimeRoot
    if (Test-Path -LiteralPath $extraction) { Remove-Item -LiteralPath $extraction -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $extraction
    $extractedGame = Join-Path (Join-Path $extraction $packageName) 'PURE-FALL.exe'
    $extractReport = Invoke-BoundedSmoke $extractedGame 'extracted-smoke'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $entries = @($archive.Entries | ForEach-Object FullName) } finally { $archive.Dispose() }
    foreach ($required in @('/PURE-FALL.exe','/Play.cmd','/README_PLAY.txt','/assets/audio/clear.wav','/assets/audio/quiet-rhythm.wav','/LICENSE','/THIRD_PARTY_NOTICES.md','/licenses/h-raylib-LICENSE.txt','/licenses/raylib-LICENSE.txt','/licenses/game-arena-LICENSE.txt','/licenses/game-transition-LICENSE.txt')) {
        if (-not ($entries | Where-Object { $_.Replace('\','/').EndsWith($required,[StringComparison]::OrdinalIgnoreCase) })) {
            throw "ZIP is missing $required"
        }
    }
    Set-Content -LiteralPath (Join-Path $runtimeRoot 'zip-contents.txt') -Value $entries -Encoding utf8
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $summary = "ZIP=$zip`nSHA256=$hash`nEntries=$($entries.Count)`nStaged and extracted smoke passed from TEMP with Windows-only PATH.`n`nSTAGED`n$stageReport`nEXTRACTED`n$extractReport"
    Set-Content -LiteralPath (Join-Path $runtimeRoot 'verification.txt') -Value $summary -Encoding utf8
    Write-Output $summary
}
finally { Pop-Location }
