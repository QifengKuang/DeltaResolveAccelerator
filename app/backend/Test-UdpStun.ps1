param(
    [string]$Server = 'stun.cloudflare.com',
    [ValidateRange(1, 65535)][int]$Port = 3478,
    [ValidateRange(100, 15000)][int]$TimeoutMs = 3000,
    [ValidateRange(1, 5)][int]$Attempts = 2,
    [ValidateRange(0, 65535)][int]$LocalPort = 0,
    [ValidateRange(0, 65535)][int]$SocksProxyPort = 0,
    [pscredential]$SocksCredential
)

# Raw UDP STUN Binding query. Does not configure any proxy, adapter, or route.
# Server may be a pinned IPv4 so an exact destination rule can be tested.
# https://developers.cloudflare.com/realtime/turn/
# https://www.rfc-editor.org/rfc/rfc8489.html
$ErrorActionPreference = 'Stop'
$udp = $null
$socksTcp = $null
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$selectedIp = $null
$lastError = 'No STUN response was received.'

function Read-U16([byte[]]$Bytes, [int]$Offset) {
    return ([int]$Bytes[$Offset] * 256 + [int]$Bytes[$Offset + 1])
}

function Read-SocksBytes($Stream, [int]$Count) {
    $bytes = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($bytes, $offset, $Count - $offset)
        if ($read -eq 0) { throw 'SOCKS control connection closed.' }
        $offset += $read
    }
    return ,$bytes
}

function Read-MappedAddress([byte[]]$Response, [byte[]]$Transaction) {
    if ($Response.Length -lt 20 -or (Read-U16 $Response 0) -ne 0x0101) { return $null }
    if ($Response[4] -ne 0x21 -or $Response[5] -ne 0x12 -or $Response[6] -ne 0xA4 -or $Response[7] -ne 0x42) { return $null }
    for ($i = 0; $i -lt 12; $i++) {
        if ($Response[$i + 8] -ne $Transaction[$i]) { return $null }
    }
    $limit = 20 + (Read-U16 $Response 2)
    if ($limit -gt $Response.Length) { return $null }
    $fallback = $null
    for ($offset = 20; $offset + 4 -le $limit; ) {
        $kind = Read-U16 $Response $offset
        $length = Read-U16 $Response ($offset + 2)
        $value = $offset + 4
        if ($value + $length -gt $limit) { return $null }
        if (($kind -eq 0x0020 -or $kind -eq 0x0001) -and $length -ge 8 -and $Response[$value + 1] -eq 1) {
            $mappedPort = Read-U16 $Response ($value + 2)
            [byte[]]$address = $Response[($value + 4)..($value + 7)]
            if ($kind -eq 0x0020) {
                $mappedPort = $mappedPort -bxor 0x2112
                [byte[]]$cookie = @(0x21, 0x12, 0xA4, 0x42)
                for ($i = 0; $i -lt 4; $i++) { $address[$i] = $address[$i] -bxor $cookie[$i] }
            }
            $mapped = [pscustomobject]@{
                mappedIP = ([System.Net.IPAddress]::new($address)).ToString()
                mappedPort = $mappedPort
                attribute = $(if ($kind -eq 0x0020) { 'XOR-MAPPED-ADDRESS' } else { 'MAPPED-ADDRESS' })
            }
            if ($kind -eq 0x0020) { return $mapped }
            $fallback = $mapped
        }
        $offset = $value + $length + ((4 - ($length % 4)) % 4)
    }
    return $fallback
}

