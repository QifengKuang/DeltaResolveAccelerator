#requires -Version 7.0
# Fabricated snapshots only: no private files, processes or network state are read.
$ErrorActionPreference='Stop'
$backend=Join-Path (Split-Path $PSScriptRoot -Parent) 'app/backend'
. (Join-Path $backend 'Trial-NetworkState.ps1')
. (Join-Path $backend 'Mna-RouterAdvertisementRecovery.ps1')
. (Join-Path $backend 'Mna-RebootRecovery.ps1')
function Get-NetAdapter { throw 'Fixture must not query network adapters' }
function Get-CimInstance { throw 'Fixture must not query processes or Windows' }
function Get-TrialRouteOriginEvidence { throw 'Fixture must not query native route origins' }
function Stop-Process { throw 'Fixture must not stop processes' }
function Set-DnsClientServerAddress { throw 'Fixture must not change DNS' }
function New-NetRoute { throw 'Fixture must not change routes' }
$script:rebootChecks=0

function New-RebootFixture {
    $run='abcdef123456789012345678'
    $adapters=@(
        [pscustomobject]@{Name='Wi-Fi';InterfaceDescription='Fixture wireless';ifIndex=7;Status='Up';LinkSpeed='866 Mbps';Virtual=$false;HardwareInterface=$true},
        [pscustomobject]@{Name='vEthernet (WSL)';InterfaceDescription='Fixture Hyper-V';ifIndex=12;Status='Up';LinkSpeed='10 Gbps';Virtual=$true;HardwareInterface=$false},
        [pscustomobject]@{Name='Tailscale';InterfaceDescription='Fixture shared tunnel';ifIndex=18;Status='Up';LinkSpeed='100 Gbps';Virtual=$true;HardwareInterface=$false}
    )
    $interfaces=@($adapters | ForEach-Object {
        foreach ($family in @('IPv4','IPv6')) {
            [pscustomobject]@{InterfaceAlias=$_.Name;InterfaceIndex=$_.ifIndex;AddressFamily=$family;ConnectionState=1;NlMtuBytes=1500;InterfaceMetric=20;Dhcp=1;RouterDiscovery=1;Forwarding=0;WeakHostSend=0;WeakHostReceive=0}
        }
    })
    $interfaces+= [pscustomobject]@{InterfaceAlias='Loopback Pseudo-Interface 1';InterfaceIndex=1;AddressFamily='IPv6';ConnectionState=1;NlMtuBytes=4294967295;InterfaceMetric=75;Dhcp=0;RouterDiscovery=0;Forwarding=0;WeakHostSend=0;WeakHostReceive=0}
    function Address([string]$Alias,[int]$Index,[string]$Ip,[int]$Prefix=2,[int]$Suffix=4,[bool]$Skip=$false) {
        [pscustomobject]@{InterfaceAlias=$Alias;InterfaceIndex=$Index;AddressFamily='IPv6';IPAddress=$Ip;PrefixLength=64;Type=1;AddressState=4;SkipAsSource=$Skip;PrefixOrigin=$Prefix;SuffixOrigin=$Suffix}
    }
    function Route([string]$Alias,[int]$Index,[string]$Ip) {
        [pscustomobject]@{InterfaceAlias=$Alias;InterfaceIndex=$Index;AddressFamily='IPv6';DestinationPrefix=($Ip+'/128');NextHop='::';RouteMetric=256;Protocol=2;Publish=0}
    }
    $before=[pscustomobject]@{
        SchemaVersion=1;StartedAt='2026-09-16T01:00:00Z';FinishedAt='2026-09-16T01:00:02Z';Complete=$true;ReadErrors=@()
        Data=[pscustomobject]@{
            Adapters=$adapters;Interfaces=$interfaces
            IPAddresses=@(
                (Address 'Wi-Fi' 7 'fe80::10'),(Address 'vEthernet (WSL)' 12 'fe80::20'),
                (Address 'Wi-Fi' 7 'fd12:3456::10' 4 4),(Address 'Wi-Fi' 7 '2001:db8::10' 4 5),
                (Address 'Tailscale' 18 'fe80::30' 2 4 $true),
                [pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=7;AddressFamily='IPv4';IPAddress='192.0.2.10';PrefixLength=24;Type=1;AddressState=4;SkipAsSource=$false;PrefixOrigin=3;SuffixOrigin=3},
                [pscustomobject]@{InterfaceAlias='Loopback Pseudo-Interface 1';InterfaceIndex=1;AddressFamily='IPv6';IPAddress='::1';PrefixLength=128;Type=1;AddressState=4;SkipAsSource=$false;PrefixOrigin=1;SuffixOrigin=1}
            )
            ActiveRoutes=@(
                (Route 'Wi-Fi' 7 'fe80::10'),(Route 'vEthernet (WSL)' 12 'fe80::20'),
                [pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=7;AddressFamily='IPv4';DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=0;Protocol=3;Publish=0},
                [pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=7;AddressFamily='IPv6';DestinationPrefix='::/0';NextHop='fe80::1';RouteMetric=256;Protocol=4;Publish=0}
            )
            PersistentRoutes=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=7;AddressFamily='IPv4';DestinationPrefix='198.51.100.0/24';NextHop='192.0.2.1';RouteMetric=5;Protocol=3;Publish=0})
            DNS=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=7;AddressFamily=2;ServerAddresses=@('192.0.2.53','192.0.2.54')})
            WinINETProxy=@([pscustomobject]@{ProxyEnable=0;ProxyServer=$null;ProxyOverride=$null;AutoConfigURL=$null;AutoDetectRegistryValue=1;CurrentUserConfiguration=[pscustomobject]@{AutoDetect=$true;AutoConfigURL=$null;Proxy=$null;Bypass=$null}})
            WinHTTPProxy=@([pscustomobject]@{AccessType=1;Proxy=$null;Bypass=$null})
            RelatedProcesses=@();RelatedServices=@()
            RelatedDrivers=@([pscustomobject]@{Name='wintun';DisplayName='Shared Wintun';State='Running';StartMode='Manual';Started=$true;ServiceType='Kernel Driver'})
        }
    }
    $after=$before | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16
    $after.StartedAt='2026-09-17T01:00:00Z';$after.FinishedAt='2026-09-17T01:00:02Z'
    $map=@{7=17;12=32;18=28}
    foreach ($adapter in $after.Data.Adapters) { $adapter.ifIndex=$map[[int]$adapter.ifIndex] }
    foreach ($section in @('Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS')) {
        foreach ($row in $after.Data.$section) {
            if ($map.ContainsKey([int]$row.InterfaceIndex)) { $row.InterfaceIndex=$map[[int]$row.InterfaceIndex] }
        }
    }
    $after.Data.IPAddresses[0].IPAddress='fe80::11'
    $after.Data.IPAddresses[1].IPAddress='fe80::21'
    $after.Data.IPAddresses[2].IPAddress='fd12:3456::11'
    $after.Data.IPAddresses[3].IPAddress='2001:db8::11'
    $after.Data.IPAddresses[5].AddressState=3
    $after.Data.ActiveRoutes[0].DestinationPrefix='fe80::11/128'
    $after.Data.ActiveRoutes[1].DestinationPrefix='fe80::21/128'
    [pscustomobject]@{RunId=$run;Owner=[pscustomobject]@{RunId=$run;RootCreated='2026-09-16T01:00:04Z'};Before=$before;After=$after;Boot=[datetime]'2026-09-17T00:00:00Z'}
}

