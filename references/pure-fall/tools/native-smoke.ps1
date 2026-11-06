[CmdletBinding()]
param(
    [string]$Executable,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\.runtime\os-input-smoke')
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Executable) {
    $Executable = (& cabal list-bin exe:pure-fall --offline --verbose=0 | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the built game executable.' }
}
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

if (-not ('PureFallSmoke.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PureFallSmoke {
  public static class Native {
    [StructLayout(LayoutKind.Sequential)] public struct Keyboard {
      public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Explicit, Size=32)] public struct InputData {
      [FieldOffset(0)] public Keyboard Keyboard;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Input {
      public uint Type; public InputData Data;
    }
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static void Key(ushort key, bool down) {
      uint extended = (key >= 0x21 && key <= 0x28) || key == 0x2D || key == 0x2E ? 1u : 0u;
      var item = new Input { Type=1, Data=new InputData { Keyboard=new Keyboard { Vk=key, Flags=(down ? 0u : 2u) | extended } } };
      if (SendInput(1, new Input[] { item }, Marshal.SizeOf<Input>()) != 1)
        throw new InvalidOperationException("Windows SendInput failed: " + Marshal.GetLastWin32Error());
    }
  }
}
'@
}

$script:keyEvents = 0
function Send-Key([ushort]$Key, [int]$Milliseconds = 90) {
    [PureFallSmoke.Native]::Key($Key, $true)
    $script:keyEvents++
    try { Start-Sleep -Milliseconds $Milliseconds }
    finally { [PureFallSmoke.Native]::Key($Key, $false); $script:keyEvents++ }
    Start-Sleep -Milliseconds 110
}

function Start-Game([string]$Name, [string]$Arguments) {
    $target = Join-Path $OutputDirectory $Name
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $argumentText = $Arguments + ' --data-dir "' + (Join-Path $target 'user-data') + '" --shots "' + $target + '"'
    $gameProcess = Start-Process -FilePath $Executable -ArgumentList $argumentText -WorkingDirectory $env:TEMP `
        -RedirectStandardOutput (Join-Path $target 'stdout.log') -RedirectStandardError (Join-Path $target 'stderr.log') -PassThru
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 100
        $gameProcess.Refresh()
    } while (-not $gameProcess.HasExited -and $gameProcess.MainWindowHandle -eq 0 -and $timer.Elapsed.TotalSeconds -lt 15)
    if ($gameProcess.HasExited -or $gameProcess.MainWindowHandle -eq 0) { throw 'The native game window did not open.' }
    [void][PureFallSmoke.Native]::SetForegroundWindow($gameProcess.MainWindowHandle)
    Start-Sleep -Milliseconds 50
    if ([PureFallSmoke.Native]::GetForegroundWindow() -ne $gameProcess.MainWindowHandle) {
        [PureFallSmoke.Native]::Key(0x12,$true)
        [void][PureFallSmoke.Native]::SetForegroundWindow($gameProcess.MainWindowHandle)
        [PureFallSmoke.Native]::Key(0x12,$false)
        Start-Sleep -Milliseconds 50
    }
    if ([PureFallSmoke.Native]::GetForegroundWindow() -ne $gameProcess.MainWindowHandle) {
        Stop-Process -Id $gameProcess.Id
        throw 'The game did not receive foreground focus; OS input evidence cannot be claimed.'
    }
    return $gameProcess
}

function Finish-Game([Diagnostics.Process]$GameProcess, [string]$Name) {
    if (-not $GameProcess.WaitForExit(30000)) {
        Stop-Process -Id $GameProcess.Id
        throw 'The bounded native game did not exit.'
    }
    $GameProcess.Refresh()
    if ($GameProcess.ExitCode -ne 0) { throw "Game exited with code $($GameProcess.ExitCode)." }
    $report = Join-Path (Join-Path $OutputDirectory $Name) 'native-report.txt'
    if (-not (Test-Path -LiteralPath $report)) { throw 'The game did not write a native report.' }
    return Get-Content -LiteralPath $report -Raw
}

$game = $null
try {
    $game = Start-Game 'practice' '--mode Practice --seed 90210 --frames 1800'
    Send-Key 0x25 450 # Left, through the actual Windows key-state polling path.
    Send-Key 0x27 450
    Send-Key 0x58
    Send-Key 0x20
    Send-Key 0x43
    Send-Key 0x28 300
    Send-Key 0x20
    Send-Key 0x74 # F5 save.
    Send-Key 0x20
    Send-Key 0x78 # F9 restore.
    Send-Key 0x51 # Q study.
    Send-Key 0x22 # Page Down.
    Send-Key 0x0D # Enter: play the returned witness.
    Start-Sleep -Milliseconds 1100
    Send-Key 0x08 # Rewind the piece.
    Send-Key 0x50 # Pause.
    Send-Key 0x54 # Title.
    Send-Key 0x4F # Settings.
    Send-Key 0x27 # Increase volume and persist.
    Send-Key 0x4F
    Send-Key 0x70 # F1 controls.
    Send-Key 0x1B
    $practice = Finish-Game $game 'practice'
    if ($practice -notmatch 'source=native-os-polling' -or $practice -notmatch 'os_command_edges=([1-9][0-9]*)') {
        throw 'No real OS command edges reached the production input reader.'
    }
    if ($practice -notmatch 'os_held_frames=([1-9][0-9]*)') { throw 'Held key input was not observed.' }
    $game = Start-Game 'finish' '--fixture NearSprint --frames 420'
    Send-Key 0x20 250
    $finish = Finish-Game $game 'finish'
    if ($finish -notmatch 'phase=Won') { throw 'The real Space key did not complete the Sprint fixture.' }
    if ($finish -notmatch 'semantic_ticks=([0-9]+)' -or [int]$Matches[1] -ge 30) {
        throw 'The finishing input did not beat the fixture lock deadline; Space cannot be claimed as the cause.'
    }
    $summary = "Windows SendInput events=$script:keyEvents`nThe game reported native-os-polling input, held frames, and Won before the fixture auto-lock deadline of 30 semantic ticks.`n`n$practice`n$finish"
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'verification.txt') -Value $summary -Encoding utf8
    Write-Output $summary
}
finally {
    foreach ($key in @(0x25,0x27,0x28,0x20,0x58,0x43,0x50)) { [PureFallSmoke.Native]::Key([ushort]$key,$false) }
    if ($game -and -not $game.HasExited) { Stop-Process -Id $game.Id }
}
