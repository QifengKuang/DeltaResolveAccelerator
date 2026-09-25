#requires -Version 7.0
<# Build the complete first-party application from a frozen allowlisted source
   snapshot. Does not read installed apps, start the SDK, or publish an update. #>
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Application bundle builds require Windows.' }
$repository=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\','/')
$dist=Join-Path $repository 'dist'

function Assert-PhysicalPath([string]$Path) {
    for ($item=[IO.Path]::GetFullPath($Path); $item; $item=[IO.Path]::GetDirectoryName($item)) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Bundle paths must not cross reparse points.'
        }
    }
}
function Get-BundleHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-NoEmbeddedPrivateKey([string]$Path) {
    $text=[IO.File]::ReadAllText($Path)
    if ($text -match '-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----' -or
        $text -match '(?s)<RSAKeyValue>.*?<(?:D|P|Q|DP|DQ|InverseQ)>' -or
        $text -match '(?i)\b(?:AKIA|ASIA)[A-Z0-9]{16}\b') {
        throw ('Embedded private key or credential detected in allowlisted input: '+[IO.Path]::GetFileName($Path))
    }
}

# Never discover payload files with a recursive copy or a wildcard. New backend
# modules must be reviewed and added here and in Test-ApplicationBundle.ps1.
$backendNames=@(
    'Check-Configuration.ps1','Control-Accelerator.ps1','Mna-GameRoute.ps1',
    'Mna-RebootRecovery.ps1','Mna-ReleasedResources.ps1','Mna-RouterAdvertisementRecovery.ps1',
    'Mna-SessionRecovery.ps1','Mna-UI.Common.ps1','Run-Accelerator.ps1',
    'Test-UdpStun.ps1','Trial-NetworkState.ps1','Trial-RouteOrigin.ps1'
)
$compileInputs=@(
    'build/Compile-App.ps1','build/Compile-Launcher.ps1','build/New-AppAssets.ps1',
    'src/AcceleratorApp.cs','src/GameDiscovery.cs','src/Launcher.cs',
    'src/UpdateManager.cs','src/UpdatePublicKey.cs','src/AssemblyInfo.cs',
    'src/Accelerator.exe.config','src/app.manifest','src/launcher.manifest'
)
$supportFiles=@('build/Prepare-Dependencies.ps1','docs/BUILD.md','docs/DEPENDENCIES.md','LICENSE')
$backendFiles=@($backendNames | ForEach-Object { 'app/backend/'+$_ })
$inputs=@($compileInputs+$backendFiles+$supportFiles+'build/Build-ApplicationBundle.ps1' | Sort-Object -Unique)
Assert-PhysicalPath $repository
$gitRoot=& git -C $repository rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath([string]$gitRoot).TrimEnd('\','/') -ine $repository) { throw 'Build from the Git checkout root so source revision can be recorded.' }
$revision=[string](& git -C $repository rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[a-f0-9]{40,64}$') { throw 'Cannot identify the source Git revision.' }
$gitState=@(& git -C $repository status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Git source status.' }
$dirty=$gitState.Count -ne 0
$assemblyPath=Join-Path $repository 'src/AssemblyInfo.cs'
Assert-PhysicalPath $assemblyPath
$versionMatch=[regex]::Match([IO.File]::ReadAllText($assemblyPath),'AssemblyFileVersion\("(\d+\.\d+\.\d+)\.0"\)')
if (-not $versionMatch.Success) { throw 'AssemblyInfo must declare a three-component application version plus .0.' }
$version=$versionMatch.Groups[1].Value
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $dist ('application-'+$version+'-'+[guid]::NewGuid().ToString('N')) }
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if (-not $output.StartsWith($dist+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory must be a new directory below this checkout dist directory.' }
Assert-PhysicalPath $output
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory already exists; select a new directory to prevent mixed builds.' }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not [IO.File]::Exists($compiler)) { throw '.NET Framework C# compiler missing.' }
foreach ($name in $inputs) {
    $path=Join-Path $repository $name
    Assert-PhysicalPath $path
    if (-not [IO.File]::Exists($path)) { throw ('Required source missing: '+$name) }
    Assert-NoEmbeddedPrivateKey $path
}

$null=[IO.Directory]::CreateDirectory($dist)
$stage=Join-Path $dist ('.bundle-work-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $stage
$payload=Join-Path $stage 'payload'
$snapshot=Join-Path $stage 'source'
try {
    $sourceFiles=@(foreach ($name in $inputs) {
        $source=Join-Path $repository $name
        $target=Join-Path $snapshot $name
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        $before=Get-BundleHash $source
        [IO.File]::Copy($source,$target,$false)
        $after=Get-BundleHash $target
        if ($before -cne $after -or $before -cne (Get-BundleHash $source)) { throw ('Source changed during snapshot: '+$name) }
        Assert-NoEmbeddedPrivateKey $target
        [ordered]@{name=$name;sha256=$after;size=(Get-Item -LiteralPath $target).Length}
    })
    # Compiler entry points resolve paths against this isolated tree. They never
    # replace this checkout's app/*.exe or an installed/running application.
    $null=[IO.Directory]::CreateDirectory((Join-Path $snapshot 'app'))
    & (Join-Path $snapshot 'build/Compile-App.ps1') | Out-Null
    & (Join-Path $snapshot 'build/Compile-Launcher.ps1') | Out-Null
    foreach ($name in @('Accelerator.exe','DeltaLauncher.exe')) {
        if ([version](Get-Item -LiteralPath (Join-Path $snapshot ('app/'+$name))).VersionInfo.FileVersion -ne [version]($version+'.0')) {
            throw ('Compiled executable version does not match source: '+$name)
        }
    }
    $payloadNames=@(@('app/Accelerator.exe','app/Accelerator.exe.config','app/DeltaLauncher.exe','app/DeltaResolve.ico')+$backendFiles+$supportFiles | Sort-Object)
    $files=@(foreach ($name in $payloadNames) {
        $source=Join-Path $snapshot $name
        $target=Join-Path $payload $name
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($source,$target,$false)
        [ordered]@{name=$name;sha256=(Get-BundleHash $target);size=(Get-Item -LiteralPath $target).Length}
    })
    $manifest=[ordered]@{
        schemaVersion=1;kind='complete-first-party-application';version=$version;platform='win-x64'
        source=[ordered]@{gitRevision=$revision;workingTreeDirty=$dirty;inputs=$sourceFiles}
        compiler=[ordered]@{name='Microsoft .NET Framework C#';fileVersion=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion;sha256=(Get-BundleHash $compiler)}
        dependencies=[ordered]@{bundled=$false;powerShell='7.6.6 Windows x64';mnaSdk='0.23.1_e012851';instructions='docs/DEPENDENCIES.md'}
        files=$files
    }
    [IO.File]::WriteAllText((Join-Path $payload 'application-manifest.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    # Fail a concurrent edit instead of labeling a mixed source snapshot as a
    # successful build. Provenance includes hashes of uncommitted changes.
    foreach ($file in $sourceFiles) {
        if ((Get-BundleHash (Join-Path $repository $file.name)) -cne $file.sha256) { throw ('Source changed while building; rebuild: '+$file.name) }
    }
    $currentRevision=[string](& git -C $repository rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $currentRevision -cne $revision) { throw 'Git revision changed while building; rebuild.' }
    # Atomic directory rename exposes a complete bundle only after all checks.
    Assert-PhysicalPath $output
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
    [IO.Directory]::Move($payload,$output)
} finally {
    # Only delete the fresh private staging tree, after checking its resolved
    # boundary and every descendant for links. Never delete an output/input.
    $resolved=[IO.Path]::GetFullPath($stage)
    if (-not $resolved.StartsWith($dist+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Staging cleanup escaped dist.' }
    Assert-PhysicalPath $resolved
    if (Test-Path -LiteralPath $resolved) {
        $items=@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Staging cleanup rejected a reparse point.' }
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) { Remove-Item -LiteralPath $file.FullName -Force }
        foreach ($directory in @($items | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending)) { Remove-Item -LiteralPath $directory.FullName -Force }
        Remove-Item -LiteralPath $resolved -Force
    }
}
[pscustomobject]@{Succeeded=$true;Version=$version;Directory=$output;AppDirectory=(Join-Path $output 'app');Manifest=(Join-Path $output 'application-manifest.json');FileCount=$files.Count;BackendIncluded=$true;DependenciesIncluded=$false;NetworkUsed=$false}
