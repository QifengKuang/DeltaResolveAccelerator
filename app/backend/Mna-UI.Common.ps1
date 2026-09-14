# Shared local runtime helpers copied from the reviewed trial script; no execution on import.
$script:MnaUiRoot = $PSScriptRoot
$script:MnaUiOwnershipSaved = @{}

function Protect-MnaTrialMessage {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $valueText = [string]$Value
    foreach ($sensitive in $trialSensitiveStrings) {
        if ($sensitive) { $valueText = $valueText.Replace($sensitive, '[redacted]') }
    }
    $valueText = [regex]::Replace($valueText, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '[redacted-id]')
    $valueText = [regex]::Replace($valueText, '(?i)\b(dataKey|uuid|password|passWord|userName|secretKey|token|authorization)\b\s*[:=]\s*("[^"]*"|''[^'']*''|[^,;\s}]+)', '$1=[redacted]')
    $valueText = [regex]::Replace($valueText, '(?i)([a-z][a-z0-9+.-]*://)[^/;\s]*@', '$1[redacted]@')
    $valueText = [regex]::Replace($valueText, '[?#][^\s]*', '[redacted-query]')
    $valueText = [regex]::Replace($valueText, '(?<![A-Za-z0-9+/])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/])', '[redacted-long-value]')
    $valueText = [regex]::Replace($valueText, '[\r\n\t\x00-\x1f]+', ' ')
    if ($valueText.Length -gt 240) { $valueText = $valueText.Substring(0,240) + '…' }
    return $valueText
}

function Get-MnaSafeResponse {
    param([AllowNull()][object]$Response)
    $fields = [System.Collections.Generic.List[object]]::new()
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $allowed = @('ready','accGateway','gatewayPort','interfaces','scheduleMode','swVersion','area','rttAccelerated','rttDirect','state','rtt','loss')
    function Visit-MnaSafeField {
        param([AllowNull()][object]$Node,[string]$Path,[int]$Depth)
        if ($null -eq $Node -or $Depth -gt 7) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string] -and $Node -isnot [pscustomobject] -and $Node -isnot [System.Collections.IDictionary]) {
            $index = 0
            foreach ($item in $Node) {
                if ($index -ge 32) { break }
                Visit-MnaSafeField -Node $item -Path ($Path + '[' + $index + ']') -Depth ($Depth+1)
                $index++
            }
            return
        }
        if ($Node -isnot [pscustomobject]) { return }
        foreach ($property in $Node.PSObject.Properties) {
            $name = $property.Name
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,47}$' -or $name -match '(?i)key|uuid|password|username|token|secret|authorization|signature|appSign|deviceId|openId') { continue }
            $null = $names.Add($name)
            $fieldPath = if ($Path) { $Path + '.' + $name } else { $name }
            $value = $property.Value
            $numericCounter = $name -match '(?i)flow|bytes?|packets?|traffic|rtt|loss|sent|received|recv|tx|rx' -and
                ($value -is [ValueType]) -and $value -isnot [bool] -and $value -isnot [datetime]
            if (($name -in $allowed -or $numericCounter) -and ($value -is [string] -or $value -is [ValueType] -or $null -eq $value)) {
                $safeValue = if ($value -is [string]) { Protect-MnaTrialMessage $value } else { $value }
                $fields.Add([pscustomobject]@{Path=$fieldPath;Value=$safeValue})
            } elseif ($name -eq 'interfaces' -and $value -is [array] -and @($value | Where-Object { $_ -isnot [string] }).Count -eq 0) {
                $fields.Add([pscustomobject]@{Path=$fieldPath;Value=@($value | Select-Object -First 16 | ForEach-Object { Protect-MnaTrialMessage $_ })})
            }
            Visit-MnaSafeField -Node $value -Path $fieldPath -Depth ($Depth+1)
        }
    }
    Visit-MnaSafeField -Node $Response -Path '' -Depth 0
    [pscustomobject]@{Fields=@($fields.ToArray());FieldNames=@($names | Sort-Object)}
}

function Find-MnaResponseValue {
    param([AllowNull()][object]$Response,[string]$Name,[int]$Depth=0)
    if ($null -eq $Response -or $Depth -gt 4 -or $Response -isnot [pscustomobject]) { return $null }
    $property = $Response.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    foreach ($container in @('data','result','response','status')) {
        $child = $Response.PSObject.Properties[$container]
        if ($child) {
            $found = Find-MnaResponseValue -Response $child.Value -Name $Name -Depth ($Depth+1)
            if ($null -ne $found) { return $found }
        }
    }
    return $null
}

