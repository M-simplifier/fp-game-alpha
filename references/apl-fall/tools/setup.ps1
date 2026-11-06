param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$project=Split-Path -Parent $PSScriptRoot
$runtime=Join-Path $project '.runtime'
$downloads=Join-Path $runtime 'downloads'
foreach ($name in @('apl-2.0','array-host')) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$runtime\*" }) {
        throw 'Close this project game and APL sessions before extracting the local runtime.'
    }
}
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$files=@(
    @{Name='GNU_APL_2_0_r3518_Setup.exe';Url='https://ftp.gnu.org/gnu/apl/GNU_APL_2_0_r3518_Setup.exe';Hash='7f4ccf0ba6261b26fd6f1734a0ccc84f6da47e3713040d212effec5b313fb1dd'},
    @{Name='apl-2.0.tar.gz';Url='https://ftp.gnu.org/gnu/apl/apl-2.0.tar.gz';Hash='24bbb744fce47e62837234a053bdeecee51b9ea61c82c79f7cc191bc6a54c0a1'},
    @{Name='raylib-6.2_win64_msvc16.zip';Url='https://github.com/raysan5/raylib/releases/download/6.2/raylib-6.2_win64_msvc16.zip';Hash='8467b5dd6db4d7ab942f3148a3d30d93be6ed9b2fab88069d177e59604268ebd'},
    @{Name='7zr.exe';Url='https://github.com/ip7z/7zip/releases/download/26.05/7zr.exe';Hash='9bf582b894dfa665f852d7e9112b02290a1c303c2d95a21fcdc41ffcb03143b7'},
    @{Name='7z2605-x64.exe';Url='https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.exe';Hash='fd99e86f57d8f429ef5ed045bf98315af962e2309b0f1ba87a147a44c71647d0'},
    @{Name='winpthreads-COPYING';Url='https://raw.githubusercontent.com/mingw-w64/mingw-w64/v7.0.0/mingw-w64-libraries/winpthreads/COPYING';Hash='63263614cdd29f2f93cba85e992f041b31f9fc7b4033692f31269489a8a1b177'}
)
foreach($file in $files) {
    $path=Join-Path $downloads $file.Name
    if(!(Test-Path -LiteralPath $path)) { Write-Host "Downloading $($file.Name)"; Invoke-WebRequest -Uri $file.Url -OutFile $path }
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -ne $file.Hash) { throw "Checksum mismatch: $($file.Name)" }
}
# These commands only extract archives. No installer or global registration runs.
& "$downloads\7zr.exe" x "$downloads\7z2605-x64.exe" "-o$runtime\7zip" -y | Out-Null
if($LASTEXITCODE -ne 0) { throw '7-Zip bootstrap extraction failed.' }
& "$runtime\7zip\7z.exe" x "$downloads\GNU_APL_2_0_r3518_Setup.exe" "-o$runtime\apl" -y | Out-Null
if($LASTEXITCODE -ne 0) { throw 'GNU APL extraction failed.' }
Expand-Archive -LiteralPath "$downloads\raylib-6.2_win64_msvc16.zip" -DestinationPath "$runtime\raylib" -Force
$sourceScratch=Join-Path $project '.scratch\upstream-source'
New-Item -ItemType Directory -Force -Path $sourceScratch | Out-Null
& "$runtime\7zip\7z.exe" x "$downloads\apl-2.0.tar.gz" "-o$sourceScratch" -y | Out-Null
if($LASTEXITCODE -ne 0) { throw 'GNU APL source decompression failed.' }
& "$runtime\7zip\7z.exe" x "$sourceScratch\apl-2.0.tar" "-o$sourceScratch" 'apl-2.0\COPYING' -y | Out-Null
if($LASTEXITCODE -ne 0) { throw 'GNU APL license extraction failed.' }
Copy-Item -LiteralPath "$sourceScratch\apl-2.0\COPYING" -Destination "$runtime\apl\COPYING" -Force
$licenses=Join-Path $project 'vendor\licenses'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -LiteralPath "$runtime\apl\COPYING" -Destination "$licenses\GNU-APL-COPYING" -Force
Copy-Item -LiteralPath "$runtime\raylib\raylib-6.2_win64_msvc16\LICENSE" -Destination "$licenses\raylib-LICENSE" -Force
Copy-Item -LiteralPath "$runtime\7zip\License.txt" -Destination "$licenses\7zip-License.txt" -Force
Copy-Item -LiteralPath "$downloads\winpthreads-COPYING" -Destination "$licenses\winpthreads-COPYING" -Force
$oldRoot=$env:APL_LIB_ROOT
Push-Location $sourceScratch
try { $env:APL_LIB_ROOT="$runtime\apl"; & "$runtime\apl\apl-2.0.exe" --version }
finally { $env:APL_LIB_ROOT=$oldRoot; Pop-Location }
if(!$SkipBuild) { & (Join-Path $PSScriptRoot 'build.ps1') }
