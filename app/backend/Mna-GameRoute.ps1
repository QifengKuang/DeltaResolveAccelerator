#requires -Version 7.0
# Dot-source from the worker. This file does not start a process or change networking.
# Primary schema: https://wiki.metacubex.one/config/{rules,inbound/tun,proxies/socks,general}/
# Session objects contain a SecureString REST secret. Do not serialize whole sessions.

function ConvertTo-MnaRouteYamlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.IndexOfAny([char[]]"`r`n`0") -ge 0) { throw '线路配置不接受换行或空字符' }
    "'" + $Value.Replace("'", "''") + "'"
}

function New-MnaRouteSecret {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    try { [Convert]::ToHexString($bytes).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Protect-MnaRouteDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $null = [IO.Directory]::CreateDirectory($Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '线路私有目录不能是链接或重解析点' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-MnaGameRouteSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{24}$')][string]$RunId,
        [Parameter(Mandatory)][string]$SocksUser,
        [Parameter(Mandatory)][string]$SocksPassword,
        [ValidateRange(1,65535)][int]$SocksPort = 12345,
        [ValidateRange(1,65535)][int]$RestPort = 9803,
        [string]$PrivateDirectory = (Join-Path $PSScriptRoot 'private'),
        [string]$HelperExecutable = (Join-Path $PSScriptRoot 'vendor_inspection/sdk_v0.23.1/linkboost/helper/multipath-helper.exe'),
        [Parameter(Mandatory)][string]$GameExecutable,
        [string[]]$GameExecutables
    )
    $gamePaths=@(Resolve-MnaGameExecutables -GameExecutable $GameExecutable -GameExecutables $GameExecutables)
    $gamePath=$gamePaths[0]
    $ProbeDestination='162.159.207.0'
    $RouteDestinations=@('182.254.116.117')
    $RoutingMode='ResolveOnly'
    $privatePath = [IO.Path]::GetFullPath($PrivateDirectory).TrimEnd('\','/')
    $directory = [IO.Path]::GetFullPath((Join-Path $privatePath ('game-route-' + $RunId)))
    if (-not $directory.StartsWith($privatePath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '线路配置路径不在指定私有目录中' }
    if (Test-Path -LiteralPath $directory) { throw '本轮线路配置已存在，未覆盖' }
    $helperPath = [IO.Path]::GetFullPath($HelperExecutable)
    $tcpProbePath = (Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $udpProbePath = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw '游戏引流程序缺失' }
    if ($tcpProbePath.Contains(',') -or $udpProbePath.Contains(',')) { throw '探测程序路径包含规则分隔符' }
    Assert-MnaRulePathParentheses -Path $tcpProbePath
    Assert-MnaRulePathParentheses -Path $udpProbePath
    if ($ProbeDestination) {
        $probeAddress = $null
        if (-not [Net.IPAddress]::TryParse($ProbeDestination, [ref]$probeAddress) -or $probeAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw 'UDP 探测地址必须是明确的 IPv4 地址'
        }
        $ProbeDestination = $probeAddress.ToString()
    }
    Protect-MnaRouteDirectory -Path $directory
    $secret = New-MnaRouteSecret
    $configPath = Join-Path $directory 'game-route.yaml'
    $proxyName = 'MNA-HK'
    $tunName = 'mna_game_' + $RunId.Substring(0,6)
    $lines = [Collections.Generic.List[string]]::new()
    $routeAddresses = @($RouteDestinations) + @($ProbeDestination, '1.1.1.1')
    $routeAddresses = @($routeAddresses | Where-Object { $_ } | ForEach-Object {
        $routeIp = $null
        if (-not [Net.IPAddress]::TryParse($_,[ref]$routeIp) -or $routeIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw '游戏路由必须是明确的 IPv4 地址' }
        $routeIp.ToString() + '/32'
    } | Sort-Object -Unique)
    foreach ($line in @(
        'mode: rule', 'ipv6: false', 'log-level: warning', 'allow-lan: false',
        'find-process-mode: always',
        ('external-controller: ' + (ConvertTo-MnaRouteYamlString ('127.0.0.1:' + $RestPort))),
        ('secret: ' + (ConvertTo-MnaRouteYamlString $secret)),
        'dns:', '  enable: false',
        'tun:', '  enable: true', ('  device: ' + (ConvertTo-MnaRouteYamlString $tunName)),
        '  stack: mixed', '  mtu: 1500', '  auto-route: true', '  auto-detect-interface: true', '  strict-route: false', '  dns-hijack: []',
        ('  route-address: [' + (($routeAddresses | ForEach-Object { ConvertTo-MnaRouteYamlString $_ }) -join ', ') + ']'),
        '  inet6-address: []',
        'proxies:', ('  - name: ' + (ConvertTo-MnaRouteYamlString $proxyName)),
        '    type: socks5', '    server: 127.0.0.1', ('    port: ' + $SocksPort),
        ('    username: ' + (ConvertTo-MnaRouteYamlString $SocksUser)),
        ('    password: ' + (ConvertTo-MnaRouteYamlString $SocksPassword)), '    udp: true',
        'rules:'
    )) { $lines.Add($line) }
    foreach ($path in $gamePaths) {
        $gameRule='AND,((PROCESS-PATH,'+$path+'),(IP-CIDR,182.254.116.117/32),(DST-PORT,80),(NETWORK,TCP)),'+$proxyName
        $lines.Add('  - ' + (ConvertTo-MnaRouteYamlString $gameRule))
    }
    if ($ProbeDestination) {
        # Logical rule syntax is documented at https://wiki.metacubex.one/config/rules/.
        $lines.Add('  - ' + (ConvertTo-MnaRouteYamlString ('AND,((PROCESS-PATH,' + $udpProbePath + '),(IP-CIDR,' + $ProbeDestination + '/32),(DST-PORT,3478),(NETWORK,UDP)),' + $proxyName)))
    }
    $lines.Add('  - ' + (ConvertTo-MnaRouteYamlString ('AND,((PROCESS-PATH,' + $tcpProbePath + '),(IP-CIDR,1.1.1.1/32),(DST-PORT,443),(NETWORK,TCP)),' + $proxyName)))
    $lines.Add('  - MATCH,DIRECT')
    try {
        [IO.File]::WriteAllText($configPath, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{
            RunId=$RunId; PrivateDirectory=$privatePath; Directory=$directory; ConfigPath=$configPath
            HelperExecutable=$helperPath; GameExecutable=$gamePath; GameExecutables=$gamePaths; ProxyName=$proxyName
            TunName=$tunName; RestPort=$RestPort; RestBase=('http://127.0.0.1:' + $RestPort)
            RestSecret=(ConvertTo-SecureString $secret -AsPlainText -Force)
            ProbeDestination=$ProbeDestination; ProcessIdentity=$null; RouteDestinations=@($RouteDestinations); RoutingMode=$RoutingMode
        }
    } finally { $secret=$null; $lines.Clear() }
}

function Test-MnaGameRouteProcess {
    param([Parameter(Mandatory)][object]$Session)
    if (-not $Session.ProcessIdentity) { return $false }
    $identity = $Session.ProcessIdentity
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$identity.Pid) -Property CreationDate,ExecutablePath -ErrorAction Stop
    $imagePath=if ($current) { $current.ExecutablePath } else { $null }
    if ($current -and -not $imagePath -and ('MnaUi.LimitedProcessImageQuery' -as [type])) {
        $imagePath=[MnaUi.LimitedProcessImageQuery]::Read([uint32]$identity.Pid)
    }
    [bool]($current -and $current.CreationDate -eq $identity.Created -and
        [string]::Equals($imagePath, $Session.HelperExecutable, [StringComparison]::OrdinalIgnoreCase))
}

function Save-MnaGameRouteRecovery {
    param([Parameter(Mandatory)][object]$Session)
    if (-not $Session.ProcessIdentity) { throw '游戏引流进程身份缺失，不能保存恢复记录' }
    # ConvertFrom-SecureString uses Windows current-user DPAPI when no key is supplied.
    $record = [ordered]@{
        RunId=$Session.RunId; HelperExecutable=$Session.HelperExecutable; GameExecutable=$Session.GameExecutable
        GameExecutables=@(Get-MnaGameRouteExecutablePaths -Session $Session)
        ProxyName=$Session.ProxyName; TunName=$Session.TunName; RestPort=$Session.RestPort
        ProbeDestination=$Session.ProbeDestination; ProcessIdentity=$Session.ProcessIdentity
        ProtectedRestSecret=(ConvertFrom-SecureString $Session.RestSecret)
    }
    $path = Join-Path $Session.Directory 'recovery.json'
    try { Write-MnaUiJson -Path $path -Value $record }
    finally { $record=$null }
}

function Import-MnaGameRouteRecovery {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{24}$')][string]$RunId,
        [string]$PrivateDirectory=(Join-Path $PSScriptRoot 'private')
    )
    $privatePath=[IO.Path]::GetFullPath($PrivateDirectory).TrimEnd('\','/')
    $directory=[IO.Path]::GetFullPath((Join-Path $privatePath ('game-route-'+$RunId)))
    if (-not $directory.StartsWith($privatePath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '恢复记录不在私有目录中' }
    $path=Join-Path $directory 'recovery.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '恢复目录不能是链接' }
    $record=Read-MnaUiJson $path
    if (-not $record) { throw '无法读取游戏引流恢复记录，请检查文件是否被占用或损坏' }
    $expectedHelper=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'vendor_inspection/sdk_v0.23.1/linkboost/helper/multipath-helper.exe'))
    if ($record.RunId -ne $RunId -or -not [string]::Equals($record.HelperExecutable,$expectedHelper,[StringComparison]::OrdinalIgnoreCase) -or
        $record.ProcessIdentity.RunId -ne $RunId -or [int]$record.ProcessIdentity.Pid -le 0 -or
        [int]$record.RestPort -lt 1 -or [int]$record.RestPort -gt 65535) { throw '游戏引流恢复记录身份核验失败' }
    $record.ProcessIdentity.Created=[datetime]$record.ProcessIdentity.Created
    [pscustomobject]@{
        RunId=$RunId; PrivateDirectory=$privatePath; Directory=$directory; ConfigPath=(Join-Path $directory 'game-route.yaml')
        HelperExecutable=$expectedHelper; GameExecutable=[string]$record.GameExecutable; ProxyName=[string]$record.ProxyName
        # Recovery must still clean up an owned session after a game is moved or removed.
        # These paths are only used for connection accounting, never to create new rules.
        GameExecutables=@(Get-MnaGameRouteExecutablePaths -Session $record)
        TunName=[string]$record.TunName; RestPort=[int]$record.RestPort; RestBase=('http://127.0.0.1:'+ [int]$record.RestPort)
        RestSecret=(ConvertTo-SecureString $record.ProtectedRestSecret)
        ProbeDestination=[string]$record.ProbeDestination; ProcessIdentity=$record.ProcessIdentity
    }
}

function Get-MnaGameRouteExecutablePaths {
    param([Parameter(Mandatory)][object]$Session)
    $paths=[Collections.Generic.List[string]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Session.GameExecutable) + @($Session.GameExecutables)) {
        if ($path -is [string] -and -not [string]::IsNullOrWhiteSpace($path) -and $seen.Add($path)) { $paths.Add($path) }
    }
    if ($paths.Count -lt 1 -or $paths.Count -gt 2) { throw '游戏引流记录中的程序路径数量无效' }
    $paths.ToArray()
}

function Test-MnaGameRouteController {
    param([Parameter(Mandatory)][object]$Session)
    if (-not (Test-MnaGameRouteProcess $Session)) { return $false }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
        $_.LocalPort -eq $Session.RestPort -and $_.LocalAddress -eq '127.0.0.1' -and $_.OwningProcess -eq $Session.ProcessIdentity.Pid
    })
    [bool]$listeners.Count
}

