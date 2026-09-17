#requires -Version 7.0
# Offline release checks. Creates dummy executables/key bytes in an isolated
# tests fixture, generates YAML, and removes that fixture. The optional helper
# check runs only its -t config parser; never starts forwarding, SDK, TUN, game,
# or cloud authentication. No real settings/private files are read.
[CmdletBinding()]
param([switch]$ValidateHelperConfiguration)
$ErrorActionPreference='Stop'
$releaseRoot=Split-Path $PSScriptRoot -Parent
$backend=Join-Path $releaseRoot 'app/backend'
$checks=[Collections.Generic.List[string]]::new()

function Assert-Offline([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('离线验证失败：'+$Message) }
    $checks.Add($Message)
}
function Assert-OfflineThrows([scriptblock]$Action,[string]$Expected,[string]$Name) {
    $failure=$null
    try { $null=& $Action } catch { $failure=$_.Exception.Message }
    Assert-Offline ($null -ne $failure -and $failure.Contains($Expected)) $Name
}
# Guards catch an accidental expansion of the file-only test into a runtime test.
function Start-Process { throw '离线验证禁止启动进程' }
function Invoke-RestMethod { throw '离线验证禁止网络请求' }
function Invoke-WebRequest { throw '离线验证禁止网络请求' }
function Get-NetAdapter { throw '离线验证不读取或修改网卡' }
function Get-NetRoute { throw '离线验证不读取或修改路由' }
function New-NetRoute { throw '离线验证禁止修改路由' }
function Set-DnsClientServerAddress { throw '离线验证禁止修改 DNS' }

$expected=@('Control-Accelerator.ps1','Run-Accelerator.ps1','Mna-UI.Common.ps1','Mna-GameRoute.ps1','Mna-RebootRecovery.ps1','Mna-SessionRecovery.ps1','Trial-NetworkState.ps1','Test-UdpStun.ps1','Check-Configuration.ps1')
foreach ($name in $expected) {
    $path=Join-Path $backend $name
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    Assert-Offline (@($parseErrors).Count -eq 0) ('PowerShell 语法：'+$name)
    $source=$ast.Extent.Text
    Assert-Offline (-not $source.Contains('FullGame')) ('无全游戏模式：'+$name)
    Assert-Offline (-not $source.Contains('Get-GameRouteTargets') -and -not $source.Contains('Get-MnaGameRouteTargets')) ('无历史地址日志依赖：'+$name)
    if ($name -eq 'Control-Accelerator.ps1') {
        Assert-Offline (($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -join ',') -eq 'Action') '控制入口没有模式切换参数'
    }
    if ($name -eq 'Run-Accelerator.ps1') {
        Assert-Offline (($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -join ',') -eq 'RunId') '后台入口没有模式切换参数'
        Assert-Offline ($source.Contains("area='hongkong';speedMode=35")) '保留香港 speedMode 35'
        Assert-Offline ($source.Contains('-GameExecutable $uiSettings.GameExecutable')) '已验证设置传入线路生成器'
    }
}
. (Join-Path $backend 'Mna-UI.Common.ps1')
. (Join-Path $backend 'Mna-GameRoute.ps1')
. (Join-Path $backend 'Trial-NetworkState.ps1')

