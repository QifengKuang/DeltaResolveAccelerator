#requires -Version 7.0
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath=Join-Path $root 'dist/DeltaResolveSetup-1.1.0.exe' }
$output=[IO.Path]::GetFullPath($OutputPath)
$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
$manifest=[ordered]@{}
$payload=[ordered]@{
    'Accelerator.exe'=(Join-Path $root 'app/Accelerator.exe')
    'Accelerator.exe.config'=(Join-Path $root 'app/Accelerator.exe.config')
    'DeltaLauncher.exe'=(Join-Path $root 'app/DeltaLauncher.exe')
    'DeltaResolve.ico'=(Join-Path $root 'app/DeltaResolve.ico')
    'Install-App.ps1'=(Join-Path $root 'build/Install-App.ps1')
}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$arguments=@('/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',('/out:'+$output),('/win32icon:'+(Join-Path $root 'src/app.ico')),('/win32manifest:'+(Join-Path $root 'src/preview.manifest')),
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll')
foreach ($name in $payload.Keys) {
    $manifest[$name]=(Get-FileHash -LiteralPath $payload[$name] -Algorithm SHA256).Hash
    $arguments+='/resource:'+$payload[$name]+',payload.'+$name
}
$manifestPath=Join-Path ([IO.Path]::GetDirectoryName($output)) 'setup-payload-manifest.json'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$arguments+='/resource:'+$manifestPath+',payload.manifest'
$arguments+=Join-Path $root 'src/Setup.cs'
$arguments+=Join-Path $root 'src/AssemblyInfo.cs'
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Setup compilation failed.' }
Get-Item -LiteralPath $output | Select-Object FullName,Length
