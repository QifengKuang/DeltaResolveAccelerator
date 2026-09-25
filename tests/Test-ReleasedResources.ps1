#requires -Version 7.0
# Fabricated inventories only. Assessment must not read or change live state.
$ErrorActionPreference='Stop'
$script:releasedCheckResults=[Collections.Generic.List[object]]::new()
$script:releasedInputsUnmodified=$true
$script:releasedCurrentCheck='Load release assessment'
function Write-ReleasedResult([bool]$Passed) {
    [pscustomobject]@{
        Passed=$Passed;CheckCount=$script:releasedCheckResults.Count
        NetworkStarted=$false;SdkStarted=$false;InputsUnmodified=$script:releasedInputsUnmodified
        Checks=@($script:releasedCheckResults.ToArray())
    } | ConvertTo-Json -Depth 6
}
trap {
    $script:releasedCheckResults.Add([pscustomobject]@{Name=$script:releasedCurrentCheck;Passed=$false;Error=$_.Exception.Message})
    Write-ReleasedResult $false
    exit 1
}
$backend=Join-Path (Split-Path $PSScriptRoot -Parent) 'app/backend'
. (Join-Path $backend 'Mna-ReleasedResources.ps1')
function Get-NetAdapter { throw 'Release fixture must not query adapters' }
function Get-NetRoute { throw 'Release fixture must not query routes' }
function Get-CimInstance { throw 'Release fixture must not query Windows' }
function Get-TrialNetworkState { throw 'Release fixture must not query live state' }
function Compare-TrialNetworkState { throw 'Release fixture must not depend on whole-machine comparison' }
function Stop-Process { throw 'Release fixture must not stop processes' }
function Set-DnsClientServerAddress { throw 'Release fixture must not change DNS' }
function New-NetRoute { throw 'Release fixture must not change routes' }
function Remove-NetRoute { throw 'Release fixture must not remove routes' }
$script:releasedChecks=0

function New-ReleasedFixture {
    $current=[pscustomobject]@{
        SchemaVersion=1;Complete=$true;ReadErrors=@()
        Data=[pscustomobject]@{
            Adapters=@(
                [pscustomobject]@{Name='Wi-Fi';InterfaceDescription='Fixture wireless';ifIndex=17;Status='Up';Virtual=$false;HardwareInterface=$true},
                [pscustomobject]@{Name='Tailscale';InterfaceDescription='Fixture shared tunnel';ifIndex=28;Status='Disconnected';Virtual=$true;HardwareInterface=$false}
            )
            Interfaces=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';ConnectionState=1;InterfaceMetric=20;Dhcp=1})
            IPAddresses=@(
                [pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;IPAddress='192.0.2.10';PrefixLength=24},
                [pscustomobject]@{InterfaceAlias='Tailscale';InterfaceIndex=28;IPAddress='169.254.10.20';PrefixLength=16}
            )
            ActiveRoutes=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=5;Protocol=3})
            PersistentRoutes=@()
            DNS=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;ServerAddresses=@('192.0.2.53')})
            WinINETProxy=@([pscustomobject]@{ProxyEnable=0;ProxyServer=$null;ProxyOverride=$null;CurrentUserConfiguration=[pscustomobject]@{Proxy=$null;AutoConfigURL=$null;Bypass=$null}})
            WinHTTPProxy=@([pscustomobject]@{AccessType=1;Proxy=$null;Bypass=$null})
            RelatedProcesses=@();RelatedServices=@()
            RelatedDrivers=@([pscustomobject]@{Name='wintun';DisplayName='Shared Wintun';State='Running'})
        }
    }
    [pscustomobject]@{Current=$current;Baseline=($current | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16)}
}

function Assert-ReleasedFixture {
    param([string]$Name,[scriptblock]$Edit={},[string]$Classification='Released',[string]$Reason)
    $script:releasedCurrentCheck=$Name
    $fixture=New-ReleasedFixture
    & $Edit $fixture
    $original=$fixture | ConvertTo-Json -Depth 20 -Compress
    $result=Get-MnaReleasedResourceAssessment -CurrentState $fixture.Current -BaselineState $fixture.Baseline
    if ($result.Classification -cne $Classification -or $result.Released -ne ($Classification -eq 'Released')) {
        throw ('Release fixture failed: '+$Name+'; '+($result | ConvertTo-Json -Compress))
    }
    if ($Reason -and $Reason -notin @($result.Reasons)) { throw ('Missing release reason: '+$Name+' / '+$Reason) }
    if (($fixture | ConvertTo-Json -Depth 20 -Compress) -cne $original) {
        $script:releasedInputsUnmodified=$false
        throw ('Release assessment mutated evidence: '+$Name)
    }
    $script:releasedCheckResults.Add([pscustomobject]@{Name=$Name;Passed=$true})
    $script:releasedChecks++
}

