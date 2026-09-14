#requires -Version 7.0
<# Offline Windows filesystem regression. Uses only a newly created fixture;
   no real settings, keys, process ownership, SDK, adapters, or network access.
   Background threads only hold/read fixture files or clear their ReadOnly bit. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw '此文件系统回归需要 Windows' }
$releaseRoot=Split-Path $PSScriptRoot -Parent
$backend=Join-Path $releaseRoot 'app/backend/Mna-UI.Common.ps1'
$runToken=[guid]::NewGuid().ToString('N')
$fixtureBase=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'atomic-runtime-work'))
$fixtureRoot=Join-Path $fixtureBase $runToken
$reportPath=Join-Path $PSScriptRoot ('atomic-runtime-state-'+$runToken+'.json')
$checks=[Collections.Generic.List[object]]::new()
$measurements=[ordered]@{}
$cleanupVerified=$false
$unexpected=$null

# Import only the explicitly reviewed file helpers. No source-level statements
# or other backend functions execute; subsequent path resolution is fixture-only.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($backend,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw '后端源文件语法检查失败' }
foreach ($name in @('Write-MnaUiJson','Read-MnaUiJson','Get-MnaUiPaths','Get-MnaRunFile','Save-MnaUiOwnership','ConvertTo-MnaUiOperationTime','Write-MnaUiStatus','Get-MnaUiStatus','Protect-MnaTrialMessage')) {
    $definition=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name)
    if ($definition.Count -ne 1) { throw ('后端函数未唯一找到：'+$name) }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$script:MnaUiRoot=Join-Path $fixtureRoot 'app/backend'
$script:MnaUiOwnershipSaved=@{}
$trialSensitiveStrings=@()
# Only fixture liveness is inspected; synthetic identities never reach process APIs.
$script:fixtureWorkerAlive=$true
function Test-MnaUiWorker { param($Record) return $script:fixtureWorkerAlive }

function Assert-Atomic([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('离线断言失败：'+$Message) }
}
function Test-AtomicCase([string]$Name,[scriptblock]$Action) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $null=& $Action
        $checks.Add([pscustomobject]@{Name=$Name;Passed=$true;ElapsedMs=$watch.ElapsedMilliseconds;Failure=$null})
    } catch {
        $message=$_.Exception.Message.Replace($fixtureRoot,'[fixture]')
        $checks.Add([pscustomobject]@{Name=$Name;Passed=$false;ElapsedMs=$watch.ElapsedMilliseconds;Failure=$message})
    }
}
function New-AtomicValue([int]$Revision) {
    [pscustomobject]@{Revision=$Revision;Message='中文 文件状态';Payload=('完整状态内容0123456789' * 512)}
}
function Assert-AtomicNoTemps([string]$Path) {
    $directory=[IO.Path]::GetDirectoryName($Path)
    $pattern=[IO.Path]::GetFileName($Path)+'.*.tmp'
    Assert-Atomic (@([IO.Directory]::GetFiles($directory,$pattern)).Count -eq 0) '写入结束后无残留临时文件'
}

if (-not ('AtomicRuntimeRegression.FileActivity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Collections.Concurrent;
namespace AtomicRuntimeRegression {
    public sealed class FileActivity : IDisposable {
        private readonly Thread worker;
        private readonly ManualResetEventSlim stop = new ManualResetEventSlim(false);
        public readonly ConcurrentQueue<string> Samples = new ConcurrentQueue<string>();
        public readonly ConcurrentQueue<string> Errors = new ConcurrentQueue<string>();
        public volatile int SampleCount;
        public volatile bool Complete;
        private FileActivity(string path, int mode, int delayMs) {
            // Open synchronously so the caller cannot race ahead of lock creation.
            FileStream held = mode == 0 ? File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read) : null;
            worker = new Thread(() => {
                try {
                    if (mode == 0) { stop.Wait(delayMs); }
                    else if (mode == 1) {
                        stop.Wait(delayMs);
                        File.SetAttributes(path, File.GetAttributes(path) & ~FileAttributes.ReadOnly);
                    } else {
                        while (!stop.IsSet) {
                            try {
                                using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                                using (var reader = new StreamReader(stream, Encoding.UTF8)) {
                                    string text = reader.ReadToEnd();
                                    if (SampleCount < 2000) { Samples.Enqueue(text); Interlocked.Increment(ref SampleCount); }
                                }
                            } catch (Exception ex) { Errors.Enqueue(ex.GetType().Name + ":" + (ex.HResult & 65535)); }
                            stop.Wait(1);
                        }
                    }
                } catch (Exception ex) { Errors.Enqueue(ex.GetType().Name + ":" + (ex.HResult & 65535)); }
                finally { if (held != null) held.Dispose(); Complete = true; }
            });
            worker.IsBackground = true;
            worker.Start();
        }
        public static FileActivity HoldRead(string path, int delayMs) { return new FileActivity(path, 0, delayMs); }
        public static FileActivity ClearReadOnly(string path, int delayMs) { return new FileActivity(path, 1, delayMs); }
        public static FileActivity ReadRepeatedly(string path) { return new FileActivity(path, 2, 0); }
        public void Dispose() {
            stop.Set();
            if (!worker.Join(4000)) throw new InvalidOperationException("Fixture file activity failed to stop");
            stop.Dispose();
        }
    }
}
'@ -ErrorAction Stop | Out-Null
}

