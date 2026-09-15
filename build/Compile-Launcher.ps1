[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework C# compiler missing' }
if (-not (Test-Path -LiteralPath (Join-Path $root 'src/UpdatePublicKey.cs'))) { throw 'Update public key source missing' }
& (Join-Path $PSScriptRoot 'New-AppAssets.ps1') | Out-Null
$out = Join-Path $root 'app/DeltaLauncher.exe'
$argsList = @('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',('/out:'+$out),
    ('/win32icon:'+(Join-Path $root 'src/app.ico')),('/win32manifest:'+(Join-Path $root 'src/launcher.manifest')),
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll','/reference:System.Security.dll','/reference:System.IO.Compression.dll')
foreach ($source in @('Launcher.cs','UpdateManager.cs','UpdatePublicKey.cs','AssemblyInfo.cs')) { $argsList += Join-Path $root ('src/'+$source) }
& $compiler @argsList
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed' }
Copy-Item -LiteralPath (Join-Path $root 'src/app.ico') -Destination (Join-Path $root 'app/DeltaResolve.ico') -Force
Get-Item -LiteralPath $out | Select-Object Name,Length