Assert-ReleasedFixture 'complete current inventory proves owned resources absent'
foreach ($kind in @('MissingBaseline','BrokenBaseline','IncompleteBaseline','OldOwnedIndexReused','TailscaleApipaToActive','WslAdapterAdded','WifiDisconnected','DhcpRenewed','ExternalDns','ManualDefaultRoute','PublicProbeRoute','SharedTunDriver','ExternalProxy','NoRouteOrigins','DisabledProxyCache','ProxyBypassText','AllExternalChurn')) {
    Assert-ReleasedFixture ('external differences are not release failures: '+$kind) {
        param($f)
        switch ($kind) {
            'MissingBaseline' {$f.Baseline=$null}
            'BrokenBaseline' {$f.Baseline='unreadable diagnostic baseline'}
            'IncompleteBaseline' {$f.Baseline.Complete=$false;$f.Baseline.ReadErrors=@('old read failure')}
            'OldOwnedIndexReused' {$f.Baseline.Data.Adapters[0].Name='mna_game_abcdef'}
            'TailscaleApipaToActive' {$f.Current.Data.Adapters[1].Status='Up';$f.Current.Data.IPAddresses[1].IPAddress='100.100.20.30';$f.Current.Data.IPAddresses[1].PrefixLength=32}
            'WslAdapterAdded' {$f.Current.Data.Adapters+=[pscustomobject]@{Name='vEthernet (WSL)';InterfaceDescription='Fixture Hyper-V';ifIndex=88;Virtual=$true;HardwareInterface=$false}}
            'WifiDisconnected' {$f.Current.Data.Adapters[0].Status='Disconnected';$f.Current.Data.Interfaces[0].ConnectionState=0;$f.Current.Data.ActiveRoutes=@()}
            'DhcpRenewed' {$f.Current.Data.IPAddresses[0].IPAddress='192.0.2.130'}
            'ExternalDns' {$f.Current.Data.DNS[0].ServerAddresses=@('203.0.113.53','2001:db8::53')}
            'ManualDefaultRoute' {$f.Current.Data.PersistentRoutes=@([pscustomobject]@{InterfaceAlias='Wi-Fi';InterfaceIndex=17;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.254';Protocol=3})}
            'PublicProbeRoute' {$f.Current.Data.ActiveRoutes[0].DestinationPrefix='182.254.116.117/32'}
            'SharedTunDriver' {$f.Current.Data.RelatedDrivers+=[pscustomobject]@{Name='tap0901';DisplayName='Shared TAP driver';State='Running'}}
            'ExternalProxy' {$f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].ProxyServer='proxy.example:8080';$f.Current.Data.WinHTTPProxy[0].AccessType=3;$f.Current.Data.WinHTTPProxy[0].Proxy='localhost:7890'}
            'NoRouteOrigins' {$f.Current | Add-Member RouteOriginEvidence ([pscustomobject]@{Complete=$false;Routes=@()})}
            'DisabledProxyCache' {$f.Current.Data.WinINETProxy[0].ProxyServer='127.0.0.1:12345';$f.Current.Data.WinINETProxy[0].CurrentUserConfiguration.Proxy='localhost:9801';$f.Current.Data.WinHTTPProxy[0].Proxy='[::1]:9803'}
            'ProxyBypassText' {$f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].ProxyOverride='127.0.0.1:12345';$f.Current.Data.WinHTTPProxy[0].AccessType=3;$f.Current.Data.WinHTTPProxy[0].Bypass='localhost:9801'}
            'AllExternalChurn' {
                $f.Current.Data.Adapters[0].Status='Disconnected';$f.Current.Data.Adapters[1].Status='Up'
                $f.Current.Data.Adapters+=[pscustomobject]@{Name='vEthernet (WSL)';InterfaceDescription='Fixture Hyper-V';ifIndex=88}
                $f.Current.Data.IPAddresses[0].IPAddress='169.254.22.55';$f.Current.Data.IPAddresses[1].IPAddress='100.100.20.30'
                $f.Current.Data.Interfaces[0].ConnectionState=0;$f.Current.Data.DNS[0].ServerAddresses=@('203.0.113.53')
                $f.Current.Data.ActiveRoutes[0].NextHop='192.0.2.254'
            }
        }
    }
}
foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')) {
    Assert-ReleasedFixture ('missing section '+$section) {param($f) $f.Current.Data.PSObject.Properties.Remove($section)} 'InventoryIncomplete' ('MissingSection:'+$section)
    Assert-ReleasedFixture ('null section '+$section) {param($f) $f.Current.Data.$section=$null} 'InventoryIncomplete' ('MissingSection:'+$section)
    Assert-ReleasedFixture ('malformed row in '+$section) {param($f) $f.Current.Data.$section=@([pscustomobject]@{})} 'InventoryIncomplete'
}
foreach ($kind in @('NoCurrent','UnsupportedSchema','Incomplete','ReadErrors','MissingReadErrors','NullReadErrors','MissingData','StringComplete','BadIndex','NullDnsServers','MissingUserProxy','UnknownUserProxyMode','UnknownMachineProxyMode')) {
    Assert-ReleasedFixture ('cannot prove release with incomplete evidence: '+$kind) {
        param($f)
        switch ($kind) {
            'NoCurrent' {$f.Current=$null}
            'UnsupportedSchema' {$f.Current.SchemaVersion=2}
            'Incomplete' {$f.Current.Complete=$false}
            'ReadErrors' {$f.Current.ReadErrors=@([pscustomobject]@{Section='DNS';ErrorType='Fixture.ReadFailure'})}
            'MissingReadErrors' {$f.Current.PSObject.Properties.Remove('ReadErrors')}
            'NullReadErrors' {$f.Current.ReadErrors=$null}
            'MissingData' {$f.Current.Data=$null}
            'StringComplete' {$f.Current.Complete='true'}
            'BadIndex' {$f.Current.Data.ActiveRoutes[0].InterfaceIndex='unknown'}
            'NullDnsServers' {$f.Current.Data.DNS[0].ServerAddresses=$null}
            'MissingUserProxy' {$f.Current.Data.WinINETProxy[0].CurrentUserConfiguration=$null}
            'UnknownUserProxyMode' {$f.Current.Data.WinINETProxy[0].ProxyEnable=7}
            'UnknownMachineProxyMode' {$f.Current.Data.WinHTTPProxy[0].AccessType=77}
        }
    } 'InventoryIncomplete'
}
foreach ($name in @('linkboost.exe','linkboost-core.exe','multipath-helper.exe','mp-speeder.exe')) {
    Assert-ReleasedFixture ('SDK process '+$name) {param($f) $f.Current.Data.RelatedProcesses=@([pscustomobject]@{Name=$name;ProcessId=900})} 'ResourcesRemain' 'OwnedSdkProcess'
}
foreach ($section in @('RelatedServices','RelatedDrivers')) {
    foreach ($name in @('linkboost','mp-speeder','multipath','mp_tun0','mna_game_abcdef')) {
        Assert-ReleasedFixture ('SDK resource '+$section+'/'+$name) {param($f) $f.Current.Data.$section=@([pscustomobject]@{Name='Fixture';DisplayName=$name;State='Stopped'})} 'ResourcesRemain'
    }
}
foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS')) {
    foreach ($name in @('mp_tun0','mna_game_abcdef')) {
        Assert-ReleasedFixture ('named TUN remnant '+$section+'/'+$name) {
            param($f)
            if ($section -eq 'PersistentRoutes') { $f.Current.Data.PersistentRoutes=@($f.Current.Data.ActiveRoutes[0].PSObject.Copy()) }
            if ($section -eq 'Adapters') { $f.Current.Data.$section[0].Name=$name } else { $f.Current.Data.$section[0].InterfaceAlias=$name }
        } 'ResourcesRemain' ('OwnedIdentity:'+$section)
    }
}
foreach ($address in @('198.18.0.1','198.18.0.2','::ffff:198.18.0.1')) {
    Assert-ReleasedFixture ('assigned TUN endpoint '+$address) {param($f) $f.Current.Data.IPAddresses[0].IPAddress=$address} 'ResourcesRemain' 'OwnedTunAddress'
    Assert-ReleasedFixture ('TUN DNS '+$address) {param($f) $f.Current.Data.DNS[0].ServerAddresses=@($address)} 'ResourcesRemain' 'OwnedTunDns'
    foreach ($section in @('ActiveRoutes','PersistentRoutes')) {
        Assert-ReleasedFixture ('TUN next-hop '+$section+'/'+$address) {
            param($f)
            if ($section -eq 'PersistentRoutes') { $f.Current.Data.PersistentRoutes=@($f.Current.Data.ActiveRoutes[0].PSObject.Copy()) }
            $f.Current.Data.$section[0].NextHop=$address
        } 'ResourcesRemain' ('OwnedTunNextHop:'+$section)
    }
}
foreach ($section in @('ActiveRoutes','PersistentRoutes')) {
    Assert-ReleasedFixture ('unnamed route uses owned CURRENT adapter index '+$section) {
        param($f)
        $f.Current.Data.Adapters+=[pscustomobject]@{Name='mna_game_abcdef';InterfaceDescription='Fixture TUN';ifIndex=99}
        $f.Current.Data.$section=@([pscustomobject]@{InterfaceAlias='';InterfaceIndex=99;DestinationPrefix='182.254.116.117/32';NextHop='0.0.0.0'})
    } 'ResourcesRemain' ('OwnedInterfaceIndex:'+$section)
    Assert-ReleasedFixture ('renamed TUN still owns route index by assigned endpoint '+$section) {
        param($f)
        $f.Current.Data.IPAddresses[0].IPAddress='198.18.0.1'
        $f.Current.Data.$section=@([pscustomobject]@{InterfaceAlias='stale name';InterfaceIndex=17;DestinationPrefix='1.1.1.1/32';NextHop='0.0.0.0'})
    } 'ResourcesRemain' ('OwnedInterfaceIndex:'+$section)
}
foreach ($endpoint in @('127.0.0.1:12345','http=localhost:9801;https=proxy.example:8080','socks=[::1]:9803','http://[::ffff:127.0.0.1]:12345','localhost.:9801')) {
    Assert-ReleasedFixture ('enabled user proxy '+$endpoint) {param($f) $f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].ProxyServer=$endpoint} 'ResourcesRemain' 'OwnedWinInetProxy'
    Assert-ReleasedFixture ('enabled machine proxy '+$endpoint) {param($f) $f.Current.Data.WinHTTPProxy[0].AccessType=3;$f.Current.Data.WinHTTPProxy[0].Proxy=$endpoint} 'ResourcesRemain' 'OwnedWinHttpProxy'
}
Assert-ReleasedFixture 'effective enabled user proxy' {
    param($f) $f.Current.Data.WinINETProxy[0].ProxyEnable=1;$f.Current.Data.WinINETProxy[0].CurrentUserConfiguration.Proxy='127.0.0.1:12345'
} 'ResourcesRemain' 'OwnedWinInetProxy'
Assert-ReleasedFixture 'effective PAC points at SDK endpoint' {
    param($f) $f.Current.Data.WinINETProxy[0].CurrentUserConfiguration.AutoConfigURL='http://127.0.0.1:9801/proxy.pac'
} 'ResourcesRemain' 'OwnedWinInetAutoConfig'
Assert-ReleasedFixture 'same artifact already in baseline never makes an owned remnant acceptable' {
    param($f) $f.Current.Data.IPAddresses[0].IPAddress='198.18.0.1';$f.Baseline.Data.IPAddresses[0].IPAddress='198.18.0.1'
} 'ResourcesRemain' 'OwnedTunAddress'
Assert-ReleasedFixture 'arbitrary external product name has no allowlist' {
    param($f) $f.Current.Data.Adapters[1].Name='Example Other VPN';$f.Current.Data.Adapters[1].InterfaceDescription='Generic virtual network device'
}
$script:releasedCurrentCheck='baseline parameter is optional'
$withoutBaseline=Get-MnaReleasedResourceAssessment -CurrentState (New-ReleasedFixture).Current
if (-not $withoutBaseline.Released) { throw 'Optional baseline parameter was required' }
$script:releasedCheckResults.Add([pscustomobject]@{Name=$script:releasedCurrentCheck;Passed=$true})
$script:releasedChecks++
Write-ReleasedResult $true