try {
    $null=[IO.Directory]::CreateDirectory($script:MnaUiRoot)
    $paths=Get-MnaUiPaths
    Assert-Atomic ($paths.Private.StartsWith($fixtureRoot+'\',[StringComparison]::OrdinalIgnoreCase)) '测试只解析独立目录'

    Test-AtomicCase '无 Delete 共享读取锁 450ms 后释放，可原子更新' {
        $path=Join-Path $fixtureRoot 'shared-read.json'
        Write-MnaUiJson $path (New-AtomicValue 0)
        $activity=[AtomicRuntimeRegression.FileActivity]::HoldRead($path,450)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { Write-MnaUiJson $path (New-AtomicValue 1) } finally { $activity.Dispose() }
        $measurements.SharedReadLockUpdateMs=$watch.ElapsedMilliseconds
        Assert-Atomic ($watch.ElapsedMilliseconds -ge 400 -and $watch.ElapsedMilliseconds -lt 3500) '确实等待短暂锁后成功'
        Assert-Atomic ($activity.Errors.Count -eq 0 -and $activity.Complete) '锁线程正常结束'
        Assert-Atomic ((Read-MnaUiJson $path).Revision -eq 1) '锁释放后新状态落盘'
        Assert-AtomicNoTemps $path
    }

    Test-AtomicCase '真实并发读取只观察完整的新旧 JSON' {
        $path=Join-Path $fixtureRoot 'concurrent.json'
        Write-MnaUiJson $path (New-AtomicValue 0)
        $activity=[AtomicRuntimeRegression.FileActivity]::ReadRepeatedly($path)
        try {
            for ($i=1;$i -le 120;$i++) { Write-MnaUiJson $path (New-AtomicValue $i); Start-Sleep -Milliseconds 2 }
        } finally { $activity.Dispose() }
        $samples=$activity.Samples.ToArray()
        $measurements.ConcurrentReadSamples=$samples.Count
        $measurements.ConcurrentReadErrors=$activity.Errors.Count
        Assert-Atomic ($samples.Count -ge 10 -and $activity.Errors.Count -eq 0 -and $activity.Complete) '并发读取得到样本且无文件异常'
        $versions=[Collections.Generic.HashSet[int]]::new()
        foreach ($sample in $samples) {
            $value=ConvertFrom-Json -InputObject $sample -ErrorAction Stop
            Assert-Atomic ($value.Revision -ge 0 -and $value.Revision -le 120) '每次读取都是某次完整更新'
            Assert-Atomic ($value.Message -ceq '中文 文件状态' -and $value.Payload -ceq (New-AtomicValue 0).Payload) '并发读取内容未截断'
            $null=$versions.Add([int]$value.Revision)
        }
        $measurements.ConcurrentReadDistinctVersions=$versions.Count
        Assert-Atomic ($versions.Count -ge 2 -and (Read-MnaUiJson $path).Revision -eq 120) '读取覆盖多次替换且最终状态正确'
        Assert-AtomicNoTemps $path
    }

    Test-AtomicCase '持续 ReadOnly 拒绝：有界中文错误、原状态完整、临时文件清理' {
        $path=Join-Path $fixtureRoot 'readonly-target.json'
        Write-MnaUiJson $path (New-AtomicValue 0)
        $original=[IO.File]::ReadAllText($path)
        [IO.File]::SetAttributes($path,([IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly))
        $failure=$null;$cause=$null
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { Write-MnaUiJson $path (New-AtomicValue 1) } catch { $failure=$_.Exception.Message;$cause=$_.Exception }
        $measurements.PersistentReadOnlyFailureMs=$watch.ElapsedMilliseconds
        while ($cause -and $cause.InnerException) { $cause=$cause.InnerException }
        $measurements.PersistentReadOnlyCauseType=if ($cause) { $cause.GetType().Name } else { $null }
        $measurements.PersistentReadOnlyWin32Code=if ($cause) { $cause.HResult -band 0xffff } else { $null }
        try {
            Assert-Atomic ($failure -match '无法.*本地运行记录（readonly-target\.json）.*访问被拒绝.*错误码 5') '错误转换为中文安全文件名和 Win32 5'
            Assert-Atomic (-not $failure.Contains($fixtureRoot)) '错误不暴露完整路径'
            Assert-Atomic ($cause -is [UnauthorizedAccessException]) 'PowerShell 包装正确展开到真实 UnauthorizedAccessException'
            Assert-Atomic ($watch.ElapsedMilliseconds -ge 1800 -and $watch.ElapsedMilliseconds -lt 4000) '永久权限错误在约两秒内结束'
            Assert-Atomic ([IO.File]::ReadAllText($path) -ceq $original) '失败保留完整旧状态'
            Assert-AtomicNoTemps $path
        } finally { [IO.File]::SetAttributes($path,([IO.File]::GetAttributes($path) -band (-bnot [IO.FileAttributes]::ReadOnly))) }
    }

    Test-AtomicCase '解除 ReadOnly 后原调用可再次成功' {
        $path=Join-Path $fixtureRoot 'readonly-target.json'
        Write-MnaUiJson $path (New-AtomicValue 2)
        Assert-Atomic ((Read-MnaUiJson $path).Revision -eq 2) '权限恢复后重试写入成功'
        Assert-AtomicNoTemps $path
    }

    Test-AtomicCase 'ReadOnly 450ms 后解除，当前重试内自动恢复' {
        $path=Join-Path $fixtureRoot 'temporary-readonly.json'
        Write-MnaUiJson $path (New-AtomicValue 0)
        [IO.File]::SetAttributes($path,([IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly))
        $activity=[AtomicRuntimeRegression.FileActivity]::ClearReadOnly($path,450)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { Write-MnaUiJson $path (New-AtomicValue 1) } finally { $activity.Dispose() }
        $measurements.TemporaryReadOnlyUpdateMs=$watch.ElapsedMilliseconds
        Assert-Atomic ($watch.ElapsedMilliseconds -ge 400 -and $watch.ElapsedMilliseconds -lt 3500) '访问拒绝在有界重试内恢复'
        Assert-Atomic ($activity.Errors.Count -eq 0 -and $activity.Complete) '属性释放线程正常结束'
        Assert-Atomic ((Read-MnaUiJson $path).Revision -eq 1) '短暂访问拒绝后的新状态完整'
        Assert-AtomicNoTemps $path
    }

    Test-AtomicCase '状态互斥锁占用 1500ms，等待成功且状态完整' {
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.Status))
        $lockPath=$paths.Status+'.lock'
        [IO.File]::WriteAllText($lockPath,'')
        $activity=[AtomicRuntimeRegression.FileActivity]::HoldRead($lockPath,1500)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { Write-MnaUiStatus -Phase stopped -Message '离线测试完成' } finally { $activity.Dispose() }
        $measurements.StatusLockUpdateMs=$watch.ElapsedMilliseconds
        Assert-Atomic ($watch.ElapsedMilliseconds -ge 1400 -and $watch.ElapsedMilliseconds -lt 4500) '状态锁不再在一秒时提前失败'
        $status=Read-MnaUiJson $paths.Status
        Assert-Atomic ($status.phase -ceq 'stopped' -and $status.message -ceq '离线测试完成') '状态互斥锁释放后完整提交'
        Assert-Atomic ($activity.Complete -and $activity.Errors.Count -eq 0) '状态锁线程结束'
        Assert-AtomicNoTemps $paths.Status
    }

    Test-AtomicCase '启动阶段更新保留真实起点，JSON 时间类型与状态读取兼容' {
        $progressRun='111111111111111111111111'
        Write-MnaUiJson $paths.WorkerRecord ([pscustomobject]@{RunId=$progressRun})
        $started='2026-09-15T01:00:00+10:00'
        Write-MnaUiStatus -Phase starting -Message '正在准备本地服务…' -RunId $progressRun -ProgressStage '准备本地服务' -OperationStartedAt $started
        $first=Get-MnaUiStatus
        Assert-Atomic ($first.progressStage -ceq '准备本地服务' -and ([DateTimeOffset]$first.operationStartedAt).UtcTicks -eq ([DateTimeOffset]$started).UtcTicks) '首个阶段记录真实操作起点'
        Write-MnaUiStatus -Phase starting -Message '正在连接香港线路…' -RunId $progressRun -ProgressStage '连接香港线路' -OperationStartedAt '2026-09-15T01:00:10+10:00'
        $next=Get-MnaUiStatus
        Assert-Atomic ($next.progressStage -ceq '连接香港线路' -and $next.operationStartedAt -ceq $first.operationStartedAt) '阶段推进不重置起点，兼容 ConvertFrom-Json 的 DateTime 类型'
        Assert-Atomic ($next.operationStartedAt -match '(?:Z|[+-]\d{2}:\d{2})$' -and -not $next.ready) '时间携带偏移且启动阶段不能显示已就绪'
        $unchanged=[IO.File]::ReadAllText($paths.Status)
        Write-MnaUiStatus -Phase starting -Message '过期后台' -RunId '222222222222222222222222' -ProgressStage '过期阶段'
        Assert-Atomic ([IO.File]::ReadAllText($paths.Status) -ceq $unchanged) '过期 RunId 不能覆盖阶段或起点'
    }

    Test-AtomicCase '完成清空进度，健康检查与停止各自计时，重复停止保留起点' {
        $progressRun='111111111111111111111111'
        Write-MnaUiStatus -Phase connected -Message '主入口优化已开启' -RunId $progressRun -Ready $true -GameRoutingConfigured $true -UdpRoutingVerified $true
        $connected=Get-MnaUiStatus
        Assert-Atomic ($connected.ready -and $null -eq $connected.progressStage -and $null -eq $connected.operationStartedAt) '已连接清空启动进度'
        Write-MnaUiStatus -Phase starting -Message '正在检查线路状态…' -RunId $progressRun -ProgressStage '检查线路状态' -OperationStartedAt '2026-09-15T01:30:00+10:00'
        $recheck=Get-MnaUiStatus
        Assert-Atomic (($recheck.progressStage -ceq '检查线路状态') -and ([DateTimeOffset]$recheck.operationStartedAt).UtcTicks -eq ([DateTimeOffset]'2026-09-15T01:30:00+10:00').UtcTicks) '健康重查不沿用上次启动时长'
        Write-MnaUiStatus -Phase stopping -Message '正在关闭' -RunId $progressRun -ProgressStage '关闭游戏解析路由' -OperationStartedAt '2026-09-15T01:31:00+10:00'
        $stopping=Get-MnaUiStatus
        Write-MnaUiStatus -Phase stopping -Message '正在关闭线路' -RunId $progressRun -ProgressStage '关闭香港线路' -OperationStartedAt '2026-09-15T01:31:20+10:00'
        $repeat=Get-MnaUiStatus
        Assert-Atomic (([DateTimeOffset]$stopping.operationStartedAt).UtcTicks -eq ([DateTimeOffset]'2026-09-15T01:31:00+10:00').UtcTicks -and $repeat.operationStartedAt -ceq $stopping.operationStartedAt -and $repeat.progressStage -ceq '关闭香港线路') '停止从本次关闭计时，阶段和重复点击不重置'
        Write-MnaUiStatus -Phase stopping -Message '恢复清理' -RunId $progressRun -ProgressStage '清理上次连接' -OperationStartedAt '2026-09-15T01:40:00+10:00' -AllowTerminalTransition
        Assert-Atomic (([DateTimeOffset](Get-MnaUiStatus).operationStartedAt).UtcTicks -eq ([DateTimeOffset]'2026-09-15T01:40:00+10:00').UtcTicks) '后台已退出后的显式恢复清理另起计时'
        foreach ($terminal in @('error','stopped')) {
            Write-MnaUiStatus -Phase $terminal -Message '操作结束' -RunId $progressRun
            $done=Get-MnaUiStatus
            Assert-Atomic ($null -eq $done.progressStage -and $null -eq $done.operationStartedAt) ($terminal+' 清空操作进度')
        }
    }

    Test-AtomicCase '旧状态缺少进度仍可读，新运行不继承旧起点，后台退出不显示旧进度' {
        $oldRun='111111111111111111111111'
        Write-MnaUiJson $paths.Status ([pscustomobject]@{phase='starting';message='旧版本启动中';runId=$oldRun})
        $legacy=Get-MnaUiStatus
        Assert-Atomic ($legacy.phase -ceq 'starting' -and $null -eq $legacy.progressStage -and $null -eq $legacy.operationStartedAt) '旧版本可选字段缺失兼容'
        Write-MnaUiStatus -Phase starting -Message '兼容旧调用' -RunId $oldRun
        $fallback=Get-MnaUiStatus
        Assert-Atomic ($fallback.progressStage -ceq '兼容旧调用' -and $fallback.operationStartedAt) '旧签名自动记录开始时间并以消息作阶段'
        $newRun='333333333333333333333333'
        Write-MnaUiJson $paths.WorkerRecord ([pscustomobject]@{RunId=$newRun})
        Write-MnaUiStatus -Phase starting -Message '新运行' -RunId $newRun -OperationStartedAt '2026-09-15T02:00:00+10:00'
        Assert-Atomic (([DateTimeOffset](Get-MnaUiStatus).operationStartedAt).UtcTicks -eq ([DateTimeOffset]'2026-09-15T02:00:00+10:00').UtcTicks) '新 RunId 的相同阶段使用新起点'
        $script:fixtureWorkerAlive=$false
        try {
            $exited=Get-MnaUiStatus
            Assert-Atomic ($exited.phase -ceq 'error' -and $null -eq $exited.progressStage -and $null -eq $exited.operationStartedAt) '退出后台不遗留计时动画'
        } finally { $script:fixtureWorkerAlive=$true }
        Assert-Atomic ($null -eq (ConvertTo-MnaUiOperationTime 'not-a-date') -and $null -eq (ConvertTo-MnaUiOperationTime '2026-09-15T01:00:00')) '损坏时间与无时区时间不冒充真实起点'
    }

    # Synthetic ownership identities are never passed to a process API.
    $trialProcess=[pscustomobject]@{Id=123456}
    $trialStartTime=[datetime]'2026-01-01T00:00:00Z'
    $trialRuntimeDirectory=Join-Path $fixtureRoot 'runtime'
    $uiBeforePath=Join-Path $fixtureRoot 'before.json'
    $trialOwned=@{123456=[pscustomobject]@{Pid=123456;Created=$trialStartTime;Depth=0;Kind='Root';ExecutablePath=(Join-Path $trialRuntimeDirectory 'dummy.exe')}}
    $runId='0123456789abcdef01234567'
    $ownerPath=Get-MnaRunFile $runId ownership

    Test-AtomicCase 'Ownership 无变化不触碰 mtime，新增 Owned 必须落盘' {
        Save-MnaUiOwnership $runId
        $stamp=[IO.File]::GetLastWriteTimeUtc($ownerPath).Ticks
        Start-Sleep -Milliseconds 100
        Save-MnaUiOwnership $runId
        Assert-Atomic ([IO.File]::GetLastWriteTimeUtc($ownerPath).Ticks -eq $stamp) '相同 ownership 内容不重复写盘'
        $trialOwned[123457]=[pscustomobject]@{Pid=123457;Created=$trialStartTime.AddSeconds(1);Depth=1;Kind='Helper';ExecutablePath=(Join-Path $trialRuntimeDirectory 'helper.exe')}
        Save-MnaUiOwnership $runId
        $owner=Read-MnaUiJson $ownerPath
        Assert-Atomic ($owner.Owned.Count -eq 2 -and $owner.Owned[1].Pid -eq 123457 -and [IO.File]::GetLastWriteTimeUtc($ownerPath).Ticks -gt $stamp) '新增进程归属写入磁盘'
    }

    Test-AtomicCase 'Ownership 相同 PID 的归属字段变更与根进程字段均落盘' {
        $trialOwned[123457].Created=$trialStartTime.AddSeconds(2)
        $trialOwned[123457].Depth=2
        $trialOwned[123457].Kind='ChangedHelper'
        $trialOwned[123457].ExecutablePath=Join-Path $trialRuntimeDirectory 'other.exe'
        $trialProcess.Id=123458
        # Parent-scope values are restored after the case; the saved record must
        # still capture their changed values during this invocation.
        $trialStartTime=$trialStartTime.AddSeconds(3)
        $trialRuntimeDirectory=Join-Path $fixtureRoot 'other-runtime'
        $uiBeforePath=Join-Path $fixtureRoot 'other-before.json'
        Save-MnaUiOwnership $runId
        $owner=Read-MnaUiJson $ownerPath
        $item=$owner.Owned | Where-Object Pid -eq 123457
        Assert-Atomic ($item.Kind -ceq 'ChangedHelper' -and $item.Depth -eq 2 -and $item.ExecutablePath.EndsWith('other.exe') -and ([datetime]$item.Created).Ticks -eq ([datetime]'2026-01-01T00:00:02Z').Ticks) '缓存比较覆盖完整子进程归属'
        Assert-Atomic ($owner.RootPid -eq 123458 -and ([datetime]$owner.RootCreated).Ticks -eq $trialStartTime.Ticks -and $owner.Runtime -ceq $trialRuntimeDirectory -and $owner.BeforePath -ceq $uiBeforePath) '缓存比较覆盖根进程和路径字段'
    }

    Test-AtomicCase 'Ownership 写入失败不缓存未提交内容，权限恢复后相同记录能提交' {
        Save-MnaUiOwnership $runId
        $original=[IO.File]::ReadAllText($ownerPath)
        $trialOwned[123457].Kind='AfterAccessDenied'
        [IO.File]::SetAttributes($ownerPath,([IO.File]::GetAttributes($ownerPath) -bor [IO.FileAttributes]::ReadOnly))
        $failed=$false
        try { Save-MnaUiOwnership $runId } catch { $failed=$_.Exception.Message -match '访问被拒绝.*错误码 5' }
        finally { [IO.File]::SetAttributes($ownerPath,([IO.File]::GetAttributes($ownerPath) -band (-bnot [IO.FileAttributes]::ReadOnly))) }
        Assert-Atomic $failed 'ownership 权限失败确实发生'
        Assert-Atomic ([IO.File]::ReadAllText($ownerPath) -ceq $original) 'ownership 失败保留原记录'
        Assert-AtomicNoTemps $ownerPath
        Save-MnaUiOwnership $runId
        Assert-Atomic ((Read-MnaUiJson $ownerPath).Owned[1].Kind -ceq 'AfterAccessDenied') '失败后相同新记录仍尝试落盘'
    }

    Test-AtomicCase 'Ownership 记录缺失重写、新 RunId 保存独立完整记录' {
        [IO.File]::Delete($ownerPath)
        Save-MnaUiOwnership $runId
        Assert-Atomic ([IO.File]::Exists($ownerPath)) '缓存命中但文件丢失时重写'
        $secondRun='fedcba9876543210fedcba98'
        Save-MnaUiOwnership $secondRun
        $other=Read-MnaUiJson (Get-MnaRunFile $secondRun ownership)
        Assert-Atomic ($other.RunId -ceq $secondRun -and $other.Owned.Count -eq 2 -and (Read-MnaUiJson $ownerPath).RunId -ceq $runId) 'RunId 隔离且保留完整归属'
    }
} catch {
    $unexpected=$_.Exception.Message.Replace($fixtureRoot,'[fixture]')
} finally {
    # Refuse links and validate the exact freshly-created absolute target before
    # deleting only its files and empty directories, entirely within PowerShell.
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolved.StartsWith($fixtureBase+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cne $runToken) { throw '测试清理路径越界，未删除' }
    if ([IO.Directory]::Exists($resolved)) {
        $rootItem=Get-Item -LiteralPath $resolved -Force
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '测试目录出现链接，未删除' }
        $items=@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw '测试目录出现链接，未删除' }
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
            [IO.File]::SetAttributes($file.FullName,($file.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            Remove-Item -LiteralPath $file.FullName -Force
        }
        foreach ($directory in @($items | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending)) { Remove-Item -LiteralPath $directory.FullName -Force }
        Remove-Item -LiteralPath $resolved -Force
    }
    $cleanupVerified=-not [IO.Directory]::Exists($resolved)
}
$passed=($null -eq $unexpected -and $checks.Count -eq 13 -and @($checks | Where-Object { -not $_.Passed }).Count -eq 0 -and $cleanupVerified)
$report=[pscustomobject]@{
    Passed=$passed;CreatedAt=Get-Date -Format o;PowerShell=$PSVersionTable.PSVersion.ToString()
    CheckCount=$checks.Count;NetworkStarted=$false;SdkStarted=$false;RealUserStateAccessed=$false
    FixtureCleanupVerified=$cleanupVerified;Measurements=$measurements;Checks=$checks.ToArray();Unexpected=$unexpected
}
[IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
Write-Output ('ReportPath: '+$reportPath)
if (-not $passed) { exit 1 }
