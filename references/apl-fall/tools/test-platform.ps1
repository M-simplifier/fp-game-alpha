$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$shot=Join-Path $project '.scratch\platform-check.png'
& (Join-Path $PSScriptRoot 'run.ps1') -Script @('examples\platform-check.apl') -Frames 6 -Width 320 -Height 220 -FixedDt 0.125 -InputFixture 'examples\platform-input.txt' -Screenshot $shot -Title 'APL platform verification'
Add-Type -AssemblyName System.Drawing
$image=[Drawing.Bitmap]::FromFile($shot)
try {
    if($image.Width -ne 320 -or $image.Height -ne 220) { throw 'Screenshot dimensions did not match the host.' }
    $checks=@(
        @{X=4;Y=16;R=220;G=30;B=40},
        @{X=60;Y=20;R=20;G=210;B=100},
        @{X=80;Y=40;R=10;G=14;B=23},
        @{X=200;Y=40;R=240;G=200;B=30},
        @{X=255;Y=25;R=255;G=0;B=80}
    )
    foreach($check in $checks) {
        $pixel=$image.GetPixel($check.X,$check.Y)
        if($pixel.R -ne $check.R -or $pixel.G -ne $check.G -or $pixel.B -ne $check.B) {
            throw "Pixel oracle failed at ($($check.X),$($check.Y)): $pixel"
        }
    }
} finally { $image.Dispose() }
Write-Host 'PLATFORM PASS: independent screenshot pixel checks; native APL input/time assertions.'

$textShot=Join-Path $project '.scratch\platform-text.png'
& (Join-Path $PSScriptRoot 'run.ps1') -Script @('examples\array-smoke.apl') -Frames 30 -Screenshot $textShot -Title 'APL repeated text verification'
$image=[Drawing.Bitmap]::FromFile($textShot)
try {
    $ink=0
    for($y=25;$y -lt 60;$y++) { for($x=30;$x -lt 650;$x++) {
        $pixel=$image.GetPixel($x,$y)
        if($pixel.R -gt 100 -and $pixel.G -gt 100) { $ink++ }
    }}
    if($ink -ne 3591) { throw "Repeated static label pixels changed unexpectedly: $ink" }
} finally { $image.Dispose() }
Write-Host 'PLATFORM PASS: static text remains present after repeated frame batches.'

& (Join-Path $PSScriptRoot 'run.ps1') -Script @('examples\native-key-check.apl') -Frames 6 -Width 320 -Height 220 -NativeInputFixture 'examples\native-key-input.txt' -Title 'APL native callback verification'
Write-Host 'PLATFORM PASS: own-window Win32 messages exercise GLFW key-down queue.'

# Synthetic native close, not a physical-input or gameplay-feel claim.
$log=Join-Path $project '.scratch\platform-stall.log'
$out=Join-Path $project '.scratch\platform-stall.out'
$hostExe=Join-Path $project '.runtime\bin\array-host.exe'
$stall=Join-Path $project 'examples\platform-stall.apl'
$process=Start-Process -FilePath $hostExe -ArgumentList @('--width','320','--height','220','--title','"APL stalled boundary test"',('"'+$stall+'"')) -PassThru -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput $out
$null=$process.Handle
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 50
        $process.Refresh()
    } while(!$process.HasExited -and !$process.MainWindowHandle -and [DateTime]::UtcNow -lt $deadline)
    if($process.HasExited -or !$process.MainWindowHandle) { throw 'Stalled fixture did not create a native window.' }
    Start-Sleep -Milliseconds 350
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if(!$process.CloseMainWindow()) { throw 'Native close message could not reach the stalled host.' }
    if(!$process.WaitForExit(2500)) { throw 'Native window close did not stop the stalled APL child promptly.' }
    $clock.Stop()
    if($process.ExitCode -ne 0) { throw 'Owner close was reported as a runtime error.' }
    $text=Get-Content -Raw -LiteralPath $log
    if($text -notmatch 'child_pid=(\d+).*child_exit=0 protocol=ok close=owner') { throw 'Owner-close cleanup evidence is missing.' }
    if(Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) { throw 'The stalled APL child survived native window close.' }
    Write-Host "PLATFORM PASS: stalled APL native close and child cleanup ($($clock.ElapsedMilliseconds) ms)."
} finally {
    $process.Refresh()
    if(!$process.HasExited) { $process.Kill() }
    $process.Dispose()
}

$bad=Join-Path $project 'examples\platform-error.apl'
$errorLog=Join-Path $project '.scratch\platform-error.log'
$errorProcess=Start-Process -FilePath $hostExe -ArgumentList @('--width','320','--height','220',('"'+$bad+'"')) -PassThru -WindowStyle Hidden -RedirectStandardError $errorLog
$null=$errorProcess.Handle
if(!$errorProcess.WaitForExit(5000)) { $errorProcess.Kill(); throw 'APL error fixture did not release the native host.' }
if($errorProcess.ExitCode -eq 0) { throw 'An APL interpreter error was not reported as a failed run.' }
$errorProcess.Dispose()
$errorText=Get-Content -Raw -LiteralPath $errorLog
if($errorText -notmatch 'unexpected APL output: VALUE ERROR' -or $errorText -notmatch 'protocol=error') { throw 'The original interpreter error was not retained.' }
Write-Host 'PLATFORM PASS: APL interpreter error surfaced and native host exited.'
