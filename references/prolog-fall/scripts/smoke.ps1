# Native window + application command-dispatch test. No desktop key injection.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$evidence=Join-Path $project '.scratch\smoke'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$report=Join-Path $evidence 'replay.json'
$screenshot=Join-Path $evidence 'replay.png'
& (Join-Path $PSScriptRoot 'run.ps1') --demo --query --autoplay --seed 42 --smoke 160 --screenshot $screenshot --report $report
$result=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
if ($result.ui_events.queries -ne 1 -or $result.ui_events.filters -ne 1 -or
    $result.ui_events.cycles -ne 2 -or $result.ui_events.selection_changes -ne 2 -or
    $result.ui_events.replay_moves -ne 19 -or
    $result.ui_events.replays_started -ne 1 -or $result.ui_events.replays_completed -ne 1 -or
    $result.lines -lt 1 -or $result.mode -ne 'play' -or $result.status -ne 'playing') {
    throw 'Query/replay application smoke did not reach the expected result.'
}
if (!(Test-Path -LiteralPath $screenshot) -or (Get-Item -LiteralPath $screenshot).Length -lt 1000) {
    throw 'Native screenshot was not produced.'
}
Write-Host "Native application smoke passed. Evidence: $evidence"
