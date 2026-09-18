#requires -Version 7.0
# Fabricated records and snapshots only. No live process/network state is read.
$ErrorActionPreference='Stop'
$backend=Join-Path (Split-Path $PSScriptRoot -Parent) 'app/backend'
. (Join-Path $backend 'Mna-RebootRecovery.ps1')
function Get-NetAdapter { throw 'Fixture must not query network adapters' }
function Get-NetRoute { throw 'Fixture must not query routes' }
function Get-CimInstance { throw 'Fixture must not query processes or Windows' }
function Get-TrialNetworkState { throw 'Fixture must not query network state' }
function Get-TrialRouteOriginEvidence { throw 'Fixture must not query native route origins' }
function Stop-Process { throw 'Fixture must not stop processes' }
function Set-DnsClientServerAddress { throw 'Fixture must not change DNS' }
function New-NetRoute { throw 'Fixture must not change routes' }
$script:rebootChecks=0

function New-RebootFixture {
    $run='abcdef123456789012345678'
    [pscustomobject]@{
        RunId=$run
        Record=[pscustomobject]@{RunId=$run;WorkerPid=4101;WorkerCreatedUtc='2026-09-16T01:00:00Z'}
        Owner=[pscustomobject]@{
            RunId=$run;RootPid=4201;RootCreated='2026-09-16T01:00:02Z';Runtime='C:\Fixture\runtime'
            Owned=@(
                [pscustomobject]@{Pid=4201;Created='2026-09-16T01:00:02Z'},
                [pscustomobject]@{Pid=4202;Created='2026-09-16T01:00:03Z'},
                [pscustomobject]@{Pid=4203;Created='2026-09-16T01:00:04Z'}
            )
        }
        Boot=[datetime]'2026-09-17T00:00:00Z'
        Current=[pscustomobject]@{
            SchemaVersion=1;StartedAt='2026-09-17T01:00:00Z';FinishedAt='2026-09-17T01:00:02Z';Complete=$true;ReadErrors=@()
            Data=[pscustomobject]@{
                Adapters=@(
                    [pscustomobject]@{Name='Wi-Fi';InterfaceDescription='Fixture wireless';ifIndex=17;Status='Up';LinkSpeed='866 Mbps';Virtual=$false;HardwareInterface=$true},
                    [pscustomobject]@{Name='vEthernet (WSL)';InterfaceDescription='Fixture Hyper-V';ifIndex=32;Status='Up';Virtual=$true;HardwareInterface=$false},
                    [pscustomobject]@{Name='Tailscale';InterfaceDescription='Fixture shared tunnel';ifIndex=28;Status='Up';Virtual=$true;HardwareInterface=$false}
                )
                Interfaces=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';InterfaceMetric=20;Dhcp=1;RouterDiscovery=1})
                IPAddresses=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';IPAddress='192.0.2.10';PrefixLength=24})
                ActiveRoutes=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=0;Protocol=3;Publish=0})
                PersistentRoutes=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';DestinationPrefix='198.51.100.0/24';NextHop='192.0.2.1';RouteMetric=5;Protocol=3;Publish=0})
                DNS=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily=2;ServerAddresses=@('192.0.2.53','192.0.2.54')})
                WinINETProxy=@([pscustomobject]@{ProxyEnable=0;ProxyServer=$null;ProxyOverride=$null;AutoConfigURL=$null;CurrentUserConfiguration=[pscustomobject]@{Proxy=$null;Bypass=$null;AutoDetect=$true}})
                WinHTTPProxy=@([pscustomobject]@{AccessType=1;Proxy=$null;Bypass=$null})
                RelatedProcesses=@();RelatedServices=@()
                RelatedDrivers=@([pscustomobject]@{Name='wintun';DisplayName='Shared Wintun';State='Running';StartMode='Manual';Started=$true})
            }
        }
    }
}