function Test-NetworkComparisonFixtures {
    # Only this test scope supplies fabricated adapter identities; the outer
    # Get-NetAdapter guard still forbids reading any real network adapter.
    function Get-NetAdapter { @([pscustomobject]@{ifIndex=7;HardwareInterface=$true},[pscustomobject]@{ifIndex=99;HardwareInterface=$false}) }
    function New-FixtureAddress([int]$Suffix=4,[int]$Index=7,[string]$Ip='fd12:3456:789a:1::10',[int]$Length=64) {
        [pscustomobject]@{InterfaceAlias='Fixture';InterfaceIndex=$Index;AddressFamily='IPv6';IPAddress=$Ip;PrefixLength=$Length;Type=1;AddressState=3;SkipAsSource=$false;PrefixOrigin=4;SuffixOrigin=$Suffix}
    }
    function New-FixtureRoute([string]$Prefix='fd12:3456:789a:1::/64',[int]$Protocol=3,[int]$Index=7) {
        [pscustomobject]@{InterfaceAlias='Fixture';InterfaceIndex=$Index;AddressFamily='IPv6';DestinationPrefix=$Prefix;NextHop='::';RouteMetric=256;Protocol=$Protocol;Publish=0}
    }
    function New-FixtureState([object[]]$Addresses=@(),[object[]]$Routes=@(),[object[]]$Dns=@(),[object[]]$Persistent=@()) {
        [pscustomobject]@{SchemaVersion=1;Complete=$true;FinishedAt='2026-09-15T00:00:00+10:00';ReadErrors=@();Data=[pscustomobject]@{IPAddresses=$Addresses;ActiveRoutes=$Routes;DNS=$Dns;PersistentRoutes=$Persistent}}
    }
    function Assert-NetworkFixture([string]$Name,$Before,$After,[bool]$Expected) {
        $comparison=Compare-TrialNetworkState -BaselineState $Before -CurrentState $After
        $original=$comparison | ConvertTo-Json -Depth 12 -Compress
        Assert-Offline ((Test-MnaUiConfigurationRestored $comparison) -eq $Expected) ('网络归类：'+$Name)
        if (($comparison | ConvertTo-Json -Depth 12 -Compress) -cne $original) { throw '网络归类改写了原始差异证据' }
    }
    $empty=New-FixtureState
    $link=New-FixtureAddress
    $random=New-FixtureAddress -Suffix 5 -Ip 'fd12:3456:789a:1::20' -Length 128
    $prefix=New-FixtureRoute
    $linkHost=New-FixtureRoute -Prefix ($link.IPAddress+'/128') -Protocol 2
    $randomHost=New-FixtureRoute -Prefix ($random.IPAddress+'/128') -Protocol 2
    $automatic=New-FixtureState -Addresses @($link,$random) -Routes @($linkHost,$randomHost)
    Assert-NetworkFixture 'RA Link 和 Random 地址连同附属路由到期可归类，保留完整差异' $automatic $empty $true
    Assert-NetworkFixture '同样来源的地址及附属路由重新出现可归类' $empty $automatic $true
    $stateChanged=New-FixtureAddress;$stateChanged.AddressState=4
    Assert-NetworkFixture '物理地址仅 AddressState 变化不当作配置变更' (New-FixtureState -Addresses @($link)) (New-FixtureState -Addresses @($stateChanged)) $true

    foreach ($kind in @('Manual','Unknown','ManualSuffix','GlobalIpv6','MalformedIpv6','VirtualInterface','UnknownInterface','UnexpectedLength','SkipAsSource')) {
        $address=New-FixtureAddress
        switch ($kind) {
            'Manual' {$address.PrefixOrigin=1;$address.SuffixOrigin=1}
            'Unknown' {$address.PrefixOrigin=0;$address.SuffixOrigin=0}
            'ManualSuffix' {$address.SuffixOrigin=1}
            'GlobalIpv6' {$address.IPAddress='2001:db8::10'}
            'MalformedIpv6' {$address.IPAddress='fd-invalid'}
            'VirtualInterface' {$address.InterfaceIndex=99}
            'UnknownInterface' {$address.InterfaceIndex=77}
            'UnexpectedLength' {$address.PrefixLength=48}
            'SkipAsSource' {$address.SkipAsSource=$true}
        }
        Assert-NetworkFixture ('仍拦截地址 '+$kind) (New-FixtureState -Addresses @($address)) $empty $false
    }
    $changed=New-FixtureAddress;$changed.PrefixLength=128;$changed.SuffixOrigin=5
    Assert-NetworkFixture '同一地址修改前缀或生成方式不可伪装成轮换' (New-FixtureState -Addresses @($link)) (New-FixtureState -Addresses @($changed)) $false
    $manual=New-FixtureAddress -Ip 'fd12:3456:789a:1::30';$manual.PrefixOrigin=1;$manual.SuffixOrigin=1
    Assert-NetworkFixture '自动与手工地址混合变更仍拦截' (New-FixtureState -Addresses @($link,$manual)) $empty $false

    foreach ($kind in @('UnrelatedPrefix','RemoteNextHop','DefaultIpv6','GlobalIpv6','UnknownProtocol','ChangedMetric','Published','VirtualInterface','UnknownInterface','WrongLocalAddress','PrefixHostBits')) {
        $route=New-FixtureRoute -Prefix ($link.IPAddress+'/128') -Protocol 2
        switch ($kind) {
            'UnrelatedPrefix' {$route.DestinationPrefix='fd12:3456:789a:99::/64'}
            'RemoteNextHop' {$route.NextHop='fe80::1'}
            'DefaultIpv6' {$route.DestinationPrefix='::/0'}
            'GlobalIpv6' {$route.DestinationPrefix='2001:db8::/64'}
            'UnknownProtocol' {$route.Protocol=1}
            'ChangedMetric' {$route.RouteMetric=12}
            'Published' {$route.Publish=1}
            'VirtualInterface' {$route.InterfaceIndex=99}
            'UnknownInterface' {$route.InterfaceIndex=77}
            'WrongLocalAddress' {$route.Protocol=2;$route.DestinationPrefix='fd12:3456:789a:1::99/128'}
            'PrefixHostBits' {$route.DestinationPrefix='fd12:3456:789a:1::99/64'}
        }
        Assert-NetworkFixture ('仍拦截路由 '+$kind) (New-FixtureState -Addresses @($link,$random) -Routes @($route)) $empty $false
    }
    Assert-NetworkFixture 'NetMgmt 协议与 ULA 形状不能单独证明自动路由' (New-FixtureState -Routes @($prefix)) $empty $false
    Assert-NetworkFixture 'NetMgmt /64 即使同侧有相同 RA 前缀也不推断为自动路由' (New-FixtureState -Addresses @($link) -Routes @($prefix)) $empty $false
    $finitePrefix=New-FixtureRoute;$finitePrefix | Add-Member -NotePropertyName FiniteLifetime -NotePropertyValue $true
    Assert-NetworkFixture '有限寿命也不能证明 NetMgmt /64 非手工路由' (New-FixtureState -Addresses @($link) -Routes @($finitePrefix)) $empty $false
    Assert-NetworkFixture 'Local host 路由没有同侧自动地址证据仍拦截' (New-FixtureState -Routes @($linkHost)) $empty $false
    Assert-NetworkFixture '路由消失不能由另一侧新地址解释' (New-FixtureState -Routes @($linkHost)) (New-FixtureState -Addresses @($link)) $false
    Assert-NetworkFixture '手工地址关联的 on-link 前缀仍拦截' (New-FixtureState -Addresses @($manual) -Routes @($prefix)) $empty $false
    $v4=New-FixtureAddress;$v4.AddressFamily='IPv4';$v4.IPAddress='192.0.2.10';$v4.PrefixLength=24
    Assert-NetworkFixture 'IPv4 地址变化仍拦截' (New-FixtureState -Addresses @($v4)) $empty $false
    $v4Route=New-FixtureRoute;$v4Route.AddressFamily='IPv4';$v4Route.DestinationPrefix='0.0.0.0/0';$v4Route.NextHop='192.0.2.1'
    Assert-NetworkFixture 'IPv4 默认路由变化仍拦截' (New-FixtureState -Routes @($v4Route)) $empty $false
    Assert-NetworkFixture 'DNS 即使同时发生自动地址轮换仍拦截' (New-FixtureState -Addresses @($link) -Dns @([pscustomobject]@{InterfaceIndex=7;ServerAddresses=@('192.0.2.53')})) $empty $false
    Assert-NetworkFixture '持久路由变化仍拦截' (New-FixtureState -Persistent @($prefix)) $empty $false
    $incomplete=New-FixtureState;$incomplete.Complete=$false
    Assert-NetworkFixture '不完整快照即使无差异仍拦截' $incomplete $empty $false
    Assert-NetworkFixture '完整且无差异继续通过' $empty $empty $true
}
Test-NetworkComparisonFixtures

