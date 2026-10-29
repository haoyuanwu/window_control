$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$releasePath = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$archivePath = Join-Path $projectRoot 'build\WindowControl-Windows-x64.zip'
$outputPath = Join-Path $projectRoot 'build\WindowControl.exe'
$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
Compress-Archive -Path (Join-Path $releasePath '*') -DestinationPath $archivePath -Force
& $compilerPath /nologo /target:winexe /platform:x64 /optimize+ /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Windows.Forms.dll "/resource:$archivePath,payload.zip" "/win32manifest:$PSScriptRoot\launcher.manifest" "/out:$outputPath" (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
Get-Item $outputPath