function Assert-RebootFixture {
    param([string]$Name,[scriptblock]$Edit={},[bool]$Expected=$false,[bool]$ExpectedPreviousBoot=$true,[Nullable[bool]]$ExpectedIdentity=$null)
    $fixture=New-RebootFixture
    & $Edit $fixture
    $original=$fixture | ConvertTo-Json -Depth 20 -Compress
    $identity=Test-MnaSessionProcessIdentity -RunId $fixture.RunId -Record $fixture.Record -Owner $fixture.Owner
    $previous=Test-MnaPreviousBootSession -RunId $fixture.RunId -Record $fixture.Record -Owner $fixture.Owner -BootTime $fixture.Boot
    $released=Test-MnaRebootSessionReleased -RunId $fixture.RunId -Record $fixture.Record -Owner $fixture.Owner -CurrentState $fixture.Current -BootTime $fixture.Boot
    if ($null -ne $ExpectedIdentity -and $identity -ne $ExpectedIdentity) { throw "Session identity fixture failed: $Name (expected $ExpectedIdentity, got $identity)" }
    if ($previous -ne $ExpectedPreviousBoot) { throw "Previous-boot fixture failed: $Name (expected $ExpectedPreviousBoot, got $previous)" }
    if ($released -ne $Expected) { throw "Reboot fixture failed: $Name (expected $Expected, got $released)" }
    if (($fixture | ConvertTo-Json -Depth 20 -Compress) -cne $original) { throw "Reboot fixture mutated evidence: $Name" }
    $script:rebootChecks++
}

Assert-RebootFixture 'earlier boot session is released without a historical network baseline' {} $true
Assert-RebootFixture 'same instant with different explicit UTC offsets matches the root identity' {
    param($f) $f.Owner.RootCreated='2026-09-16T11:00:02+10:00'
} $true
Assert-RebootFixture 'real Process.StartTime and CIM microsecond precision are compatible' {
    param($f)
    $f.Record.WorkerCreatedUtc='2026-09-18T08:15:15.2328804Z'
    $f.Owner.RootCreated='2026-09-18T18:15:19.2577659+10:00'
    $f.Owner.Owned[0].Created='2026-09-18T18:15:19.257765+10:00'
    $f.Owner.Owned[1].Created='2026-09-18T18:15:20+10:00'
    $f.Owner.Owned[2].Created='2026-09-18T18:15:21+10:00'
    $f.Boot=[datetimeoffset]'2026-09-18T20:22:38.5+10:00'
    $f.Current.StartedAt='2026-09-18T20:23:00+10:00'
    $f.Current.FinishedAt='2026-09-18T20:23:02+10:00'
} $true
Assert-RebootFixture 'root identity tolerance includes exactly one microsecond' {
    param($f) $f.Owner.Owned[0].Created=([datetimeoffset]$f.Owner.RootCreated).AddTicks(10)
} $true
Assert-RebootFixture 'root identity tolerance cannot exceed one microsecond' {
    param($f) $f.Owner.Owned[0].Created=([datetimeoffset]$f.Owner.RootCreated).AddTicks(11)
} $false $false
Assert-RebootFixture 'precision tolerance does not permit an owned process on this boot' {
    param($f)
    $f.Owner.RootCreated=([datetimeoffset]$f.Boot).AddTicks(-1)
    $f.Owner.Owned[0].Created=[datetimeoffset]$f.Boot
    $f.Owner.Owned[1].Created=$f.Owner.RootCreated
    $f.Owner.Owned[2].Created=$f.Owner.RootCreated
} $false $false $true
Assert-RebootFixture 'worker must precede the SDK root even without a boot comparison' {
    param($f) $f.Record.WorkerCreatedUtc='2026-09-16T01:00:03Z'
} $false $false $false
Assert-RebootFixture 'owned child cannot predate the SDK root' {
    param($f) $f.Owner.Owned[1].Created='2026-09-16T01:00:01Z'
} $false $false $false
Assert-RebootFixture 'duplicate owned PID cannot provide two process identities' {
    param($f) $f.Owner.Owned[1].Pid=$f.Owner.Owned[0].Pid
} $false $false $false
Assert-RebootFixture 'future process times are rejected even with an internally ordered future boot' {
    param($f)
    $future=[DateTimeOffset]::UtcNow.AddHours(1)
    $f.Record.WorkerCreatedUtc=$future
    $f.Owner.RootCreated=$future.AddSeconds(1)
    for($i=0;$i -lt $f.Owner.Owned.Count;$i++) {$f.Owner.Owned[$i].Created=$future.AddSeconds(1+$i)}
    $f.Boot=$future.AddHours(1)
    $f.Current.StartedAt=$f.Boot.AddSeconds(1)
    $f.Current.FinishedAt=$f.Boot.AddSeconds(2)
} $false $false $false
Assert-RebootFixture 'one future owned child invalidates an otherwise old identity' {
    param($f) $f.Owner.Owned[1].Created=[DateTimeOffset]::UtcNow.AddHours(1)
} $false $false $false

