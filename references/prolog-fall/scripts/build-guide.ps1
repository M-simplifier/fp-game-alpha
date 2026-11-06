$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$python=Get-Command python.exe -ErrorAction SilentlyContinue
if (!$python) { throw 'Python 3 is required to assemble the standalone HTML. The finished HTML opens without Python or Prolog.' }
& $python.Source (Join-Path $PSScriptRoot 'build-guide.py')
if ($LASTEXITCODE -ne 0) { throw 'Guide export or build failed.' }