function Invoke-MnaTrialApi {
    param([string]$Step,[ValidateSet('Get','Post')][string]$Method,[string]$Route,
        [AllowNull()][object]$Body=$null,[hashtable]$Headers=@{},[ValidateRange(1,45)][int]$TimeoutSeconds=4)
    $status = $null; $payload = $null; $message = $null; $errorType = $null
    $requestBody = $null
    try {
        $request = @{Uri=($trialApiBase+$Route);Method=$Method;Headers=$Headers;TimeoutSec=$TimeoutSeconds;SkipHttpErrorCheck=$true;NoProxy=$true;ErrorAction='Stop'}
        if ($null -ne $Body) {
            $requestBody = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
            $request.Body = $requestBody
            $request.ContentType = 'application/json'
        }
        $http = Invoke-WebRequest @request
        $status = [int]$http.StatusCode
        if ($http.Content) {
            try { $payload = ConvertFrom-Json -InputObject $http.Content -Depth 30 -ErrorAction Stop }
            catch { $message = 'Response was not JSON; raw response withheld.' }
        }
        if ($status -ge 400) {
            foreach ($messageName in @('message','msg','errorMessage','error')) {
                $errorValue = Find-MnaResponseValue -Response $payload -Name $messageName
                if ($errorValue -is [string]) { $message = Protect-MnaTrialMessage $errorValue; break }
            }
        }
    } catch {
        $errorType = $_.Exception.GetType().FullName
        $message = Protect-MnaTrialMessage $_.Exception.Message
    } finally { $requestBody = $null; $request = $null; $http = $null }
    $safe = Get-MnaSafeResponse $payload
    $success = $null -ne $status -and $status -ge 200 -and $status -lt 300
    $trialEvents.Add([pscustomobject]@{
        At=Get-Date -Format o;Step=$Step;Method=$Method;Route=$Route;HttpStatus=$status;HttpSucceeded=$success
        Fields=$safe.Fields;FieldNames=$safe.FieldNames;ErrorType=$errorType;Message=$message
    })
    # Raw is internal only. Callers must not serialize this return object.
    [pscustomobject]@{HttpSucceeded=$success;Raw=$payload;HttpStatus=$status}
}

function Update-MnaOwnedProcesses {
    if (-not $trialProcess -or -not $trialStartTime) { return }
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='linkboost.exe' OR Name='linkboost-core.exe' OR Name='multipath-helper.exe' OR Name='mp-speeder.exe'" -Property Name,ProcessId,ParentProcessId,CreationDate,ExecutablePath -ErrorAction Stop |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($trialRuntimeDirectory + '\',[StringComparison]::OrdinalIgnoreCase) -and $_.CreationDate -ge $trialStartTime.AddSeconds(-1) })
    foreach ($candidate in $candidates) {
        if ($candidate.ProcessId -eq $trialProcess.Id -and [string]::Equals($candidate.ExecutablePath,$trialExecutable,[StringComparison]::OrdinalIgnoreCase) -and [math]::Abs(($candidate.CreationDate-$trialStartTime).TotalSeconds) -lt 2) {
            $trialOwned[[int]$candidate.ProcessId] = [pscustomobject]@{Pid=[int]$candidate.ProcessId;Created=$candidate.CreationDate;Depth=0}
        }
    }
    for ($level=0;$level -lt 8;$level++) {
        foreach ($candidate in $candidates) {
            $parent = $trialOwned[[int]$candidate.ParentProcessId]
            if ($parent -and -not $trialOwned.ContainsKey([int]$candidate.ProcessId) -and $candidate.CreationDate -ge $parent.Created) {
                $trialOwned[[int]$candidate.ProcessId] = [pscustomobject]@{Pid=[int]$candidate.ProcessId;Created=$candidate.CreationDate;Depth=($parent.Depth+1)}
            }
        }
    }
}

function Test-MnaOwnedApi {
    if (-not $trialProcess) { return $false }
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $trialProcess.Id) -Property CreationDate,ExecutablePath -ErrorAction Stop
    if (-not $current -or -not [string]::Equals($current.ExecutablePath,$trialExecutable,[StringComparison]::OrdinalIgnoreCase) -or [math]::Abs(($current.CreationDate-$trialStartTime).TotalSeconds) -ge 2) { return $false }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq 9801)
    return @($listeners | Where-Object { $_.LocalAddress -eq '127.0.0.1' -and $_.OwningProcess -eq $trialProcess.Id }).Count -gt 0
}

function New-MnaHexSecret {
    param([int]$ByteCount)
    $bytes = [byte[]]::new($ByteCount)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes); return [BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant() }
    finally { $rng.Dispose(); [Array]::Clear($bytes,0,$bytes.Length) }
}

function Invoke-MnaSocksTrace {
    param([ValidateRange(1,10)][int]$TimeoutSeconds=10, [switch]$Direct, [switch]$ProbeTcp)
    $curl = $null; $configuration = $null; $output = $null; $curlError = $null
    try {
        $curlPath = (Get-Command curl.exe -CommandType Application -ErrorAction Stop).Source
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $curlPath
        $info.Arguments = '-q --config -'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $curl = [Diagnostics.Process]::new()
        $curl.StartInfo = $info
        $null = $curl.Start()
        $outTask = $curl.StandardOutput.ReadToEndAsync()
        $errTask = $curl.StandardError.ReadToEndAsync()
        $configuration = @(
            $(if ($Direct) { 'proxy = ""' } else { 'proxy = "socks5h://127.0.0.1:12345"' })
            $(if (-not $Direct) { 'proxy-user = "' + $trialSocksUser + ':' + $trialSocksPassword + '"' })
            $(if ($Direct) { 'noproxy = "*"' } else { 'noproxy = ""' })
            $(if ($ProbeTcp) { 'url = "https://one.one.one.one/cdn-cgi/trace"' } else { 'url = "https://www.cloudflare.com/cdn-cgi/trace"' })
            'ipv4'
            $(if ($ProbeTcp) { 'resolve = "one.one.one.one:443:1.1.1.1"' })
            ('connect-timeout = ' + [math]::Min(5,$TimeoutSeconds))
            ('max-time = ' + $TimeoutSeconds)
            'silent'
            'show-error'
            'fail'
        ) -join "`n"
        $curl.StandardInput.WriteLine($configuration)
        $curl.StandardInput.Close()
        if (-not $curl.WaitForExit(($TimeoutSeconds+1)*1000)) {
            $curl.Kill()
            $null = $curl.WaitForExit(2000)
            return [pscustomobject]@{Succeeded=$false;ExitCode=$null;EgressIP=$null;Message='curl exceeded bounded wait and was stopped.'}
        }
        $output = $outTask.GetAwaiter().GetResult()
        $curlError = $errTask.GetAwaiter().GetResult()
        $egress = $null
        $ipMatch = [regex]::Match($output,'(?m)^ip=([^\r\n]+)\r?$')
        if ($ipMatch.Success) {
            $parsed = $null
            if ([Net.IPAddress]::TryParse($ipMatch.Groups[1].Value,[ref]$parsed)) { $egress = $parsed.ToString() }
        }
        return [pscustomobject]@{Succeeded=($curl.ExitCode -eq 0 -and $null -ne $egress);ExitCode=$curl.ExitCode;EgressIP=$egress;Message=$(if ($curl.ExitCode -ne 0) { Protect-MnaTrialMessage $curlError } else { $null })}
    } catch {
        return [pscustomobject]@{Succeeded=$false;ExitCode=$null;EgressIP=$null;Message=(Protect-MnaTrialMessage $_.Exception.Message)}
    } finally {
        if ($curl) {
            try { if (-not $curl.HasExited) { $curl.Kill(); $null=$curl.WaitForExit(2000) } } catch { }
            $curl.Dispose()
        }
        $configuration=$null; $output=$null; $curlError=$null
    }
}

