# Dot-source this file to load read-only snapshot and comparison functions.
# No credentials, process command lines, network changes, or automatic cleanup.
$script:MnaTrialNetworkResults = Join-Path $PSScriptRoot 'results'

function Protect-TrialProxyText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # Preserve proxy endpoints, but remove URL userinfo, queries and fragments.
    $clean = [regex]::Replace($Text, '(?i)([a-z][a-z0-9+.-]*://)[^/;\s]*@', '$1[redacted]@')
    $clean = [regex]::Replace($clean, '(^|[;\s=])[^/;\s=]+@', '$1[redacted]@')
    return [regex]::Replace($clean, '[?#][^;\s]*', '[redacted-query]')
}

function Get-TrialWinHttpProxy {
    param([switch]$CurrentUser)
    if (-not ('MnaTrial.NetworkProxyReader' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace MnaTrial {
    public sealed class DefaultProxy {
        public uint AccessType;
        public string Proxy;
        public string Bypass;
    }
    public sealed class UserProxy {
        public bool AutoDetect;
        public string AutoConfigURL;
        public string Proxy;
        public string Bypass;
    }
    public static class NetworkProxyReader {
        [StructLayout(LayoutKind.Sequential)]
        private struct ProxyInfo {
            public uint AccessType;
            public IntPtr Proxy;
            public IntPtr Bypass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct UserProxyInfo {
            [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
            public IntPtr AutoConfigURL;
            public IntPtr Proxy;
            public IntPtr Bypass;
        }
        [DllImport("winhttp.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpGetDefaultProxyConfiguration(out ProxyInfo info);
        [DllImport("winhttp.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpGetIEProxyConfigForCurrentUser(out UserProxyInfo info);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GlobalFree(IntPtr pointer);
        public static DefaultProxy Read() {
            ProxyInfo info;
            if (!WinHttpGetDefaultProxyConfiguration(out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                return new DefaultProxy {
                    AccessType=info.AccessType,
                    Proxy=Marshal.PtrToStringUni(info.Proxy),
                    Bypass=Marshal.PtrToStringUni(info.Bypass)
                };
            } finally {
                if (info.Proxy != IntPtr.Zero) GlobalFree(info.Proxy);
                if (info.Bypass != IntPtr.Zero) GlobalFree(info.Bypass);
            }
        }
        public static UserProxy ReadUser() {
            UserProxyInfo info;
            if (!WinHttpGetIEProxyConfigForCurrentUser(out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                return new UserProxy {
                    AutoDetect=info.AutoDetect,
                    AutoConfigURL=Marshal.PtrToStringUni(info.AutoConfigURL),
                    Proxy=Marshal.PtrToStringUni(info.Proxy),
                    Bypass=Marshal.PtrToStringUni(info.Bypass)
                };
            } finally {
                if (info.AutoConfigURL != IntPtr.Zero) GlobalFree(info.AutoConfigURL);
                if (info.Proxy != IntPtr.Zero) GlobalFree(info.Proxy);
                if (info.Bypass != IntPtr.Zero) GlobalFree(info.Bypass);
            }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
    }
    if ($CurrentUser) {
        $proxy = [MnaTrial.NetworkProxyReader]::ReadUser()
        return [pscustomobject]@{
            AutoDetect = $proxy.AutoDetect
            AutoConfigURL = Protect-TrialProxyText $proxy.AutoConfigURL
            Proxy = Protect-TrialProxyText $proxy.Proxy
            Bypass = Protect-TrialProxyText $proxy.Bypass
        }
    }
    $proxy = [MnaTrial.NetworkProxyReader]::Read()
    [pscustomobject]@{
        AccessType = $proxy.AccessType
        Proxy = Protect-TrialProxyText $proxy.Proxy
        Bypass = Protect-TrialProxyText $proxy.Bypass
    }
}

function Get-TrialNetworkState {
    [CmdletBinding()]
    param()
    $started = Get-Date -Format o
    $data = [ordered]@{}
    $readErrors = [System.Collections.Generic.List[object]]::new()
    $relatedPattern = 'linkboost|mp-speeder|multipath|mp_tun|wintun|wintap|tap0901'
    $queries = [ordered]@{
        Adapters = {
            Get-NetAdapter -IncludeHidden -ErrorAction Stop |
                Select-Object Name,InterfaceDescription,ifIndex,Status,LinkSpeed,Virtual,HardwareInterface
        }
        Interfaces = {
            Get-NetIPInterface -ErrorAction Stop | Select-Object InterfaceAlias,InterfaceIndex,
                @{n='AddressFamily';e={$_.AddressFamily.ToString()}},ConnectionState,NlMtuBytes,
                InterfaceMetric,Dhcp,RouterDiscovery,Forwarding,WeakHostSend,WeakHostReceive
        }
        IPAddresses = {
            Get-NetIPAddress -ErrorAction Stop | Select-Object InterfaceAlias,InterfaceIndex,
                @{n='AddressFamily';e={$_.AddressFamily.ToString()}},IPAddress,PrefixLength,
                Type,AddressState,SkipAsSource,PrefixOrigin,SuffixOrigin
        }
        ActiveRoutes = {
            Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Select-Object InterfaceAlias,
                InterfaceIndex,@{n='AddressFamily';e={$_.AddressFamily.ToString()}},
                DestinationPrefix,NextHop,RouteMetric,Protocol,Publish
        }
        PersistentRoutes = {
            Get-NetRoute -PolicyStore PersistentStore -ErrorAction Stop | Select-Object InterfaceAlias,
                InterfaceIndex,@{n='AddressFamily';e={$_.AddressFamily.ToString()}},
                DestinationPrefix,NextHop,RouteMetric,Protocol,Publish
        }
        DNS = {
            Get-DnsClientServerAddress -ErrorAction Stop | Select-Object InterfaceAlias,
                InterfaceIndex,AddressFamily,ServerAddresses
        }
        WinINETProxy = {
            $proxy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            [pscustomobject]@{
                ProxyEnable = $proxy.ProxyEnable
                ProxyServer = Protect-TrialProxyText $proxy.ProxyServer
                ProxyOverride = Protect-TrialProxyText $proxy.ProxyOverride
                AutoConfigURL = Protect-TrialProxyText $proxy.AutoConfigURL
                AutoDetectRegistryValue = $proxy.AutoDetect
                CurrentUserConfiguration = Get-TrialWinHttpProxy -CurrentUser
            }
        }
        WinHTTPProxy = { Get-TrialWinHttpProxy }
        RelatedProcesses = {
            Get-CimInstance -ClassName Win32_Process -Filter "Name='linkboost.exe' OR Name='linkboost-core.exe' OR Name='multipath-helper.exe' OR Name='mp-speeder.exe'" -Property Name,ProcessId,ParentProcessId,CreationDate -ErrorAction Stop |
                Select-Object Name,ProcessId,ParentProcessId,CreationDate
        }
        RelatedServices = {
            $relatedPids = @($data.RelatedProcesses | ForEach-Object ProcessId)
            Get-CimInstance -ClassName Win32_Service -Property Name,DisplayName,State,StartMode,ProcessId -ErrorAction Stop |
                Where-Object { $_.Name -match $relatedPattern -or $_.DisplayName -match $relatedPattern -or ($_.ProcessId -gt 0 -and $_.ProcessId -in $relatedPids) } |
                Select-Object Name,DisplayName,State,StartMode,ProcessId
        }
        RelatedDrivers = {
            Get-CimInstance -ClassName Win32_SystemDriver -Property Name,DisplayName,State,StartMode,Started,ServiceType -ErrorAction Stop |
                Where-Object { $_.Name -match $relatedPattern -or $_.DisplayName -match $relatedPattern } |
                Select-Object Name,DisplayName,State,StartMode,Started,ServiceType
        }
    }
    foreach ($section in $queries.Keys) {
        try { $data[$section] = @(& $queries[$section]) }
        catch {
            $data[$section] = @()
            # Do not emit exception text, paths, proxy strings or complete CIM objects.
            $readErrors.Add([pscustomobject]@{Section=$section; ErrorType=$_.Exception.GetType().FullName})
        }
    }
    [pscustomobject]@{
        SchemaVersion = 1
        StartedAt = $started
        FinishedAt = Get-Date -Format o
        Complete = ($readErrors.Count -eq 0)
        ReadErrors = @($readErrors.ToArray())
        Data = [pscustomobject]$data
        Limitations = @(
            'Local-only report retains network addresses and proxy endpoints needed for comparison; URL userinfo/query/fragment are redacted.',
            'WinINET includes current-user registry settings and WinHttpGetIEProxyConfigForCurrentUser, including automatic detection; application-specific proxies are not established.',
            'WinHTTP records default machine proxy settings; application/session-specific and advanced per-user proxy settings are not established.',
            'Shared TUN/TAP names are candidates, not proof that a driver or service belongs to this SDK. No automatic cleanup is performed.',
            'Snapshots are sequential rather than atomic. Route/IP lifetimes and timestamps are excluded from comparison; DNS server order is preserved.',
            'No credentials, process command lines, usernames, MAC addresses or device serial numbers are collected.'
        )
    }
}

function Save-TrialNetworkState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$State,
        [ValidatePattern('^[A-Za-z0-9_-]{1,48}$')][string]$Label = 'network'
    )
    New-Item -ItemType Directory -Path $script:MnaTrialNetworkResults -Force -ErrorAction Stop | Out-Null
    $name = '{0}_{1}_{2}.json' -f $Label,(Get-Date -Format 'yyyyMMdd_HHmmss_fff'),([guid]::NewGuid().ToString('N').Substring(0,8))
    $path = Join-Path $script:MnaTrialNetworkResults $name
    $State | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
    return $path
}

function Compare-TrialNetworkState {
    [CmdletBinding(DefaultParameterSetName='Object')]
    param(
        [Parameter(Mandatory,ParameterSetName='Object')][psobject]$BaselineState,
        [Parameter(Mandatory,ParameterSetName='File')][string]$BaselinePath,
        [psobject]$CurrentState
    )
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $BaselineState = Get-Content -LiteralPath $BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    if (-not $PSBoundParameters.ContainsKey('CurrentState')) { $CurrentState = Get-TrialNetworkState }
    if ($BaselineState.SchemaVersion -ne 1 -or $CurrentState.SchemaVersion -ne 1 -or -not $BaselineState.Data -or -not $CurrentState.Data) {
        throw 'Both inputs must be Trial-NetworkState schema version 1 snapshots.'
    }
    $sections = @(@($BaselineState.Data.PSObject.Properties.Name) + @($CurrentState.Data.PSObject.Properties.Name) | Sort-Object -Unique)
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($section in $sections) {
        $counts = [System.Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
        foreach ($row in @($BaselineState.Data.$section)) {
            $key = ConvertTo-Json -InputObject $row -Depth 10 -Compress
            if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
            $counts[$key]--
        }
        foreach ($row in @($CurrentState.Data.$section)) {
            $key = ConvertTo-Json -InputObject $row -Depth 10 -Compress
            if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
            $counts[$key]++
        }
        $removed = @(); $added = @()
        foreach ($key in @($counts.Keys | Sort-Object)) {
            for ($index = 0; $index -lt [math]::Abs($counts[$key]); $index++) {
                if ($counts[$key] -lt 0) { $removed += ConvertFrom-Json -InputObject $key }
                else { $added += ConvertFrom-Json -InputObject $key }
            }
        }
        if ($removed.Count -or $added.Count) {
            $changes.Add([pscustomobject]@{Section=$section; Removed=$removed; Added=$added})
        }
    }
    $readable = $BaselineState.Complete -eq $true -and $CurrentState.Complete -eq $true -and
        @($BaselineState.ReadErrors).Count -eq 0 -and @($CurrentState.ReadErrors).Count -eq 0
    [pscustomobject]@{
        ComparedAt = Get-Date -Format o
        BaselineTime = $BaselineState.FinishedAt
        CurrentTime = $CurrentState.FinishedAt
        FullyComparable = $readable
        Equal = ($readable -and $changes.Count -eq 0)
        HasDifferences = ($changes.Count -gt 0)
        BaselineReadErrors = @($BaselineState.ReadErrors)
        CurrentReadErrors = @($CurrentState.ReadErrors)
        Changes = @($changes.ToArray())
    }
}