function Invoke-MnaGameRouteApi {
    param(
        [Parameter(Mandatory)][object]$Session,
        [ValidateSet('GET','PATCH')][string]$Method = 'GET',
        [ValidateSet('/configs','/connections')][string]$Route,
        [object]$Body
    )
    if (-not (Test-MnaGameRouteController $Session)) { throw '本轮游戏引流控制接口未就绪或身份不符' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(3)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Session.RestBase + $Route)
    $pointer = [IntPtr]::Zero
    $response = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Session.RestSecret)
        $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $secret)
        if ($null -ne $Body) {
            $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 5 -Compress), [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw ('游戏引流控制接口返回 HTTP ' + [int]$response.StatusCode) }
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($content) {
            try { $content | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
            catch { throw '游戏引流接口返回了无法解析的数据' }
        }
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        $secret=$null; $content=$null
        if ($response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose()
    }
}

function Get-MnaGameRouteStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [switch]$IncludeConnections)
    $running = Test-MnaGameRouteProcess $Session
    $controller = $running -and (Test-MnaGameRouteController $Session)
    $enabled = $false
    $gameConnections = 0
    $routedGameConnections = 0
    $routedGameUdpConnections = 0
    $gamePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @(Get-MnaGameRouteExecutablePaths -Session $Session)) { $null=$gamePaths.Add($path) }
    if ($controller) {
        $configuration = Invoke-MnaGameRouteApi -Session $Session -Route '/configs'
        $enabled = $configuration.tun.enable -eq $true
        $configuration = $null
        if ($IncludeConnections) {
            $connections = Invoke-MnaGameRouteApi -Session $Session -Route '/connections'
            foreach ($connection in @($connections.connections)) {
                if ($gamePaths.Contains([string]$connection.metadata.processPath)) {
                    $gameConnections++
                    if (@($connection.chains) -contains $Session.ProxyName) {
                        $routedGameConnections++
                        if ([string]$connection.metadata.network -ieq 'udp') { $routedGameUdpConnections++ }
                    }
                }
            }
            $connections = $null
        }
    }
    [pscustomobject]@{
        Running=[bool]$running; ControllerReady=[bool]$controller; TunEnabled=[bool]$enabled
        GameRoutingConfigured=[bool]($controller -and $enabled)
        GameConnections=$gameConnections; RoutedGameConnections=$routedGameConnections
        RoutedGameUdpConnections=$routedGameUdpConnections
        GameRoutingVerified=($routedGameUdpConnections -gt 0)
    }
}

