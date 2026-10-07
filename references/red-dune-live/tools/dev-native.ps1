param(
    [ValidateSet('settlement', 'recovery')][string]$Scenario = 'settlement',
    [string]$ContentPack,
    [string]$QaDirectory,
    [ValidateRange(0, 2147483647)][int]$Frames = 0,
    [switch]$Hidden
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$dev = Join-Path $repo '.build\red-dune-native-dev'
$app = Join-Path $dev 'app'
$binary = Join-Path $app 'Red Dune.exe'
$store = Join-Path $dev 'saves'
if (-not $ContentPack) { $ContentPack = Join-Path $repo 'references\red-dune-live\data\campaign-pack-v1.json' }
$pack = (Resolve-Path -LiteralPath $ContentPack).Path

# An older development window must not look like the result of a failed build.
# Only this exact output path matters; the owner's installed app is independent.
$running = Get-Process -Name 'Red Dune' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and [string]::Equals($_.Path, $binary, [System.StringComparison]::OrdinalIgnoreCase)
}
if ($running) { throw 'Close the previous development window, save your edit, then run this command again.' }

$buildTime = [System.Diagnostics.Stopwatch]::StartNew()
& (Join-Path $PSScriptRoot 'build-native.ps1') -OutputDirectory $app
$buildTime.Stop()
Write-Host ('Build and package: {0:F3} s' -f $buildTime.Elapsed.TotalSeconds)
Write-Host "Development saves: $store"
$nativeArguments = @('--store', ('"{0}"' -f $store), '--pack', ('"{0}"' -f $pack), '--new', $Scenario)
if ($QaDirectory) {
    $qa = [System.IO.Path]::GetFullPath($QaDirectory)
    $nativeArguments += @('--qa-dir', ('"{0}"' -f $qa))
}
if ($Frames -gt 0) { $nativeArguments += @('--frames', "$Frames") }
if ($Hidden) { $nativeArguments += '--hidden' }
Write-Host "Launching rebuilt development app ($Scenario)."
$launch = @{FilePath = $binary; ArgumentList = $nativeArguments; WorkingDirectory = $app; Wait = $true; PassThru = $true}
if ($Hidden) { $launch.WindowStyle = 'Hidden' }
$process = Start-Process @launch
if ($process.ExitCode -ne 0) { throw "Development app exited with code $($process.ExitCode)." }
