#requires -Version 7.0
<# Offline preparation from explicitly supplied original vendor ZIP files.
   Does not download, launch executables, inspect installed apps, or read keys. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SdkArchive,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$SdkSha256,
    [Parameter(Mandatory)][string]$PowerShellArchive,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$PowerShellSha256,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Runtime preparation requires Windows.' }
$repository=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))

function Assert-OriginalArchive {
    param([string]$Path,[string]$ExpectedHash,[string[]]$RequiredFiles,[switch]$Sdk)
    $resolved=[IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'Input ZIP does not exist.' }
    if ((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -ine $ExpectedHash) { throw 'Input ZIP SHA-256 mismatch.' }
    $archive=[IO.Compression.ZipFile]::OpenRead($resolved)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($entry in $archive.Entries) {
            $name=$entry.FullName.Replace('\','/')
            $parts=$name.TrimEnd('/').Split('/')
            if (-not $name -or $name.StartsWith('/') -or $name.Contains(':') -or
                @($parts | Where-Object { $_ -in @('','..','.') -or $_ -match '[\x00-\x1f<>"|?*]' -or $_ -match '[. ]$' }).Count) {
                throw 'Unsafe archive path.'
            }
            # Unix symlinks are not valid runtime payload files on Windows.
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Archive symlinks are not supported.' }
            if (-not $seen.Add($name.TrimEnd('/'))) { throw 'Duplicate archive path.' }
            if ($entry.Name) { $null=$files.Add($name) }
            # The original SDK has one empty log/ directory, with no log files.
            $originalEmptyLogDirectory=(-not $entry.Name -and $name -ceq 'linkboost/log/')
            if ($Sdk -and (-not $name.StartsWith('linkboost/',[StringComparison]::Ordinal) -or
                (-not $originalEmptyLogDirectory -and $name -match '(?i)(^|/)(private|results|log|logs|credentials|sessions?)(/|$)') -or
                $name -match '(?i)(^|/)(user-settings\.json|mp_client_uuid\.conf|mp_client\.json|speed_mode_rules\.json)$' -or
                $name -match '(?i)\.(log|mlog|etl|dpapi)$')) {
                throw 'SDK archive has an unexpected layout or generated state.'
            }
        }
        foreach ($required in $RequiredFiles) {
            if (-not $files.Contains($required)) { throw ('Required archive file missing: '+$required) }
        }
    } finally { $archive.Dispose() }
    return $resolved
}

$sdkSource=Assert-OriginalArchive -Path $SdkArchive -ExpectedHash $SdkSha256 -Sdk -RequiredFiles @(
    'linkboost/linkboost.exe','linkboost/linkboost-core.exe','linkboost/helper/multipath-helper.exe')
$psSource=Assert-OriginalArchive -Path $PowerShellArchive -ExpectedHash $PowerShellSha256 -RequiredFiles @('pwsh.exe','LICENSE.txt','ThirdPartyNotices.txt')
$sdkDestination=Join-Path $repository 'app/backend/vendor_inspection/sdk_v0.23.1'
$psDestination=Join-Path $repository 'app/runtime'
if ($ValidateOnly) {
    [pscustomobject]@{Validated=$true;Extracted=$false;SdkTargetVersion='0.23.1_e012851';TargetArchitecture='Windows x64';NetworkUsed=$false}
    return
}
foreach ($destination in @($sdkDestination,$psDestination)) {
    if (Test-Path -LiteralPath $destination) { throw 'Dependency destination exists. Stop the app and review existing files before replacing dependencies.' }
    for ($directory=[IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($destination)); $null -ne $directory; $directory=$directory.Parent) {
        if ($directory.Exists -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Dependency destination crosses a reparse point.' }
    }
}
$stageBase=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dependency-work'))
$stageRoot=[IO.Path]::GetFullPath((Join-Path $stageBase ([guid]::NewGuid().ToString('N'))))
if (-not $stageRoot.StartsWith($stageBase+'\',[StringComparison]::OrdinalIgnoreCase) -or
    -not $stageBase.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Staging path is outside the repository.' }
for ($directory=[IO.DirectoryInfo]::new($stageBase); $null -ne $directory; $directory=$directory.Parent) {
    if ($directory.Exists -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Staging destination crosses a reparse point.' }
}
$sdkStage=Join-Path $stageRoot 'sdk'
$psStage=Join-Path $stageRoot 'powershell'
$null=New-Item -ItemType Directory -Path $stageRoot
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($sdkSource,$sdkStage)
    [IO.Compression.ZipFile]::ExtractToDirectory($psSource,$psStage)
    $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($sdkDestination)) -Force
    [IO.Directory]::Move($sdkStage,$sdkDestination)
    [IO.Directory]::Move($psStage,$psDestination)
    [IO.Directory]::Delete($stageRoot,$false)
    [pscustomobject]@{Validated=$true;Extracted=$true;Sdk='app/backend/vendor_inspection/sdk_v0.23.1';PowerShell='app/runtime';NetworkUsed=$false}
} catch {
    # Keep any staging files for inspection; never remove or overwrite an
    # existing runtime automatically, and never recursively delete an input.
    throw 'Dependency preparation failed. Inspect build/dependency-work and the two dependency destinations before retrying; no installed application was modified.'
}
