param([string]$Directory = '.runtime/render-check', [string]$Output = '.runtime/render-check/contact.png')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$names = @('day-FullQuality','day-BalancedQuality','day-LightQuality','dusk','night','no-clouds','no-shadows','no-ao','no-bloom','wide-odd','portrait-tele','restored-high')
$canvas = [Drawing.Bitmap]::new(1080, 896)
$graphics = [Drawing.Graphics]::FromImage($canvas)
$font = [Drawing.Font]::new('Arial', 12)
try {
    $graphics.Clear([Drawing.Color]::FromArgb(18,22,26))
    for ($index = 0; $index -lt $names.Length; $index++) {
        $path = (Resolve-Path -LiteralPath (Join-Path $Directory ($names[$index] + '.png'))).Path
        $picture = [Drawing.Image]::FromFile($path)
        try {
            $x = ($index % 3) * 360
            $y = [Math]::Floor($index / 3) * 224
            $scale = [Math]::Min(352.0 / $picture.Width, 192.0 / $picture.Height)
            $width = [int]($picture.Width * $scale)
            $height = [int]($picture.Height * $scale)
            $graphics.DrawImage($picture, [int]($x + (360-$width)/2), [int]$y, $width, $height)
            $graphics.DrawString($names[$index], $font, [Drawing.Brushes]::White, [single]($x+8), [single]($y+197))
        } finally { $picture.Dispose() }
    }
    $outputPath = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Output))
    $canvas.Save($outputPath, [Drawing.Imaging.ImageFormat]::Png)
    Write-Output $outputPath
} finally { $font.Dispose(); $graphics.Dispose(); $canvas.Dispose() }
