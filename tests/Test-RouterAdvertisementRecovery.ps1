#requires -Version 7.0
<# Pure offline regression for native Router Advertisement route evidence.
   Fabricated snapshots and production classifiers only. No installation files,
   Windows network inventory, processes, SDK, or network mutation are accessed. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$backend=Join-Path (Split-Path $PSScriptRoot -Parent) 'app/backend'
. (Join-Path $backend 'Trial-NetworkState.ps1')
. (Join-Path $backend 'Mna-UI.Common.ps1')
. (Join-Path $backend 'Mna-RouterAdvertisementRecovery.ps1')
$checks=[Collections.Generic.List[object]]::new()
$script:raFixtureAdapters=@()
$script:raInputsUnmodified=$true

# The existing broad classifier asks for physical adapter indexes. Supply only
# the fabricated snapshot; the new RA classifier itself uses snapshot identity.
function Get-NetAdapter { param([switch]$IncludeHidden,$ErrorAction) return $script:raFixtureAdapters }
function Get-NetIPInterface { throw 'RA fixture must not read network interfaces' }
function Get-NetIPAddress { throw 'RA fixture must not read network addresses' }
function Get-NetRoute { throw 'RA fixture must not read network routes' }
function Get-DnsClientServerAddress { throw 'RA fixture must not read DNS' }
function Get-CimInstance { throw 'RA fixture must not read Windows processes or boot state' }
function Start-Process { throw 'RA fixture must not start processes' }
function Stop-Process { throw 'RA fixture must not stop processes' }
function New-NetRoute { throw 'RA fixture must not change routes' }
function Remove-NetRoute { throw 'RA fixture must not change routes' }
function Set-NetIPInterface { throw 'RA fixture must not change interfaces' }
function Set-DnsClientServerAddress { throw 'RA fixture must not change DNS' }
function Invoke-RestMethod { throw 'RA fixture must not access network' }
function Invoke-WebRequest { throw 'RA fixture must not access network' }