function Clear-MnaGameRouteDns {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session)
    if ($Session.TunName -ne ('mna_game_' + $Session.RunId.Substring(0,6)) -or
        -not (Test-MnaGameRouteController $Session)) { throw '未确认本轮虚拟网卡归属，未修改 DNS' }
    $adapter=Get-NetAdapter -Name $Session.TunName -ErrorAction Stop
    if ($adapter.Name -ne $Session.TunName -or $adapter.HardwareInterface -or
        -not @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object IPAddress -eq '198.18.0.1').Count) {
        throw '本轮虚拟网卡身份不符，未修改 DNS'
    }
    $adapterGuid=$adapter.InterfaceGuid
    $before=@(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | ForEach-Object ServerAddresses)
    # This tunnel is explicitly IPv4-only. Windows otherwise advertises legacy
    # IPv6 placeholder DNS servers after removing the bad IPv4 resolver.
    # Disable only our disposable NIC's unused IPv6 binding, before ready.
    $ipv6Binding=Get-NetAdapterBinding -Name $Session.TunName -ComponentID ms_tcpip6 -ErrorAction Stop
    if ($ipv6Binding.Enabled) {
        Disable-NetAdapterBinding -Name $Session.TunName -ComponentID ms_tcpip6 -Confirm:$false -ErrorAction Stop
    }
    $adapter=Get-NetAdapter -Name $Session.TunName -ErrorAction Stop
    if ($adapter.InterfaceGuid -ne $adapterGuid -or $adapter.HardwareInterface -or
        -not (Test-MnaGameRouteController $Session) -or
        -not @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object IPAddress -eq '198.18.0.1').Count) {
        throw '虚拟网卡重启后身份未确认，未修改 DNS'
    }
    # Mihomo 1.19.1 / sing-tun 0.4.5 registers this resolver even when its
    # DNS server is disabled. It returns SERVFAIL and can win Windows DNS
    # selection at the TUN's metric 0. Remove only this owned adapter's DNS.
    if ($before.Count) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
    }
    $sameAdapter=Get-NetAdapter -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
    $after=@(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | ForEach-Object ServerAddresses)
    if ($sameAdapter.InterfaceGuid -eq $adapterGuid -and $after.Count) {
        # DHCP reset can expose Windows' legacy IPv6 placeholder resolvers.
        # netsh's documented address=none clears static DNS for this exact NIC.
        foreach ($family in @('ipv4','ipv6')) {
            $null=& "$env:SystemRoot\System32\netsh.exe" interface $family set dnsservers ('name='+$adapter.ifIndex) source=static address=none validate=no
            if ($LASTEXITCODE -ne 0) { throw '未能清空本轮虚拟网卡 DNS' }
        }
        $after=@(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | ForEach-Object ServerAddresses)
    }
    if ($sameAdapter.InterfaceGuid -ne $adapterGuid -or $after.Count) { throw '虚拟网卡 DNS 尚未清除，本次不启用加速' }
    $nativeAdapter=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { [guid]$_.Id -eq [guid]$adapterGuid })
    if ($nativeAdapter.Count -ne 1 -or @($nativeAdapter[0].GetIPProperties().DnsAddresses).Count) { throw '原生接口仍能枚举到虚拟 DNS，本次不启用加速' }
    [pscustomobject]@{InterfaceAlias=$Session.TunName;InterfaceGuid=$adapterGuid;Before=$before;After=$after;Cleared=$true}
}