function Assert-RebootFixture {
    param([string]$Name,[scriptblock]$Edit={},[bool]$Expected=$false)
    $fixture=New-RebootFixture
    & $Edit $fixture
    $original=$fixture | ConvertTo-Json -Depth 20 -Compress
    $result=Test-MnaRebootNetworkRestored -RunId $fixture.RunId -Owner $fixture.Owner -BaselineState $fixture.Before -CurrentState $fixture.After -BootTime $fixture.Boot
    if ($result -ne $Expected) { throw "Reboot fixture failed: $Name (expected $Expected, got $result)" }
    if (($fixture | ConvertTo-Json -Depth 20 -Compress) -cne $original) { throw "Reboot fixture mutated evidence: $Name" }
    $script:rebootChecks++
}

function Add-RebootRouterAdvertisementFixture {
    param([object]$Fixture,[switch]$IncludeAdditionAndRemoval)
    foreach ($side in @('Before','After')) {
        $state=$Fixture.$side
        $index=if ($side -eq 'Before') {7} else {17}
        $nextHop=if ($side -eq 'Before') {'fe80::1'} else {'fe80::2'}
        $routes=@([pscustomobject]@{
            InterfaceAlias='Wi-Fi';InterfaceIndex=$index;AddressFamily='IPv6';DestinationPrefix='fd99:a3dc:1578::/64'
            NextHop=$nextHop;RouteMetric=256;Protocol=3;Publish=0
        })
        if ($IncludeAdditionAndRemoval) {
            $prefix=if ($side -eq 'Before') {'fd10:ab1c:d16c:1::/64'} else {'fd22:e412:3463:4335::/64'}
            $routes+=[pscustomobject]@{
                InterfaceAlias='Wi-Fi';InterfaceIndex=$index;AddressFamily='IPv6';DestinationPrefix=$prefix
                NextHop='::';RouteMetric=256;Protocol=3;Publish=0
            }
        }
        $state.Data.ActiveRoutes+=$routes
        $state | Add-Member RouteOriginEvidence ([pscustomobject]@{
            Complete=$true
            Routes=@($routes | ForEach-Object {
                [pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;DestinationPrefix=$_.DestinationPrefix;NextHop=$_.NextHop;Origin=3}
            })
        })
    }
}