function Copy-RaFixtureValue($Value) { $Value | ConvertTo-Json -Depth 24 | ConvertFrom-Json -Depth 24 }
function New-RaFixtureRoute([string]$NextHop='fe80::1',[string]$Prefix='fd12:3456:789a:1::/64') {
    [pscustomobject]@{InterfaceAlias='Fixture Wi-Fi';InterfaceIndex=7;AddressFamily='IPv6';DestinationPrefix=$Prefix;NextHop=$NextHop;RouteMetric=256;Protocol=3;Publish=0}
}
function Set-RaFixtureEvidence($State,[int]$Origin=3) {
    $rows=@($State.Data.ActiveRoutes | Where-Object AddressFamily -eq IPv6 | ForEach-Object {
        [pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;DestinationPrefix=$_.DestinationPrefix;NextHop=$_.NextHop;Origin=$Origin}
    })
    $State | Add-Member -NotePropertyName RouteOriginEvidence -NotePropertyValue ([pscustomobject]@{Complete=$true;Routes=$rows}) -Force
}
function New-RaFixture {
    $before=[pscustomobject]@{
        SchemaVersion=1;StartedAt='2026-09-17T02:00:00Z';FinishedAt='2026-09-17T02:00:02Z';Complete=$true;ReadErrors=@()
        Data=[pscustomobject]@{
            Adapters=@([pscustomobject]@{Name='Fixture Wi-Fi';InterfaceDescription='Fixture wireless adapter';ifIndex=7;Status='Up';LinkSpeed='866 Mbps';Virtual=$false;HardwareInterface=$true})
            Interfaces=@([pscustomobject]@{InterfaceAlias='Fixture Wi-Fi';InterfaceIndex=7;AddressFamily='IPv6';ConnectionState=1;NlMtuBytes=1500;InterfaceMetric=20;Dhcp=1;RouterDiscovery=1;Forwarding=0;WeakHostSend=0;WeakHostReceive=0})
            IPAddresses=@([pscustomobject]@{InterfaceAlias='Fixture Wi-Fi';InterfaceIndex=7;AddressFamily='IPv6';IPAddress='fd12:3456:789a:1::10';PrefixLength=64;Type=1;AddressState=4;SkipAsSource=$false;PrefixOrigin=4;SuffixOrigin=4})
            ActiveRoutes=@(New-RaFixtureRoute);PersistentRoutes=@()
            DNS=@([pscustomobject]@{InterfaceAlias='Fixture Wi-Fi';InterfaceIndex=7;AddressFamily=23;ServerAddresses=@('2001:db8::53')})
            WinINETProxy=@([pscustomobject]@{ProxyEnable=0;ProxyServer=$null;ProxyOverride=$null;AutoConfigURL=$null})
            WinHTTPProxy=@([pscustomobject]@{AccessType=1;Proxy=$null;Bypass=$null})
            RelatedProcesses=@();RelatedServices=@();RelatedDrivers=@()
        }
    }
    Set-RaFixtureEvidence $before
    $after=Copy-RaFixtureValue $before
    # Same boot and adapter index: no reboot or interface-remap exception needed.
    $after.StartedAt='2026-09-17T02:05:00Z';$after.FinishedAt='2026-09-17T02:05:02Z'
    $after.Data.ActiveRoutes[0].NextHop='fe80::2'
    Set-RaFixtureEvidence $after
    [pscustomobject]@{Before=$before;After=$after}
}
function Assert-Ra([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-RaFixture {
    param([string]$Name,[scriptblock]$Edit={},[bool]$Expected=$false,[switch]$NoAllowance,[string[]]$BlockedSides=@(),[int]$LegacyCount=-1,[scriptblock]$ComparisonEdit={})
    try {
        $fixture=New-RaFixture
        & $Edit $fixture
        $comparison=Compare-TrialNetworkState -BaselineState $fixture.Before -CurrentState $fixture.After
        & $ComparisonEdit $fixture $comparison
        $original=$fixture | ConvertTo-Json -Depth 24 -Compress
        $originalDiff=$comparison | ConvertTo-Json -Depth 24 -Compress
        $script:raFixtureAdapters=$fixture.After.Data.Adapters
        $allowance=Get-MnaUiRouterAdvertisementChanges -Comparison $comparison -BaselineState $fixture.Before -CurrentState $fixture.After
        $restored=Test-MnaUiConfigurationRestored -Comparison $comparison -BaselineState $fixture.Before -CurrentState $fixture.After
        $snapshotsUnmodified=($fixture | ConvertTo-Json -Depth 24 -Compress) -ceq $original
        $diffUnmodified=($comparison | ConvertTo-Json -Depth 24 -Compress) -ceq $originalDiff
        if (-not $snapshotsUnmodified -or -not $diffUnmodified) { $script:raInputsUnmodified=$false }
        Assert-Ra $snapshotsUnmodified '原始快照/路由来源证据被修改'
        Assert-Ra $diffUnmodified '完整 comparison 被修改'
        Assert-Ra ($restored -eq $Expected) ('最终分类错误，期望 '+$Expected+'，实际 '+$restored)
        if ($NoAllowance) { Assert-Ra ($null -eq $allowance) '无效来源或身份不应产生任何路由豁免' }
        foreach ($side in $BlockedSides) { Assert-Ra ($null -eq $allowance -or @($allowance[$side+'Routes']).Count -eq 0) ('不可信的 '+$side+' 路由不能豁免') }
        if ($Expected) { Assert-Ra ($null -ne $allowance) '允许 RA 变化时必须返回显式路由豁免' }
        if ($LegacyCount -ge 0) { Assert-Ra ($allowance.LegacyReplacementCount -eq $LegacyCount) 'LegacyReplacementCount 不准确' }
        if ($allowance) {
            foreach ($side in @('Removed','Added')) {
                $actual=@($comparison.Changes | Where-Object Section -eq ActiveRoutes | ForEach-Object { $_.$side } | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress })
                foreach ($allowed in @($allowance[$side+'Routes'])) { Assert-Ra ($allowed -is [string] -and $allowed -cin $actual) '豁免必须精确引用同侧原始路由 JSON' }
                if ($Expected) { Assert-Ra (@($allowance[$side+'Routes']).Count -eq $actual.Count) '成功场景必须逐条解释所有变化路由' }
            }
        }
        $checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Failure=$null})
    } catch { $checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Failure=$_.Exception.Message}) }
}