function Start-MnaGameRoute {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [Parameter(Mandatory)][hashtable]$OwnedProcesses)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '游戏引流需要管理员权限，请通过界面授权启动' }
    if ($Session.ProcessIdentity) { throw '本轮游戏引流已启动过，未重复启动' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $Session.RestPort }).Count -or
        @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.LocalPort -eq $Session.RestPort }).Count) { throw '游戏引流控制端口已被占用' }
    foreach ($path in @($Session.Directory,$Session.ConfigPath)) {
        if ($path.Contains('"')) { throw '线路路径含有不支持的引号' }
    }
    # Only paths are passed on the command line; credentials remain in the private YAML.
    $arguments = @('-d', ('"' + $Session.Directory + '"'), '-f', ('"' + $Session.ConfigPath + '"'))
    $process = Start-Process -FilePath $Session.HelperExecutable -ArgumentList $arguments -WorkingDirectory $Session.Directory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Session.Directory 'helper.stdout.log') -RedirectStandardError (Join-Path $Session.Directory 'helper.stderr.log')
    $created = $process.StartTime
    $Session.ProcessIdentity = [pscustomobject]@{Pid=[int]$process.Id;Created=$created;Depth=2;ExecutablePath=$Session.HelperExecutable;RunId=$Session.RunId;Kind='GameRouteHelper'}
    $OwnedProcesses[[int]$process.Id] = $Session.ProcessIdentity
    $actual = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $process.Id) -Property CreationDate,ExecutablePath -ErrorAction Stop
    if ($actual -and [string]::Equals($actual.ExecutablePath,$Session.HelperExecutable,[StringComparison]::OrdinalIgnoreCase) -and [math]::Abs(($actual.CreationDate-$created).TotalSeconds) -lt 1) {
        $Session.ProcessIdentity.Created = $actual.CreationDate
    }
    Save-MnaGameRouteRecovery -Session $Session
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (-not (Test-MnaGameRouteProcess $Session)) { throw '游戏引流程序在控制接口就绪前退出' }
        if (Test-MnaGameRouteController $Session) {
            $status = Get-MnaGameRouteStatus $Session
            if ($status.TunEnabled) {
                $dnsResult=Clear-MnaGameRouteDns -Session $Session
                $status=Get-MnaGameRouteStatus $Session
                if (-not $status.TunEnabled) { throw 'DNS 修正后虚拟网卡未就绪' }
                $status | Add-Member -NotePropertyName VirtualDns -NotePropertyValue $dnsResult
                return $status
            }
        }
        Start-Sleep -Milliseconds 250
    } while ($clock.Elapsed.TotalSeconds -lt 10)
    throw '游戏引流接口在 10 秒内未就绪；调用方必须清理本轮进程'
}

