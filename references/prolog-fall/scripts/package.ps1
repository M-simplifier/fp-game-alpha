# Private local bundle, including source and the prepared runtime. No upload.
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$dist=Join-Path $project 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zipPath=Join-Path $dist 'PrologTetris-Windows-x64.zip'
$tempPath=Join-Path $dist 'PrologTetris-Windows-x64.pending.zip'
if (!(Test-Path -LiteralPath "$project\.runtime\bin\prolog_raylib.dll")) { throw 'Build the native bridge first.' }
Add-Type -AssemblyName System.IO.Compression
$stream=[System.IO.File]::Open($tempPath,'Create','Write','None')
$zip=[System.IO.Compression.ZipArchive]::new($stream,[System.IO.Compression.ZipArchiveMode]::Create)
try {
    $files=Get-ChildItem -LiteralPath $project -File -Recurse -Force | Where-Object {
        $relative=$_.FullName.Substring($project.Length+1).Replace('\','/')
        if ($relative -match '^(\.git|\.scratch|dist)/') { return $false }
        if ($relative -notmatch '^\.runtime/') { return $true }
        if ($relative -in @('.runtime/bin/prolog_raylib.dll','.runtime/bin/raylib.dll')) { return $true }
        if ($relative -match '^\.runtime/(swipl|raylib)/') {
            return $relative -notmatch '(\$PLUGINSDIR/|/Uninstall\.exe$)'
        }
        return $false
    }
    foreach ($file in $files) {
        $relative=$file.FullName.Substring($project.Length+1).Replace('\','/')
        $entry=$zip.CreateEntry("PrologTetris/$relative",[System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime=$file.LastWriteTime
        $sourceStream=[System.IO.File]::OpenRead($file.FullName)
        $entryStream=$entry.Open()
        try { $sourceStream.CopyTo($entryStream) } finally { $sourceStream.Dispose();$entryStream.Dispose() }
    }
} finally { $zip.Dispose();$stream.Dispose() }
Move-Item -LiteralPath $tempPath -Destination $zipPath -Force
$hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  PrologTetris-Windows-x64.zip" | Set-Content -LiteralPath (Join-Path $dist 'SHA256.txt') -Encoding ascii
Get-Item -LiteralPath $zipPath | Select-Object FullName,Length
Write-Host "SHA256 $hash"