Assert-RaFixture '同一次 Windows 启动内原生 RA ULA 路由下一跳轮换' {} $true -LegacyCount 0
Assert-RaFixture '旧基线无 metadata 时仅接受被新原生证据证明的下一跳替换' {
    param($f) $f.Before.PSObject.Properties.Remove('RouteOriginEvidence')
} $true -LegacyCount 1
Assert-RaFixture '未来完整来源快照允许 RA 前缀自然到期' {
    param($f) $f.After.Data.ActiveRoutes=@();Set-RaFixtureEvidence $f.After
} $true -LegacyCount 0
Assert-RaFixture '未来完整来源快照允许 RA 前缀重新出现' {
    param($f) $f.Before.Data.ActiveRoutes=@();Set-RaFixtureEvidence $f.Before
} $true -LegacyCount 0
Assert-RaFixture '两侧完整来源支持不同 RA 前缀独立增减' {
    param($f) $f.After.Data.ActiveRoutes[0].DestinationPrefix='fd12:3456:789a:2::/64';Set-RaFixtureEvidence $f.After
} $true -LegacyCount 0
Assert-RaFixture '完整原生证据允许 on-link RA 路由到期' {
    param($f) $f.Before.Data.ActiveRoutes[0].NextHop='::';Set-RaFixtureEvidence $f.Before;$f.After.Data.ActiveRoutes=@();Set-RaFixtureEvidence $f.After
} $true -LegacyCount 0
Assert-RaFixture '完整原生证据允许 on-link RA 路由新增' {
    param($f) $f.Before.Data.ActiveRoutes=@();Set-RaFixtureEvidence $f.Before;$f.After.Data.ActiveRoutes[0].NextHop='::';Set-RaFixtureEvidence $f.After
} $true -LegacyCount 0
Assert-RaFixture '链路本地 scope 与 ifIndex 一致时可证明来源' {
    param($f) foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].NextHop+='%7';Set-RaFixtureEvidence $s }
} $true
Assert-RaFixture '旧基线路由带正确 scope 仍可迁移' {
    param($f) foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].NextHop+='%7';Set-RaFixtureEvidence $s };$f.Before.PSObject.Properties.Remove('RouteOriginEvidence')
} $true -LegacyCount 1
Assert-RaFixture '载波和连接观测变化不改变物理接口身份' {
    param($f) $f.After.Data.Adapters[0].Status='Disconnected';$f.After.Data.Adapters[0].LinkSpeed='0 bps';$f.After.Data.Interfaces[0].ConnectionState=0
} $true
Assert-RaFixture '同一物理接口 GUID 一致' {
    param($f) foreach ($s in @($f.Before,$f.After)) { $s.Data.Adapters[0] | Add-Member InterfaceGuid '11111111-1111-1111-1111-111111111111' }
} $true
Assert-RaFixture '现有共享 Wintun 驱动保持原状不阻止 RA 恢复' {
    param($f) foreach ($s in @($f.Before,$f.After)) { $s.Data.RelatedDrivers=@([pscustomobject]@{Name='wintun';DisplayName='Shared Wintun';State='Running';Started=$true}) }
} $true
Assert-RaFixture '无关默认路由原状保留且原生证据顺序不影响归类' {
    param($f)
    foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes+=New-RaFixtureRoute 'fe80::99' '::/0';Set-RaFixtureEvidence $s }
    [array]::Reverse($f.After.RouteOriginEvidence.Routes)
} $true