function Stop-MnaGameRoute {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Session, [Parameter(Mandatory)][hashtable]$OwnedProcesses)
    $disabled = $false
    $stopped = $false
    $errors = [Collections.Generic.List[string]]::new()
    try {
        if (Test-MnaGameRouteController $Session) {
            # Verified against MetaCubeX/mihomo hub/route/configs.go:
            # configSchema.Tun -> tunSchema.Enable -> pointerOrDefaultTun -> ReCreateTun.
            $null = Invoke-MnaGameRouteApi -Session $Session -Method PATCH -Route '/configs' -Body @{tun=@{enable=$false}}
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                $status = Get-MnaGameRouteStatus $Session
                if (-not $status.TunEnabled) { $disabled=$true;break }
                Start-Sleep -Milliseconds 200
            } while ($clock.Elapsed.TotalSeconds -lt 5)
        }
    } catch { $errors.Add('未通过控制接口确认 TUN 已关闭') }
    try {
        if (Test-MnaGameRouteProcess $Session) {
            Stop-Process -Id $Session.ProcessIdentity.Pid -ErrorAction Stop
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while ((Test-MnaGameRouteProcess $Session) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
        }
        $stopped = -not (Test-MnaGameRouteProcess $Session)
        if (-not $stopped) { $errors.Add('本轮游戏引流进程仍在运行') }
    } catch { $errors.Add('未能确认本轮游戏引流进程已退出') }
    if ($stopped) {
        # No recursive removal: delete only the exact credential file created by this session.
        $expected = [IO.Path]::GetFullPath((Join-Path $Session.PrivateDirectory ('game-route-' + $Session.RunId)))
        if ([string]::Equals($expected,$Session.Directory,[StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((Join-Path $expected 'game-route.yaml'),$Session.ConfigPath,[StringComparison]::OrdinalIgnoreCase)) {
            try {
                if (Test-Path -LiteralPath $Session.ConfigPath -PathType Leaf) { Remove-Item -LiteralPath $Session.ConfigPath -Force -ErrorAction Stop }
                $recoveryPath=Join-Path $expected 'recovery.json'
                if (Test-Path -LiteralPath $recoveryPath -PathType Leaf) { Remove-Item -LiteralPath $recoveryPath -Force -ErrorAction Stop }
            } catch { $errors.Add('本轮私有线路配置未能删除') }
        } else { $errors.Add('线路配置路径核验失败，未执行删除') }
        if ($Session.RestSecret) { $Session.RestSecret.Dispose() }
    }
    [pscustomobject]@{TunDisabledViaApi=$disabled;ProcessStopped=$stopped;Errors=@($errors.ToArray())}
}

function Stop-MnaGameRouteRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{24}$')][string]$RunId,
        [Parameter(Mandatory)][hashtable]$OwnedProcesses,
        [string]$PrivateDirectory=(Join-Path $PSScriptRoot 'private')
    )
    $session=Import-MnaGameRouteRecovery -RunId $RunId -PrivateDirectory $PrivateDirectory
    if (-not $session) { return [pscustomobject]@{Found=$false;TunDisabledViaApi=$false;ProcessStopped=$true;Errors=@()} }
    $OwnedProcesses[[int]$session.ProcessIdentity.Pid]=$session.ProcessIdentity
    $result=Stop-MnaGameRoute -Session $session -OwnedProcesses $OwnedProcesses
    [pscustomobject]@{Found=$true;TunDisabledViaApi=$result.TunDisabledViaApi;ProcessStopped=$result.ProcessStopped;Errors=$result.Errors}
}
