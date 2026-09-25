# Verify an earlier boot's session and the absence of its resources, without
# changing Windows or comparing external network settings with an old baseline.

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

function ConvertTo-MnaRecoveryProcessId {
    param([AllowNull()][object]$Value)
    $processId=0
    if ($null -ne $Value -and [int]::TryParse([string]$Value,[Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,[ref]$processId) -and $processId -gt 0) { return $processId }
    return $null
}

function Test-MnaSessionProcessIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$RunId,
        [Parameter(Mandatory)][AllowNull()][object]$Record,
        [Parameter(Mandatory)][AllowNull()][object]$Owner
    )
    try {
        # Runtime path ownership is separately verified by the caller.
        if ($RunId -notmatch '^[a-f0-9]{24}$' -or -not $Record -or -not $Owner -or
            $Record.RunId -cne $RunId -or $Owner.RunId -cne $RunId) { return $false }
        $now=[DateTimeOffset]::UtcNow
        $workerCreated=ConvertTo-MnaRecoveryInstant $Record.WorkerCreatedUtc
        $rootCreated=ConvertTo-MnaRecoveryInstant $Owner.RootCreated
        $workerId=ConvertTo-MnaRecoveryProcessId $Record.WorkerPid
        $rootId=ConvertTo-MnaRecoveryProcessId $Owner.RootPid
        if (-not $workerCreated -or -not $rootCreated -or -not $workerId -or -not $rootId -or
            $workerCreated -gt $rootCreated -or $workerCreated -gt $now -or $rootCreated -gt $now -or
            $null -eq $Owner.Owned -or @($Owner.Owned).Count -eq 0) { return $false }
        $rootRecorded=$false
        $seenIds=[Collections.Generic.HashSet[int]]::new()
        foreach ($item in @($Owner.Owned)) {
            $ownedId=ConvertTo-MnaRecoveryProcessId $item.Pid
            $created=ConvertTo-MnaRecoveryInstant $item.Created
            if (-not $ownedId -or -not $created -or $created -gt $now -or
                $created -lt $rootCreated.AddTicks(-10) -or -not $seenIds.Add($ownedId)) { return $false }
            # Process.StartTime has 100 ns precision; CIM CreationDate is truncated
            # to microseconds. The previous-boot check applies its own strict boundary.
            if ($ownedId -eq $rootId -and [math]::Abs(($created-$rootCreated).Ticks) -le 10) { $rootRecorded=$true }
        }
        return $rootRecorded
    } catch { return $false }
}

function Test-MnaPreviousBootSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$RunId,
        [Parameter(Mandatory)][AllowNull()][object]$Record,
        [Parameter(Mandatory)][AllowNull()][object]$Owner,
        [Parameter(Mandatory)][AllowNull()][object]$BootTime
    )
    try {
        if (-not (Test-MnaSessionProcessIdentity -RunId $RunId -Record $Record -Owner $Owner)) { return $false }
        $boot=ConvertTo-MnaRecoveryInstant $BootTime
        if (-not $boot -or (ConvertTo-MnaRecoveryInstant $Record.WorkerCreatedUtc) -ge $boot -or
            (ConvertTo-MnaRecoveryInstant $Owner.RootCreated) -ge $boot) { return $false }
        foreach ($item in @($Owner.Owned)) {
            if ((ConvertTo-MnaRecoveryInstant $item.Created) -ge $boot) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-MnaReleasedSessionInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$State)
    try {
        if (-not $State -or $State.SchemaVersion -ne 1 -or $State.Complete -ne $true -or
            -not $State.PSObject.Properties['ReadErrors'] -or $null -eq $State.ReadErrors -or
            @($State.ReadErrors).Count -ne 0 -or -not $State.Data) { return $false }
        $sections=@('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')
        foreach ($section in $sections) {
            if ($section -notin @($State.Data.PSObject.Properties.Name) -or $null -eq $State.Data.$section) { return $false }
        }
        # The collector's RelatedProcesses section contains only SDK executables.
        if (@($State.Data.RelatedProcesses).Count) { return $false }
        foreach ($section in $sections) {
            foreach ($row in @($State.Data.$section)) {
                foreach ($field in @('Name','InterfaceAlias','InterfaceDescription','DisplayName')) {
                    if ([string]$row.$field -match '(?i)mna_game_|mp_tun') { return $false }
                }
                if ($section -in @('RelatedServices','RelatedDrivers') -and
                    (([string]$row.Name+' '+[string]$row.DisplayName) -match '(?i)linkboost|mp-speeder|multipath')) { return $false }
            }
        }
        $isTunEndpoint={
            param($Value)
            $address=$null
            if (-not [Net.IPAddress]::TryParse([string]$Value,[ref]$address)) { return $false }
            if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
            return $address.ToString() -in @('198.18.0.1','198.18.0.2')
        }
        foreach ($row in @($State.Data.IPAddresses)) {
            if (& $isTunEndpoint $row.IPAddress) { return $false }
        }
        foreach ($row in @($State.Data.DNS)) {
            foreach ($server in @($row.ServerAddresses)) {
                if (& $isTunEndpoint $server) { return $false }
            }
        }
        foreach ($row in @($State.Data.ActiveRoutes)+@($State.Data.PersistentRoutes)) {
            if (& $isTunEndpoint $row.NextHop) { return $false }
        }
        $isSdkProxy={
            param($Value)
            foreach ($token in ([string]$Value -split '[;\s]+')) {
                $endpoint=$token -replace '^(?i)(?:https?|ftp|socks[45]?)=',''
                if ([string]::IsNullOrWhiteSpace($endpoint)) { continue }
                if ($endpoint -notmatch '^[a-z][a-z0-9+.-]*://') { $endpoint='http://'+$endpoint }
                $uri=$null
                if ([Uri]::TryCreate($endpoint,[UriKind]::Absolute,[ref]$uri) -and
                    $uri.Host.Trim('[',']') -in @('localhost','127.0.0.1','::1') -and
                    $uri.Port -in @(12345,9801,9803)) { return $true }
            }
            return $false
        }
        foreach ($proxy in @($State.Data.WinINETProxy)) {
            # Disabled registry values and bypass lists are only cached text.
            if ($proxy.ProxyEnable -eq 1 -and
                ((& $isSdkProxy $proxy.ProxyServer) -or (& $isSdkProxy $proxy.CurrentUserConfiguration.Proxy))) { return $false }
        }
        foreach ($proxy in @($State.Data.WinHTTPProxy)) {
            if ($proxy.AccessType -eq 3 -and (& $isSdkProxy $proxy.Proxy)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-MnaRebootSessionReleased {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$RunId,
        [Parameter(Mandatory)][AllowNull()][object]$Record,
        [Parameter(Mandatory)][AllowNull()][object]$Owner,
        [Parameter(Mandatory)][AllowNull()][object]$CurrentState,
        [Parameter(Mandatory)][AllowNull()][object]$BootTime
    )
    try {
        if (-not (Test-MnaPreviousBootSession -RunId $RunId -Record $Record -Owner $Owner -BootTime $BootTime) -or
            -not (Test-MnaReleasedSessionInventory -State $CurrentState)) { return $false }
        $boot=ConvertTo-MnaRecoveryInstant $BootTime
        $started=ConvertTo-MnaRecoveryInstant $CurrentState.StartedAt
        $finished=ConvertTo-MnaRecoveryInstant $CurrentState.FinishedAt
        return ($null -ne $started -and $null -ne $finished -and $started -ge $boot -and $finished -ge $started)
    } catch { return $false }
}
