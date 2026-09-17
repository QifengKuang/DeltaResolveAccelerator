#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Installation tests require Windows.' }
$repository=Split-Path $PSScriptRoot -Parent
$installer=Join-Path $repository 'build/Install-App.ps1'
$testBase=Join-Path $env:USERPROFILE 'Documents/DeltaResolveAcceleratorInstallTests'
$test=Join-Path $testBase ([guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($test)
$source=Join-Path $test 'Source'
$installed=Join-Path $test 'Installed'
$null=[IO.Directory]::CreateDirectory($source)
$null=[IO.Directory]::CreateDirectory($installed)
$checks=[Collections.Generic.List[string]]::new()
function Check([string]$Name,[bool]$Condition) { if (-not $Condition) { throw ('FAIL: '+$Name) }; $checks.Add($Name) }
function Must-Reject([string]$Name,[scriptblock]$Action,[string]$Pattern) {
    $message=$null
    try { $null=& $Action } catch { $message=$_.Exception.Message }
    Check $Name ($message -and $message -match $Pattern)
}
function Put([string]$Path,[string]$Text) {
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$fixtureSource=Join-Path $test 'Fixture.cs'
Put $fixtureSource 'using System.Reflection; [assembly: AssemblyFileVersion("1.1.0.0")] [assembly: AssemblyVersion("1.1.0.0")] class Fixture { static void Main() { System.Threading.Thread.Sleep(120000); } }'
& $compiler /nologo /target:winexe /platform:x64 ('/out:'+(Join-Path $source 'Accelerator.exe')) $fixtureSource
if ($LASTEXITCODE -ne 0) { throw 'Test executable compilation failed.' }
[IO.File]::Copy((Join-Path $source 'Accelerator.exe'),(Join-Path $source 'DeltaLauncher.exe'))
Put (Join-Path $source 'Accelerator.exe.config') '<configuration />'
[IO.File]::Copy((Join-Path $repository 'src/app.ico'),(Join-Path $source 'DeltaResolve.ico'))
Put (Join-Path $source 'backend/Control-Accelerator.ps1') 'upstream backend must not replace local fixes'
Put (Join-Path $source 'private/never-copy.key') 'synthetic source secret'
Put (Join-Path $source 'user-settings.json') '{"synthetic":"do not copy"}'
Put (Join-Path $installed 'backend/Control-Accelerator.ps1') 'local backend fix sentinel'
Put (Join-Path $installed 'backend/results/ui-status.json') '{"phase":"stopped"}'
Put (Join-Path $installed 'backend/private/device.dpapi') 'synthetic installed credential'
Put (Join-Path $installed 'runtime/pwsh.exe') 'existing runtime sentinel'
Put (Join-Path $installed 'user-settings.json') '{"customGamePath":"synthetic sentinel"}'
$protected=@('backend/Control-Accelerator.ps1','backend/results/ui-status.json','backend/private/device.dpapi','runtime/pwsh.exe','user-settings.json')
$before=@{}; foreach ($name in $protected) { $before[$name]=Sha (Join-Path $installed $name) }
$first=& $installer -SourceDirectory $source -InstallDirectory $installed -TestRoot $test
Check 'InstallCompletes' $first.Succeeded
Check 'InstallPathPhysical' ($first.InstallPath -eq $first.PhysicalPath)
Check 'ExactlyFourOwnedFiles' (($first.FilesCopied | Sort-Object) -join ',' -eq 'Accelerator.exe,Accelerator.exe.config,DeltaLauncher.exe,DeltaResolve.ico')
foreach ($name in $protected) { Check ('Preserved '+$name) ((Sha (Join-Path $installed $name)) -eq $before[$name]) }
Check 'SourceSecretExcluded' (-not [IO.File]::Exists((Join-Path $installed 'private/never-copy.key')))
Check 'RegisteredPath' ((Get-Content -LiteralPath (Join-Path $test 'registry.json') -Raw | ConvertFrom-Json).InstallPath -eq $installed)
function Check-Links([string]$Root,[string]$Install) {
    foreach ($folder in @('Desktop','Programs')) {
        $path=Join-Path $Root ($folder+'/三角洲加速器.lnk')
        $shell=New-Object -ComObject WScript.Shell
        try {
            $link=$shell.CreateShortcut($path)
            try {
                Check ($folder+'StableTarget') ($link.TargetPath -ieq (Join-Path $Install 'DeltaLauncher.exe'))
                Check ($folder+'WorkingDirectory') ($link.WorkingDirectory -ieq $Install)
                Check ($folder+'IndependentIcon') ($link.IconLocation -ieq ((Join-Path $Install 'DeltaResolve.ico')+',0'))
                Check ($folder+'LaunchArgument') ($link.Arguments -eq '--launch')
            } finally { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        } finally { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        $flags=[BitConverter]::ToUInt32([IO.File]::ReadAllBytes($path),20)
        Check ($folder+'NoLinkTracking') (($flags -band 0x00140000) -eq 0x00140000)
        Check ($folder+'NotRunAs') (($flags -band 0x00002000) -eq 0)
    }
}
Check-Links $test $installed
$second=& $installer -SourceDirectory $source -TestRoot $test
Check 'RegisteredInstallReused' ($second.InstallPath -eq $installed)
Check 'SingleDesktopShortcut' (@(Get-ChildItem -LiteralPath (Join-Path $test 'Desktop') -Filter '*.lnk').Count -eq 1)
[IO.File]::WriteAllText((Join-Path $test 'Desktop/三角洲加速器.lnk'),'broken shortcut')
$repair=& $installer -RepairShortcuts -TestRoot $test
Check 'RepairHasNoPayload' ($repair.RepairOnly -and $repair.FilesCopied.Count -eq 0)
Check-Links $test $installed
$managed=@('DeltaLauncher.exe','Accelerator.exe','Accelerator.exe.config','DeltaResolve.ico')
$old=@{}; foreach ($name in $managed) { $old[$name]=Sha (Join-Path $installed $name) }
Put (Join-Path $source 'Accelerator.exe.config') '<configuration><!-- changed --></configuration>'
Must-Reject 'InjectedFailureReported' { & $installer -SourceDirectory $source -TestRoot $test -TestFailAfterCopy } 'Injected failure'
foreach ($name in $managed) { Check ('Rollback '+$name) ((Sha (Join-Path $installed $name)) -eq $old[$name]) }
foreach ($name in $protected) { Check ('RollbackPreserved '+$name) ((Sha (Join-Path $installed $name)) -eq $before[$name]) }
Must-Reject 'RegisteredPathCannotDrift' { & $installer -SourceDirectory $source -InstallDirectory (Join-Path $test 'Other') -TestRoot $test } 'already registered'
Must-Reject 'FreshCannotOverwriteBackend' { & $installer -SourceDirectory $source -TestRoot $test -FreshInstall } 'cannot overwrite'
Put (Join-Path $installed 'backend/results/ui-status.json') '{"phase":"connected"}'
Must-Reject 'ConnectedStateBlocksReplacement' { & $installer -SourceDirectory $source -TestRoot $test } 'not stopped'
Put (Join-Path $installed 'backend/results/ui-status.json') '{"phase":"stopped"}'
$running=Start-Process -FilePath (Join-Path $installed 'Accelerator.exe') -WindowStyle Hidden -PassThru
try { Must-Reject 'RunningUiBlocksReplacement' { & $installer -SourceDirectory $source -TestRoot $test } 'running' }
finally { if (-not $running.HasExited) { $running.Kill(); $running.WaitForExit() }; $running.Dispose() }
$freshRoot=Join-Path $test 'FreshCase'; $null=[IO.Directory]::CreateDirectory($freshRoot)
Must-Reject 'FreshRequiresExplicitDependencies' { & $installer -SourceDirectory $source -TestRoot $freshRoot -FreshInstall } 'Bundled backend source missing|requires explicitly'
$runtime=Join-Path $test 'CleanRuntime'; $sdk=Join-Path $test 'CleanSdk'
foreach ($file in @('pwsh.exe','LICENSE.txt','ThirdPartyNotices.txt')) { Put (Join-Path $runtime $file) ('clean runtime '+$file) }
foreach ($file in @('linkboost/linkboost.exe','linkboost/linkboost-core.exe','linkboost/helper/multipath-helper.exe')) { Put (Join-Path $sdk $file) ('clean sdk '+$file) }
foreach ($file in @('Check-Configuration.ps1','Control-Accelerator.ps1','Mna-GameRoute.ps1','Mna-RebootRecovery.ps1','Mna-SessionRecovery.ps1','Mna-UI.Common.ps1','Run-Accelerator.ps1','Test-UdpStun.ps1','Trial-NetworkState.ps1')) { Put (Join-Path $source ('backend/'+$file)) ('clean backend '+$file) }
Put (Join-Path $sdk 'linkboost/mp_client_uuid.conf') 'synthetic contaminated dependency'
Must-Reject 'GeneratedSdkIdentityRejected' { & $installer -SourceDirectory $source -TestRoot $freshRoot -FreshInstall -PreparedRuntimeDirectory $runtime -PreparedSdkDirectory $sdk } 'generated state or secrets'
[IO.File]::Delete((Join-Path $sdk 'linkboost/mp_client_uuid.conf'))
$fresh=& $installer -SourceDirectory $source -TestRoot $freshRoot -FreshInstall -PreparedRuntimeDirectory $runtime -PreparedSdkDirectory $sdk
Check 'FreshInstallExplicitDependencies' ($fresh.Succeeded -and [IO.File]::Exists((Join-Path $fresh.InstallPath 'runtime/pwsh.exe')) -and [IO.File]::Exists((Join-Path $fresh.InstallPath 'backend/vendor_inspection/sdk_v0.23.1/linkboost/linkboost.exe')))
Check 'FreshExcludesSourceCredentials' (-not [IO.File]::Exists((Join-Path $fresh.InstallPath 'private/never-copy.key')) -and -not [IO.File]::Exists((Join-Path $fresh.InstallPath 'user-settings.json')))
$unsafeRoot=Join-Path $test 'UnsafeCase'; $null=[IO.Directory]::CreateDirectory($unsafeRoot)
Must-Reject 'TestIsolationEnforced' { & $installer -SourceDirectory $source -TestRoot $unsafeRoot -InstallDirectory $repository } 'within TestRoot'
$gitLike=Join-Path $unsafeRoot 'GitCheckout'; $null=[IO.Directory]::CreateDirectory($gitLike); Put (Join-Path $gitLike '.git') 'gitdir: fixture'
Must-Reject 'WorktreeTargetRejected' { & $installer -SourceDirectory $source -TestRoot $unsafeRoot -InstallDirectory (Join-Path $gitLike 'app') } 'source checkouts'
$realTarget=Join-Path $unsafeRoot 'Real'; $null=[IO.Directory]::CreateDirectory($realTarget)
$junction=Join-Path $unsafeRoot 'Junction'; $null=New-Item -ItemType Junction -Path $junction -Target $realTarget
Must-Reject 'ReparseTargetRejected' { & $installer -SourceDirectory $source -TestRoot $unsafeRoot -InstallDirectory (Join-Path $junction 'app') } 'reparse points'
$private=Join-Path $test 'signing-private.dpapi'; $public=Join-Path $test 'signing-public.xml'
$key=& (Join-Path $repository 'build/New-UpdateSigningKey.ps1') -PrivateKeyPath $private -PublicKeyPath $public
Check 'KeyUsesCurrentUserDpapi' ($key.Protection -eq 'DPAPI CurrentUser' -and [IO.File]::Exists($private))
Check 'PublicKeyHasNoPrivateMaterial' (-not [IO.File]::ReadAllText($public).Contains('<D>'))
$packageOne=& (Join-Path $repository 'build/New-UpdatePackage.ps1') -SourceDirectory $source -PrivateKeyPath $private -OutputDirectory (Join-Path $test 'Release1') -IncludeBootstrap
$packageTwo=& (Join-Path $repository 'build/New-UpdatePackage.ps1') -SourceDirectory $source -PrivateKeyPath $private -OutputDirectory (Join-Path $test 'Release2') -IncludeBootstrap
Check 'DeterministicPackage' ($packageOne.PackageSha256 -eq $packageTwo.PackageSha256)
Check 'DeterministicManifest' ((Sha $packageOne.Manifest) -eq (Sha $packageTwo.Manifest))
Check 'DeterministicSignature' ((Sha (Join-Path $packageOne.Directory 'delta-ui-manifest.sig')) -eq (Sha (Join-Path $packageTwo.Directory 'delta-ui-manifest.sig')))
$manifestBytes=[IO.File]::ReadAllBytes($packageOne.Manifest)
$manifest=[Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
Check 'ManifestHasNoBom' (-not ($manifestBytes[0] -eq 239 -and $manifestBytes[1] -eq 187))
Check 'SignedFeedUrl' ($manifest.packageUrl -ceq 'https://raw.githubusercontent.com/QifengKuang/DeltaResolveAccelerator/updates/packages/1.1.0/delta-ui-1.1.0.zip')
Check 'ManifestStrictUiAllowlist' (($manifest.files.name | Sort-Object) -join ',' -eq 'Accelerator.exe,Accelerator.exe.config')
$rsa=[Security.Cryptography.RSACryptoServiceProvider]::new(); $rsa.PersistKeyInCsp=$false
try {
    $rsa.FromXmlString([IO.File]::ReadAllText($public)); $signature=[IO.File]::ReadAllBytes((Join-Path $packageOne.Directory 'delta-ui-manifest.sig'))
    Check 'PublicSignatureVerification' ($rsa.VerifyData($manifestBytes,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
    $manifestBytes[0]=$manifestBytes[0] -bxor 1
    Check 'TamperedManifestRejected' (-not $rsa.VerifyData($manifestBytes,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
} finally { $rsa.Dispose() }
$zip=[IO.Compression.ZipFile]::OpenRead($packageOne.Package)
try { Check 'UpdateZipExactlyTwoFiles' (($zip.Entries.FullName | Sort-Object) -join ',' -eq 'Accelerator.exe,Accelerator.exe.config') } finally { $zip.Dispose() }
$zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $packageOne.Directory 'delta-bootstrap-1.1.0-win-x64.zip'))
try { Check 'BootstrapExactlyOwnedFiles' (($zip.Entries.FullName | Sort-Object) -join ',' -eq 'app/Accelerator.exe,app/Accelerator.exe.config,app/DeltaLauncher.exe,app/DeltaResolve.ico,Install-App.ps1') } finally { $zip.Dispose() }
Must-Reject 'WrongReleaseVersionRejected' { & (Join-Path $repository 'build/New-UpdatePackage.ps1') -SourceDirectory $source -PrivateKeyPath $private -OutputDirectory (Join-Path $test 'WrongVersion') -Version '9.9.9' } 'version'
$report=[ordered]@{Passed=$true;CheckCount=$checks.Count;Checks=@($checks);TestDirectory=$test;RealRegistryModified=$false;RealShortcutsModified=$false;NetworkStarted=$false;ProductionProcessesStopped=$false}
[IO.File]::WriteAllText((Join-Path $test 'test-result.json'),($report|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 4