Assert-RebootFixture 'renumbered Wi-Fi/WSL, automatic IPv6 rotation and unchanged shared tunnel' {} $true
Assert-RebootFixture 'carrier observations may change' {param($f) $f.After.Data.Adapters[0].Status='Disconnected';$f.After.Data.Adapters[0].LinkSpeed='0 bps';$f.After.Data.Interfaces[0].ConnectionState=0} $true
Assert-RebootFixture 'new snapshots may add unique adapter GUIDs' {param($f) foreach($a in $f.After.Data.Adapters) {$a | Add-Member InterfaceGuid ([guid]::NewGuid().ToString())}} $true
Assert-RebootFixture 'same GUID on both snapshots' {param($f) for($i=0;$i -lt 3;$i++) {$g=[guid]::NewGuid().ToString();$f.Before.Data.Adapters[$i] | Add-Member InterfaceGuid $g;$f.After.Data.Adapters[$i] | Add-Member InterfaceGuid $g}} $true
Assert-RebootFixture 'IPv6 privacy address can use /128' {param($f) $f.Before.Data.IPAddresses[3].PrefixLength=128;$f.After.Data.IPAddresses[3].PrefixLength=128} $true
Assert-RebootFixture 'no index changes required' {param($f) $f.Before.Data=$f.After.Data | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16} $true
Assert-RebootFixture 'array ordering is irrelevant' {param($f) [array]::Reverse($f.After.Data.Adapters);[array]::Reverse($f.After.Data.IPAddresses)} $true
Assert-RebootFixture 'Windows hidden adapter may have an empty description' {param($f) $f.Before.Data.Adapters[1].InterfaceDescription='';$f.After.Data.Adapters[1].InterfaceDescription=''} $true
Assert-RebootFixture 'Windows link-local scope changes with interface index' {
    param($f)
    foreach($state in @($f.Before,$f.After)) {
        foreach($address in $state.Data.IPAddresses) {
            if($address.IPAddress.StartsWith('fe80:')) {$address.IPAddress += '%'+$address.InterfaceIndex}
        }
        $state.Data.ActiveRoutes[3].NextHop += '%'+$state.Data.ActiveRoutes[3].InterfaceIndex
    }
} $true
Assert-RebootFixture 'scope must match the address interface' {param($f) $f.After.Data.IPAddresses[0].IPAddress+='%'+'999'}
Assert-RebootFixture 'reboot index remapping and IPv6 rotation combine with proven RA add, remove and next-hop replacement' {
    param($f)
    Add-RebootRouterAdvertisementFixture $f -IncludeAdditionAndRemoval
} $true
Assert-RebootFixture 'reboot index remapping retains legacy RA next-hop replacement compatibility' {
    param($f)
    Add-RebootRouterAdvertisementFixture $f
    $f.Before.PSObject.Properties.Remove('RouteOriginEvidence')
} $true
Assert-RebootFixture 'reboot must not reclassify a manual baseline route as RA' {
    param($f)
    Add-RebootRouterAdvertisementFixture $f
    $f.Before.RouteOriginEvidence.Routes[0].Origin=0
}
Assert-RebootFixture 'reboot cannot bypass a failed current origin query' {
    param($f)
    Add-RebootRouterAdvertisementFixture $f
    $f.After.RouteOriginEvidence.Complete=$false
}
Assert-RebootFixture 'reboot current origin evidence must use the current interface index' {
    param($f)
    Add-RebootRouterAdvertisementFixture $f
    $f.After.RouteOriginEvidence.Routes[0].InterfaceIndex=7
}

