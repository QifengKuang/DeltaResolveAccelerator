#requires -Version 7.0
<# One release operation: validate/build, sign the tiny update package, push source,
   then atomically publish the signed feed. The private key never enters Git.
   -PrepareOnly creates the same local Git tree for connector-based publication. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutputDirectory,
    [switch]$PrepareOnly,
    [switch]$SkipTests,
    [switch]$UseExistingBuild
)
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
function Invoke-Git([string[]]$Arguments) {
    $result=@(& git -C $repository @Arguments)
    if ($LASTEXITCODE -ne 0) { throw ('Git operation failed: '+$Arguments[0]) }
    return $result
}
if (@(Invoke-Git @('status','--porcelain','--untracked-files=all')).Count) { throw 'Commit all source changes before publishing.' }
$sourceCommit=@(Invoke-Git @('rev-parse','HEAD'))[0]
$sourceTree=@(Invoke-Git @('rev-parse','HEAD^{tree}'))[0]
$null=Invoke-Git @('fetch','origin','main')
& git -C $repository merge-base --is-ancestor origin/main HEAD
if ($LASTEXITCODE -ne 0) { throw 'Release source must contain the current GitHub main branch. Integrate it first; no force-push is allowed.' }
if (-not $UseExistingBuild) {
    & (Join-Path $PSScriptRoot 'Compile-App.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'Compile-Launcher.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'Compile-Setup.ps1') -OutputPath (Join-Path $repository ('dist/DeltaResolveSetup-'+$Version+'.exe')) | Out-Null
}
if (-not $SkipTests) {
    foreach ($test in @('Test-Offline.ps1','Test-GameDiscovery.ps1','Test-Updates.ps1','Test-Installation.ps1','Test-UiLayout.ps1','Test-UiResize.ps1')) {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $repository ('tests/'+$test)) | Out-Host
        if ($LASTEXITCODE -ne 0) { throw ('Release validation failed: '+$test) }
    }
}
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $repository ('dist/release-'+$Version+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)) }
$packageResult=& (Join-Path $PSScriptRoot 'New-UpdatePackage.ps1') -PrivateKeyPath $PrivateKeyPath -OutputDirectory $OutputDirectory -Version $Version -Channel SignedGitFeed -IncludeBootstrap
$output=[IO.Path]::GetFullPath($OutputDirectory)
# Verify against the keys actually embedded in both delivered binaries. Selecting
# another otherwise-valid signing key must never produce an unusable live feed.
$manifestBytes=[IO.File]::ReadAllBytes((Join-Path $output 'delta-ui-manifest.json'))
$signature=[IO.File]::ReadAllBytes((Join-Path $output 'delta-ui-manifest.sig'))
foreach ($binary in @('Accelerator.exe','DeltaLauncher.exe')) {
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $repository ('app/'+$binary))))
    $key=$assembly.GetType('DeltaResolveAccelerator.UpdatePublicKey',$true).GetField('Xml',[Reflection.BindingFlags]'NonPublic,Static').GetRawConstantValue()
    $verifier=[Security.Cryptography.RSACryptoServiceProvider]::new()
    $verifier.PersistKeyInCsp=$false
    try {
        $verifier.FromXmlString($key)
        if (-not $verifier.VerifyData($manifestBytes,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw ('Signing key does not match the delivered '+$binary) }
    } finally { $verifier.Dispose() }
}
$setup=Join-Path $repository ('dist/DeltaResolveSetup-'+$Version+'.exe')
if (-not (Test-Path -LiteralPath $setup)) { throw 'Build the lightweight setup executable before publishing.' }
Copy-Item -LiteralPath $setup -Destination (Join-Path $output ([IO.Path]::GetFileName($setup)))
$oldFeed=@(Invoke-Git @('ls-remote','--heads','origin','refs/heads/updates'))
$feedParent=$null
if ($oldFeed.Count) {
    $null=Invoke-Git @('fetch','origin','refs/heads/updates:refs/remotes/origin/updates')
    $feedParent=@(Invoke-Git @('rev-parse','refs/remotes/origin/updates'))[0]
    if (@(Invoke-Git @('ls-tree','--name-only',$feedParent,('packages/'+$Version+'/'))).Count) { throw 'This version is already published. Increment the version; published package URLs are immutable.' }
}
$files=[ordered]@{
    'stable/delta-ui-manifest.json'=(Join-Path $output 'delta-ui-manifest.json')
    'stable/delta-ui-manifest.sig'=(Join-Path $output 'delta-ui-manifest.sig')
    ('packages/'+$Version+'/delta-ui-'+$Version+'.zip')=(Join-Path $output ('delta-ui-'+$Version+'.zip'))
    ('installers/DeltaResolveSetup-'+$Version+'.exe')=(Join-Path $output ('DeltaResolveSetup-'+$Version+'.exe'))
}
$readme=Join-Path $output 'feed-README.md'
[IO.File]::WriteAllText($readme,"# Official signed update feed`n`nSource: https://github.com/QifengKuang/DeltaResolveAccelerator/commit/$sourceCommit`nVersion: $Version`n`nOnly application-owned UI files are distributed here. No SDK, runtime, credentials, user settings or logs are included.`n",[Text.UTF8Encoding]::new($false))
$files['README.md']=$readme
$index=Join-Path $output ('git-index-'+[guid]::NewGuid().ToString('N'))
$previousIndex=$env:GIT_INDEX_FILE
try {
    $env:GIT_INDEX_FILE=$index
    if ($feedParent) { $null=Invoke-Git @('read-tree',$feedParent) } else { $null=Invoke-Git @('read-tree','--empty') }
    foreach ($name in $files.Keys) {
        $blob=@(Invoke-Git @('hash-object','-w','--no-filters','--',$files[$name]))[0]
        $null=Invoke-Git @('update-index','--add','--cacheinfo',('100644,'+$blob+','+$name))
    }
    $feedTree=@(Invoke-Git @('write-tree'))[0]
} finally {
    if ($null -eq $previousIndex) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE=$previousIndex }
    if (Test-Path -LiteralPath $index) { Remove-Item -LiteralPath $index }
}
$result=[ordered]@{Version=$Version;SourceCommit=$sourceCommit;SourceTree=$sourceTree;FeedParent=$feedParent;FeedTree=$feedTree;OutputDirectory=$output;PreparedOnly=[bool]$PrepareOnly;SourcePublished=$false;FeedPublished=$false;Files=$files}
if (-not $PrepareOnly) {
    if (@(Invoke-Git @('status','--porcelain','--untracked-files=all')).Count -or @(Invoke-Git @('rev-parse','HEAD'))[0] -ne $sourceCommit) { throw 'Source changed during release preparation; nothing was pushed.' }
    # A failed source push leaves the live update feed untouched.
    $null=Invoke-Git @('push','origin',($sourceCommit+':refs/heads/main'))
    $result.SourcePublished=$true
    $message=Join-Path $output 'feed-commit-message.txt'
    [IO.File]::WriteAllText($message,"Publish signed UI update $Version`n`nSource: $sourceCommit`n",[Text.UTF8Encoding]::new($false))
    $parent=if($feedParent){$feedParent}else{$sourceCommit}
    $feedCommit=@(Invoke-Git @('commit-tree',$feedTree,'-p',$parent,'-F',$message))[0]
    $null=Invoke-Git @('push','origin',($feedCommit+':refs/heads/updates'))
    $result.FeedPublished=$true
    $result.FeedCommit=$feedCommit
}
[IO.File]::WriteAllText((Join-Path $output 'publication.json'),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
[pscustomobject]$result
