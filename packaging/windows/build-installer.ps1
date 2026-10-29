param([switch]$SkipBuild, [string]$IsccPath, [string]$RedistPath)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Push-Location $projectRoot
try {
  if (-not $SkipBuild) {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
  }
  $versionMatch = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)')
  if (-not $versionMatch.Success) { throw 'Cannot read app version.' }
  $appVersion = $versionMatch.Groups[1].Value
  if (-not $IsccPath) {
    $IsccPath = @('C:\Program Files\Inno Setup 7\ISCC.exe', 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  }
  if (-not $IsccPath) { throw 'Install Inno Setup 6.3+ or pass -IsccPath.' }
  if (-not $RedistPath) {
    $vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswherePath)) { throw 'Pass -RedistPath pointing to the official x64 Microsoft.VC*.CRT directory.' }
    $visualStudioPath = & $vswherePath -latest -property installationPath
    $RedistPath = Get-ChildItem -LiteralPath (Join-Path $visualStudioPath 'VC\Redist\MSVC') -Directory | Where-Object Name -Match '^\d' | Sort-Object Name -Descending | ForEach-Object {
      Get-ChildItem -Path (Join-Path $_.FullName 'x64\Microsoft.VC*.CRT') -Directory -ErrorAction SilentlyContinue
    } | Select-Object -First 1 -ExpandProperty FullName
  }
  if (-not $RedistPath -or -not (Test-Path -LiteralPath (Join-Path $RedistPath 'msvcp140.dll'))) { throw 'Official Visual C++ x64 runtime files were not found.' }
  $redistOutput = Join-Path $projectRoot 'build\redist'
  New-Item -ItemType Directory -Path $redistOutput -Force | Out-Null
  Copy-Item -Path (Join-Path $RedistPath '*.dll') -Destination $redistOutput -Force
  # App-local CRT is also included in the portable distribution.
  Copy-Item -Path (Join-Path $RedistPath '*.dll') -Destination (Join-Path $projectRoot 'build\windows\x64\runner\Release') -Force
  & $IsccPath "/DAppVersion=$appVersion" (Join-Path $PSScriptRoot 'installer.iss')
  if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
  Get-Item (Join-Path $projectRoot "build\releases\WindowControl-Setup-$appVersion-Windows-x64.exe")
} finally { Pop-Location }