foreach ($kind in @('BothEvidenceAbsent','CurrentEvidenceAbsent','CurrentEvidenceNull','CurrentEvidenceFailed','BaselineEvidenceNull','BaselineEvidenceFailed','BaselineManualOrigin','CurrentManualOrigin','CurrentUnknownOrigin','CurrentOriginMissing','NoNativeMatch','WrongNativeInterface','WrongNativePrefix','WrongNativeNextHop','DuplicateOrigin','ContradictoryOrigin','BaselineDuplicateOrigin')) {
    $globalEvidenceFailure=$kind -in @('BothEvidenceAbsent','CurrentEvidenceAbsent','CurrentEvidenceNull','CurrentEvidenceFailed','BaselineEvidenceNull','BaselineEvidenceFailed')
    $blockedSide=if ($kind.StartsWith('Baseline')) {'Removed'} else {'Added'}
    Assert-RaFixture ('来源证据不可信：'+$kind) {
        param($f)
        switch ($kind) {
            'BothEvidenceAbsent' { $f.Before.PSObject.Properties.Remove('RouteOriginEvidence');$f.After.PSObject.Properties.Remove('RouteOriginEvidence') }
            'CurrentEvidenceAbsent' { $f.After.PSObject.Properties.Remove('RouteOriginEvidence') }
            'CurrentEvidenceNull' { $f.After.RouteOriginEvidence=$null }
            'CurrentEvidenceFailed' { $f.After.RouteOriginEvidence.Complete=$false }
            'BaselineEvidenceNull' { $f.Before.RouteOriginEvidence=$null }
            'BaselineEvidenceFailed' { $f.Before.RouteOriginEvidence.Complete=$false }
            'BaselineManualOrigin' { $f.Before.RouteOriginEvidence.Routes[0].Origin=0 }
            'CurrentManualOrigin' { $f.After.RouteOriginEvidence.Routes[0].Origin=0 }
            'CurrentUnknownOrigin' { $f.After.RouteOriginEvidence.Routes[0].Origin=99 }
            'CurrentOriginMissing' { $f.After.RouteOriginEvidence.Routes[0].PSObject.Properties.Remove('Origin') }
            'NoNativeMatch' { $f.After.RouteOriginEvidence.Routes=@() }
            'WrongNativeInterface' { $f.After.RouteOriginEvidence.Routes[0].InterfaceIndex=99 }
            'WrongNativePrefix' { $f.After.RouteOriginEvidence.Routes[0].DestinationPrefix='fd12:3456:789a:9::/64' }
            'WrongNativeNextHop' { $f.After.RouteOriginEvidence.Routes[0].NextHop='fe80::99' }
            'DuplicateOrigin' { $f.After.RouteOriginEvidence.Routes+=Copy-RaFixtureValue $f.After.RouteOriginEvidence.Routes[0] }
            'ContradictoryOrigin' { $other=Copy-RaFixtureValue $f.After.RouteOriginEvidence.Routes[0];$other.Origin=0;$f.After.RouteOriginEvidence.Routes+=$other }
            'BaselineDuplicateOrigin' { $f.Before.RouteOriginEvidence.Routes+=Copy-RaFixtureValue $f.Before.RouteOriginEvidence.Routes[0] }
        }
    } -NoAllowance:$globalEvidenceFailure -BlockedSides $blockedSide
}
foreach ($kind in @('LegacyManualOrigin','LegacyUnknownOrigin','LegacyOnLink','LegacyPrefixChanged','LegacyMetricChanged','LegacyRemovalOnly','LegacyAdditionOnly','LegacyDuplicateRemoved','LegacyDuplicateAdded','LegacyAmbiguousPairs')) {
    Assert-RaFixture ('旧基线窄迁移拒绝：'+$kind) {
        param($f)
        $f.Before.PSObject.Properties.Remove('RouteOriginEvidence')
        switch ($kind) {
            'LegacyManualOrigin' { $f.After.RouteOriginEvidence.Routes[0].Origin=0 }
            'LegacyUnknownOrigin' { $f.After.RouteOriginEvidence.Routes[0].Origin=99 }
            'LegacyOnLink' { $f.After.Data.ActiveRoutes[0].NextHop='::';Set-RaFixtureEvidence $f.After }
            'LegacyPrefixChanged' { $f.After.Data.ActiveRoutes[0].DestinationPrefix='fd12:3456:789a:2::/64';Set-RaFixtureEvidence $f.After }
            'LegacyMetricChanged' { $f.After.Data.ActiveRoutes[0].RouteMetric=257 }
            'LegacyRemovalOnly' { $f.After.Data.ActiveRoutes=@();Set-RaFixtureEvidence $f.After }
            'LegacyAdditionOnly' { $f.Before.Data.ActiveRoutes=@() }
            'LegacyDuplicateRemoved' { $f.Before.Data.ActiveRoutes+=Copy-RaFixtureValue $f.Before.Data.ActiveRoutes[0] }
            'LegacyDuplicateAdded' { $f.After.Data.ActiveRoutes+=Copy-RaFixtureValue $f.After.Data.ActiveRoutes[0] }
            'LegacyAmbiguousPairs' { $f.Before.Data.ActiveRoutes+=New-RaFixtureRoute 'fe80::3';$f.After.Data.ActiveRoutes+=New-RaFixtureRoute 'fe80::4';Set-RaFixtureEvidence $f.After }
        }
    } -NoAllowance
}
foreach ($kind in @('Virtual','NotHardware','UnknownInterface','DuplicateAdapter','AliasMismatch','RenamedHardware','ChangedDescription','ChangedIndex','RouterDiscoveryOff','RouterDiscoveryMissing','DuplicateInterface','InterfaceMtuChanged','InterfaceFamilyWrong','WrongScope','NativeWrongScope','GlobalScope','UnspecifiedScope','NonUla','DefaultPrefix','WrongPrefixLength','PrefixHostBits','ExpandedNonCanonicalPrefix','InvalidPrefix','GlobalNextHop','MulticastNextHop','InvalidNextHop','Protocol4','ProtocolLocal2','WrongMetric','Published','PersistentSameRoute')) {
    $onlyAddedInvalid=$kind -in @('AliasMismatch','WrongScope','NativeWrongScope','GlobalScope','UnspecifiedScope','InvalidPrefix','GlobalNextHop','MulticastNextHop','InvalidNextHop')
    Assert-RaFixture ('路由及接口约束：'+$kind) {
        param($f)
        switch ($kind) {
            'Virtual' { foreach ($s in @($f.Before,$f.After)) { $s.Data.Adapters[0].Virtual=$true } }
            'NotHardware' { foreach ($s in @($f.Before,$f.After)) { $s.Data.Adapters[0].HardwareInterface=$false } }
            'UnknownInterface' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].InterfaceIndex=99;Set-RaFixtureEvidence $s } }
            'DuplicateAdapter' { $f.After.Data.Adapters+=Copy-RaFixtureValue $f.After.Data.Adapters[0] }
            'AliasMismatch' { $f.After.Data.ActiveRoutes[0].InterfaceAlias='Other interface' }
            'RenamedHardware' { $f.After.Data.Adapters[0].Name='Other interface' }
            'ChangedDescription' { $f.After.Data.Adapters[0].InterfaceDescription='Replacement hardware' }
            'ChangedIndex' { $f.After.Data.Adapters[0].ifIndex=8;$f.After.Data.Interfaces[0].InterfaceIndex=8;$f.After.Data.ActiveRoutes[0].InterfaceIndex=8;Set-RaFixtureEvidence $f.After }
            'RouterDiscoveryOff' { foreach ($s in @($f.Before,$f.After)) { $s.Data.Interfaces[0].RouterDiscovery=0 } }
            'RouterDiscoveryMissing' { foreach ($s in @($f.Before,$f.After)) { $s.Data.Interfaces[0].PSObject.Properties.Remove('RouterDiscovery') } }
            'DuplicateInterface' { $f.After.Data.Interfaces+=Copy-RaFixtureValue $f.After.Data.Interfaces[0] }
            'InterfaceMtuChanged' { $f.After.Data.Interfaces[0].NlMtuBytes=1400 }
            'InterfaceFamilyWrong' { foreach ($s in @($f.Before,$f.After)) { $s.Data.Interfaces[0].AddressFamily='IPv4' } }
            'WrongScope' { $f.After.Data.ActiveRoutes[0].NextHop='fe80::2%99';Set-RaFixtureEvidence $f.After }
            'NativeWrongScope' { $f.After.RouteOriginEvidence.Routes[0].NextHop='fe80::2%99' }
            'GlobalScope' { $f.After.Data.ActiveRoutes[0].NextHop='fd12::2%7';Set-RaFixtureEvidence $f.After }
            'UnspecifiedScope' { $f.After.Data.ActiveRoutes[0].NextHop='::%7';Set-RaFixtureEvidence $f.After }
            'NonUla' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].DestinationPrefix='2001:db8::/64';Set-RaFixtureEvidence $s } }
            'DefaultPrefix' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].DestinationPrefix='::/0';Set-RaFixtureEvidence $s } }
            'WrongPrefixLength' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].DestinationPrefix='fd12:3456:789a:1::/48';Set-RaFixtureEvidence $s } }
            'PrefixHostBits' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].DestinationPrefix='fd12:3456:789a:1::10/64';Set-RaFixtureEvidence $s } }
            'ExpandedNonCanonicalPrefix' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].DestinationPrefix='fd12:3456:789a:0001:0000:0000:0000:0000/64';Set-RaFixtureEvidence $s } }
            'InvalidPrefix' { $f.After.Data.ActiveRoutes[0].DestinationPrefix='fd-invalid/64';Set-RaFixtureEvidence $f.After }
            'GlobalNextHop' { $f.After.Data.ActiveRoutes[0].NextHop='2001:db8::1';Set-RaFixtureEvidence $f.After }
            'MulticastNextHop' { $f.After.Data.ActiveRoutes[0].NextHop='ff02::1';Set-RaFixtureEvidence $f.After }
            'InvalidNextHop' { $f.After.Data.ActiveRoutes[0].NextHop='not-an-ip';Set-RaFixtureEvidence $f.After }
            'Protocol4' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].Protocol=4 } }
            'ProtocolLocal2' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].Protocol=2 } }
            'WrongMetric' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].RouteMetric=12 } }
            'Published' { foreach ($s in @($f.Before,$f.After)) { $s.Data.ActiveRoutes[0].Publish=1 } }
            'PersistentSameRoute' { foreach ($s in @($f.Before,$f.After)) { $s.Data.PersistentRoutes=@(Copy-RaFixtureValue $s.Data.ActiveRoutes[0]) } }
        }
    } -NoAllowance:(-not $onlyAddedInvalid) -BlockedSides Added
}
foreach ($kind in @('IncompleteBefore','IncompleteAfter','ReadError','MissingSection','NullSection','SdkProcess','SdkService','SdkDriver','SdkServiceUnchanged','SdkDriverUnchanged','TunAdapter','TunRoute')) {
    Assert-RaFixture ('快照及残留保护：'+$kind) {
        param($f)
        switch ($kind) {
            'IncompleteBefore' { $f.Before.Complete=$false }
            'IncompleteAfter' { $f.After.Complete=$false }
            'ReadError' { $f.After.ReadErrors=@([pscustomobject]@{Section='ActiveRoutes';ErrorType='Fixture'}) }
            'MissingSection' { $f.After.Data.PSObject.Properties.Remove('RelatedDrivers') }
            'NullSection' { $f.After.Data.DNS=$null }
            'SdkProcess' { $f.After.Data.RelatedProcesses=@([pscustomobject]@{Name='linkboost.exe';ProcessId=123}) }
            'SdkService' { $f.After.Data.RelatedServices=@([pscustomobject]@{Name='linkboost';DisplayName='SDK service'}) }
            'SdkDriver' { $f.After.Data.RelatedDrivers=@([pscustomobject]@{Name='multipath';DisplayName='SDK driver'}) }
            'SdkServiceUnchanged' { foreach ($s in @($f.Before,$f.After)) { $s.Data.RelatedServices=@([pscustomobject]@{Name='linkboost';DisplayName='SDK service'}) } }
            'SdkDriverUnchanged' { foreach ($s in @($f.Before,$f.After)) { $s.Data.RelatedDrivers=@([pscustomobject]@{Name='multipath';DisplayName='SDK driver'}) } }
            'TunAdapter' { $f.After.Data.Adapters+= [pscustomobject]@{Name='mp_tun0';InterfaceDescription='SDK tunnel';ifIndex=99;Virtual=$true;HardwareInterface=$false} }
            'TunRoute' { $route=New-RaFixtureRoute;$route.InterfaceAlias='mna_game_abcdef';$route.InterfaceIndex=99;$f.After.Data.ActiveRoutes+=$route;Set-RaFixtureEvidence $f.After }
        }
    } -NoAllowance
}
foreach ($kind in @('DNS','PersistentRoute','DefaultRoute','WinINETProxy','WinHTTPProxy','ManualUlaAddress','UnrelatedIpv4Route')) {
    Assert-RaFixture ('允许 RA 不得掩盖其他配置差异：'+$kind) {
        param($f)
        switch ($kind) {
            'DNS' { $f.After.Data.DNS[0].ServerAddresses=@('2001:db8::99') }
            'PersistentRoute' { $f.After.Data.PersistentRoutes=@(New-RaFixtureRoute 'fe80::99' 'fd12:3456:789a:9::/64') }
            'DefaultRoute' { $f.After.Data.ActiveRoutes+=New-RaFixtureRoute 'fe80::99' '::/0';Set-RaFixtureEvidence $f.After }
            'WinINETProxy' { $f.After.Data.WinINETProxy[0].ProxyEnable=1 }
            'WinHTTPProxy' { $f.After.Data.WinHTTPProxy[0].Proxy='127.0.0.1:8888' }
            'ManualUlaAddress' { $a=Copy-RaFixtureValue $f.After.Data.IPAddresses[0];$a.IPAddress='fd12:3456:789a:1::99';$a.PrefixOrigin=1;$a.SuffixOrigin=1;$f.After.Data.IPAddresses+=$a }
            'UnrelatedIpv4Route' { $r=New-RaFixtureRoute '192.0.2.1' '198.51.100.0/24';$r.AddressFamily='IPv4';$f.After.Data.ActiveRoutes+=$r }
        }
    }
}
foreach ($kind in @('ComparisonMissingRemoved','ComparisonForgedRoute','ComparisonDuplicateRoute','ComparisonIncomplete','SnapshotAfterComparison','BadSchema')) {
    Assert-RaFixture ('禁止信任伪造或过期 comparison：'+$kind) -ComparisonEdit {
        param($f,$c)
        $change=@($c.Changes | Where-Object Section -eq ActiveRoutes)[0]
        switch ($kind) {
            'ComparisonMissingRemoved' { $change.Removed=@() }
            'ComparisonForgedRoute' { $change.Added[0].NextHop='fe80::99' }
            'ComparisonDuplicateRoute' { $change.Added+=Copy-RaFixtureValue $change.Added[0] }
            'ComparisonIncomplete' { $c.FullyComparable=$false }
            'SnapshotAfterComparison' { $f.After.Data.ActiveRoutes[0].NextHop='fe80::99';Set-RaFixtureEvidence $f.After }
            'BadSchema' { $f.After.SchemaVersion=99 }
        }
    } -NoAllowance
}

$passed=$checks.Count -gt 0 -and @($checks | Where-Object { -not $_.Passed }).Count -eq 0
[pscustomobject]@{Passed=$passed;CheckCount=$checks.Count;NetworkStarted=$false;SdkStarted=$false;RealUserStateAccessed=$false;InputsUnmodified=$script:raInputsUnmodified;Checks=$checks.ToArray()} | ConvertTo-Json -Depth 6
if (-not $passed) { exit 1 }
