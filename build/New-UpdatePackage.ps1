#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SourceDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'app'),
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='1.1.0',
    [ValidateSet('GitHubRelease','SignedGitFeed')][string]$Channel='SignedGitFeed',
    [switch]$IncludeBootstrap
)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Release signing requires Windows DPAPI.' }
$source=[IO.Path]::GetFullPath($SourceDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
$repository=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$private=[IO.Path]::GetFullPath($PrivateKeyPath)
if ($private.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Private signing key must be outside the repository.' }
if (Test-Path -LiteralPath $output) { throw 'Use a new output directory to avoid mixing release assets.' }
foreach ($path in @($source,$output,$private)) {
    for ($item=$path; $item; $item=[IO.Path]::GetDirectoryName($item)) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Release paths must not cross reparse points.' }
    }
}
$names=@('Accelerator.exe','Accelerator.exe.config')
foreach ($name in $names) {
    if (-not [IO.File]::Exists((Join-Path $source $name))) { throw ('Release file missing: '+$name) }
}
if ([version](Get-Item -LiteralPath (Join-Path $source 'Accelerator.exe')).VersionInfo.FileVersion -ne [version]($Version+'.0')) { throw 'Executable version does not match release version.' }
if ($IncludeBootstrap -and -not [IO.File]::Exists((Join-Path $source 'DeltaLauncher.exe'))) { throw 'Build DeltaLauncher.exe before creating the bootstrap.' }
$null=[IO.Directory]::CreateDirectory($output)
function Write-DeterministicZip([string]$Path,[System.Collections.IDictionary]$Files) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach ($name in $Files.Keys) {
            $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime=[DateTimeOffset]::new(2020,1,1,0,0,0,[TimeSpan]::Zero)
            $entry.ExternalAttributes=0
            $dest=$entry.Open()
            try { $bytes=[IO.File]::ReadAllBytes($Files[$name]); $dest.Write($bytes,0,$bytes.Length) } finally { $dest.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}
$packageName=if ($Channel -eq 'SignedGitFeed') { 'delta-ui-'+$Version+'.zip' } else { 'delta-ui-'+$Version+'-win-x64.zip' }
$package=Join-Path $output $packageName
$payload=[ordered]@{}
$files=@(foreach ($name in $names) {
    $path=Join-Path $source $name
    $payload[$name]=$path
    [ordered]@{name=$name;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();size=(Get-Item -LiteralPath $path).Length}
})
Write-DeterministicZip $package $payload
# Recheck source bytes against the ZIP: no release may mix files changed during packaging.
$checkZip=[IO.Compression.ZipFile]::OpenRead($package)
try {
    foreach ($file in $files) {
        $entry=$checkZip.GetEntry($file.name); $input=$entry.Open(); $hash=[Security.Cryptography.SHA256]::Create()
        try { $actual=[Convert]::ToHexString($hash.ComputeHash($input)).ToLowerInvariant() } finally { $hash.Dispose(); $input.Dispose() }
        if ($actual -ne $file.sha256 -or $entry.Length -ne $file.size) { throw 'A source file changed during packaging.' }
    }
} finally { $checkZip.Dispose() }
$manifest=[ordered]@{
    version=$Version
    packageUrl=$(if ($Channel -eq 'SignedGitFeed') { 'https://raw.githubusercontent.com/QifengKuang/DeltaResolveAccelerator/updates/packages/'+$Version+'/'+$packageName } else { 'https://github.com/QifengKuang/DeltaResolveAccelerator/releases/download/v'+$Version+'/'+$packageName })
    packageSha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    packageSize=(Get-Item -LiteralPath $package).Length
    files=$files
}
$manifestPath=Join-Path $output 'delta-ui-manifest.json'
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 5 -Compress))
$clear=$null
$rsa=[Security.Cryptography.RSACryptoServiceProvider]::new()
$rsa.PersistKeyInCsp=$false
try {
    $clear=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($private),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($clear))
    if ($rsa.KeySize -lt 3072) { throw 'Release signing key must be at least RSA-3072.' }
    $signature=$rsa.SignData($bytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (-not $rsa.VerifyData($bytes,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Signature verification failed.' }
    [IO.File]::WriteAllBytes($manifestPath,$bytes)
    [IO.File]::WriteAllBytes((Join-Path $output 'delta-ui-manifest.sig'),$signature)
} finally { if ($null -ne $clear) { [Array]::Clear($clear,0,$clear.Length) }; $rsa.Dispose() }
if ($IncludeBootstrap) {
    # This bootstrap repairs/upgrades an existing installation. It contains no
    # backend, runtime, SDK, device identity or live configuration.
    $bootstrap=[ordered]@{'Install-App.ps1'=(Join-Path $PSScriptRoot 'Install-App.ps1')}
    foreach ($name in @('DeltaLauncher.exe','DeltaResolve.ico')+$names) { $bootstrap['app/'+$name]=Join-Path $source $name }
    Write-DeterministicZip (Join-Path $output ('delta-bootstrap-'+$Version+'-win-x64.zip')) $bootstrap
}
[pscustomobject]@{Version=$Version;Directory=$output;Manifest=$manifestPath;Package=$package;PackageSha256=$manifest.packageSha256;Signed=$true;BackendIncluded=$false;SecretsIncluded=$false}
