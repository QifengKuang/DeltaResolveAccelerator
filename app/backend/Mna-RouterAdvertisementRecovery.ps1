# Classify narrowly evidenced IPv6 router-advertisement changes without changing
# routes, querying Windows, or rewriting the caller's snapshots/comparison.

function Get-MnaUiRouterAdvertisementChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Comparison,
        [AllowNull()][object]$BaselineState,
        [AllowNull()][object]$CurrentState
    )
    try {
        if (-not $BaselineState -or -not $CurrentState) { return $null }
        $sections=@('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')
        foreach ($state in @($BaselineState,$CurrentState)) {
            if ($state.SchemaVersion -ne 1 -or $state.Complete -ne $true -or @($state.ReadErrors).Count -ne 0 -or -not $state.Data) { return $null }
            foreach ($section in $sections) {
                if ($section -notin @($state.Data.PSObject.Properties.Name) -or $null -eq $state.Data.$section) { return $null }
            }
        }
        $actual=Compare-TrialNetworkState -BaselineState $BaselineState -CurrentState $CurrentState
        if (-not $Comparison.FullyComparable -or -not $actual.FullyComparable -or
            (ConvertTo-Json -InputObject @($actual.Changes) -Depth 12 -Compress) -cne
            (ConvertTo-Json -InputObject @($Comparison.Changes) -Depth 12 -Compress)) { return $null }

        if (@($CurrentState.Data.RelatedProcesses).Count) { return $null }
        foreach ($section in $sections) {
            foreach ($row in @($CurrentState.Data.$section)) {
                foreach ($field in @('Name','InterfaceAlias','InterfaceDescription','DisplayName')) {
                    if ([string]$row.$field -match '(?i)mna_game_|mp_tun') { return $null }
                }
                if ($section -in @('RelatedServices','RelatedDrivers') -and
                    (([string]$row.Name+' '+[string]$row.DisplayName) -match '(?i)linkboost|mp-speeder|multipath')) { return $null }
            }
        }
        # An absent old field is a legacy snapshot. Failed/incomplete evidence
        # is never treated as absence, and Origin=3 must be proven by native data.
        $legacy=-not [bool]$BaselineState.PSObject.Properties['RouteOriginEvidence']
        foreach ($state in @($CurrentState) + $(if (-not $legacy) {@($BaselineState)} else {@()})) {
            $evidence=$state.RouteOriginEvidence
            if (-not $state.PSObject.Properties['RouteOriginEvidence'] -or -not $evidence -or
                $evidence.Complete -ne $true -or -not $evidence.PSObject.Properties['Routes'] -or $null -eq $evidence.Routes) { return $null }
        }

        $parseAddress={
            param($Text,[int]$Index)
            $address=$null
            if (-not [Net.IPAddress]::TryParse([string]$Text,[ref]$address) -or
                $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6 -or
                ($address.ScopeId -ne 0 -and ($address.ScopeId -ne $Index -or -not $address.IsIPv6LinkLocal))) { return $null }
            $address.ScopeId=0
            return $address
        }
        $parsePrefix={
            param($Text,[int]$Index)
            $parts=([string]$Text).Split('/')
            if ($parts.Count -ne 2 -or $parts[1] -cne '64' -or $parts[0].Contains('%')) { return $null }
            $address=& $parseAddress $parts[0] $Index
            if (-not $address -or $parts[0] -ine $address.ToString()) { return $null }
            $bytes=$address.GetAddressBytes()
            if (($bytes[0] -band 0xfe) -ne 0xfc) { return $null }
            for ($i=8;$i -lt 16;$i++) { if ($bytes[$i] -ne 0) { return $null } }
            return ($address.ToString()+'/64')
        }
        $routeKey={
            param($Route)
            if ([int]$Route.InterfaceIndex -le 0) { return $null }
            $prefix=& $parsePrefix $Route.DestinationPrefix ([int]$Route.InterfaceIndex)
            $hop=& $parseAddress $Route.NextHop ([int]$Route.InterfaceIndex)
            if (-not $prefix -or -not $hop -or (-not $hop.IsIPv6LinkLocal -and -not $hop.Equals([Net.IPAddress]::IPv6Any))) { return $null }
            return ([string]$Route.InterfaceIndex+'|'+$prefix+'|'+$hop.ToString())
        }
        $hasNativeOrigin={
            param($State,$Route)
            $key=& $routeKey $Route
            if (-not $key) { return $false }
            $matching=@($State.RouteOriginEvidence.Routes | Where-Object { (& $routeKey $_) -ceq $key })
            # Duplicate native identities are ambiguous even if origins agree.
            return ($matching.Count -eq 1 -and $matching[0].Origin -eq 3)
        }
        $stableInterface={
            param($Route)
            $index=[int]$Route.InterfaceIndex
            $adapters=@();$interfaces=@()
            foreach ($state in @($BaselineState,$CurrentState)) {
                $foundAdapters=@($state.Data.Adapters | Where-Object ifIndex -eq $index)
                if ($foundAdapters.Count -ne 1) { return $false }
                $adapter=$foundAdapters[0]
                if ($adapter.HardwareInterface -ne $true -or $adapter.Virtual -ne $false -or
                    [string]::IsNullOrWhiteSpace($adapter.Name) -or -not $adapter.PSObject.Properties['InterfaceDescription'] -or
                    $adapter.Name -cne $Route.InterfaceAlias) { return $false }
                $adapters+=ConvertTo-Json -InputObject ($adapter | Select-Object -Property * -ExcludeProperty Status,LinkSpeed) -Depth 8 -Compress
                $foundInterfaces=@($state.Data.Interfaces | Where-Object { $_.InterfaceIndex -eq $index -and $_.AddressFamily -eq 'IPv6' })
                if ($foundInterfaces.Count -ne 1) { return $false }
                $interface=$foundInterfaces[0]
                foreach ($field in @('InterfaceAlias','InterfaceIndex','AddressFamily','NlMtuBytes','InterfaceMetric','Dhcp','RouterDiscovery','Forwarding','WeakHostSend','WeakHostReceive')) {
                    if (-not $interface.PSObject.Properties[$field]) { return $false }
                }
                if ($interface.InterfaceAlias -cne $adapter.Name -or $interface.RouterDiscovery -ne 1) { return $false }
                $interfaces+=ConvertTo-Json -InputObject ($interface | Select-Object -Property * -ExcludeProperty ConnectionState) -Depth 8 -Compress
                # No persistent route to this interface/prefix may be masked by
                # an active RA route that happens to use the same destination.
                foreach ($persistent in @($state.Data.PersistentRoutes)) {
                    if ($persistent.InterfaceIndex -eq $index -and
                        (& $parsePrefix $persistent.DestinationPrefix $index) -ceq (& $parsePrefix $Route.DestinationPrefix $index)) { return $false }
                }
            }
            return ($adapters[0] -ceq $adapters[1] -and $interfaces[0] -ceq $interfaces[1])
        }
        $eligibleRoute={
            param($State,$Route)
            foreach ($field in @('InterfaceAlias','InterfaceIndex','AddressFamily','DestinationPrefix','NextHop','RouteMetric','Protocol','Publish')) {
                if (-not $Route.PSObject.Properties[$field]) { return $false }
            }
            if ($Route.AddressFamily -ne 'IPv6' -or $Route.Protocol -ne 3 -or $Route.RouteMetric -ne 256 -or $Route.Publish -ne 0) { return $false }
            $key=& $routeKey $Route
            if (-not $key -or -not (& $stableInterface $Route)) { return $false }
            $sameIdentity=@($State.Data.ActiveRoutes | Where-Object { (& $routeKey $_) -ceq $key })
            return ($sameIdentity.Count -eq 1)
        }

        $changes=@($Comparison.Changes | Where-Object Section -eq 'ActiveRoutes')
        if ($changes.Count -ne 1) { return $null }
        $removed=@($changes[0].Removed);$added=@($changes[0].Added)
        $allowedRemoved=[Collections.Generic.List[string]]::new()
        $allowedAdded=[Collections.Generic.List[string]]::new()
        $legacyReplacementCount=0
        if ($legacy) {
            foreach ($old in $removed) {
                if (-not (& $eligibleRoute $BaselineState $old)) { continue }
                $prefix=& $parsePrefix $old.DestinationPrefix ([int]$old.InterfaceIndex)
                $oldHop=& $parseAddress $old.NextHop ([int]$old.InterfaceIndex)
                if (-not $oldHop.IsIPv6LinkLocal) { continue }
                # Migration only recognizes a one-for-one replacement of an
                # already present route, not unknown legacy additions/removals.
                $oldGroup=@($removed | Where-Object { $_.InterfaceIndex -eq $old.InterfaceIndex -and
                    (& $parsePrefix $_.DestinationPrefix ([int]$_.InterfaceIndex)) -ceq $prefix })
                $newGroup=@($added | Where-Object { $_.InterfaceIndex -eq $old.InterfaceIndex -and
                    (& $parsePrefix $_.DestinationPrefix ([int]$_.InterfaceIndex)) -ceq $prefix })
                if ($oldGroup.Count -ne 1 -or $newGroup.Count -ne 1) { continue }
                $new=$newGroup[0]
                if (-not (& $eligibleRoute $CurrentState $new) -or -not (& $hasNativeOrigin $CurrentState $new)) { continue }
                $newHop=& $parseAddress $new.NextHop ([int]$new.InterfaceIndex)
                if (-not $newHop.IsIPv6LinkLocal -or $newHop.Equals($oldHop) -or
                    (ConvertTo-Json -InputObject ($old | Select-Object -Property * -ExcludeProperty NextHop) -Depth 10 -Compress) -cne
                    (ConvertTo-Json -InputObject ($new | Select-Object -Property * -ExcludeProperty NextHop) -Depth 10 -Compress)) { continue }
                $allowedRemoved.Add((ConvertTo-Json -InputObject $old -Depth 10 -Compress))
                $allowedAdded.Add((ConvertTo-Json -InputObject $new -Depth 10 -Compress))
                $legacyReplacementCount++
            }
        } else {
            foreach ($side in @('Removed','Added')) {
                $state=if ($side -eq 'Removed') {$BaselineState} else {$CurrentState}
                $routes=if ($side -eq 'Removed') {$removed} else {$added}
                foreach ($route in $routes) {
                    if (-not (& $eligibleRoute $state $route) -or -not (& $hasNativeOrigin $state $route)) { continue }
                    $json=ConvertTo-Json -InputObject $route -Depth 10 -Compress
                    if ($side -eq 'Removed') { $allowedRemoved.Add($json) } else { $allowedAdded.Add($json) }
                }
            }
        }
        if ($allowedRemoved.Count -eq 0 -and $allowedAdded.Count -eq 0) { return $null }
        return @{RemovedRoutes=@($allowedRemoved.ToArray());AddedRoutes=@($allowedAdded.ToArray());LegacyReplacementCount=$legacyReplacementCount}
    } catch {
        return $null
    }
}
