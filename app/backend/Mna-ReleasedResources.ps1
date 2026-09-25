# Read-only release assessment. Historical network differences are diagnostic:
# external adapter, DHCP, DNS and route changes do not belong to this session.
. (Join-Path $PSScriptRoot 'Mna-RebootRecovery.ps1')

function Get-MnaReleasedResourceAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$CurrentState,
        [AllowNull()][object]$BaselineState
    )
    # BaselineState is deliberately not an authority for release. In particular,
    # Windows can reuse a historical ifIndex for an unrelated, newly added NIC.
    $incomplete=[Collections.Generic.List[string]]::new()
    $remaining=[Collections.Generic.List[string]]::new()
    $result={
        if ($incomplete.Count) {
            return [pscustomobject]@{Released=$false;Classification='InventoryIncomplete';Reasons=@($incomplete.ToArray())+@($remaining.ToArray())}
        }
        if ($remaining.Count) {
            return [pscustomobject]@{Released=$false;Classification='ResourcesRemain';Reasons=@($remaining.ToArray())}
        }
        return [pscustomobject]@{Released=$true;Classification='Released';Reasons=@('CurrentOwnedResourcesAbsent')}
    }
    try {
        if (-not $CurrentState) { $incomplete.Add('CurrentInventoryMissing');return (& $result) }
        if ($CurrentState.SchemaVersion -ne 1) { $incomplete.Add('UnsupportedSchema') }
        if ($CurrentState.Complete -isnot [bool] -or -not $CurrentState.Complete) { $incomplete.Add('CurrentInventoryNotComplete') }
        if (-not $CurrentState.PSObject.Properties['ReadErrors'] -or $null -eq $CurrentState.ReadErrors -or @($CurrentState.ReadErrors).Count) {
            $incomplete.Add('CurrentInventoryReadErrors')
        }
        if (-not $CurrentState.Data) { $incomplete.Add('CurrentInventoryDataMissing');return (& $result) }
        $required=[ordered]@{
            Adapters=@('Name','ifIndex')
            Interfaces=@('InterfaceAlias','InterfaceIndex')
            IPAddresses=@('InterfaceAlias','InterfaceIndex','IPAddress')
            ActiveRoutes=@('InterfaceAlias','InterfaceIndex','NextHop')
            PersistentRoutes=@('InterfaceAlias','InterfaceIndex','NextHop')
            DNS=@('InterfaceAlias','InterfaceIndex','ServerAddresses')
            WinINETProxy=@('ProxyEnable','ProxyServer','CurrentUserConfiguration')
            WinHTTPProxy=@('AccessType','Proxy')
            RelatedProcesses=@('Name')
            RelatedServices=@('Name','DisplayName')
            RelatedDrivers=@('Name','DisplayName')
        }
        foreach ($section in $required.Keys) {
            if (-not $CurrentState.Data.PSObject.Properties[$section] -or $null -eq $CurrentState.Data.$section) {
                $incomplete.Add('MissingSection:'+ $section)
                continue
            }
            foreach ($row in @($CurrentState.Data.$section)) {
                if ($null -eq $row) { $incomplete.Add('InvalidRow:'+ $section);continue }
                foreach ($field in $required[$section]) {
                    if (-not $row.PSObject.Properties[$field]) { $incomplete.Add('MissingField:'+ $section+'.'+$field) }
                }
            }
        }
        if ($incomplete.Count) { return (& $result) }

        $fieldValue={
            param($Row,[string]$Name)
            if ($Row -and $Row.PSObject.Properties[$Name]) { return $Row.$Name }
            return $null
        }
        $isOwnedName={
            param($Row)
            foreach ($field in @('Name','InterfaceAlias','InterfaceDescription','DisplayName')) {
                if ([string](& $fieldValue $Row $field) -match '(?i)mna_game_|mp_tun') { return $true }
            }
            return $false
        }
        $isTunEndpoint={
            param($Value)
            $address=$null
            if (-not [Net.IPAddress]::TryParse([string]$Value,[ref]$address)) { return $false }
            if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
            return $address.ToString() -in @('198.18.0.1','198.18.0.2')
        }
        $ownedIndices=[Collections.Generic.HashSet[int]]::new()
        foreach ($section in $required.Keys) {
            foreach ($row in @($CurrentState.Data.$section)) {
                $owned=& $isOwnedName $row
                if ($owned) { $remaining.Add('OwnedIdentity:'+ $section) }
                if ($section -in @('RelatedServices','RelatedDrivers') -and
                    (([string]$row.Name+' '+[string]$row.DisplayName) -match '(?i)linkboost|mp-speeder|multipath')) {
                    $remaining.Add('OwnedSdkResource:'+ $section)
                }
                if ($section -eq 'IPAddresses' -and (& $isTunEndpoint $row.IPAddress)) {
                    $owned=$true;$remaining.Add('OwnedTunAddress')
                }
                if ($section -eq 'DNS') {
                    if ($null -eq $row.ServerAddresses) { $incomplete.Add('InvalidDnsInventory') }
                    foreach ($server in @($row.ServerAddresses)) {
                        if (& $isTunEndpoint $server) { $remaining.Add('OwnedTunDns') }
                    }
                }
                if ($section -in @('ActiveRoutes','PersistentRoutes') -and (& $isTunEndpoint $row.NextHop)) {
                    $remaining.Add('OwnedTunNextHop:'+ $section)
                }
                # A name or the TUN's assigned local IP proves interface ownership.
                # DNS server/next-hop addresses do not: a physical NIC may point at
                # a leftover TUN resolver or gateway without belonging to the SDK.
                if ($owned) {
                    $indexText=if ($section -eq 'Adapters') { & $fieldValue $row 'ifIndex' } else { & $fieldValue $row 'InterfaceIndex' }
                    $index=0
                    if ([int]::TryParse([string]$indexText,[ref]$index) -and $index -gt 0) { $null=$ownedIndices.Add($index) }
                }
            }
        }
        if (@($CurrentState.Data.RelatedProcesses).Count) { $remaining.Add('OwnedSdkProcess') }
        foreach ($section in @('Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS')) {
            foreach ($row in @($CurrentState.Data.$section)) {
                $index=0
                if (-not [int]::TryParse([string]$row.InterfaceIndex,[ref]$index) -or $index -le 0) {
                    $incomplete.Add('InvalidInterfaceIndex:'+ $section)
                } elseif ($ownedIndices.Contains($index)) {
                    # Covers routes with an empty/stale InterfaceAlias, even when
                    # the pre-start baseline did not contain the disposable TUN.
                    $remaining.Add('OwnedInterfaceIndex:'+ $section)
                }
            }
        }
        $isSdkProxy={
            param($Value)
            foreach ($token in ([string]$Value -split '[;\s]+')) {
                $endpoint=$token -replace '^(?i)(?:https?|ftp|socks[45]?)=',''
                if ([string]::IsNullOrWhiteSpace($endpoint)) { continue }
                if ($endpoint -notmatch '^[a-z][a-z0-9+.-]*://') { $endpoint='http://'+$endpoint }
                $uri=$null
                if (-not [Uri]::TryCreate($endpoint,[UriKind]::Absolute,[ref]$uri) -or $uri.Port -notin @(12345,9801,9803)) { continue }
                $hostName=$uri.Host.Trim('[',']').TrimEnd('.')
                if ($hostName -ieq 'localhost') { return $true }
                $address=$null
                if ([Net.IPAddress]::TryParse($hostName,[ref]$address)) {
                    if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
                    if ([Net.IPAddress]::IsLoopback($address)) { return $true }
                }
            }
            return $false
        }
        foreach ($proxy in @($CurrentState.Data.WinINETProxy)) {
            # A null ProxyEnable is a missing optional registry value (= disabled).
            if ($null -ne $proxy.ProxyEnable -and $proxy.ProxyEnable -notin @(0,1)) { $incomplete.Add('InvalidWinInetProxyMode') }
            if (-not $proxy.CurrentUserConfiguration -or -not $proxy.CurrentUserConfiguration.PSObject.Properties['Proxy']) {
                $incomplete.Add('MissingCurrentUserProxyConfiguration');continue
            }
            if ($proxy.ProxyEnable -eq 1 -and
                ((& $isSdkProxy $proxy.ProxyServer) -or (& $isSdkProxy $proxy.CurrentUserConfiguration.Proxy))) {
                $remaining.Add('OwnedWinInetProxy')
            }
            # WinHttpGetIEProxyConfigForCurrentUser returns the effective PAC URL.
            # Cached disabled manual proxy strings and bypass lists are harmless.
            if (& $isSdkProxy (& $fieldValue $proxy.CurrentUserConfiguration 'AutoConfigURL')) { $remaining.Add('OwnedWinInetAutoConfig') }
        }
        foreach ($proxy in @($CurrentState.Data.WinHTTPProxy)) {
            if ($null -eq $proxy.AccessType -or $proxy.AccessType -notin @(0,1,3,4)) { $incomplete.Add('InvalidWinHttpProxyMode') }
            if ($proxy.AccessType -eq 3 -and (& $isSdkProxy $proxy.Proxy)) { $remaining.Add('OwnedWinHttpProxy') }
        }
        # Keep the original release inventory guard as a floor. Additional checks
        # must never accidentally make an SDK remnant accepted by a newer caller.
        if (-not (Test-MnaReleasedSessionInventory -State $CurrentState) -and -not $remaining.Count -and -not $incomplete.Count) {
            $incomplete.Add('ReleaseInventoryRejected')
        }
    } catch {
        $incomplete.Add('ReleaseInventoryInvalid')
    }
    return (& $result)
}
