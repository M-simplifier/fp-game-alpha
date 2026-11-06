$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$python = Get-Command python -ErrorAction Stop
& $python.Source (Join-Path $PSScriptRoot 'oracle.py')
if ($LASTEXITCODE -ne 0) { throw 'Independent APL game oracle failed.' }
& $python.Source (Join-Path $PSScriptRoot 'gui_smoke.py')
if ($LASTEXITCODE -ne 0) { throw 'Native GUI game traces failed.' }
Add-Type -AssemblyName System.Drawing
$evidence=Join-Path $project '.scratch\evidence'
$checks=@(
    @{File='opening.png'; X=352; Y=118; R=234; G=211; B=90},
    @{File='inspect-first.png'; X=268; Y=510; R=92; G=126; B=235}
)
foreach($check in $checks) {
    $image=[Drawing.Bitmap]::FromFile((Join-Path $evidence $check.File))
    try {
        $pixel=$image.GetPixel($check.X,$check.Y)
        if($pixel.R -ne $check.R -or $pixel.G -ne $check.G -or $pixel.B -ne $check.B) {
            throw "Game screenshot pixel failed: $($check.File) ($($check.X),$($check.Y)) = $pixel"
        }
    } finally { $image.Dispose() }
}
Write-Host 'GAME PASS: visible spawn and board retained on first inspect frame, native screenshot pixels.'