foreach ($kind in @('InvalidRun','RecordRunMismatch','OwnerRunMismatch','MissingRecord','MissingOwner','UnknownBoot','BadBoot','SameBoot','WorkerAtBoot','WorkerAfterBoot','RootAtBoot','RootAfterBoot','OwnedAtBoot','OwnedAfterBoot','BadWorkerTime','BadRootTime','BadOwnedTime','WorkerNoOffset','RootNoOffset','OwnedNoOffset','UnspecifiedDateTime','ZeroWorkerPid','NegativeWorkerPid','FractionalWorkerPid','OverflowWorkerPid','ZeroRootPid','BadOwnedPid','MissingOwned','EmptyOwned','MissingRootPid','MismatchedRootTime')) {
    Assert-RebootFixture $kind {
        param($f)
        switch ($kind) {
            'InvalidRun' {$f.RunId='invalid'}
            'RecordRunMismatch' {$f.Record.RunId='111111111111111111111111'}
            'OwnerRunMismatch' {$f.Owner.RunId='111111111111111111111111'}
            'MissingRecord' {$f.Record=$null}
            'MissingOwner' {$f.Owner=$null}
            'UnknownBoot' {$f.Boot=$null}
            'BadBoot' {$f.Boot='broken'}
            'SameBoot' {$f.Boot=[datetime]'2026-09-15T00:00:00Z'}
            'WorkerAtBoot' {$f.Record.WorkerCreatedUtc='2026-09-17T00:00:00Z'}
            'WorkerAfterBoot' {$f.Record.WorkerCreatedUtc='2026-09-17T00:00:01Z'}
            'RootAtBoot' {$f.Owner.RootCreated='2026-09-17T00:00:00Z';$f.Owner.Owned[0].Created=$f.Owner.RootCreated}
            'RootAfterBoot' {$f.Owner.RootCreated='2026-09-17T00:00:01Z';$f.Owner.Owned[0].Created=$f.Owner.RootCreated}
            'OwnedAtBoot' {$f.Owner.Owned[1].Created='2026-09-17T00:00:00Z'}
            'OwnedAfterBoot' {$f.Owner.Owned[1].Created='2026-09-17T00:00:01Z'}
            'BadWorkerTime' {$f.Record.WorkerCreatedUtc='broken'}
            'BadRootTime' {$f.Owner.RootCreated='broken'}
            'BadOwnedTime' {$f.Owner.Owned[1].Created='broken'}
            'WorkerNoOffset' {$f.Record.WorkerCreatedUtc='2026-09-16T01:00:00'}
            'RootNoOffset' {$f.Owner.RootCreated='2026-09-16T01:00:02'}
            'OwnedNoOffset' {$f.Owner.Owned[1].Created='2026-09-16T01:00:03'}
            'UnspecifiedDateTime' {$f.Record.WorkerCreatedUtc=[datetime]::SpecifyKind([datetime]'2026-09-16T01:00:00',[DateTimeKind]::Unspecified)}
            'ZeroWorkerPid' {$f.Record.WorkerPid=0}
            'NegativeWorkerPid' {$f.Record.WorkerPid=-1}
            'FractionalWorkerPid' {$f.Record.WorkerPid=4101.5}
            'OverflowWorkerPid' {$f.Record.WorkerPid='2147483648'}
            'ZeroRootPid' {$f.Owner.RootPid=0}
            'BadOwnedPid' {$f.Owner.Owned[1].Pid='invalid'}
            'MissingOwned' {$f.Owner.PSObject.Properties.Remove('Owned')}
            'EmptyOwned' {$f.Owner.Owned=@()}
            'MissingRootPid' {$f.Owner.Owned[0].Pid=9999}
            'MismatchedRootTime' {$f.Owner.Owned[0].Created='2026-09-16T01:00:01Z'}
        }
    } $false $false
}

