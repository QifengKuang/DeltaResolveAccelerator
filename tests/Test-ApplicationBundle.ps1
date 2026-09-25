#requires -Version 7.0
<# File-only checks: real C# compilation is permitted; application/SDK launch,
   network access, installed files, and real credentials are never used. #>
[CmdletBinding()]
param([string]$BundleDirectory)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Application bundle tests require Windows.' }
$repository=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$checks=[Collections.Generic.List[string]]::new()
function Start-Process { throw 'Bundle tests must not launch applications.' }
function Invoke-RestMethod { throw 'Bundle tests must not access the network.' }
function Invoke-WebRequest { throw 'Bundle tests must not access the network.' }
function Check([string]$Name,[bool]$Condition) { if (-not $Condition) { throw ('FAIL: '+$Name) }; $checks.Add($Name) }
function Must-Reject([string]$Name,[scriptblock]$Action,[string]$Pattern) {
    $message=$null
    try { $null=& $Action } catch { $message=$_.Exception.Message }
    Check $Name ($null -ne $message -and $message -match $Pattern)
}
function Put([string]$Path,[string]$Text) {
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$backendNames=@(
    'Check-Configuration.ps1','Control-Accelerator.ps1','Mna-GameRoute.ps1',
    'Mna-RebootRecovery.ps1','Mna-ReleasedResources.ps1','Mna-RouterAdvertisementRecovery.ps1',
    'Mna-SessionRecovery.ps1','Mna-UI.Common.ps1','Run-Accelerator.ps1',
    'Test-UdpStun.ps1','Trial-NetworkState.ps1','Trial-RouteOrigin.ps1'
)
$backendFiles=@($backendNames | ForEach-Object { 'app/backend/'+$_ })
$support=@('build/Prepare-Dependencies.ps1','docs/BUILD.md','docs/DEPENDENCIES.md','LICENSE')
$required=@(@('app/Accelerator.exe','app/Accelerator.exe.config','app/DeltaLauncher.exe','app/DeltaResolve.ico')+$backendFiles+$support | Sort-Object)
$sourceRequired=@(@(
    'build/Build-ApplicationBundle.ps1','build/Compile-App.ps1','build/Compile-Launcher.ps1','build/New-AppAssets.ps1',
    'src/AcceleratorApp.cs','src/GameDiscovery.cs','src/Launcher.cs','src/UpdateManager.cs','src/UpdatePublicKey.cs',
    'src/AssemblyInfo.cs','src/Accelerator.exe.config','src/app.manifest','src/launcher.manifest'
)+$backendFiles+$support | Sort-Object)

function Assert-Bundle([string]$Directory) {
    $root=[IO.Path]::GetFullPath($Directory).TrimEnd('\','/')
    for ($parent=$root; $parent; $parent=[IO.Path]::GetDirectoryName($parent)) {
        if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Bundle has a reparse point.' }
    }
    # Walk one level at a time: reject links before enumerating their children.
    $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($root)
    $actual=[Collections.Generic.List[string]]::new()
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Bundle has a reparse point.' }
            $relative=[IO.Path]::GetRelativePath($root,$item.FullName).Replace('\','/')
            if ($item.PSIsContainer) {
                if ($relative -notin @('app','app/backend','build','docs')) { throw ('Unexpected bundle directory: '+$relative) }
                $pending.Enqueue($item.FullName)
            } else { $actual.Add($relative) }
        }
    }
    if ((($actual | Sort-Object) -join "`n") -cne ((@($required+'application-manifest.json') | Sort-Object) -join "`n")) { throw 'Bundle file allowlist mismatch.' }
    $manifest=Get-Content -LiteralPath (Join-Path $root 'application-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.kind -cne 'complete-first-party-application' -or $manifest.platform -cne 'win-x64') { throw 'Invalid bundle manifest kind or platform.' }
    if ($manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.source.gitRevision -notmatch '^[a-f0-9]{40,64}$' -or $manifest.source.workingTreeDirty -isnot [bool]) { throw 'Invalid bundle source provenance.' }
    if ($manifest.compiler.sha256 -notmatch '^[a-f0-9]{64}$' -or -not $manifest.compiler.fileVersion -or $manifest.dependencies.bundled -cne $false) { throw 'Invalid compiler or dependency metadata.' }
    if ((@($manifest.files.name | Sort-Object) -join "`n") -cne ($required -join "`n")) { throw 'Manifest file allowlist mismatch.' }
    if ((@($manifest.source.inputs.name | Sort-Object) -join "`n") -cne ($sourceRequired -join "`n")) { throw 'Manifest source allowlist mismatch.' }
    foreach ($inputFile in $manifest.source.inputs) {
        if ($inputFile.sha256 -notmatch '^[a-f0-9]{64}$' -or $inputFile.size -le 0) { throw 'Invalid source input hash or size.' }
    }
    foreach ($name in @($backendFiles+$support)) {
        $source=@($manifest.source.inputs | Where-Object name -CEQ $name)[0]
        $payload=@($manifest.files | Where-Object name -CEQ $name)[0]
        if ($source.sha256 -cne $payload.sha256 -or $source.size -ne $payload.size) { throw ('Payload differs from recorded source: '+$name) }
    }
    $configSource=@($manifest.source.inputs | Where-Object name -CEQ 'src/Accelerator.exe.config')[0]
    $configPayload=@($manifest.files | Where-Object name -CEQ 'app/Accelerator.exe.config')[0]
    if ($configSource.sha256 -cne $configPayload.sha256 -or $configSource.size -ne $configPayload.size) { throw 'Payload differs from recorded source configuration.' }
    foreach ($file in $manifest.files) {
        $path=Join-Path $root $file.name
        if ($file.sha256 -notmatch '^[a-f0-9]{64}$' -or (Sha $path) -cne $file.sha256 -or (Get-Item -LiteralPath $path).Length -ne $file.size) { throw ('Payload hash or size mismatch: '+$file.name) }
        if ($file.name.EndsWith('.ps1')) {
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            if (@($errors).Count) { throw ('Backend/script syntax error: '+$file.name) }
            # A newly introduced local backend dependency must also be shipped.
            foreach ($match in [regex]::Matches($ast.Extent.Text,'Join-Path\s+\$PSScriptRoot\s+[''"]([^''"]+\.ps1)[''"]')) {
                if ($file.name.StartsWith('app/backend/') -and $match.Groups[1].Value -notin $backendNames) { throw ('Missing local backend dependency: '+$match.Groups[1].Value) }
            }
        }
        if ($file.name -notmatch '\.(exe|ico)$') {
            $text=[IO.File]::ReadAllText($path)
            if ($text -match '-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----' -or $text -match '(?s)<RSAKeyValue>.*?<(?:D|P|Q|DP|DQ|InverseQ)>') { throw 'Payload contains private key material.' }
        }
    }
    foreach ($name in @('Accelerator.exe','DeltaLauncher.exe')) {
        if ([version](Get-Item -LiteralPath (Join-Path $root ('app/'+$name))).VersionInfo.FileVersion -ne [version]($manifest.version+'.0')) { throw 'Executable version mismatch.' }
    }
    return $manifest
}

if (-not $BundleDirectory) {
    $build=& (Join-Path $repository 'build/Build-ApplicationBundle.ps1')
    Check 'RealCompileSucceeded' ($build.Succeeded -and $build.BackendIncluded -and -not $build.DependenciesIncluded -and -not $build.NetworkUsed)
    $BundleDirectory=$build.Directory
}
$manifest=Assert-Bundle $BundleDirectory
Check 'CompleteBundleHashesVersionsAndBackendDependencies' $true
Check 'AllTwelveBackendModulesIncluded' (@($manifest.files | Where-Object name -like 'app/backend/*').Count -eq 12)
Check 'NoRuntimeSdkPersonalSettingsOrPrivateFilesInPayload' $true
Check 'SourceHashesIncludeBuildRecipeAndAllBackendModules' $true

# Mutations occur only in this fresh test directory; the supplied bundle and
# current app directory remain untouched, including existing local credentials.
$test=Join-Path $PSScriptRoot ('output/application-bundle/'+[guid]::NewGuid().ToString('N'))
$copy=Join-Path $test 'mutated'
foreach ($name in @($required+'application-manifest.json')) {
    $target=Join-Path $copy $name
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy((Join-Path $BundleDirectory $name),$target,$false)
}
$module=Join-Path $copy 'app/backend/Mna-ReleasedResources.ps1'
$original=[IO.File]::ReadAllBytes($module)
Put $module '# corrupted backend'
Must-Reject 'TamperedBackendRejected' { Assert-Bundle $copy } 'hash or size mismatch'
[IO.File]::WriteAllBytes($module,$original)
[IO.File]::Delete($module)
Must-Reject 'MissingRecoveryBackendRejected' { Assert-Bundle $copy } 'file allowlist mismatch'
[IO.File]::WriteAllBytes($module,$original)
foreach ($name in @('app/backend/private/device-key.dpapi.bin','app/backend/results/ui-status.json','app/runtime/pwsh.exe','app/backend/vendor_inspection/secret.txt','app/user-settings.json')) {
    $sentinel=Join-Path $copy $name
    Put $sentinel 'synthetic sentinel, never a real key'
    Must-Reject ('UnexpectedPrivateOrRuntimeFileRejected '+$name) { Assert-Bundle $copy } 'Unexpected bundle directory|file allowlist mismatch'
    [IO.File]::Delete($sentinel)
    for ($directory=[IO.Path]::GetDirectoryName($sentinel); $directory -and $directory -notin @((Join-Path $copy 'app'),(Join-Path $copy 'app/backend')); $directory=[IO.Path]::GetDirectoryName($directory)) {
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { [IO.Directory]::Delete($directory,$false) } else { break }
    }
}
$manifestPath=Join-Path $copy 'application-manifest.json'
$manifestBytes=[IO.File]::ReadAllBytes($manifestPath)
foreach ($kind in @('Traversal','Duplicate','OmittedBackend','WrongVersion')) {
    $changed=[Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    switch ($kind) {
        'Traversal' {$changed.files[0].name='../private/device.dpapi'}
        'Duplicate' {$changed.files+=@($changed.files[0])}
        'OmittedBackend' {$changed.files=@($changed.files | Where-Object name -ne 'app/backend/Mna-ReleasedResources.ps1')}
        'WrongVersion' {$changed.version='99.99.99'}
    }
    Put $manifestPath ($changed | ConvertTo-Json -Depth 8)
    Must-Reject ('InvalidManifestRejected '+$kind) { Assert-Bundle $copy } 'allowlist mismatch|version mismatch'
}
[IO.File]::WriteAllBytes($manifestPath,$manifestBytes)

# Build a real isolated repository containing synthetic unwanted local files.
# Only the manifest's independently checked source allowlist is copied.
$fixture=Join-Path $test 'source-fixture'
foreach ($name in $sourceRequired) {
    $target=Join-Path $fixture $name
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy((Join-Path $repository $name),$target,$false)
}
& git -C $fixture init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Fixture Git initialization failed.' }
& git -C $fixture -c core.autocrlf=false -c core.safecrlf=false add -- .
if ($LASTEXITCODE -ne 0) { throw 'Fixture Git staging failed.' }
& git -C $fixture -c user.name=OfflineFixture -c user.email=offline@example.invalid -c commit.gpgsign=false -c core.hooksPath=disabled-fixture-hooks commit --quiet -m 'Synthetic bundle source fixture'
if ($LASTEXITCODE -ne 0) { throw 'Fixture Git commit failed.' }
foreach ($name in @('app/backend/private/device-key.dpapi.bin','app/backend/results/ui-status.json','app/runtime/pwsh.exe','app/backend/vendor_inspection/linkboost/mp_client.json','app/user-settings.json','app/Unknown.exe')) {
    Put (Join-Path $fixture $name) 'DO-NOT-PACKAGE-SYNTHETIC-SECRET-SENTINEL'
}
$fixtureBuild=& (Join-Path $fixture 'build/Build-ApplicationBundle.ps1')
$fixtureManifest=Assert-Bundle $fixtureBuild.Directory
Check 'ContaminatedSourcePackagesOnlyAllowlistedOwnedFiles' ($fixtureBuild.Succeeded -and $fixtureManifest.source.workingTreeDirty)
foreach ($file in $fixtureManifest.files) {
    if ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $fixtureBuild.Directory $file.name))).Contains('DO-NOT-PACKAGE-SYNTHETIC-SECRET-SENTINEL')) { throw 'Synthetic secret leaked into payload.' }
}
Check 'SyntheticSecretBytesAbsentFromEveryPayloadFile' $true
Must-Reject 'ExistingOutputRejected' { & (Join-Path $fixture 'build/Build-ApplicationBundle.ps1') -OutputDirectory $fixtureBuild.Directory } 'already exists'
Must-Reject 'OutsideDistOutputRejected' { & (Join-Path $fixture 'build/Build-ApplicationBundle.ps1') -OutputDirectory (Join-Path $fixture 'app/replacement') } 'below this checkout dist'
$missing=Join-Path $fixture 'app/backend/Mna-ReleasedResources.ps1'
[IO.File]::Delete($missing)
Must-Reject 'MissingRequiredSourceStopsBuild' { & (Join-Path $fixture 'build/Build-ApplicationBundle.ps1') } 'Required source missing'
[IO.File]::Copy((Join-Path $repository 'app/backend/Mna-ReleasedResources.ps1'),$missing,$false)
Put (Join-Path $fixture 'src/UpdatePublicKey.cs') ('// '+'-----BEGIN RSA '+'PRIVATE KEY-----')
Must-Reject 'EmbeddedPrivateKeyStopsBuild' { & (Join-Path $fixture 'build/Build-ApplicationBundle.ps1') } 'Embedded private key'
$report=[ordered]@{Passed=$true;CheckCount=$checks.Count;Checks=@($checks);BundleDirectory=[IO.Path]::GetFullPath($BundleDirectory);TestDirectory=$test;NetworkStarted=$false;SdkStarted=$false;InstalledFilesModified=$false;RealCredentialsRead=$false}
Put (Join-Path $test 'test-result.json') ($report | ConvertTo-Json -Depth 5)
$report | ConvertTo-Json -Depth 5