foreach ($kind in @('SameBoot','OwnerAfterBoot','BaselineAtBoot','CurrentBeforeBoot','UnknownBoot','BadBaselineTime','NoOffsetTime','WrongRun','IncompleteBefore','IncompleteAfter','ReadError','NullSection','SdkProcess','SdkService','SdkDriver','CurrentTun','OtherTun','TunInterface','TunRoute','TunDns','MpTun','AddedAdapter','DeletedAdapter','AmbiguousAdapter','DuplicateIndex','RenamedAdapter','DifferentDescription','ChangedVirtual','GuidMismatch','GuidDisappeared','DuplicateGuid','UnknownInterface','AliasMismatch','Mtu','InterfaceMetric','Dhcp','RouterDiscovery','DNS','DnsOrder','WinINET','WinHTTP','PersistentRoute','DefaultRoute','ManualIpv6','ManualSuffix','UnknownOrigin','SkipAsSource','WrongPrefix','Multicast','IPv4Address','SameAddressConfiguration','UnrelatedHostRoute','WrongSideHostRoute','RouteMetric','RouteProtocol','RoutePublished','RemoteNextHop','NonHostRoute','SharedDriverChanged','UnknownSection')) {
    Assert-RebootFixture $kind {
        param($f)
        switch ($kind) {
            'SameBoot' {$f.Boot=[datetime]'2026-09-15T00:00:00Z'}
            'OwnerAfterBoot' {$f.Owner.RootCreated='2026-09-17T00:00:01Z'}
            'BaselineAtBoot' {$f.Before.FinishedAt='2026-09-17T00:00:00Z'}
            'CurrentBeforeBoot' {$f.After.StartedAt='2026-09-16T23:59:59Z'}
            'UnknownBoot' {$f.Boot=[datetime]::SpecifyKind([datetime]'2026-09-17T00:00:00',[DateTimeKind]::Unspecified)}
            'BadBaselineTime' {$f.Before.FinishedAt='broken'}
            'NoOffsetTime' {$f.Before.FinishedAt='2026-09-16T01:00:02'}
            'WrongRun' {$f.Owner.RunId='111111111111111111111111'}
            'IncompleteBefore' {$f.Before.Complete=$false}
            'IncompleteAfter' {$f.After.Complete=$false}
            'ReadError' {$f.After.ReadErrors=@([pscustomobject]@{Section='DNS';ErrorType='Fixture'})}
            'NullSection' {$f.After.Data.DNS=$null}
            'SdkProcess' {$f.After.Data.RelatedProcesses=@([pscustomobject]@{Name='linkboost.exe';ProcessId=123})}
            'SdkService' {$f.After.Data.RelatedServices=@([pscustomobject]@{Name='linkboost';DisplayName='SDK service'})}
            'SdkDriver' {$f.After.Data.RelatedDrivers=@([pscustomobject]@{Name='multipath';DisplayName='SDK driver'})}
            'CurrentTun' {$f.After.Data.Adapters[0].Name='mna_game_abcdef'}
            'OtherTun' {$f.After.Data.Adapters[0].Name='mna_game_123456'}
            'TunInterface' {$f.After.Data.Interfaces[0].InterfaceAlias='mna_game_abcdef'}
            'TunRoute' {$f.After.Data.ActiveRoutes[0].InterfaceAlias='mna_game_abcdef'}
            'TunDns' {$f.After.Data.DNS[0].InterfaceAlias='mna_game_abcdef'}
            'MpTun' {$f.After.Data.Adapters[0].Name='mp_tun0'}
            'AddedAdapter' {$f.After.Data.Adapters+= [pscustomobject]@{Name='New';InterfaceDescription='New';ifIndex=55;HardwareInterface=$true;Virtual=$false}}
            'DeletedAdapter' {$f.After.Data.Adapters=@($f.After.Data.Adapters | Select-Object -First 2)}
            'AmbiguousAdapter' {$f.Before.Data.Adapters+=($f.Before.Data.Adapters[0] | ConvertTo-Json | ConvertFrom-Json)}
            'DuplicateIndex' {$f.After.Data.Adapters[1].ifIndex=17}
            'RenamedAdapter' {$f.After.Data.Adapters[0].Name='Renamed'}
            'DifferentDescription' {$f.After.Data.Adapters[0].InterfaceDescription='Other hardware'}
            'ChangedVirtual' {$f.After.Data.Adapters[0].Virtual=$true}
            'GuidMismatch' {$f.Before.Data.Adapters[0] | Add-Member InterfaceGuid ([guid]::NewGuid().ToString());$f.After.Data.Adapters[0] | Add-Member InterfaceGuid ([guid]::NewGuid().ToString())}
            'GuidDisappeared' {$f.Before.Data.Adapters[0] | Add-Member InterfaceGuid ([guid]::NewGuid().ToString())}
            'DuplicateGuid' {$g=[guid]::NewGuid().ToString();$f.After.Data.Adapters[0] | Add-Member InterfaceGuid $g;$f.After.Data.Adapters[1] | Add-Member InterfaceGuid $g}
            'UnknownInterface' {$f.After.Data.IPAddresses[0].InterfaceIndex=999}
            'AliasMismatch' {$f.After.Data.IPAddresses[0].InterfaceAlias='Other adapter'}
            'Mtu' {$f.After.Data.Interfaces[0].NlMtuBytes=1300}
            'InterfaceMetric' {$f.After.Data.Interfaces[0].InterfaceMetric=25}
            'Dhcp' {$f.After.Data.Interfaces[0].Dhcp=0}
            'RouterDiscovery' {$f.After.Data.Interfaces[0].RouterDiscovery=0}
            'DNS' {$f.After.Data.DNS[0].ServerAddresses=@('192.0.2.99')}
            'DnsOrder' {$f.After.Data.DNS[0].ServerAddresses=@('192.0.2.54','192.0.2.53')}
            'WinINET' {$f.After.Data.WinINETProxy[0].ProxyEnable=1}
            'WinHTTP' {$f.After.Data.WinHTTPProxy[0].Proxy='127.0.0.1:8080'}
            'PersistentRoute' {$f.After.Data.PersistentRoutes[0].RouteMetric=10}
            'DefaultRoute' {$f.After.Data.ActiveRoutes[2].NextHop='192.0.2.2'}
            'ManualIpv6' {$f.Before.Data.IPAddresses[0].PrefixOrigin=1}
            'ManualSuffix' {$f.Before.Data.IPAddresses[0].SuffixOrigin=1}
            'UnknownOrigin' {$f.Before.Data.IPAddresses[0].PrefixOrigin=0}
            'SkipAsSource' {$f.Before.Data.IPAddresses[0].SkipAsSource=$true}
            'WrongPrefix' {$f.Before.Data.IPAddresses[0].PrefixLength=48}
            'Multicast' {$f.After.Data.IPAddresses[2].IPAddress='ff02::12'}
            'IPv4Address' {$f.After.Data.IPAddresses[5].IPAddress='192.0.2.11'}
            'SameAddressConfiguration' {$f.After.Data.IPAddresses[2].IPAddress=$f.Before.Data.IPAddresses[2].IPAddress;$f.After.Data.IPAddresses[2].SuffixOrigin=5}
            'UnrelatedHostRoute' {$f.After.Data.ActiveRoutes[0].DestinationPrefix='fe80::99/128'}
            'WrongSideHostRoute' {$f.Before.Data.ActiveRoutes[0].DestinationPrefix='fe80::11/128';$f.After.Data.ActiveRoutes=@($f.After.Data.ActiveRoutes | Select-Object -Skip 1)}
            'RouteMetric' {$f.After.Data.ActiveRoutes[0].RouteMetric=25}
            'RouteProtocol' {$f.After.Data.ActiveRoutes[0].Protocol=3}
            'RoutePublished' {$f.After.Data.ActiveRoutes[0].Publish=1}
            'RemoteNextHop' {$f.After.Data.ActiveRoutes[0].NextHop='fe80::1'}
            'NonHostRoute' {$f.After.Data.ActiveRoutes[0].DestinationPrefix='fe80::/64'}
            'SharedDriverChanged' {$f.After.Data.RelatedDrivers[0].State='Stopped'}
            'UnknownSection' {$f.After.Data | Add-Member Unexpected @([pscustomobject]@{Changed=$true})}
        }
    }
}
foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')) {
    foreach ($side in @('Before','After')) {
        Assert-RebootFixture ('missing '+$side+'/'+$section) {param($f) $f.$side.Data.PSObject.Properties.Remove($section)}
    }
}
Write-Output ('PASS: '+$script:rebootChecks+' reboot recovery fixtures; inputs preserved and no network/process operations.')