function Test-DisconnectedDhcpFixtures {
    function Get-NetAdapter { @([pscustomobject]@{ifIndex=7;HardwareInterface=$true},[pscustomobject]@{ifIndex=99;HardwareInterface=$false}) }
    function New-DhcpFixture {
        $dhcp=[pscustomobject]@{InterfaceAlias='Fixture Ethernet';InterfaceIndex=7;AddressFamily='IPv4';IPAddress='192.0.2.10';PrefixLength=24;Type=1;AddressState=3;SkipAsSource=$false;PrefixOrigin=3;SuffixOrigin=3}
        $apipa=[pscustomobject]@{InterfaceAlias='Fixture Ethernet';InterfaceIndex=7;AddressFamily='IPv4';IPAddress='169.254.10.123';PrefixLength=16;Type=1;AddressState=1;SkipAsSource=$false;PrefixOrigin=2;SuffixOrigin=4}
        $routes=@('192.0.2.0/24','192.0.2.10/32','192.0.2.255/32' | ForEach-Object {
            [pscustomobject]@{InterfaceAlias='Fixture Ethernet';InterfaceIndex=7;AddressFamily='IPv4';DestinationPrefix=$_;NextHop='0.0.0.0';RouteMetric=256;Protocol=2;Publish=0}
        })
        $before=[pscustomobject]@{SchemaVersion=1;Complete=$true;FinishedAt='2026-09-15T00:00:00+10:00';ReadErrors=@();Data=[pscustomobject]@{
            Adapters=@([pscustomobject]@{Name='Fixture Ethernet';InterfaceDescription='Offline physical adapter';ifIndex=7;Status='Disconnected';LinkSpeed='1 Gbps';Virtual=$false;HardwareInterface=$true})
            Interfaces=@([pscustomobject]@{InterfaceAlias='Fixture Ethernet';InterfaceIndex=7;AddressFamily='IPv4';ConnectionState=0;NlMtuBytes=1500;InterfaceMetric=20;Dhcp=1;RouterDiscovery=2;Forwarding=0;WeakHostSend=0;WeakHostReceive=0})
            IPAddresses=@($dhcp);ActiveRoutes=$routes;DNS=@();PersistentRoutes=@()
            WinINETProxy=@();WinHTTPProxy=@();RelatedProcesses=@();RelatedServices=@();RelatedDrivers=@()
        }}
        $after=$before | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $after.Data.IPAddresses=@($apipa);$after.Data.ActiveRoutes=@()
        [pscustomobject]@{Before=$before;After=$after}
    }
    function Assert-DhcpFixture([string]$Name,[scriptblock]$Edit,[bool]$Expected=$false,[switch]$WithoutContext,[scriptblock]$EditComparison) {
        $fixture=New-DhcpFixture
        if ($Edit) { & $Edit $fixture }
        $comparison=Compare-TrialNetworkState -BaselineState $fixture.Before -CurrentState $fixture.After
        if ($EditComparison) { & $EditComparison $comparison $fixture }
        $saved=@($comparison,$fixture.Before,$fixture.After) | ConvertTo-Json -Depth 14 -Compress
        $result=if ($WithoutContext) { Test-MnaUiConfigurationRestored $comparison } else {
            Test-MnaUiConfigurationRestored $comparison -BaselineState $fixture.Before -CurrentState $fixture.After
        }
        Assert-Offline ($result -eq $Expected) ('断开 DHCP 归类：'+$Name)
        if ((@($comparison,$fixture.Before,$fixture.After) | ConvertTo-Json -Depth 14 -Compress) -cne $saved) { throw 'DHCP 归类改写了原始快照或差异' }
    }
    Assert-DhcpFixture '脱敏重放 DHCP 到 Tentative APIPA 和三条本地路由消失' {} $true
    Assert-DhcpFixture 'APIPA 已完成地址探测仍可归类' {param($f) $f.After.Data.IPAddresses[0].AddressState=4} $true
    Assert-DhcpFixture 'APIPA 三条精确附属路由出现仍可归类' {param($f)
        $f.After.Data.ActiveRoutes=@('169.254.0.0/16','169.254.10.123/32','169.254.255.255/32' | ForEach-Object {
            [pscustomobject]@{InterfaceAlias='Fixture Ethernet';InterfaceIndex=7;AddressFamily='IPv4';DestinationPrefix=$_;NextHop='0.0.0.0';RouteMetric=256;Protocol=2;Publish=0}
        })
    } $true
    Assert-DhcpFixture '物理链路速度观察变化不妨碍断开证据' {param($f) $f.After.Data.Adapters[0].LinkSpeed='0 bps'} $true
    Assert-DhcpFixture '旧调用没有上下文仍拒绝 IPv4 变化' {} $false -WithoutContext
    foreach ($missingSection in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','WinINETProxy','WinHTTPProxy','RelatedProcesses','RelatedServices','RelatedDrivers')) {
        foreach ($missingSide in @('Before','After','Both')) {
            Assert-DhcpFixture ('缺少完整快照节 '+$missingSide+'/'+$missingSection) {
                param($f)
                if ($missingSide -in @('Before','Both')) { $f.Before.Data.PSObject.Properties.Remove($missingSection) }
                if ($missingSide -in @('After','Both')) { $f.After.Data.PSObject.Properties.Remove($missingSection) }
            }
        }
    }
    foreach ($kind in @('BeforeIncomplete','AfterIncomplete','ReadError','MissingSection','BeforeConnected','AfterConnected','Virtual','NotHardware','UnknownLiveAdapter','MissingAdapter','DuplicateAdapter','AdapterNameChanged','DhcpDisabled','InterfaceConnected','InterfaceMetricChanged','MissingInterface','DuplicateInterface','InterfaceAliasMismatch')) {
        Assert-DhcpFixture ('不充分接口证据 '+$kind) {
            param($f)
            switch ($kind) {
                'BeforeIncomplete' {$f.Before.Complete=$false}
                'AfterIncomplete' {$f.After.Complete=$false}
                'ReadError' {$f.After.ReadErrors=@([pscustomobject]@{Section='DNS';ErrorType='Fixture'})}
                'MissingSection' {$f.Before.Data.PSObject.Properties.Remove('Adapters')}
                'BeforeConnected' {$f.Before.Data.Adapters[0].Status='Up'}
                'AfterConnected' {$f.After.Data.Adapters[0].Status='Up'}
                'Virtual' {$f.Before.Data.Adapters[0].Virtual=$true;$f.After.Data.Adapters[0].Virtual=$true}
                'NotHardware' {$f.Before.Data.Adapters[0].HardwareInterface=$false;$f.After.Data.Adapters[0].HardwareInterface=$false}
                'UnknownLiveAdapter' {
                    foreach ($state in @($f.Before,$f.After)) {
                        $state.Data.Adapters[0].ifIndex=77
                        foreach ($section in @('Interfaces','IPAddresses','ActiveRoutes')) { foreach ($item in @($state.Data.$section)) {$item.InterfaceIndex=77} }
                    }
                }
                'MissingAdapter' {$f.After.Data.Adapters=@()}
                'DuplicateAdapter' {$f.Before.Data.Adapters+=($f.Before.Data.Adapters[0] | ConvertTo-Json | ConvertFrom-Json)}
                'AdapterNameChanged' {$f.After.Data.Adapters[0].Name='Changed'}
                'DhcpDisabled' {$f.Before.Data.Interfaces[0].Dhcp=0;$f.After.Data.Interfaces[0].Dhcp=0}
                'InterfaceConnected' {$f.Before.Data.Interfaces[0].ConnectionState=1;$f.After.Data.Interfaces[0].ConnectionState=1}
                'InterfaceMetricChanged' {$f.After.Data.Interfaces[0].InterfaceMetric=10}
                'MissingInterface' {$f.After.Data.Interfaces=@()}
                'DuplicateInterface' {$f.After.Data.Interfaces+=($f.After.Data.Interfaces[0] | ConvertTo-Json | ConvertFrom-Json)}
                'InterfaceAliasMismatch' {$f.Before.Data.Interfaces[0].InterfaceAlias='Other';$f.After.Data.Interfaces[0].InterfaceAlias='Other'}
            }
        }
    }
    foreach ($kind in @('ManualDhcp','UnknownDhcp','ManualApipa','UnknownApipa','WrongApipaAddress','WrongApipaPrefix','WrongDhcpPrefix','MalformedDhcp','MalformedApipa','DhcpSkipSource','ApipaSkipSource','WrongType','DuplicateState','AddressAliasMismatch','SameIpChangedConfiguration','ExtraAddress','ReverseTransition')) {
        Assert-DhcpFixture ('不认可地址变化 '+$kind) {
            param($f)
            $dhcp=$f.Before.Data.IPAddresses[0];$apipa=$f.After.Data.IPAddresses[0]
            switch ($kind) {
                'ManualDhcp' {$dhcp.PrefixOrigin=1;$dhcp.SuffixOrigin=1}
                'UnknownDhcp' {$dhcp.PrefixOrigin=0;$dhcp.SuffixOrigin=0}
                'ManualApipa' {$apipa.PrefixOrigin=1;$apipa.SuffixOrigin=1}
                'UnknownApipa' {$apipa.PrefixOrigin=0;$apipa.SuffixOrigin=0}
                'WrongApipaAddress' {$apipa.IPAddress='192.0.2.20'}
                'WrongApipaPrefix' {$apipa.PrefixLength=24}
                'WrongDhcpPrefix' {$dhcp.PrefixLength=33}
                'MalformedDhcp' {$dhcp.IPAddress='192.0.2.999'}
                'MalformedApipa' {$apipa.IPAddress='169.254.invalid'}
                'DhcpSkipSource' {$dhcp.SkipAsSource=$true}
                'ApipaSkipSource' {$apipa.SkipAsSource=$true}
                'WrongType' {$apipa.Type=2}
                'DuplicateState' {$apipa.AddressState=2}
                'AddressAliasMismatch' {$apipa.InterfaceAlias='Other'}
                'SameIpChangedConfiguration' {$apipa.IPAddress=$dhcp.IPAddress}
                'ExtraAddress' {$f.After.Data.IPAddresses+=($apipa | ConvertTo-Json | ConvertFrom-Json)}
                'ReverseTransition' {$f.Before.Data.IPAddresses=@($apipa);$f.After.Data.IPAddresses=@($dhcp);$f.After.Data.ActiveRoutes=$f.Before.Data.ActiveRoutes;$f.Before.Data.ActiveRoutes=@()}
            }
        }
    }
    foreach ($kind in @('WrongInterface','WrongAlias','WrongSide','WrongHost','WrongNetwork','HostBitsInNetwork','WrongBroadcast','NonzeroNextHop','NetMgmtProtocol','UnknownProtocol','ChangedMetric','Published','DefaultRoute','PersistentRoute','DnsChange')) {
        Assert-DhcpFixture ('不认可路由或配置变化 '+$kind) {
            param($f)
            $route=$f.Before.Data.ActiveRoutes[0]
            switch ($kind) {
                'WrongInterface' {$route.InterfaceIndex=99}
                'WrongAlias' {$route.InterfaceAlias='Other'}
                'WrongSide' {$route.DestinationPrefix='169.254.0.0/16'}
                'WrongHost' {$route.DestinationPrefix='192.0.2.11/32'}
                'WrongNetwork' {$route.DestinationPrefix='192.0.3.0/24'}
                'HostBitsInNetwork' {$route.DestinationPrefix='192.0.2.1/24'}
                'WrongBroadcast' {$route.DestinationPrefix='192.0.3.255/32'}
                'NonzeroNextHop' {$route.NextHop='192.0.2.1'}
                'NetMgmtProtocol' {$route.Protocol=3}
                'UnknownProtocol' {$route.Protocol=1}
                'ChangedMetric' {$route.RouteMetric=12}
                'Published' {$route.Publish=1}
                'DefaultRoute' {$route.DestinationPrefix='0.0.0.0/0'}
                'PersistentRoute' {$f.Before.Data.PersistentRoutes=@($route)}
                'DnsChange' {$f.Before.Data.DNS=@([pscustomobject]@{InterfaceIndex=7;ServerAddresses=@('192.0.2.53')})}
            }
        }
    }
    Assert-DhcpFixture '无地址转换证据的孤立本地路由仍拒绝' {param($f) $f.Before.Data.IPAddresses=@();$f.After.Data.IPAddresses=@()}
    Assert-DhcpFixture '差异未包含快照中的路由变化仍拒绝' {} $false -EditComparison {param($c,$f) $c.Changes=@($c.Changes | Where-Object Section -eq 'IPAddresses')}
    Assert-DhcpFixture '差异与提供的快照不是同一次比较仍拒绝' {} $false -EditComparison {param($c,$f) $f.After.Data.IPAddresses[0].IPAddress='169.254.11.123'}
}
Test-DisconnectedDhcpFixtures
$originalBackendRoot=$script:MnaUiRoot
$fixtureBase=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'offline-work'))
$fixtureRoot=Join-Path $fixtureBase ([guid]::NewGuid().ToString('N'))
$session=$null
try {
    $fixtureApp=Join-Path $fixtureRoot 'app'
    $fixtureBackend=Join-Path $fixtureApp 'backend'
    $gameDirectory=Join-Path $fixtureRoot "Program Files (x86)\朋友 游戏目录 O'Brien"
    $gameExecutable=Join-Path $gameDirectory 'DeltaForceClient-Win64-Shipping.exe'
    $secondGameDirectory=Join-Path $fixtureRoot 'WeGameApps/rail_apps/DeltaForce(2001918)/DeltaForce/Binaries/Win64'
    $secondGameExecutable=Join-Path $secondGameDirectory 'DeltaForceClient-Win64-Shipping.exe'
    foreach ($directory in @($fixtureBackend,$gameDirectory,$secondGameDirectory,(Join-Path $fixtureApp 'runtime'))) { $null=New-Item -ItemType Directory -Path $directory -Force }
    [IO.File]::WriteAllBytes($gameExecutable,[byte[]]@())
    [IO.File]::WriteAllBytes($secondGameExecutable,[byte[]]@())
    Assert-Offline (-not $gameExecutable.StartsWith('D:',[StringComparison]::OrdinalIgnoreCase)) '测试覆盖非 D 盘路径'
    $script:MnaUiRoot=$fixtureBackend
    $paths=Get-MnaUiPaths
    Assert-Offline ($paths.App -eq $fixtureApp -and $paths.Settings -eq (Join-Path $fixtureApp 'user-settings.json')) '用户设置位于 backend 父目录'
    Assert-Offline ($paths.PowerShell -eq (Join-Path $fixtureApp 'runtime/pwsh.exe')) '使用分享包 PowerShell 路径'

    Assert-OfflineThrows { Assert-MnaReleaseConfiguration } '首次设置' '缺配置时拒绝启动'
    $emptyStatus=Get-MnaUiStatus
    Assert-Offline ($emptyStatus.routingMode -eq 'ResolveOnly' -and -not $emptyStatus.ready) '缺配置时状态不回退到全游戏模式'
    Assert-Offline (-not (Test-Path -LiteralPath $paths.Status) -and -not (Test-Path -LiteralPath $paths.Private)) '只读检查不创建状态或密钥目录'

    $settings=@{gameExecutable=$gameExecutable;trialDeadline='2026-11-13T00:00:00+11:00';mode='FullGame'}
    [IO.File]::WriteAllText($paths.Settings,($settings | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $read=Read-MnaUserSettings
    Assert-Offline ($read.GameExecutable -eq $gameExecutable -and $read.RoutingMode -eq 'ResolveOnly') '设置中额外的 mode 字段不能改变仅解析模式'
    Assert-Offline (@($read.GameExecutables).Count -eq 1 -and $read.GameExecutables[0] -eq $gameExecutable) '旧单路径设置自动兼容程序列表'
    Assert-OfflineThrows { Assert-MnaReleaseConfiguration } '尚未导入本机设备密钥' '缺密钥时返回明确中文错误'
    $settings.trialDeadline='2099-01-01T00:00:00+11:00'
    [IO.File]::WriteAllText($paths.Settings,($settings | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Assert-OfflineThrows { Read-MnaUserSettings } '截止日期配置无效' '不能通过设置延长免费授权'
    $settings.trialDeadline='2026-11-13T00:00:00+11:00'
    [IO.File]::WriteAllText($paths.Settings,($settings | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    foreach ($invalid in @("C:\bad`npath\DeltaForceClient-Win64-Shipping.exe","C:\bad`rpath\DeltaForceClient-Win64-Shipping.exe","C:\bad`0path\DeltaForceClient-Win64-Shipping.exe",'C:\bad,path\DeltaForceClient-Win64-Shipping.exe')) {
        Assert-OfflineThrows { Resolve-MnaGameExecutable $invalid } '游戏路径不能包含' '拒绝规则控制字符和逗号'
    }
    foreach ($invalid in @('C:\bad(path\DeltaForceClient-Win64-Shipping.exe','C:\bad)path\DeltaForceClient-Win64-Shipping.exe')) {
        Assert-OfflineThrows { Resolve-MnaGameExecutable $invalid } '括号必须成对' '不配对括号在配置检查时明确报错'
    }
    Assert-OfflineThrows { Resolve-MnaGameExecutable '.\DeltaForceClient-Win64-Shipping.exe' } '完整游戏程序路径' '拒绝相对游戏路径'
    Assert-OfflineThrows { Resolve-MnaGameExecutable (Join-Path $gameDirectory 'other.exe') } '请选择 DeltaForceClient-Win64-Shipping.exe' '拒绝错误的游戏文件名'
    Assert-Offline (-not (Test-MnaFreeTrialExpired -At ([DateTimeOffset]'2026-11-12T23:59:59+11:00'))) '截止时刻前仍在授权期'
    Assert-Offline (Test-MnaFreeTrialExpired -At ([DateTimeOffset]'2026-11-13T00:00:00+11:00')) '截止时刻准确停止授权'
    Assert-OfflineThrows { Resolve-MnaGameExecutables -GameExecutable $gameExecutable -GameExecutables $secondGameExecutable } '完整路径数组' '程序列表拒绝单个字符串冒充数组'
    Assert-OfflineThrows { Resolve-MnaGameExecutables -GameExecutable $gameExecutable -GameExecutables @($gameExecutable,42) } '完整路径字符串' '程序列表拒绝非字符串项'
    Assert-OfflineThrows { Resolve-MnaGameExecutables -GameExecutable $gameExecutable -GameExecutables @($gameExecutable,$secondGameExecutable,$gameExecutable) } '最多保存两个' '程序列表限制为两个显式路径'
    $deduplicated=@(Resolve-MnaGameExecutables -GameExecutable $gameExecutable -GameExecutables @($gameExecutable.ToUpperInvariant(),$secondGameExecutable))
    Assert-Offline ($deduplicated.Count -eq 2 -and $deduplicated[0] -ceq $gameExecutable -and $deduplicated[1] -ceq $secondGameExecutable) 'Windows 路径忽略大小写去重且保留主路径顺序'
    $settings.gameExecutables=@($gameExecutable,$secondGameExecutable)
    [IO.File]::WriteAllText($paths.Settings,($settings | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $read=Read-MnaUserSettings
    Assert-Offline ($read.GameExecutable -eq $gameExecutable -and @($read.GameExecutables).Count -eq 2 -and $read.GameExecutables[1] -eq $secondGameExecutable) '双路径设置同时保留原主路径和 WeGame 路径'

    foreach ($directory in @($paths.Private,(Join-Path $paths.Runtime 'helper'))) { $null=New-Item -ItemType Directory -Path $directory -Force }
    foreach ($file in @($paths.PowerShell,(Join-Path $paths.Runtime 'linkboost.exe'),(Join-Path $paths.Runtime 'linkboost-core.exe'),(Join-Path $paths.Runtime 'helper/multipath-helper.exe'))) { [IO.File]::WriteAllBytes($file,[byte[]]@()) }
    # Deliberately not a real DPAPI blob: preflight must not attempt to decrypt it.
    [IO.File]::WriteAllBytes((Join-Path $paths.Private 'device-key.dpapi.bin'),[byte[]]@(1,2,3))
    $valid=Assert-MnaReleaseConfiguration
    Assert-Offline ($valid.GameExecutable -eq $gameExecutable) '前置检查只验证密钥文件存在，不读取密钥'
    $session=New-MnaGameRouteSession -RunId '0123456789abcdef01234567' -SocksUser 'offline-user' -SocksPassword 'offline-password' -GameExecutable $valid.GameExecutable -GameExecutables $valid.GameExecutables -PrivateDirectory $paths.Private -HelperExecutable (Join-Path $paths.Runtime 'helper/multipath-helper.exe')
    $yaml=[IO.File]::ReadAllText($session.ConfigPath)
    $exactRule='AND,((PROCESS-PATH,'+$gameExecutable+'),(IP-CIDR,182.254.116.117/32),(DST-PORT,80),(NETWORK,TCP)),MNA-HK'
    Assert-Offline ($yaml.Contains((ConvertTo-MnaRouteYamlString $exactRule))) '中文空格括号单引号游戏路径生成精确 HTTPDNS TCP 80 规则'
    $secondRule='AND,((PROCESS-PATH,'+$secondGameExecutable+'),(IP-CIDR,182.254.116.117/32),(DST-PORT,80),(NETWORK,TCP)),MNA-HK'
    Assert-Offline ($yaml.Contains((ConvertTo-MnaRouteYamlString $secondRule)) -and [regex]::Matches($yaml,'IP-CIDR,182\.254\.116\.117/32').Count -eq 2) 'Steam 与 WeGame 各一条精确 HTTPDNS 规则，括号路径保持完整'
    Assert-Offline (-not $yaml.Contains((ConvertTo-MnaRouteYamlString ('PROCESS-PATH,'+$gameExecutable+',MNA-HK')))) '没有覆盖全部游戏流量的宽泛规则'
    Assert-Offline ($yaml.Contains('  - MATCH,DIRECT')) '其余流量直连'
    Assert-Offline ($yaml.Contains('  stack: mixed') -and $yaml.Contains('  mtu: 1500')) '保留已验证 mixed 栈和 MTU 1500'
    $expectedRouteLine="  route-address: ['1.1.1.1/32', '162.159.207.0/32', '182.254.116.117/32']"
    Assert-Offline ($yaml.Contains($expectedRouteLine) -and -not $yaml.Contains('0.0.0.0/0')) '仅 HTTPDNS 和固定健康探测地址进入虚拟网卡'
    Assert-Offline ($null -eq $session.ProcessIdentity) '线路生成不启动 helper 或 TUN'
    $counted=& {
        function Test-MnaGameRouteProcess { $true }
        function Test-MnaGameRouteController { $true }
        function Invoke-MnaGameRouteApi {
            param($Session,$Route)
            if ($Route -eq '/configs') { return [pscustomobject]@{tun=[pscustomobject]@{enable=$true}} }
            [pscustomobject]@{connections=@(
                [pscustomobject]@{metadata=[pscustomobject]@{processPath=$gameExecutable;network='tcp'};chains=@('MNA-HK')},
                [pscustomobject]@{metadata=[pscustomobject]@{processPath=$secondGameExecutable.ToUpperInvariant();network='tcp'};chains=@('MNA-HK')},
                [pscustomobject]@{metadata=[pscustomobject]@{processPath='C:\unconfigured\DeltaForceClient-Win64-Shipping.exe';network='tcp'};chains=@('MNA-HK')}
            )}
        }
        Get-MnaGameRouteStatus -Session $session -IncludeConnections
    }
    Assert-Offline ($counted.GameConnections -eq 2 -and $counted.RoutedGameConnections -eq 2 -and $counted.RoutedGameUdpConnections -eq 0) '连接统计仅匹配两个已配置完整路径，不匹配同名其他程序'
    $legacyPaths=@(Get-MnaGameRouteExecutablePaths -Session ([pscustomobject]@{GameExecutable=$gameExecutable}))
    Assert-Offline ($legacyPaths.Count -eq 1 -and $legacyPaths[0] -eq $gameExecutable) '旧单路径会话与恢复记录兼容'
    # This identity is synthetic and is never checked against or used to stop a process.
    # Only the freshly generated test REST secret is DPAPI round-tripped here.
    $session.HelperExecutable=Join-Path $backend 'vendor_inspection/sdk_v0.23.1/linkboost/helper/multipath-helper.exe'
    $session.ProcessIdentity=[pscustomobject]@{RunId=$session.RunId;Pid=2147483001;Created=[datetime]'2026-09-15T00:00:00';ExecutablePath=$session.HelperExecutable}
    Save-MnaGameRouteRecovery -Session $session
    $restored=Import-MnaGameRouteRecovery -RunId $session.RunId -PrivateDirectory $paths.Private
    try {
        Assert-Offline (@($restored.GameExecutables).Count -eq 2 -and $restored.GameExecutables[0] -eq $gameExecutable -and $restored.GameExecutables[1] -eq $secondGameExecutable) '双路径恢复记录实际写入和读取均保留两个路径'
    } finally { if ($restored.RestSecret) { $restored.RestSecret.Dispose() } }
    $recoveryPath=Join-Path $session.Directory 'recovery.json'
    $legacyRecord=Read-MnaUiJson $recoveryPath
    $legacyRecord.PSObject.Properties.Remove('GameExecutables')
    Write-MnaUiJson -Path $recoveryPath -Value $legacyRecord
    $restored=Import-MnaGameRouteRecovery -RunId $session.RunId -PrivateDirectory $paths.Private
    try {
        Assert-Offline (@($restored.GameExecutables).Count -eq 1 -and $restored.GameExecutables[0] -eq $gameExecutable) '旧单路径恢复文件仍可导入清理'
    } finally { if ($restored.RestSecret) { $restored.RestSecret.Dispose() } }
    $session.ProcessIdentity=$null
    if ($ValidateHelperConfiguration) {
        $realHelper=Join-Path $backend 'vendor_inspection/sdk_v0.23.1/linkboost/helper/multipath-helper.exe'
        if (-not (Test-Path -LiteralPath $realHelper -PathType Leaf)) { throw '分享包缺少用于配置解析验证的官方 helper' }
        # No remote providers/GEO rules exist in this synthetic config. -t only
        # parses it and exits, without binding listeners or creating the TUN.
        $helperCheck=$null
        try {
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=$realHelper
            foreach ($argument in @('-t','-d',$session.Directory,'-f',$session.ConfigPath)) { $info.ArgumentList.Add($argument) }
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $helperCheck=[Diagnostics.Process]::new();$helperCheck.StartInfo=$info
            $null=$helperCheck.Start()
            $outTask=$helperCheck.StandardOutput.ReadToEndAsync();$errTask=$helperCheck.StandardError.ReadToEndAsync()
            if (-not $helperCheck.WaitForExit(10000)) { throw 'helper 配置解析超过 10 秒，本次测试已终止' }
            $helperOutput=$outTask.GetAwaiter().GetResult()+$errTask.GetAwaiter().GetResult()
            Assert-Offline ($helperCheck.ExitCode -eq 0 -and $helperOutput -match 'test is successful') '官方 helper -t 实际解析双路径及中文空格括号单引号规则成功'
        } finally {
            if ($helperCheck) {
                if (-not $helperCheck.HasExited) { $helperCheck.Kill();$null=$helperCheck.WaitForExit(2000) }
                $helperCheck.Dispose()
            }
            $helperOutput=$null
        }
    }
    [pscustomobject]@{Passed=$true;Checks=$checks.Count;NetworkStarted=$false;HelperParserChecked=[bool]$ValidateHelperConfiguration;ChecksPerformed=$checks.ToArray()} | ConvertTo-Json -Depth 4
} finally {
    if ($session -and $session.RestSecret) { $session.RestSecret.Dispose() }
    $script:MnaUiRoot=$originalBackendRoot
    # Delete only this freshly generated, resolved fixture within tests/offline-work.
    # Explicit file/empty-directory removal avoids recursive deletion of other paths.
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolved.StartsWith($fixtureBase+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '离线测试清理路径越界，未删除' }
    if (Test-Path -LiteralPath $resolved) {
        $items=@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw '测试目录出现链接，未执行清理' }
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) { Remove-Item -LiteralPath $file.FullName -Force }
        foreach ($directory in @($items | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending)) { Remove-Item -LiteralPath $directory.FullName -Force }
        Remove-Item -LiteralPath $resolved -Force
    }
}