try {
    $selectedIp = [System.Net.Dns]::GetHostAddresses($Server) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        Select-Object -First 1
    if (-not $selectedIp) { throw 'The server has no IPv4 address.' }
    $local = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $LocalPort)
    $udp = [System.Net.Sockets.UdpClient]::new($local)
    if ($SocksProxyPort) {
        if (-not $SocksCredential) { throw 'A local SOCKS credential is required.' }
        $socksTcp = [Net.Sockets.TcpClient]::new()
        $connect = $socksTcp.ConnectAsync('127.0.0.1', $SocksProxyPort)
        if (-not $connect.Wait($TimeoutMs)) { throw 'Local SOCKS connection timed out.' }
        $stream = $socksTcp.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        [byte[]]$hello = @(5,1,2)
        $stream.Write($hello,0,$hello.Length)
        $helloReply = Read-SocksBytes $stream 2
        if ($helloReply[0] -ne 5 -or $helloReply[1] -ne 2) { throw 'SOCKS authentication method was not accepted.' }
        $userBytes = [Text.Encoding]::UTF8.GetBytes($SocksCredential.UserName)
        $passBytes = [Text.Encoding]::UTF8.GetBytes($SocksCredential.GetNetworkCredential().Password)
        try {
            if ($userBytes.Length -gt 255 -or $passBytes.Length -gt 255) { throw 'SOCKS credential length is invalid.' }
            [byte[]]$auth = @(1,[byte]$userBytes.Length) + $userBytes + @([byte]$passBytes.Length) + $passBytes
            $stream.Write($auth,0,$auth.Length)
        } finally {
            if ($auth) { [Array]::Clear($auth,0,$auth.Length) }
            [Array]::Clear($passBytes,0,$passBytes.Length)
        }
        $authReply = Read-SocksBytes $stream 2
        if ($authReply[1] -ne 0) { throw 'SOCKS authentication failed.' }
        [byte[]]$associate = @(5,3,0,1,0,0,0,0,0,0)
        $stream.Write($associate,0,$associate.Length)
        $reply = Read-SocksBytes $stream 4
        if ($reply[0] -ne 5 -or $reply[1] -ne 0) { throw ('SOCKS UDP ASSOCIATE failed with code ' + $reply[1]) }
        if ($reply[3] -eq 1) { $relayIp = [Net.IPAddress]::new((Read-SocksBytes $stream 4)) }
        elseif ($reply[3] -eq 4) { $relayIp = [Net.IPAddress]::new((Read-SocksBytes $stream 16)) }
        else { throw 'SOCKS UDP relay address type was unsupported.' }
        $portBytes = Read-SocksBytes $stream 2
        $relayPort = Read-U16 $portBytes 0
        if ($relayIp.Equals([Net.IPAddress]::Any)) { $relayIp = [Net.IPAddress]::Loopback }
        $udp.Connect($relayIp,$relayPort)
    } else { $udp.Connect($selectedIp, $Port) }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        [byte[]]$transaction = New-Object byte[] 12
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($transaction) } finally { $rng.Dispose() }
        [byte[]]$request = @(0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42) + $transaction
        if ($SocksProxyPort) {
            [byte[]]$request = @(0,0,0,1) + $selectedIp.GetAddressBytes() + @([byte]($Port -shr 8),[byte]($Port -band 255)) + $request
        }
        $sentAt = [DateTime]::UtcNow
        [void]$udp.Send($request, $request.Length)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $udp.Client.ReceiveTimeout = $remaining
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            try { $response = $udp.Receive([ref]$remote) } catch { $lastError = 'UDP response timed out or was unavailable.'; break }
            if ($SocksProxyPort) {
                if ($response.Length -lt 10 -or $response[0] -ne 0 -or $response[1] -ne 0 -or $response[2] -ne 0 -or $response[3] -ne 1) { continue }
                $response = [byte[]]$response[10..($response.Length-1)]
            }
            $mapped = Read-MappedAddress $response $transaction
            if ($mapped) {
                [pscustomobject]@{
                    success = $true
                    protocol = 'UDP-STUN'
                    viaSocks = [bool]$SocksProxyPort
                    server = $Server
                    serverIP = $selectedIp.ToString()
                    serverPort = $Port
                    localEndpoint = $udp.Client.LocalEndPoint.ToString()
                    mappedIP = $mapped.mappedIP
                    mappedPort = $mapped.mappedPort
                    attribute = $mapped.attribute
                    rttMs = [Math]::Round(([DateTime]::UtcNow - $sentAt).TotalMilliseconds, 1)
                    attempt = $attempt
                } | ConvertTo-Json -Compress
                exit 0
            }
            $lastError = 'The response was not a matching IPv4 STUN Binding success.'
        }
    }
} catch {
    $lastError = $_.Exception.Message
} finally {
    if ($udp) { $udp.Dispose() }
    if ($socksTcp) { $socksTcp.Dispose() }
    $clock.Stop()
}

[pscustomobject]@{
    success = $false
    protocol = 'UDP-STUN'
    server = $Server
    serverIP = $(if ($selectedIp) { $selectedIp.ToString() } else { $null })
    serverPort = $Port
    elapsedMs = $clock.ElapsedMilliseconds
    error = $lastError
} | ConvertTo-Json -Compress
exit 1