function Get-MnaUiPaths {
    $appRoot=Split-Path $script:MnaUiRoot -Parent
    [pscustomobject]@{
        Root=$script:MnaUiRoot
        App=$appRoot
        Settings=(Join-Path $appRoot 'user-settings.json')
        PowerShell=(Join-Path $appRoot 'runtime/pwsh.exe')
        Private=(Join-Path $script:MnaUiRoot 'private')
        Status=(Join-Path $script:MnaUiRoot 'results/ui-status.json')
        WorkerRecord=(Join-Path $script:MnaUiRoot 'private/ui-worker.json')
        ControlLock=(Join-Path $script:MnaUiRoot 'private/ui-control.lock')
        WorkerScript=(Join-Path $script:MnaUiRoot 'Run-Accelerator.ps1')
        Runtime=([IO.Path]::GetFullPath((Join-Path $script:MnaUiRoot 'vendor_inspection/sdk_v0.23.1/linkboost')).TrimEnd('\','/'))
    }
}

function Assert-MnaRulePathParentheses {
    param([Parameter(Mandatory)][string]$Path)
    # Mihomo's logical-rule parser counts parentheses even inside a path.
    # Balanced names such as Program Files (x86) are supported unchanged.
    $depth=0
    foreach ($character in $Path.ToCharArray()) {
        if ($character -eq '(') { $depth++ }
        elseif ($character -eq ')') {
            $depth--
            if ($depth -lt 0) { throw '程序路径中的括号必须成对，请使用括号完整的安装目录' }
        }
    }
    if ($depth -ne 0) { throw '程序路径中的括号必须成对，请使用括号完整的安装目录' }
}

function Resolve-MnaGameExecutable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '请先选择三角洲游戏程序' }
    if ($Path.IndexOfAny([char[]]"`r`n`0,") -ge 0) { throw '游戏路径不能包含换行、空字符或逗号' }
    Assert-MnaRulePathParentheses -Path $Path
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw '请选择本机磁盘中的完整游戏程序路径'
    }
    try { $fullPath=[IO.Path]::GetFullPath($Path) }
    catch { throw '游戏程序路径格式无效，请重新选择' }
    if (-not [string]::Equals([IO.Path]::GetFileName($fullPath),'DeltaForceClient-Win64-Shipping.exe',[StringComparison]::OrdinalIgnoreCase)) {
        throw '请选择 DeltaForceClient-Win64-Shipping.exe 游戏程序'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw '找不到已设置的三角洲游戏程序，请重新选择安装位置' }
    return $fullPath
}

function Resolve-MnaGameExecutables {
    param(
        [Parameter(Mandatory)][string]$GameExecutable,
        [AllowNull()][object]$GameExecutables
    )
    if ($null -ne $GameExecutables -and $GameExecutables -isnot [array]) {
        throw '游戏程序列表必须是完整路径数组'
    }
    if (@($GameExecutables).Count -gt 2) { throw '最多保存两个三角洲游戏程序路径' }
    $paths=[Collections.Generic.List[string]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($GameExecutable) + @($GameExecutables)) {
        if ($null -eq $candidate -and $null -eq $GameExecutables) { continue }
        if ($candidate -isnot [string]) { throw '游戏程序列表必须只包含完整路径字符串' }
        $resolved=Resolve-MnaGameExecutable -Path $candidate
        if ($seen.Add($resolved)) { $paths.Add($resolved) }
    }
    if ($paths.Count -gt 2) { throw '最多保存两个三角洲游戏程序路径' }
    $paths.ToArray()
}

function Read-MnaUserSettings {
    param([string]$Path=(Get-MnaUiPaths).Settings)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw '请先完成首次设置：选择游戏程序并导入设备密钥' }
    if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 16384) { throw '用户设置文件异常，请重新完成首次设置' }
    try { $settings=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -Depth 5 -ErrorAction Stop }
    catch { throw '用户设置文件无法读取，请重新完成首次设置' }
    if ($null -eq $settings -or $settings -is [array] -or $settings.gameExecutable -isnot [string]) { throw '用户设置缺少有效的游戏程序路径' }
    if ($settings.trialDeadline -cne '2026-11-13T00:00:00+11:00') { throw '免费试用截止日期配置无效，请使用完整的分享包重新设置' }
    $gamePaths=@(Resolve-MnaGameExecutables -GameExecutable $settings.gameExecutable -GameExecutables $settings.gameExecutables)
    [pscustomobject]@{
        GameExecutable=$gamePaths[0]
        GameExecutables=$gamePaths
        TrialDeadline='2026-11-13T00:00:00+11:00'
        RoutingMode='ResolveOnly'
    }
}

