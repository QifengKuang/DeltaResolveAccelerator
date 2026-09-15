#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][string]$PublicKeyPath
)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Signing keys require Windows DPAPI.' }
$repository=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$private=[IO.Path]::GetFullPath($PrivateKeyPath)
$public=[IO.Path]::GetFullPath($PublicKeyPath)
if ($private.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Private signing key must be outside the repository.' }
if ($private -eq $public -or (Test-Path -LiteralPath $private) -or (Test-Path -LiteralPath $public)) { throw 'Key destinations must be distinct and must not exist.' }
foreach ($path in @($private,$public)) {
    for ($dir=[IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($path)); $null -ne $dir; $dir=$dir.Parent) {
        if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Key destination crosses a reparse point.' }
    }
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
}
$rsa=[Security.Cryptography.RSACryptoServiceProvider]::new(3072)
$rsa.PersistKeyInCsp=$false
$clear=$null
try {
    $clear=[Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
    $encrypted=[Security.Cryptography.ProtectedData]::Protect($clear,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($private,$encrypted)
    [IO.File]::WriteAllText($public,$rsa.ToXmlString($false),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{PrivateKeyPath=$private;PublicKeyPath=$public;Algorithm='RSA-3072/SHA-256/PKCS1';Protection='DPAPI CurrentUser'}
} finally {
    if ($null -ne $clear) { [Array]::Clear($clear,0,$clear.Length) }
    $rsa.Dispose()
}