foreach ($kind in @('MissingSnapshot','WrongSchema','IncompleteSnapshot','ReadError','MissingReadErrors','NullReadErrors','NoStartedAt','NoFinishedAt','StartBeforeBoot','FinishBeforeStart','BadStartedAt','BadFinishedAt','StartNoOffset','FinishNoOffset','NoData')) {
    Assert-RebootFixture $kind {
        param($f)
        switch ($kind) {
            'MissingSnapshot' {$f.Current=$null}
            'WrongSchema' {$f.Current.SchemaVersion=2}
            'IncompleteSnapshot' {$f.Current.Complete=$false}
            'ReadError' {$f.Current.ReadErrors=@([pscustomobject]@{Section='Adapters';ErrorType='Fixture'})}
            'MissingReadErrors' {$f.Current.PSObject.Properties.Remove('ReadErrors')}
            'NullReadErrors' {$f.Current.ReadErrors=$null}
            'NoStartedAt' {$f.Current.PSObject.Properties.Remove('StartedAt')}
            'NoFinishedAt' {$f.Current.PSObject.Properties.Remove('FinishedAt')}
            'StartBeforeBoot' {$f.Current.StartedAt='2026-09-16T23:59:59Z'}
            'FinishBeforeStart' {$f.Current.FinishedAt='2026-09-17T00:59:59Z'}
            'BadStartedAt' {$f.Current.StartedAt='broken'}
            'BadFinishedAt' {$f.Current.FinishedAt='broken'}
            'StartNoOffset' {$f.Current.StartedAt='2026-09-17T01:00:00'}
            'FinishNoOffset' {$f.Current.FinishedAt='2026-09-17T01:00:02'}
            'NoData' {$f.Current.Data=$null}
        }
    }
}
foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')) {
    Assert-RebootFixture ('missing current section '+$section) {param($f) $f.Current.Data.PSObject.Properties.Remove($section)}
    Assert-RebootFixture ('null current section '+$section) {param($f) $f.Current.Data.$section=$null}
}
foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS')) {
    foreach ($name in @('mna_game_abcdef','mp_tun0')) {
        Assert-RebootFixture ('leftover '+$section+'/'+$name) {
            param($f)
            $row=$f.Current.Data.$section[0]
            if ($section -eq 'Adapters') {$row.Name=$name} else {$row.InterfaceAlias=$name}
        }
    }
}
Assert-RebootFixture 'TUN identity in adapter description also prevents success' {
    param($f) $f.Current.Data.Adapters[0].InterfaceDescription='mna_game_abcdef driver'
}
foreach ($name in @('linkboost.exe','linkboost-core.exe','multipath-helper.exe','mp-speeder.exe')) {
    Assert-RebootFixture ('remaining SDK process '+$name) {param($f) $f.Current.Data.RelatedProcesses=@([pscustomobject]@{Name=$name;ProcessId=999})}
}
foreach ($section in @('RelatedServices','RelatedDrivers')) {
    foreach ($name in @('linkboost','mp-speeder','multipath')) {
        Assert-RebootFixture ('remaining '+$section+'/'+$name) {param($f) $f.Current.Data.$section=@([pscustomobject]@{Name='Fixture';DisplayName=$name;State='Stopped'})}
    }
}
foreach ($address in @('198.18.0.1','198.18.0.2')) {
    Assert-RebootFixture ('leftover TUN address '+$address) {param($f) $f.Current.Data.IPAddresses[0].IPAddress=$address}
    Assert-RebootFixture ('leftover TUN DNS '+$address) {param($f) $f.Current.Data.DNS[0].ServerAddresses=@($address)}
    foreach ($section in @('ActiveRoutes','PersistentRoutes')) {
        Assert-RebootFixture ('leftover TUN next-hop '+$section+'/'+$address) {param($f) $f.Current.Data.$section[0].NextHop=$address}
    }
}
foreach ($endpoint in @('127.0.0.1:12345','http=localhost:9801;https=proxy.example:8080','socks=[::1]:9803')) {
    Assert-RebootFixture ('enabled WinINET proxy uses SDK endpoint '+$endpoint) {param($f) $f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].ProxyServer=$endpoint}
    Assert-RebootFixture ('enabled WinHTTP proxy uses SDK endpoint '+$endpoint) {param($f) $f.Current.Data.WinHTTPProxy[0].AccessType=3;$f.Current.Data.WinHTTPProxy[0].Proxy=$endpoint}
}
Assert-RebootFixture 'effective enabled user proxy uses an SDK endpoint' {
    param($f) $f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].CurrentUserConfiguration.Proxy='http://127.0.0.1:12345'
}

