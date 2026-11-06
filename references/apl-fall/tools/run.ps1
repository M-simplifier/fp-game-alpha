param(
    [string[]]$Script,
    [switch]$Demo,
    [int]$Frames=0,
    [string]$Screenshot='',
    [int]$SnapshotFrame=0,
    [double]$FixedDt=0,
    [string]$InputFixture='',
    [string]$NativeInputFixture='',
    [int]$Width=1080,
    [int]$Height=800,
    [int]$Fps=60,
    [string]$Title='APL Tetris / arrays in motion'
)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$executable=Join-Path $project '.runtime\bin\array-host.exe'
if(!(Test-Path -LiteralPath $executable)) { throw 'Run tools\setup.ps1 to prepare the local runtime.' }
if(!$Script) {
    $Script=@('apl\core.apl','apl\inspect.apl')
    if($Demo) { $Script+= 'apl\demo.apl' }
    $Script+= 'apl\game.apl'
}
$arguments=@('--width',"$Width",'--height',"$Height",'--fps',"$Fps",'--title',$Title)
if($Frames -gt 0) { $arguments+=@('--frames',"$Frames") }
if($FixedDt -gt 0) { $arguments+=@('--fixed-dt',$FixedDt.ToString('R',[Globalization.CultureInfo]::InvariantCulture)) }
if($SnapshotFrame -gt 0) { $arguments+=@('--snapshot-frame',"$SnapshotFrame") }
if($Screenshot) {
    if(![IO.Path]::IsPathRooted($Screenshot)) { $Screenshot=Join-Path $project $Screenshot }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Screenshot) | Out-Null
    $arguments+=@('--screenshot',$Screenshot)
}
if($InputFixture) {
    if($NativeInputFixture) { throw 'Choose synthetic input or self-window native input, not both.' }
    if(![IO.Path]::IsPathRooted($InputFixture)) { $InputFixture=Join-Path $project $InputFixture }
    $arguments+=@('--input',(Resolve-Path -LiteralPath $InputFixture).Path)
}
if($NativeInputFixture) {
    if(![IO.Path]::IsPathRooted($NativeInputFixture)) { $NativeInputFixture=Join-Path $project $NativeInputFixture }
    $arguments+=@('--native-input',(Resolve-Path -LiteralPath $NativeInputFixture).Path)
}
foreach($file in $Script) {
    if(![IO.Path]::IsPathRooted($file)) { $file=Join-Path $project $file }
    $arguments+=(Resolve-Path -LiteralPath $file).Path
}
& $executable @arguments
if($LASTEXITCODE -ne 0) { throw "APL / raylib run failed (exit $LASTEXITCODE)." }
