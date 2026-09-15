[CmdletBinding()]
param([switch]$PreviewBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework C# compiler missing' }
& (Join-Path $PSScriptRoot 'New-AppAssets.ps1') | Out-Null
$out = if ($PreviewBuild) { Join-Path $root 'build/AcceleratorPreview.exe' } else { Join-Path $root 'app/Accelerator.exe' }
$argsList = @('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',('/out:'+$out),('/win32icon:'+(Join-Path $root 'src/app.ico')),
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll','/reference:System.Security.dll',
    '/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll','/reference:System.Management.dll')
# Keep preview and production DPI behavior identical while previews remain unelevated.
$manifest = if ($PreviewBuild) { 'src/preview.manifest' } else { 'src/app.manifest' }
$argsList += '/win32manifest:'+(Join-Path $root $manifest)
$argsList += Join-Path $root 'src/AcceleratorApp.cs'
$argsList += Join-Path $root 'src/GameDiscovery.cs'
$argsList += Join-Path $root 'src/UpdateManager.cs'
$argsList += Join-Path $root 'src/UpdatePublicKey.cs'
$argsList += Join-Path $root 'src/AssemblyInfo.cs'
& $compiler @argsList
if ($LASTEXITCODE -ne 0) { throw 'App compilation failed' }
Copy-Item -LiteralPath (Join-Path $root 'src/Accelerator.exe.config') -Destination ($out+'.config') -Force
if (-not $PreviewBuild) {
    Copy-Item -LiteralPath (Join-Path $root 'src/app.ico') -Destination (Join-Path $root 'app/DeltaResolve.ico') -Force
}
Get-Item -LiteralPath $out | Select-Object Name,Length