foreach ($kind in @('DhcpAddress','ApipaAddress','IPv6Addresses','AdapterAdded','AdapterRemoved','InterfaceRenumbered','InterfaceMetric','StaticNetworkConfiguration','DefaultGateway','PersistentExternalRoute','TailscaleAndWsl','ExternalDNS','ExternalProxies','DisabledProxyCache','ProxyBypassText','OtherBenchmarkAddresses','PublicAccelerationTargets','NoOriginEvidence')) {
    Assert-RebootFixture ('external current network state is independent: '+$kind) {
        param($f)
        switch ($kind) {
            'DhcpAddress' {$f.Current.Data.IPAddresses[0].IPAddress='192.0.2.123'}
            'ApipaAddress' {$f.Current.Data.IPAddresses[0].IPAddress='169.254.23.45';$f.Current.Data.IPAddresses[0].PrefixLength=16}
            'IPv6Addresses' {$f.Current.Data.IPAddresses=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily='IPv6';IPAddress='fd12:3456::123';PrefixLength=64})}
            'AdapterAdded' {$f.Current.Data.Adapters+=[pscustomobject]@{Name='New Ethernet';InterfaceDescription='New external adapter';ifIndex=70}}
            'AdapterRemoved' {$f.Current.Data.Adapters=@()}
            'InterfaceRenumbered' {$f.Current.Data.Adapters[0].ifIndex=71;$f.Current.Data.Interfaces[0].InterfaceIndex=71}
            'InterfaceMetric' {$f.Current.Data.Interfaces[0].InterfaceMetric=55;$f.Current.Data.ActiveRoutes[0].RouteMetric=100}
            'StaticNetworkConfiguration' {$f.Current.Data.Interfaces[0].Dhcp=0;$f.Current.Data.Interfaces[0].RouterDiscovery=0}
            'DefaultGateway' {$f.Current.Data.ActiveRoutes[0].NextHop='192.0.2.254'}
            'PersistentExternalRoute' {$f.Current.Data.PersistentRoutes[0].DestinationPrefix='203.0.113.0/24';$f.Current.Data.PersistentRoutes[0].RouteMetric=50}
            'TailscaleAndWsl' {$f.Current.Data.Adapters[1].ifIndex=88;$f.Current.Data.Adapters[2].Status='Disconnected'}
            'ExternalDNS' {$f.Current.Data.DNS[0].ServerAddresses=@('192.0.2.99','2001:db8::53')}
            'ExternalProxies' {$f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].ProxyServer='proxy.example:8080';$f.Current.Data.WinHTTPProxy[0].AccessType=3;$f.Current.Data.WinHTTPProxy[0].Proxy='localhost:7890'}
            'DisabledProxyCache' {$f.Current.Data.WinINETProxy[0].ProxyServer='127.0.0.1:12345';$f.Current.Data.WinINETProxy[0].CurrentUserConfiguration.Proxy='localhost:9801';$f.Current.Data.WinHTTPProxy[0].Proxy='[::1]:9803'}
            'ProxyBypassText' {$f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].ProxyOverride='127.0.0.1:12345';$f.Current.Data.WinHTTPProxy[0].AccessType=3;$f.Current.Data.WinHTTPProxy[0].Bypass='localhost:9801'}
            'OtherBenchmarkAddresses' {$f.Current.Data.IPAddresses[0].IPAddress='198.19.0.1';$f.Current.Data.DNS[0].ServerAddresses=@('198.18.1.1');$f.Current.Data.ActiveRoutes[0].NextHop='198.18.0.3'}
            'PublicAccelerationTargets' {$f.Current.Data.ActiveRoutes[0].DestinationPrefix='182.254.116.117/32'}
            'NoOriginEvidence' {$f.Current | Add-Member RouteOriginEvidence ([pscustomobject]@{Complete=$false;Routes=@()})}
        }
    } $true
}
Write-Output ('PASS: '+$script:rebootChecks+' reboot recovery fixtures; inputs preserved and no network/process operations.')
