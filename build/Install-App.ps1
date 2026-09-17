#requires -Version 7.0
<# Per-user installation. Existing installations receive only the stable launcher
   and two UI files; backend, runtime, credentials and settings are never replaced. #>
[CmdletBinding()]
param(
    [string]$SourceDirectory,
    [string]$InstallDirectory,
    [switch]$RepairShortcuts,
    [switch]$FreshInstall,
    [string]$PreparedRuntimeDirectory,
    [string]$PreparedSdkDirectory,
    [string]$TestRoot,
    [switch]$TestFailAfterCopy
)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Installation requires Windows.' }
$utf8=[Text.UTF8Encoding]::new($false)
$registryPath='HKCU:\Software\DeltaResolveAccelerator'
$managed=@('DeltaLauncher.exe','Accelerator.exe','Accelerator.exe.config','DeltaResolve.ico')
$backendNames=@('Check-Configuration.ps1','Control-Accelerator.ps1','Mna-GameRoute.ps1','Mna-RebootRecovery.ps1','Mna-RouterAdvertisementRecovery.ps1','Mna-SessionRecovery.ps1','Mna-UI.Common.ps1','Run-Accelerator.ps1','Test-UdpStun.ps1','Trial-NetworkState.ps1','Trial-RouteOrigin.ps1')
$isolated=-not [string]::IsNullOrWhiteSpace($TestRoot)
if ($TestFailAfterCopy -and -not $isolated) { throw 'Failure injection is available only in an isolated test root.' }
function FullPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\') }
function IsWithin([string]$Child,[string]$Parent) { $Child.Equals($Parent,[StringComparison]::OrdinalIgnoreCase) -or $Child.StartsWith($Parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) }
function Assert-NoReparse([string]$Path) {
    for ($part=$Path; $part; $part=[IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Installation paths must not cross reparse points.' }
    }
}
if (-not ('DeltaInstallPhysicalPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class DeltaInstallPhysicalPath {
    public static void Replace(string source, string target) { System.IO.File.Replace(source,target,null); }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    public static string Read(string path) {
        using (SafeFileHandle handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            StringBuilder result=new StringBuilder(32768);
            uint size=GetFinalPathNameByHandle(handle,result,(uint)result.Capacity,0);
            if (size==0 || size>=result.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
            string value=result.ToString();
            if (value.StartsWith(@"\\?\UNC\")) return @"\\"+value.Substring(8);
            return value.StartsWith(@"\\?\") ? value.Substring(4) : value;
        }
    }
}
'@
}
if ($isolated) {
    $test=FullPath $TestRoot
    Assert-NoReparse $test
    if (-not [IO.Directory]::Exists($test)) { throw 'TestRoot must already exist.' }
    $testRegistry=Join-Path $test 'registry.json'
    $desktop=Join-Path $test 'Desktop'
    $programs=Join-Path $test 'Programs'
} else {
    $desktop=[Environment]::GetFolderPath('DesktopDirectory')
    $programs=[Environment]::GetFolderPath('Programs')
}
function Read-InstallPath {
    if ($isolated) {
        if ([IO.File]::Exists($testRegistry)) { return ([IO.File]::ReadAllText($testRegistry) | ConvertFrom-Json).InstallPath }
        return $null
    }
    return (Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
}
function Save-InstallPath([string]$Value) {
    if ($isolated) {
        if ($Value) { [IO.File]::WriteAllText($testRegistry,(@{InstallPath=$Value}|ConvertTo-Json -Compress),$utf8) }
        elseif ([IO.File]::Exists($testRegistry)) { [IO.File]::Delete($testRegistry) }
    } elseif ($Value) {
        $null=New-Item -Path $registryPath -Force
        $null=New-ItemProperty -LiteralPath $registryPath -Name InstallPath -Value $Value -PropertyType String -Force
    } else { Remove-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction SilentlyContinue }
}
$registered=Read-InstallPath
if (-not $InstallDirectory) {
    if ($registered) { $InstallDirectory=$registered }
    elseif ($isolated) { $InstallDirectory=Join-Path $test 'Installed' }
    else { $InstallDirectory=Join-Path $env:LOCALAPPDATA 'Programs/DeltaResolveAccelerator' }
}
$install=FullPath $InstallDirectory
if ($registered -and (FullPath $registered) -ine $install) { throw 'An installation path is already registered. Repair that installation; do not move it by creating a second shortcut.' }
if ($isolated -and -not (IsWithin $install $test)) { throw 'Test installation must stay within TestRoot.' }
if ($install.StartsWith('\\') -or $install -eq [IO.Path]::GetPathRoot($install).TrimEnd('\')) { throw 'Select a local application directory, not a drive root or network path.' }
foreach ($temp in @($env:TEMP,$env:TMP,(Join-Path $env:WINDIR 'Temp')) | Select-Object -Unique) {
    if ($temp -and (IsWithin $install (FullPath $temp))) { throw 'A temporary directory cannot be an installation destination.' }
}
for ($part=$install; $part; $part=[IO.Path]::GetDirectoryName($part)) {
    if (Test-Path -LiteralPath (Join-Path $part '.git')) { throw 'Install outside source checkouts and Git worktrees.' }
}
if ($install -match '(?i)\\(?:WindowsApps|AppData\\Local\\Packages|\.codex\\worktrees)(?:\\|$)') { throw 'Select a stable directory outside application package caches and worktrees.' }
Assert-NoReparse $install
foreach ($path in @($desktop,$programs)) { Assert-NoReparse (FullPath $path) }
if (-not $SourceDirectory) {
    $candidate=Join-Path $PSScriptRoot 'app'
    $SourceDirectory=if ([IO.Directory]::Exists($candidate)) { $candidate } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'app' }
}
$source=FullPath $SourceDirectory
$payload=[ordered]@{}
if (-not $RepairShortcuts) {
    if ((IsWithin $source $install) -or (IsWithin $install $source)) { throw 'Source and installed directories must be separate.' }
    foreach ($name in $managed) {
        $file=Join-Path $source $name
        Assert-NoReparse $file
        if (-not [IO.File]::Exists($file)) { throw ('Build or supply the release file: '+$name) }
        $payload[$name]=$file
    }
}
$existing=[IO.File]::Exists((Join-Path $install 'Accelerator.exe')) -or [IO.Directory]::Exists((Join-Path $install 'backend'))
if ($FreshInstall -and $existing) { throw 'FreshInstall cannot overwrite an existing backend. Use the default UI update.' }
if (-not $existing -and -not $FreshInstall -and -not $RepairShortcuts) { throw 'No existing installation found. Use FreshInstall with explicitly supplied clean runtime and SDK directories.' }
function Add-Dependency([string]$Source,[string]$Prefix,[string[]]$Required) {
    if (-not $Source) { throw 'FreshInstall requires explicitly supplied clean runtime and SDK directories.' }
    $dir=FullPath $Source
    Assert-NoReparse $dir
    foreach ($requiredFile in $Required) { if (-not [IO.File]::Exists((Join-Path $dir $requiredFile))) { throw 'Required dependency file is missing.' } }
    foreach ($entry in Get-ChildItem -LiteralPath $dir -Recurse -Force) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Dependencies must not contain reparse points.' }
        $relative=[IO.Path]::GetRelativePath($dir,$entry.FullName).Replace('\','/')
        if ($relative -match '(?i)(^|/)(private|results|credentials|sessions?)(/|$)|(^|/)(user-settings\.json|mp_client_uuid\.conf|mp_client\.json|speed_mode_rules\.json)$|\.(dpapi|key|pem|pfx|log|mlog|etl)$') { throw 'Dependency directory contains generated state or secrets; use clean original dependencies.' }
        if ($entry.PSIsContainer) { continue }
        if ($relative -match '(?i)(^|/)(logs?)(/|$)') { throw 'Dependency directory contains logs; use clean original dependencies.' }
        $payload[$Prefix+'/'+$relative]=$entry.FullName
    }
}
if ($FreshInstall) {
    foreach ($name in $backendNames) {
        $file=Join-Path $source ('backend/'+$name)
        Assert-NoReparse $file
        if (-not [IO.File]::Exists($file)) { throw ('Bundled backend source missing: '+$name) }
        $payload['backend/'+$name]=$file
    }
    Add-Dependency $PreparedRuntimeDirectory 'runtime' @('pwsh.exe','LICENSE.txt','ThirdPartyNotices.txt')
    Add-Dependency $PreparedSdkDirectory 'backend/vendor_inspection/sdk_v0.23.1' @('linkboost/linkboost.exe','linkboost/linkboost-core.exe','linkboost/helper/multipath-helper.exe')
}
function Assert-Stopped {
    $mutex=$null
    if (-not $isolated) { try { $mutex=[Threading.Mutex]::OpenExisting('Local\DeltaResolveAccelerator-1') } catch [Threading.WaitHandleCannotBeOpenedException] { } }
    if ($null -ne $mutex) { $mutex.Dispose(); throw 'Close the accelerator before installing. No process was stopped.' }
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='Accelerator.exe' OR Name='DeltaLauncher.exe' OR Name='linkboost.exe' OR Name='linkboost-core.exe' OR Name='multipath-helper.exe' OR Name='mp-speeder.exe' OR Name='pwsh.exe'")
    foreach ($process in $processes) {
        if ($process.ProcessId -eq $PID) { continue }
        if ($isolated -and -not ($process.ExecutablePath -and (IsWithin $process.ExecutablePath $test))) { continue }
        if ($process.Name -in @('linkboost.exe','linkboost-core.exe','multipath-helper.exe','mp-speeder.exe') -or
            ($process.Name -eq 'Accelerator.exe') -or
            ($process.ExecutablePath -and (IsWithin $process.ExecutablePath $install)) -or
            ($process.CommandLine -and $process.CommandLine.IndexOf($install,[StringComparison]::OrdinalIgnoreCase) -ge 0)) { throw 'The accelerator, launcher or SDK is running. Stop acceleration and exit before installing.' }
    }
    $status=Join-Path $install 'backend/results/ui-status.json'
    if ([IO.File]::Exists($status)) {
        Assert-NoReparse $status
        try { $phase=([IO.File]::ReadAllText($status) | ConvertFrom-Json).phase } catch { throw 'Cannot read the current connection state. Open the existing app and stop acceleration before installing.' }
        if ($phase -ne 'stopped') { throw 'The stored connection state is not stopped. Open the existing app and complete safe shutdown before installing.' }
    }
}
if (-not $RepairShortcuts) { Assert-Stopped }
$null=[IO.Directory]::CreateDirectory($install)
Assert-NoReparse $install
$physical=FullPath ([DeltaInstallPhysicalPath]::Read($install))
if ($physical -ine $install) { throw 'Windows redirected the selected installation path. Run the installer in a normal terminal outside a packaged application.' }
$launcher=Join-Path $install 'DeltaLauncher.exe'
if ($RepairShortcuts) {
    foreach ($name in $managed) { $file=Join-Path $install $name; Assert-NoReparse $file; if (-not [IO.File]::Exists($file)) { throw 'Installed files are incomplete. Run the installer with a complete release package.' } }
}
$hasher=[Security.Cryptography.SHA256]::Create()
try { $rootHash=[Convert]::ToHexString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($install.ToUpperInvariant()))).ToLowerInvariant().Substring(0,24) }
finally { $hasher.Dispose() }
$updateGate=[Threading.Mutex]::new($false,('Local\DeltaResolveUpdate-'+$rootHash))
$updateOwned=$false
$appGate=$null
$appOwned=$false
try {
    try { $updateOwned=$updateGate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $updateOwned=$true }
    if (-not $updateOwned) { throw 'An installation or update is already in progress.' }
    if (-not $RepairShortcuts) {
        Assert-Stopped
        $appName=if ($isolated) { 'Local\DeltaResolveInstallTest-'+$rootHash } else { 'Local\DeltaResolveAccelerator-1' }
        $appGate=[Threading.Mutex]::new($false,$appName)
        try { $appOwned=$appGate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $appOwned=$true }
        if (-not $appOwned) { throw 'The accelerator opened during installation. Exit it and retry.' }
    }
$transaction=Join-Path $install ('.installation/'+[guid]::NewGuid().ToString('N'))
Assert-NoReparse $transaction
$null=[IO.Directory]::CreateDirectory($transaction)
$undo=[Collections.Generic.List[object]]::new()
function Replace-File([string]$From,[string]$To) {
    Assert-NoReparse $To
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($To))
    $existed=[IO.File]::Exists($To)
    $backup=Join-Path $transaction ($undo.Count.ToString()+'.bak')
    if ($existed) { [IO.File]::Copy($To,$backup,$false) }
    $pending=$To+'.install-'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::Copy($From,$pending,$false)
    try {
        if ((Get-FileHash -LiteralPath $pending).Hash -ne (Get-FileHash -LiteralPath $From).Hash) { throw 'Staged file verification failed.' }
        if ($existed) { [DeltaInstallPhysicalPath]::Replace($pending,$To) } else { [IO.File]::Move($pending,$To) }
        $undo.Add([pscustomobject]@{Path=$To;Existed=$existed;Backup=$backup})
        if ((FullPath ([DeltaInstallPhysicalPath]::Read($To))) -ine (FullPath $To)) { throw 'An installed file was redirected by Windows.' }
    } finally { if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) } }
}
function Save-Shortcut([string]$Directory) {
    $null=[IO.Directory]::CreateDirectory($Directory)
    $shortcut=Join-Path $Directory '三角洲加速器.lnk'
    Assert-NoReparse $shortcut
    $staged=Join-Path $transaction ([guid]::NewGuid().ToString('N')+'.lnk')
    $shell=New-Object -ComObject WScript.Shell
    try {
        $link=$shell.CreateShortcut($staged)
        try {
            $link.TargetPath=$launcher
            $link.Arguments='--launch'
            $link.WorkingDirectory=$install
            $link.IconLocation=(Join-Path $install 'DeltaResolve.ico')+',0'
            $link.Description='三角洲加速器'
            $link.Save()
        } finally { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        $check=$shell.CreateShortcut($staged)
        try {
            if ($check.TargetPath -ine $launcher -or $check.WorkingDirectory -ine $install -or $check.Arguments -ne '--launch') { throw 'Shortcut verification failed.' }
        } finally { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($check) }
    } finally { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    # MS-SHLLINK LinkFlags: ForceNoLinkTrack + DisableLinkPathTracking keep
    # Windows from following a replaced EXE to a build/cache directory.
    $bytes=[IO.File]::ReadAllBytes($staged)
    if ($bytes.Length -lt 76 -or [BitConverter]::ToUInt32($bytes,0) -ne 76) { throw 'Invalid Shell Link header.' }
    $flags=[BitConverter]::ToUInt32($bytes,20) -bor 0x00040000 -bor 0x00100000
    [Array]::Copy([BitConverter]::GetBytes([uint32]$flags),0,$bytes,20,4)
    [IO.File]::WriteAllBytes($staged,$bytes)
    Replace-File $staged $shortcut
}
try {
    foreach ($name in $payload.Keys) { Replace-File $payload[$name] (Join-Path $install $name) }
    if ($TestFailAfterCopy) { throw 'Injected failure after payload copy.' }
    Save-InstallPath $install
    Save-Shortcut $desktop
    Save-Shortcut $programs
    $report=[ordered]@{Succeeded=$true;InstallPath=$install;PhysicalPath=$physical;Version=(Get-Item -LiteralPath (Join-Path $install 'Accelerator.exe')).VersionInfo.FileVersion;RepairOnly=[bool]$RepairShortcuts;FreshInstall=[bool]$FreshInstall;FilesCopied=@($payload.Keys);DesktopShortcut=(Join-Path $desktop '三角洲加速器.lnk');StartMenuShortcut=(Join-Path $programs '三角洲加速器.lnk');BackupDirectory=$transaction;RegistryIsolated=$isolated;AccelerationStarted=$false}
    [IO.File]::WriteAllText((Join-Path $transaction 'installation-result.json'),($report|ConvertTo-Json -Depth 4),$utf8)
    [pscustomobject]$report
} catch {
    $failure=$_
    $rollbackErrors=[Collections.Generic.List[string]]::new()
    for ($i=$undo.Count-1; $i -ge 0; $i--) {
        $entry=$undo[$i]
        try {
            if ($entry.Existed) { [IO.File]::Copy($entry.Backup,$entry.Path,$true) }
            elseif ([IO.File]::Exists($entry.Path)) { [IO.File]::Delete($entry.Path) }
        } catch { $rollbackErrors.Add($entry.Path) }
    }
    try { Save-InstallPath $registered } catch { $rollbackErrors.Add('InstallPath registry') }
    if ($rollbackErrors.Count) { throw ('Installation failed and rollback needs review. Backups: '+$transaction) }
    throw $failure
}
} finally {
    if ($appOwned) { $appGate.ReleaseMutex() }
    if ($null -ne $appGate) { $appGate.Dispose() }
    if ($updateOwned) { $updateGate.ReleaseMutex() }
    $updateGate.Dispose()
}
