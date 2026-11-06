# Local extraction only: no installer is executed, no registry or PATH changes.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $project '.runtime'
$downloads = Join-Path $runtime 'downloads'
if (Get-Process -Name swipl -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq "$runtime\swipl\bin\swipl.exe" }) {
    throw 'Close local game and Prolog sessions before extracting the runtime.'
}
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
$files = @(
    @{Name='swipl-10.0.2-1.x64.exe'; Url='https://www.swi-prolog.org/download/stable/bin/swipl-10.0.2-1.x64.exe'; Hash='2ec1f25be0eafb92e559004782b130774c12573fb4b7e8a917e534754a641ad6'},
    @{Name='raylib-6.2_win64_msvc16.zip'; Url='https://github.com/raysan5/raylib/releases/download/6.2/raylib-6.2_win64_msvc16.zip'; Hash='8467b5dd6db4d7ab942f3148a3d30d93be6ed9b2fab88069d177e59604268ebd'},
    @{Name='7zr.exe'; Url='https://github.com/ip7z/7zip/releases/download/26.05/7zr.exe'; Hash='9bf582b894dfa665f852d7e9112b02290a1c303c2d95a21fcdc41ffcb03143b7'},
    @{Name='7z2605-x64.exe'; Url='https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.exe'; Hash='fd99e86f57d8f429ef5ed045bf98315af962e2309b0f1ba87a147a44c71647d0'}
)
foreach ($file in $files) {
    $path=Join-Path $downloads $file.Name
    if (!(Test-Path -LiteralPath $path)) { Write-Host "Downloading $($file.Name)"; Invoke-WebRequest -Uri $file.Url -OutFile $path }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $file.Hash) { throw "Checksum mismatch: $($file.Name)" }
}
& "$downloads\7zr.exe" x "$downloads\7z2605-x64.exe" "-o$runtime\7zip" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw '7-Zip extraction failed.' }
& "$runtime\7zip\7z.exe" x "$downloads\swipl-10.0.2-1.x64.exe" "-o$runtime\swipl" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'SWI-Prolog extraction failed.' }
Expand-Archive -LiteralPath "$downloads\raylib-6.2_win64_msvc16.zip" -DestinationPath "$runtime\raylib" -Force
& "$runtime\swipl\bin\swipl.exe" --version
& (Join-Path $PSScriptRoot 'build.ps1')
