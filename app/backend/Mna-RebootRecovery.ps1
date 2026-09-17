# Read-only classification for a completed cleanup from an earlier Windows boot.
# Never replace the original snapshots or use this to reset another application's network.

function ConvertTo-MnaRecoveryInstant {
    param([AllowNull()][object]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    $parsed=[DateTimeOffset]::MinValue
    if ($Value -is [string] -and $Value -match '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$' -and
        [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Test-MnaRebootNetworkRestored {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{24}$')][string]$RunId,
        [Parameter(Mandatory)][object]$Owner,
        [Parameter(Mandatory)][object]$BaselineState,
        [Parameter(Mandatory)][object]$CurrentState,
        [Parameter(Mandatory)][datetime]$BootTime
    )
    try {
        $boot=ConvertTo-MnaRecoveryInstant $BootTime
        $baselineEnd=ConvertTo-MnaRecoveryInstant $BaselineState.FinishedAt
        $rootCreated=ConvertTo-MnaRecoveryInstant $Owner.RootCreated
        $currentStart=ConvertTo-MnaRecoveryInstant $CurrentState.StartedAt
        if (-not $boot -or -not $baselineEnd -or -not $rootCreated -or -not $currentStart -or
            $Owner.RunId -ne $RunId -or $baselineEnd -ge $boot -or $rootCreated -ge $boot -or $currentStart -lt $boot) { return $false }

        $required=@('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')
        foreach ($state in @($BaselineState,$CurrentState)) {
            if ($state.SchemaVersion -ne 1 -or $state.Complete -ne $true -or @($state.ReadErrors).Count -ne 0 -or -not $state.Data) { return $false }
            foreach ($section in $required) {
                if ($section -notin @($state.Data.PSObject.Properties.Name) -or $null -eq $state.Data.$section) { return $false }
            }
        }
        # Every related SDK process must have exited. Shared Wintun/TAP drivers
        # may predate this app, but they must still compare exactly below.
        if (@($CurrentState.Data.RelatedProcesses).Count) { return $false }
        foreach ($section in $required) {
            foreach ($row in @($CurrentState.Data.$section)) {
                foreach ($field in @('Name','InterfaceAlias','InterfaceDescription','DisplayName')) {
                    $value=[string]$row.$field
                    if ($value -match '(?i)(?:^|[^a-z0-9])(?:mna_game_[a-f0-9]+|mp_tun0)(?:$|[^a-z0-9])') { return $false }
                }
                if ($section -in @('RelatedServices','RelatedDrivers') -and
                    (([string]$row.Name+' '+[string]$row.DisplayName) -match '(?i)linkboost|mp-speeder|multipath')) { return $false }
            }
        }

        # Work on private copies: the full unmodified snapshots/diff remain the
        # caller's evidence. GUID is optional for migration from older snapshots.
        $before=$BaselineState | ConvertTo-Json -Depth 18 | ConvertFrom-Json -Depth 18
        $after=$CurrentState | ConvertTo-Json -Depth 18 | ConvertFrom-Json -Depth 18
        $indexMap=@{};$oldNames=@{};$newNames=@{}
        $oldIdentities=@{};$newIdentities=@{};$oldGuids=@{};$newGuids=@{}
        foreach ($side in @('Before','After')) {
            $state=if ($side -eq 'Before') {$before} else {$after}
            $names=if ($side -eq 'Before') {$oldNames} else {$newNames}
            $identities=if ($side -eq 'Before') {$oldIdentities} else {$newIdentities}
            $guids=if ($side -eq 'Before') {$oldGuids} else {$newGuids}
            foreach ($adapter in @($state.Data.Adapters)) {
                # Some Windows hidden adapters have a legitimately empty
                # description. The complete identity must still be unique.
                if ([string]::IsNullOrWhiteSpace($adapter.Name) -or -not $adapter.PSObject.Properties['InterfaceDescription'] -or
                    $adapter.HardwareInterface -isnot [bool] -or $adapter.Virtual -isnot [bool] -or
                    [int]$adapter.ifIndex -le 0 -or $names.ContainsKey([int]$adapter.ifIndex)) { return $false }
                $key=ConvertTo-Json -InputObject @([string]$adapter.Name,[string]$adapter.InterfaceDescription,[bool]$adapter.HardwareInterface) -Compress
                if ($identities.ContainsKey($key)) { return $false }
                $identities[$key]=$adapter
                $names[[int]$adapter.ifIndex]=[string]$adapter.Name
                if ($adapter.InterfaceGuid) {
                    $guid=[guid]::Empty
                    if (-not [guid]::TryParse([string]$adapter.InterfaceGuid,[ref]$guid) -or $guid -eq [guid]::Empty -or $guids.ContainsKey($guid.ToString())) { return $false }
                    $guids[$guid.ToString()]=$true
                }
            }
        }
        if ($oldIdentities.Count -eq 0 -or $oldIdentities.Count -ne $newIdentities.Count) { return $false }
        foreach ($key in $oldIdentities.Keys) {
            if (-not $newIdentities.ContainsKey($key)) { return $false }
            $old=$oldIdentities[$key];$new=$newIdentities[$key]
            if ($old.InterfaceGuid -and (-not $new.InterfaceGuid -or [guid]$old.InterfaceGuid -ne [guid]$new.InterfaceGuid)) { return $false }
            $indexMap[[int]$old.ifIndex]=[int]$new.ifIndex
            $old.ifIndex=$new.ifIndex
        }

        # The loopback/system interfaces omitted by Get-NetAdapter are accepted
        # only at their unchanged index and alias, never inferred from position.
        foreach ($side in @('Before','After')) {
            $state=if ($side -eq 'Before') {$before} else {$after}
            $names=if ($side -eq 'Before') {$oldNames} else {$newNames}
            $other=if ($side -eq 'Before') {$CurrentState} else {$BaselineState}
            foreach ($section in @('Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS')) {
                foreach ($row in @($state.Data.$section)) {
                    $index=[int]$row.InterfaceIndex
                    if ($index -le 0 -or [string]::IsNullOrWhiteSpace($row.InterfaceAlias)) { return $false }
                    # Windows includes %ifIndex in some link-local address
                    # strings. Strip that redundant scope only when it agrees
                    # with this row's original interface identity.
                    if ($row.AddressFamily -eq 'IPv6') {
                        foreach ($field in @('IPAddress','NextHop','DestinationPrefix')) {
                            $value=[string]$row.$field
                            if (-not $value.Contains('%')) { continue }
                            $parts=$value.Split('/')
                            $address=$null
                            if ($parts.Count -gt 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$address) -or
                                $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6 -or
                                -not $address.IsIPv6LinkLocal -or $address.ScopeId -ne $index) { return $false }
                            $address.ScopeId=0
                            $row.$field=$address.ToString()+$(if ($parts.Count -eq 2) {'/'+$parts[1]} else {''})
                        }
                    }
                    if ($names.ContainsKey($index)) {
                        if ($row.InterfaceAlias -cne $names[$index]) { return $false }
                        if ($side -eq 'Before') { $row.InterfaceIndex=$indexMap[$index] }
                    } else {
                        $matches=@($other.Data.Interfaces | Where-Object { $_.InterfaceIndex -eq $index -and $_.InterfaceAlias -ceq $row.InterfaceAlias })
                        if (-not $matches.Count -or ($side -eq 'Before' -and $newNames.ContainsKey($index)) -or
                            ($side -eq 'After' -and $oldNames.ContainsKey($index))) { return $false }
                    }
                }
            }
            # Carrier observations and address readiness are not configuration.
            $state.Data.Adapters=@($state.Data.Adapters | Select-Object -Property * -ExcludeProperty InterfaceGuid,Status,LinkSpeed)
            $state.Data.Interfaces=@($state.Data.Interfaces | Select-Object -Property * -ExcludeProperty ConnectionState)
            $state.Data.IPAddresses=@($state.Data.IPAddresses | Select-Object -Property * -ExcludeProperty AddressState)
        }
        # Native evidence uses the same interface identity as its own snapshot.
        # Rebase only the private copy alongside the corresponding route rows.
        if ($before.RouteOriginEvidence) {
            foreach ($entry in @($before.RouteOriginEvidence.Routes)) {
                $oldIndex=[int]$entry.InterfaceIndex
                if ($indexMap.ContainsKey($oldIndex)) {
                    $hop=$null
                    if ([string]$entry.NextHop -like '*%*') {
                        if (-not [Net.IPAddress]::TryParse([string]$entry.NextHop,[ref]$hop) -or
                            -not $hop.IsIPv6LinkLocal -or $hop.ScopeId -ne $oldIndex) { return $false }
                        $hop.ScopeId=0;$entry.NextHop=$hop.ToString()
                    }
                    $entry.InterfaceIndex=$indexMap[$oldIndex]
                }
            }
        }

        $parseIpv6={
            param($Text)
            $address=$null
            if ([Net.IPAddress]::TryParse([string]$Text,[ref]$address) -and
                $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and $address.ScopeId -eq 0) { return $address }
            return $null
        }
        $addressKey={
            param($Item)
            $address=& $parseIpv6 $Item.IPAddress
            if ($address) { return ([string]$Item.InterfaceIndex+'|'+$address.ToString()) }
            return $null
        }
        $automaticIpv6={
            param($Item)
            $address=& $parseIpv6 $Item.IPAddress
            if (-not $newNames.ContainsKey([int]$Item.InterfaceIndex) -or $Item.AddressFamily -ne 'IPv6' -or
                -not $address -or $Item.Type -ne 1 -or $Item.SkipAsSource -ne $false) { return $false }
            if ($address.IsIPv6LinkLocal) {
                return ($Item.PrefixOrigin -eq 2 -and $Item.SuffixOrigin -eq 4 -and $Item.PrefixLength -eq 64)
            }
            return (-not $address.IsIPv6Multicast -and -not $address.Equals([Net.IPAddress]::IPv6Any) -and
                -not $address.Equals([Net.IPAddress]::IPv6Loopback) -and -not $address.IsIPv4MappedToIPv6 -and
                $Item.PrefixOrigin -eq 4 -and (($Item.SuffixOrigin -eq 4 -and $Item.PrefixLength -eq 64) -or
                ($Item.SuffixOrigin -eq 5 -and $Item.PrefixLength -in @(64,128))))
        }
        $comparison=Compare-TrialNetworkState -BaselineState $before -CurrentState $after
        if (-not $comparison.FullyComparable) { return $false }
        . (Join-Path $PSScriptRoot 'Mna-RouterAdvertisementRecovery.ps1')
        $advertisedRoutes=Get-MnaUiRouterAdvertisementChanges -Comparison $comparison -BaselineState $before -CurrentState $after
        $addresses=@{Removed=@();Added=@()}
        $keys=@{Removed=@();Added=@()}
        foreach ($side in @('Removed','Added')) {
            $addresses[$side]=@($comparison.Changes | Where-Object Section -eq 'IPAddresses' | ForEach-Object { $_.$side })
            $keys[$side]=@($addresses[$side] | ForEach-Object { & $addressKey $_ })
        }
        foreach ($side in @('Removed','Added')) {
            $opposite=if ($side -eq 'Removed') {'Added'} else {'Removed'}
            foreach ($address in $addresses[$side]) {
                # Same-address edits are configuration changes, not rotation.
                if (-not (& $automaticIpv6 $address) -or (& $addressKey $address) -in $keys[$opposite]) { return $false }
            }
        }
        foreach ($change in @($comparison.Changes)) {
            if ($change.Section -eq 'IPAddresses') { continue }
            if ($change.Section -ne 'ActiveRoutes') { return $false }
            foreach ($side in @('Removed','Added')) {
                foreach ($route in @($change.$side)) {
                    if ($advertisedRoutes -and ($route | ConvertTo-Json -Depth 10 -Compress) -cin $advertisedRoutes[$side+'Routes']) { continue }
                    if ($route.AddressFamily -ne 'IPv6' -or $route.Protocol -ne 2 -or $route.RouteMetric -ne 256 -or $route.Publish -ne 0) { return $false }
                    $parts=([string]$route.DestinationPrefix).Split('/')
                    if ($parts.Count -ne 2 -or $parts[1] -cne '128') { return $false }
                    $destination=& $parseIpv6 $parts[0];$nextHop=& $parseIpv6 $route.NextHop
                    if (-not $destination -or -not $nextHop -or -not $nextHop.Equals([Net.IPAddress]::IPv6Any)) { return $false }
                    $key=[string]$route.InterfaceIndex+'|'+$destination.ToString()
                    if ($key -notin $keys[$side]) { return $false }
                }
            }
        }
        return $true
    } catch {
        # Damaged/ambiguous evidence must keep recovery pending, never disable
        # the guards merely because a field could not be parsed.
        return $false
    }
}