function Assert-MnaReleaseConfiguration {
    # Read-only preflight: never decrypt a key, write settings, or start a process.
    if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) { throw '此分享版需要 Windows 和随附的 PowerShell 7' }
    $paths=Get-MnaUiPaths
    $settings=Read-MnaUserSettings -Path $paths.Settings
    if (Test-MnaFreeTrialExpired -Deadline $settings.TrialDeadline) { throw '本次免费试用已到期，请先核对腾讯云服务状态' }
    $keyPath=Join-Path $paths.Private 'device-key.dpapi.bin'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw '尚未导入本机设备密钥，请先完成首次设置' }
    $keyFile=Get-Item -LiteralPath $keyPath -Force -ErrorAction Stop
    $privateDirectory=Get-Item -LiteralPath $paths.Private -Force -ErrorAction Stop
    if (($keyFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($privateDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '设备密钥必须保存在分享包的本机私有目录中，不能使用链接'
    }
    if ($keyFile.Length -lt 1 -or $keyFile.Length -gt 65536) { throw '本机设备密钥文件无效，请重新导入' }
    foreach ($path in @($paths.PowerShell,(Join-Path $paths.Runtime 'linkboost.exe'),(Join-Path $paths.Runtime 'linkboost-core.exe'),(Join-Path $paths.Runtime 'helper/multipath-helper.exe'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '分享包运行文件不完整，请重新解压完整安装包' }
    }
    if (-not (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Windows 缺少 curl.exe，无法进行连接自检' }
    return $settings
}

function Read-MnaUiJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream=$null;$reader=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
        return $reader.ReadToEnd() | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch { return $null }
    finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
}

function Write-MnaUiJson {
    param([string]$Path,[object]$Value)
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $operation = '写入'
    $committed = $false
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 16
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $attempt = 0
        while ($true) {
            try {
                if ($operation -eq '写入') {
                    [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
                    $operation = '替换'
                }
                # Never delete/truncate the destination: readers see complete old or new JSON.
                [IO.File]::Move($temporary,$Path,$true)
                $committed = $true
                break
            } catch {
                $cause = $_.Exception
                while ($cause.InnerException) { $cause = $cause.InnerException }
                $code = $cause.HResult -band 0xffff
                $fileError = $cause -is [IO.IOException] -or $cause -is [UnauthorizedAccessException]
                # Windows scanners/readers can briefly deny replacement with either
                # access denied (5) or sharing/lock violations (32/33).
                if ($fileError -and $code -in @(5,32,33) -and $timer.ElapsedMilliseconds -lt 2000) {
                    $remaining = 2000 - $timer.ElapsedMilliseconds
                    $delay = [math]::Min($remaining,[math]::Min(250,50 * [math]::Pow(2,[math]::Min($attempt,3))))
                    if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
                    $attempt++
                    continue
                }
                if (-not $fileError) { throw }
                $name = [IO.Path]::GetFileName($Path)
                $reason = if ($code -eq 5) { '访问被拒绝' } elseif ($code -in @(32,33)) { '文件仍被占用' } else { '文件操作失败' }
                throw [InvalidOperationException]::new(('无法'+$operation+'本地运行记录（'+$name+'）：'+$reason+'，错误码 '+$code+'。请检查该文件权限或安全软件的拦截记录。'),$cause)
            }
        }
    } finally {
        # Cleanup cannot hide the original write failure or invalidate a committed record.
        if (-not $committed -and [IO.File]::Exists($temporary)) {
            try { [IO.File]::Delete($temporary) } catch { }
        }
    }
}

function ConvertTo-MnaUiOperationTime {
    param([AllowNull()][object]$Value)
    # ConvertFrom-Json may deserialize ISO timestamps as DateTime on newer hosts.
    if ($Value -is [DateTimeOffset]) { return $Value.ToString('o') }
    if ($Value -is [datetime]) { return ([DateTimeOffset]$Value).ToString('o') }
    $parsed=[DateTimeOffset]::MinValue
    if ($Value -is [string] -and $Value -match '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$' -and
        [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) {
        return $parsed.ToString('o')
    }
    return $null
}

function Write-MnaUiStatus {
    param([ValidateSet('stopped','starting','connected','stopping','error')][string]$Phase,
        [string]$Message,[bool]$Ready=$false,[AllowNull()][string]$Gateway=$null,
        [AllowNull()][string]$ExitIp=$null,[AllowNull()][string]$RunId=$null,[switch]$AllowTerminalTransition,
        [bool]$GameRoutingConfigured=$false,[bool]$UdpRoutingVerified=$false,[bool]$GameRoutingVerified=$false,
        [ValidateSet('ResolveOnly')][string]$RoutingMode='ResolveOnly',
        [AllowNull()][string]$ProgressStage=$null,[AllowNull()][string]$OperationStartedAt=$null)
    $paths=Get-MnaUiPaths
    $statusLock=$null
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.Status))
    try {
        # A writer may hold this lock during its two-second atomic-write retry.
        # Allow Stop and the worker enough time to serialize that operation.
        for ($attempt=0;$attempt -lt 140;$attempt++) {
            try { $statusLock=[IO.File]::Open(($paths.Status+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);break }
            catch [IO.IOException] {
                if ($attempt -eq 139) { throw [InvalidOperationException]::new('无法更新本地连接状态：ui-status.json.lock 持续被占用，请稍后重试关闭。',$_.Exception) }
                Start-Sleep -Milliseconds 25
            }
        }
        $record=Read-MnaUiJson $paths.WorkerRecord
        if ($RunId -and (-not $record -or $record.RunId -ne $RunId)) { return }
        $effectiveRunId=if ($RunId) { $RunId } elseif ($record) { $record.RunId } else { $null }
        $current=Read-MnaUiJson $paths.Status
        # A late Stop caller cannot overwrite the worker's completed terminal state.
        if (-not $AllowTerminalTransition -and $Phase -eq 'stopping' -and $current -and $current.runId -eq $effectiveRunId -and $current.phase -in @('stopped','error')) { return }
        $operationTime=$null;$stage=$null
        if ($Phase -in @('starting','stopping')) {
            # Worker stage updates/repeated Stop preserve this operation's start.
            # Explicit dead-worker recovery starts a fresh cleanup attempt.
            if (-not $AllowTerminalTransition -and $current -and $current.runId -eq $effectiveRunId -and $current.phase -eq $Phase) {
                $operationTime=ConvertTo-MnaUiOperationTime $current.operationStartedAt
            }
            if (-not $operationTime -and $OperationStartedAt) {
                $operationTime=ConvertTo-MnaUiOperationTime $OperationStartedAt
                if (-not $operationTime) { throw '操作开始时间格式无效' }
            }
            if (-not $operationTime) { $operationTime=[DateTimeOffset]::Now.ToString('o') }
            $stage=Protect-MnaTrialMessage $(if ($ProgressStage) {$ProgressStage} else {$Message})
        }
        Write-MnaUiJson -Path $paths.Status -Value ([pscustomobject]@{
            phase=$Phase;message=(Protect-MnaTrialMessage $Message);ready=($Ready -and $Phase -eq 'connected' -and $GameRoutingConfigured -and $UdpRoutingVerified)
            gateway=(Protect-MnaTrialMessage $Gateway);exitIp=$ExitIp
            gameRoutingConfigured=($GameRoutingConfigured -and $Phase -eq 'connected')
            udpRoutingVerified=($UdpRoutingVerified -and $Phase -eq 'connected')
            gameRoutingVerified=($GameRoutingVerified -and $GameRoutingConfigured -and $UdpRoutingVerified -and $Phase -eq 'connected')
            routingMode=$RoutingMode
            progressStage=$stage;operationStartedAt=$operationTime
            runId=$effectiveRunId;updatedAt=Get-Date -Format o
        })
    } finally { if ($statusLock) { $statusLock.Dispose() } }
}

function Assert-MnaUiPreviousRunClear {
    param([AllowNull()][object]$Record)
    # This check precedes replacement of the sole current-run pointer.
    if ($Record -and $Record.RunId -match '^[a-f0-9]{24}$') {
        $owner=Read-MnaUiJson (Get-MnaRunFile $Record.RunId ownership)
        if ($owner) {
            if ($owner.RunId -ne $Record.RunId -or -not [string]::Equals($owner.Runtime,(Get-MnaUiPaths).Runtime,[StringComparison]::OrdinalIgnoreCase)) {
                throw '上次连接的归属记录无法确认，已保留记录；请先点击关闭'
            }
            foreach ($item in @($owner.Owned)) {
                $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$item.Pid) -Property CreationDate,ExecutablePath -ErrorAction Stop
                if ($current -and $current.CreationDate -eq [datetime]$item.Created -and $current.ExecutablePath -and $current.ExecutablePath.StartsWith($owner.Runtime+'\',[StringComparison]::OrdinalIgnoreCase)) {
                    throw '上次连接仍有本次拥有的 SDK 进程，已保留恢复记录；请先点击关闭'
                }
            }
            $previousStatus=Read-MnaUiJson (Get-MnaUiPaths).Status
            if (-not $previousStatus -or $previousStatus.phase -ne 'stopped') {
                throw '上次连接的清理结果尚未确认，已保留记录；请先点击关闭再重试'
            }
        }
    }
    if (Get-Process -Name linkboost,linkboost-core,multipath-helper,mp-speeder -ErrorAction SilentlyContinue) {
        throw '已有 SDK 进程运行，未覆盖上次恢复记录；请先结束已有连接'
    }
}

function Test-MnaUiWorker {
    param([AllowNull()][object]$Record)
    if (-not $Record -or $Record.RunId -notmatch '^[a-f0-9]{24}$' -or $Record.WorkerPid -le 0) { return $false }
    try {
        $process=Get-Process -Id $Record.WorkerPid -ErrorAction Stop
        $imagePath=$null
        try { $imagePath=$process.Path } catch { }
        if ([string]::IsNullOrEmpty($imagePath)) {
            # An unelevated UI can use limited, read-only process information to
            # identify its elevated worker without requesting VM/module access.
            if (-not ('MnaUi.LimitedProcessImageQuery' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace MnaUi {
    public static class LimitedProcessImageQuery {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);
        [DllImport("kernel32.dll", EntryPoint="QueryFullProcessImageNameW", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        public static string Read(uint processId) {
            const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
            IntPtr handle=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (handle==IntPtr.Zero) return null;
            try {
                uint size=32768;
                StringBuilder path=new StringBuilder((int)size);
                return QueryFullProcessImageName(handle, 0, path, ref size) ? path.ToString() : null;
            } finally { CloseHandle(handle); }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
            }
            $imagePath=[MnaUi.LimitedProcessImageQuery]::Read([uint32]$Record.WorkerPid)
        }
        return -not [string]::IsNullOrEmpty($imagePath) -and [string]::Equals($imagePath,$Record.WorkerExecutable,[StringComparison]::OrdinalIgnoreCase) -and
            $process.StartTime.ToUniversalTime().Ticks -eq ([datetime]$Record.WorkerCreatedUtc).ToUniversalTime().Ticks -and
            [string]::Equals($Record.WorkerScript,(Get-MnaUiPaths).WorkerScript,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-MnaUiStatus {
    $paths=Get-MnaUiPaths
    $status=Read-MnaUiJson $paths.Status
    $record=Read-MnaUiJson $paths.WorkerRecord
    if (-not $status) { return [pscustomobject]@{phase='stopped';message='加速器已关闭';ready=$false;gateway=$null;exitIp=$null;gameRoutingConfigured=$false;udpRoutingVerified=$false;gameRoutingVerified=$false;routingMode='ResolveOnly';progressStage=$null;operationStartedAt=$null} }
    $routingMode='ResolveOnly'
    if ($status.phase -in @('starting','connected','stopping') -and -not (Test-MnaUiWorker $record)) {
        return [pscustomobject]@{phase='error';message='后台进程已退出；请点击关闭以核对并清理本次连接';ready=$false;gateway=$null;exitIp=$null;gameRoutingConfigured=$false;udpRoutingVerified=$false;gameRoutingVerified=$false;routingMode=$routingMode;progressStage=$null;operationStartedAt=$null}
    }
    [pscustomobject]@{
        phase=$status.phase;message=(Protect-MnaTrialMessage $status.message)
        ready=($status.phase -eq 'connected' -and $status.ready -eq $true -and $status.gameRoutingConfigured -eq $true -and $status.udpRoutingVerified -eq $true)
        gateway=(Protect-MnaTrialMessage $status.gateway);exitIp=$status.exitIp
        gameRoutingConfigured=($status.phase -eq 'connected' -and $status.gameRoutingConfigured -eq $true)
        udpRoutingVerified=($status.phase -eq 'connected' -and $status.udpRoutingVerified -eq $true)
        gameRoutingVerified=($status.phase -eq 'connected' -and $status.gameRoutingVerified -eq $true)
        routingMode=$routingMode
        progressStage=if ($status.phase -in @('starting','stopping')) {Protect-MnaTrialMessage $status.progressStage} else {$null}
        operationStartedAt=if ($status.phase -in @('starting','stopping')) {ConvertTo-MnaUiOperationTime $status.operationStartedAt} else {$null}
    }
}

function Get-MnaRunFile {
    param([ValidatePattern('^[a-f0-9]{24}$')][string]$RunId,[ValidateSet('stop','ownership')][string]$Kind)
    Join-Path (Get-MnaUiPaths).Private ('ui-' + $Kind + '-' + $RunId + '.json')
}

function Save-MnaUiOwnership {
    param([string]$RunId)
    if (-not $trialProcess) { return }
    $path = Get-MnaRunFile $RunId ownership
    $record = [pscustomobject]@{
        RunId=$RunId;RootPid=$trialProcess.Id;RootCreated=$trialStartTime.ToString('o')
        Runtime=$trialRuntimeDirectory;BeforePath=$uiBeforePath;Owned=@($trialOwned.Values | Sort-Object Pid)
    }
    $serialized = ConvertTo-Json -InputObject $record -Depth 16 -Compress
    # Stable process ownership does not need rewriting on every health check.
    # Cache only after a successful commit; additions/changes must reach disk.
    if ($script:MnaUiOwnershipSaved[$path] -ceq $serialized -and [IO.File]::Exists($path)) { return }
    Write-MnaUiJson -Path $path -Value $record
    $script:MnaUiOwnershipSaved[$path] = $serialized
}

function Stop-MnaUiOwnedRuntime {
    $errors=[System.Collections.Generic.List[object]]::new()
    $stopOk=$false
    $gameHelperBlocked=$false
    # Normal callers disable helper TUN through its controller first. This is the
    # exact-identity fallback, and must run before the SDK/SOCKS service is stopped.
    foreach ($owned in @($trialOwned.Values | Where-Object {$_.Kind -eq 'GameRouteHelper'})) {
        try {
            $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$owned.Pid) -Property CreationDate,ExecutablePath -ErrorAction Stop
            $expected=Join-Path $trialRuntimeDirectory 'helper/multipath-helper.exe'
            if ($current -and $current.CreationDate -eq $owned.Created -and [string]::Equals($current.ExecutablePath,$expected,[StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $owned.Pid -ErrorAction Stop
                $clock=[Diagnostics.Stopwatch]::StartNew()
                do {
                    Start-Sleep -Milliseconds 100
                    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$owned.Pid) -Property CreationDate -ErrorAction Stop
                } while ($current -and $current.CreationDate -eq $owned.Created -and $clock.Elapsed.TotalSeconds -lt 3)
                if ($current -and $current.CreationDate -eq $owned.Created) { $gameHelperBlocked=$true }
            }
        } catch { $gameHelperBlocked=$true;$errors.Add([pscustomobject]@{Step='game_helper_before_sdk';Message=(Protect-MnaTrialMessage $_.Exception.Message)}) }
    }
    if ($gameHelperBlocked) {
        $errors.Add([pscustomobject]@{Step='sdk_stop_deferred';Message='尚未确认游戏引流 helper 已退出，暂保留其依赖的 SDK；请重新关闭并查看本地记录'})
        return [pscustomobject]@{StopApiSucceeded=$false;RemainingOwnedProcessCount=$null;Errors=@($errors.ToArray())}
    }
    try {
        Update-MnaOwnedProcesses
        if (Test-MnaOwnedApi) {
            $stopResult=Invoke-MnaTrialApi -Step stop -Method Post -Route '/api/v2/client/mp-speeder/stop' -TimeoutSeconds 15
            $stopOk=$stopResult.HttpSucceeded
            $stopResult=$null
            Start-Sleep -Milliseconds 400
        }
    } catch { $errors.Add([pscustomobject]@{Step='stop_api';Message=(Protect-MnaTrialMessage $_.Exception.Message)}) }
    try { Update-MnaOwnedProcesses } catch { $errors.Add([pscustomobject]@{Step='refresh_ownership';Message=(Protect-MnaTrialMessage $_.Exception.Message)}) }
    foreach ($owned in @($trialOwned.Values | Sort-Object Depth -Descending)) {
        try {
            $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$owned.Pid) -Property CreationDate,ExecutablePath -ErrorAction Stop
            if ($current -and $current.CreationDate -eq $owned.Created -and $current.ExecutablePath -and
                $current.ExecutablePath.StartsWith($trialRuntimeDirectory+'\',[StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $owned.Pid -ErrorAction Stop
            }
        } catch {
            if (Get-Process -Id $owned.Pid -ErrorAction SilentlyContinue) { $errors.Add([pscustomobject]@{Step='stop_owned_process';Message=(Protect-MnaTrialMessage $_.Exception.Message)}) }
        }
    }
    Start-Sleep -Milliseconds 300
    $remaining=$null
    try {
        $remaining=@(Get-CimInstance Win32_Process -Filter "Name='linkboost.exe' OR Name='linkboost-core.exe' OR Name='multipath-helper.exe' OR Name='mp-speeder.exe'" -Property ProcessId,CreationDate -ErrorAction Stop |
            Where-Object {$trialOwned.ContainsKey([int]$_.ProcessId) -and $_.CreationDate -eq $trialOwned[[int]$_.ProcessId].Created}).Count
    } catch { $errors.Add([pscustomobject]@{Step='check_remaining';Message=(Protect-MnaTrialMessage $_.Exception.Message)}) }
    [pscustomobject]@{StopApiSucceeded=$stopOk;RemainingOwnedProcessCount=$remaining;Errors=@($errors.ToArray())}
}

function Initialize-MnaUiRuntimeVariables {
    # Caller dot-sources this function body so runtime helpers share the caller's scope.
    $paths=Get-MnaUiPaths
    $trialRuntimeDirectory=$paths.Runtime
    $trialExecutable=Join-Path $trialRuntimeDirectory 'linkboost.exe'
    $trialApiBase='http://127.0.0.1:9801'
    $trialSensitiveStrings=[System.Collections.Generic.List[string]]::new()
    $trialEvents=[System.Collections.Generic.List[object]]::new()
    $trialOwned=@{}
    $trialProcess=$null
    $trialStartTime=$null
    $trialSocksUser=$null
    $trialSocksPassword=$null
}

function Test-MnaFreeTrialExpired {
    param([DateTimeOffset]$At=[DateTimeOffset]::UtcNow,[string]$Deadline='2026-11-13T00:00:00+11:00')
    # Conservative Sydney boundary. This affects local Start/worker only; it does
    # not cancel the cloud service or turn the daily Stop button into cloud deletion.
    if ($Deadline -cne '2026-11-13T00:00:00+11:00') { throw '免费试用截止日期配置无效' }
    $deadlineInstant=[DateTimeOffset]::Parse($Deadline,[Globalization.CultureInfo]::InvariantCulture)
    return $At -ge $deadlineInstant
}

function Test-MnaUiConfigurationRestored {
    param([Parameter(Mandatory)][object]$Comparison)
    if (-not $Comparison.FullyComparable) { return $false }
    if ($Comparison.Equal) { return $true }
    $physicalIndexes=@()
    if (@($Comparison.Changes | Where-Object Section -in @('IPAddresses','ActiveRoutes')).Count) {
        $physicalIndexes=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object HardwareInterface | ForEach-Object ifIndex)
    }
    $parseIpv6={
        param($Text)
        $address=$null
        if ([Net.IPAddress]::TryParse([string]$Text,[ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return $address }
        return $null
    }
    $addressIdentity={
        param($Item)
        $address=& $parseIpv6 $Item.IPAddress
        if ($address) { return ([string]$Item.InterfaceIndex+'|'+$address.ToString()) }
        return $null
    }
    $isAutomaticUla={
        param($Item)
        $address=& $parseIpv6 $Item.IPAddress
        # Windows origin enums: RA=4, Link=4, Random=5. Link is also
        # automatically generated; it expires with its advertised prefix.
        return ($Item.InterfaceIndex -in $physicalIndexes -and $Item.AddressFamily -eq 'IPv6' -and $address -and
            (($address.GetAddressBytes()[0] -band 0xfe) -eq 0xfc) -and $Item.PrefixOrigin -eq 4 -and
            (($Item.SuffixOrigin -eq 4 -and $Item.PrefixLength -eq 64) -or ($Item.SuffixOrigin -eq 5 -and $Item.PrefixLength -in @(64,128))) -and
            $Item.Type -eq 1 -and $Item.SkipAsSource -eq $false)
    }
    $changedAddresses=@{}
    $dynamicAddresses=@{}
    $dynamicKeys=@{}
    foreach ($side in @('Removed','Added')) {
        $changedAddresses[$side]=@($Comparison.Changes | Where-Object Section -eq 'IPAddresses' | ForEach-Object { $_.$side })
    }
    foreach ($side in @('Removed','Added')) {
        $opposite=if ($side -eq 'Removed') {'Added'} else {'Removed'}
        $oppositeKeys=@($changedAddresses[$opposite] | ForEach-Object { & $addressIdentity $_ })
        # An existing address whose configuration changed is not an expiry or
        # renewal. Only additions/removals can explain an attached route change.
        $dynamicAddresses[$side]=@($changedAddresses[$side] | Where-Object { (& $isAutomaticUla $_) -and (& $addressIdentity $_) -notin $oppositeKeys })
        $dynamicKeys[$side]=@($dynamicAddresses[$side] | ForEach-Object { & $addressIdentity $_ })
    }
    foreach ($change in @($Comparison.Changes)) {
        if ($change.Section -in @('IPAddresses','ActiveRoutes')) {
            # Preserve the complete diff. This only classifies narrowly proven
            # automatic ULA churn; it never rewrites adapters, addresses or routes.
            if ($change.Section -eq 'IPAddresses') {
                $normalized = @{}
                foreach ($side in @('Removed','Added')) {
                    $normalized[$side] = @($change.$side | ForEach-Object {
                        $physical = $_.InterfaceIndex -in $physicalIndexes
                        if ((& $addressIdentity $_) -notin $dynamicKeys[$side]) {
                            if ($physical) { $_ | Select-Object -Property * -ExcludeProperty AddressState | ConvertTo-Json -Depth 6 -Compress }
                            else { $_ | ConvertTo-Json -Depth 6 -Compress }
                        }
                    } | Sort-Object)
                }
                if ($normalized.Removed.Count -ne $normalized.Added.Count) { return $false }
                for ($n=0;$n -lt $normalized.Removed.Count;$n++) { if ($normalized.Removed[$n] -cne $normalized.Added[$n]) { return $false } }
                continue
            }
            foreach ($side in @('Removed','Added')) {
                foreach ($item in @($change.$side)) {
                    # Protocol=3 is NetMgmt, not proof of RA origin. Even a
                    # matching /64 can be manual; preserve it for review.
                    if ($item.InterfaceIndex -notin $physicalIndexes -or $item.AddressFamily -ne 'IPv6' -or $item.Protocol -ne 2 -or $item.Publish -ne 0 -or $item.RouteMetric -ne 256) { return $false }
                    $parts=([string]$item.DestinationPrefix).Split('/')
                    if ($parts.Count -ne 2 -or $parts[1] -ne '128') { return $false }
                    $prefix=& $parseIpv6 $parts[0]
                    $nextHop=& $parseIpv6 $item.NextHop
                    if (-not $prefix -or ($prefix.GetAddressBytes()[0] -band 0xfe) -ne 0xfc -or -not $nextHop -or -not $nextHop.Equals([Net.IPAddress]::IPv6Any)) { return $false }
                    $matched=$false
                    foreach ($address in $dynamicAddresses[$side]) {
                        if ($address.InterfaceIndex -ne $item.InterfaceIndex) { continue }
                        $parsed=& $parseIpv6 $address.IPAddress
                        if ($prefix.Equals($parsed)) { $matched=$true;break }
                    }
                    if (-not $matched) { return $false }
                }
            }
            continue
        }
        # Carrier/link observations can change independently of our configuration.
        # Keep the complete diff in the report; never reset physical interfaces.
        $excluded=switch ($change.Section) {
            'Adapters' { @('Status','LinkSpeed') }
            'Interfaces' { @('ConnectionState') }
            default { return $false }
        }
        $before=@($change.Removed | ForEach-Object { $_ | Select-Object -Property * -ExcludeProperty $excluded | ConvertTo-Json -Depth 8 -Compress } | Sort-Object)
        $after=@($change.Added | ForEach-Object { $_ | Select-Object -Property * -ExcludeProperty $excluded | ConvertTo-Json -Depth 8 -Compress } | Sort-Object)
        if ($before.Count -ne $after.Count) { return $false }
        for ($index=0;$index -lt $before.Count;$index++) { if ($before[$index] -cne $after[$index]) { return $false } }
    }
    return $true
}

function Invoke-MnaUiNativeStun {
    $process=$null;$output=$null
    try {
        $scriptPath=Join-Path (Get-MnaUiPaths).Root 'Test-UdpStun.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw 'UDP 测试脚本缺失' }
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=(Get-MnaUiPaths).PowerShell
        $info.Arguments='-NoProfile -NonInteractive -File "'+$scriptPath+'" -Server 162.159.207.0 -Port 3478 -TimeoutMs 3000 -Attempts 2'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        $null=$process.Start()
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { throw '原生 UDP 测试超过等待上限' }
        $output=$outTask.GetAwaiter().GetResult()
        $payload=ConvertFrom-Json -InputObject $output -Depth 8 -ErrorAction Stop
        $mapped=$null
        $validMapped=[Net.IPAddress]::TryParse([string]$payload.mappedIP,[ref]$mapped)
        return [pscustomobject]@{
            Success=($process.ExitCode -eq 0 -and $payload.success -eq $true -and $validMapped)
            ServerIP='162.159.207.0';ServerPort=3478
            MappedIP=$(if ($validMapped) {$mapped.ToString()} else {$null});MappedPort=$payload.mappedPort
            RttMs=$payload.rttMs;Message=(Protect-MnaTrialMessage $payload.error)
        }
    } catch { return [pscustomobject]@{Success=$false;MappedIP=$null;Message=(Protect-MnaTrialMessage $_.Exception.Message)} }
    finally {
        if ($process) { try { if (-not $process.HasExited) {$process.Kill();$null=$process.WaitForExit(2000)} } catch { };$process.Dispose() }
        $output=$null;$payload=$null
    }
}
