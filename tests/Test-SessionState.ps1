[CmdletBinding()]
param(
    [string]$BackendPath=(Join-Path (Split-Path $PSScriptRoot -Parent) 'app/backend'),
    [string]$ResultPath=(Join-Path $PSScriptRoot 'output/session.json')
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding

# Import function definitions only: never execute the installed top-level script,
# read its private records, start a real worker, or change a real network setting.
$commonPath=Join-Path $BackendPath 'Mna-UI.Common.ps1'
$controlPath=Join-Path $BackendPath 'Control-Accelerator.ps1'
$tokens=$null; $parseErrors=$null
$commonAst=[Management.Automation.Language.Parser]::ParseFile($commonPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Common source has parse errors.' }
foreach ($definition in $commonAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
    if($definition.Name -eq 'Resolve-MnaUiDirectoryPath'){$script:RealDirectoryResolver=$definition.Body.GetScriptBlock()}
}
$sessionPath=Join-Path $BackendPath 'Mna-SessionState.ps1'
if(-not [IO.File]::Exists($sessionPath)){throw 'Session-state implementation is not ready; regression runner was not started.'}
$sessionAst=[Management.Automation.Language.Parser]::ParseFile($sessionPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Session-state source has parse errors.'}
foreach ($definition in $sessionAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:Results=[Collections.Generic.List[object]]::new()
$script:Mutations=[Collections.Generic.List[string]]::new()
$script:Reads=[Collections.Generic.List[string]]::new()
$script:Writes=[Collections.Generic.List[object]]::new()
$script:ProcessQueries=[Collections.Generic.List[string]]::new()
$script:ReadOnlyEvidence=[Collections.Generic.List[object]]::new()
$script:trialSensitiveStrings=@()

function Assert-True([bool]$Condition,[string]$Because) { if(-not $Condition){throw $Because} }
function Assert-Equal($Actual,$Expected,[string]$Because) {
    if($Actual -cne $Expected){throw ($Because+'; actual='+$Actual+' expected='+$Expected)}
}
function Assert-Throws([scriptblock]$Body,[string]$Because) {
    $threw=$false
    try { & $Body | Out-Null } catch { $threw=$true }
    Assert-True $threw $Because
}
function Invoke-Case([string]$Name,[scriptblock]$Body) {
    Reset-Fixture
    try {
        & $Body
        Assert-Equal $script:Mutations.Count 0 'Read-only checks must not mutate or clean up any process'
        $script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail='OK'})
    } catch {
        $script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})
    }
}
function Reset-Fixture {
    $script:Mutations.Clear(); $script:Reads.Clear(); $script:Writes.Clear(); $script:ProcessQueries.Clear()
    $script:AllowWrites=$false
    $script:FailWriteJsonPath=$null
    $script:FailStatusWrite=$false
    $script:MnaUiBootIdentity=$null
    $script:BootTime=(Get-Date).AddHours(-2)
    $script:Created=(Get-Date).AddSeconds(-5)
    $script:FixtureRoot=Join-Path $PSScriptRoot 'fixtures\physical\DeltaResolveAccelerator\backend'
    $script:AliasRoot=Join-Path $PSScriptRoot 'fixtures\alias\DeltaResolveAccelerator\backend'
    $script:MnaUiRoot=$script:FixtureRoot
    $script:Paths=[pscustomobject]@{
        Root=$script:FixtureRoot;App=(Split-Path $script:FixtureRoot -Parent)
        Status=$script:FixtureRoot+'\results\ui-status.json'
        WorkerRecord=$script:FixtureRoot+'\private\ui-worker.json'
        Private=$script:FixtureRoot+'\private'
        WorkerScript=$script:FixtureRoot+'\Run-Accelerator.ps1'
        Runtime=$script:FixtureRoot+'\vendor_inspection\sdk_v0.23.1\linkboost'
        PowerShell=(Split-Path $script:FixtureRoot -Parent)+'\runtime\pwsh.exe'
    }
    $script:RunId='aaaaaaaaaaaaaaaaaaaaaaaa'
    $script:Record=[pscustomobject]@{
        RunId=$script:RunId; WorkerPid=4242
        WorkerCreatedUtc=$script:Created.ToUniversalTime().ToString('o')
        WorkerExecutable=$script:Paths.PowerShell;WorkerScript=$script:Paths.WorkerScript
        RoutingMode='ResolveOnly'
    }
    $script:Owner=[pscustomobject]@{
        RunId=$script:RunId;RootPid=4243;RootCreated=$script:Created.ToString('o')
        Runtime=$script:Paths.Runtime;BeforePath=$script:Paths.Root+'\results\before.json';Owned=@()
    }
    $script:Status=[pscustomobject]@{
        phase='connected';ready=$true;message='已连接，游戏引流已就绪';runId=$script:RunId
        gameRoutingConfigured=$true;udpRoutingVerified=$true;gameRoutingVerified=$false
        gateway=$null;exitIp=$null;routingMode='ResolveOnly';updatedAt=$script:Created.ToString('o')
    }
    $script:Worker=$null
    $script:SdkProcesses=@()
    $script:Adapters=@()
    $script:TcpListeners=@()
    $script:UdpEndpoints=@()
    $script:CimProcesses=@{}
}

# Test doubles intentionally model exact IDs, creation timestamps and image paths.
function Get-MnaUiPaths { $script:Paths }
function Resolve-MnaUiDirectoryPath {
    param([string]$Path)
    $Path.Replace($script:AliasRoot,$script:FixtureRoot).TrimEnd('\','/')
}
function Test-MnaUiSamePath {
    param([string]$Left,[string]$Right)
    $normalizedLeft=$Left.Replace($script:AliasRoot,$script:FixtureRoot).TrimEnd('\','/')
    $normalizedRight=$Right.Replace($script:AliasRoot,$script:FixtureRoot).TrimEnd('\','/')
    [string]::Equals($normalizedLeft,$normalizedRight,[StringComparison]::OrdinalIgnoreCase)
}
function Read-MnaUiJson {
    param([string]$Path)
    $script:Reads.Add($Path)
    if($Path -eq $script:Paths.Status){return $script:Status}
    if($Path -eq $script:Paths.WorkerRecord){return $script:Record}
    if($Path -eq (Join-Path $script:Paths.Private ('ui-ownership-'+$script:RunId+'.json'))){return $script:Owner}
    throw ('Unexpected fixture read: '+$Path)
}
function Get-Process {
    [CmdletBinding()]
    param([int[]]$Id,[string[]]$Name)
    if($PSBoundParameters.ContainsKey('Id')) {
        $script:ProcessQueries.Add('Get-Process -Id '+($Id -join ','))
        if($script:Worker -and $Id -contains $script:Worker.Id){return $script:Worker}
        throw 'Fixture process is absent.'
    }
    if($PSBoundParameters.ContainsKey('Name')) { return $script:SdkProcesses }
    throw 'Unbounded process enumeration is forbidden in this regression harness.'
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName,[string]$Filter,[string[]]$Property)
    if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=$script:BootTime}}
    if($ClassName -eq 'Win32_Process' -and $Filter -match '^ProcessId=(\d+)$'){
        $script:ProcessQueries.Add('CIM '+$Filter)
        return $script:CimProcesses[[int]$Matches[1]]
    }
    throw ('Unexpected CIM fixture query: '+$ClassName+' '+$Filter)
}
function Get-NetAdapter { [CmdletBinding()]param([switch]$IncludeHidden) $script:Adapters }
function Get-NetTCPConnection { [CmdletBinding()]param([string]$State) $script:TcpListeners }
function Get-NetUDPEndpoint { [CmdletBinding()]param() $script:UdpEndpoints }
function Get-TrialNetworkState { [pscustomobject]@{Complete=$true} }
function Deny-Mutation([string]$Name) { $script:Mutations.Add($Name); throw ('Forbidden real operation: '+$Name) }
function Start-Process { Deny-Mutation 'Start-Process' }
function Stop-Process { Deny-Mutation 'Stop-Process' }
function Invoke-RestMethod { Deny-Mutation 'Invoke-RestMethod' }
function Invoke-WebRequest { Deny-Mutation 'Invoke-WebRequest' }
function Invoke-MnaTrialApi { Deny-Mutation 'Invoke-MnaTrialApi' }
function Invoke-MnaOwnedHttp { Deny-Mutation 'Invoke-MnaOwnedHttp' }
function Stop-MnaUiOwnedRuntime { Deny-Mutation 'Stop-MnaUiOwnedRuntime' }
function Stop-MnaGameRouteRecovery { Deny-Mutation 'Stop-MnaGameRouteRecovery' }
function Write-MnaUiJson {
    param([string]$Path,[object]$Value)
    if(-not $script:AllowWrites){Deny-Mutation 'Write-MnaUiJson'}
    if($script:FailWriteJsonPath -and $Path -eq $script:FailWriteJsonPath){
        $script:FailWriteJsonPath=$null
        throw [IO.IOException]::new('Injected worker-record write interruption.')
    }
    $script:Writes.Add([pscustomobject]@{Operation='WriteJson';Path=$Path;Value=$Value})
    if($Path -eq $script:Paths.WorkerRecord){$script:Record=$Value}
    if($Path -eq (Get-MnaRunFile $script:RunId ownership)){$script:Owner=$Value}
}
function Write-MnaUiStatus {
    param([string]$Phase,[string]$Message,[string]$RunId)
    if(-not $script:AllowWrites){Deny-Mutation 'Write-MnaUiStatus'}
    if($script:FailStatusWrite){
        $script:FailStatusWrite=$false
        throw [IO.IOException]::new('Injected status write interruption.')
    }
    $script:Writes.Add([pscustomobject]@{Operation='WriteStatus';Phase=$Phase;Message=$Message;RunId=$RunId})
    $script:Status=[pscustomobject]@{phase=$Phase;message=$Message;ready=$false;runId=$RunId;updatedAt=Get-Date -Format o}
}
function Save-TrialNetworkState { Deny-Mutation 'Save-TrialNetworkState' }
function New-NetRoute { Deny-Mutation 'New-NetRoute' }
function Remove-NetRoute { Deny-Mutation 'Remove-NetRoute' }
function Set-DnsClientServerAddress { Deny-Mutation 'Set-DnsClientServerAddress' }

Invoke-Case 'missing status is stopped and never ready' {
    $script:Status=$null; $script:Record=$null; $script:Owner=$null
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'stopped' 'No session should appear stopped'
    Assert-Equal $actual.ready $false 'No session must not appear ready'
}
Invoke-Case 'previous boot connected is retired in displayed state without cleanup' {
    $old=$script:BootTime.AddHours(-1)
    $script:Record.WorkerCreatedUtc=$old.ToUniversalTime().ToString('o')
    $script:Owner.RootCreated=$old.ToString('o')
    $script:Status.updatedAt=$old.ToString('o')
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'stopped' 'A completed previous boot is no longer a live connection'
    Assert-Equal $actual.ready $false 'A previous boot cannot be ready'
}
Invoke-Case 'same boot dead worker requires recovery and is never ready' {
    $actual=Get-MnaUiStatus
    Assert-True ($actual.phase -notin @('connected','stopped')) 'Same-boot dead worker must expose recovery requirement'
    Assert-Equal $actual.ready $false 'Dead worker must not be ready'
    Assert-True ($actual.message -match '关闭|清理|恢复|核对') 'Recovery action must be explicit in the message'
}
Invoke-Case 'foreign ownership run ID fails closed' {
    $script:Owner.RunId='bbbbbbbbbbbbbbbbbbbbbbbb'
    Assert-Throws { Assert-MnaUiPreviousRunClear $script:Record } 'A mismatched ownership run ID must be rejected'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A foreign record cannot advertise ready'
}
Invoke-Case 'foreign runtime path fails closed' {
    $script:Owner.Runtime='C:\OtherProduct\sdk'
    Assert-Throws { Assert-MnaUiPreviousRunClear $script:Record } 'A foreign runtime must be rejected'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A foreign runtime cannot advertise ready'
}
Invoke-Case 'canonical worker identity stays connected and is never cleaned up' {
    $script:Worker=[pscustomobject]@{Id=4242;Path=$script:Record.WorkerExecutable;StartTime=$script:Created;HasExited=$false}
    Assert-Equal (Test-MnaUiWorker $script:Record) $true 'Exact worker identity must be accepted'
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'connected' 'A live exactly owned worker must retain state'
    Assert-Equal $actual.ready $true 'A verified live worker should remain ready'
}
Invoke-Case 'worker PID reuse with different creation tick fails closed' {
    $script:Worker=[pscustomobject]@{Id=4242;Path=$script:Record.WorkerExecutable;StartTime=$script:Created.AddTicks(1);HasExited=$false}
    Assert-Equal (Test-MnaUiWorker $script:Record) $false 'Exact creation timestamp must remain mandatory'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A recycled PID cannot be ready'
}
Invoke-Case 'worker with a foreign executable fails closed' {
    $script:Worker=[pscustomobject]@{Id=4242;Path='C:\OtherProduct\pwsh.exe';StartTime=$script:Created;HasExited=$false}
    Assert-Equal (Test-MnaUiWorker $script:Record) $false 'Exact image identity must remain mandatory'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A foreign executable cannot be ready'
}
Invoke-Case 'session classifier accepts the verified runtime path alias' {
    $script:Owner.Runtime=$script:Owner.Runtime.Replace($script:FixtureRoot,$script:AliasRoot)
    $script:Status.phase='stopped';$script:Status.ready=$false
    $actual=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $actual.Kind 'stopped' 'A canonicalized alias must retain the valid stopped session'
    Assert-Equal $actual.Ready $false 'A stopped aliased session cannot be ready'
}
Invoke-Case 'previous boot old runtime is classified before the legacy path mismatch' {
    $old=$script:BootTime.AddHours(-1)
    $script:Record.WorkerCreatedUtc=$old.ToUniversalTime().ToString('o')
    $script:Owner.RootCreated=$old.ToString('o')
    $script:Owner.Runtime='C:\PreviousInstallation\sdk'
    $actual=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $actual.Kind 'previousBoot' 'An ended previous boot must not be blocked only by its old path'
    Assert-Equal $actual.Ready $false 'A previous-boot session cannot be ready'
}
Invoke-Case 'previous boot with mismatched run ID is foreign' {
    $old=$script:BootTime.AddHours(-1)
    $script:Record.WorkerCreatedUtc=$old.ToUniversalTime().ToString('o')
    $script:Owner.RootCreated=$old.ToString('o')
    $script:Owner.RunId='bbbbbbbbbbbbbbbbbbbbbbbb'
    $actual=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $actual.Kind 'foreign' 'The previous boot rule must not bypass run ID ownership'
    Assert-Equal $actual.Ready $false 'A foreign previous-boot session cannot be ready'
}
Invoke-Case 'same boot stale status on a live worker is never ready' {
    $script:Worker=[pscustomobject]@{Id=4242;Path=$script:Record.WorkerExecutable;StartTime=$script:Created;HasExited=$false}
    $script:Status.updatedAt=(Get-Date).AddMinutes(-2).ToString('o')
    Assert-Equal (Get-MnaUiStatus).ready $false 'A stale status must not advertise ready even while the worker exists'
}
Invoke-Case 'live worker with a mismatched status run ID is never ready' {
    $script:Worker=[pscustomobject]@{Id=4242;Path=$script:Record.WorkerExecutable;StartTime=$script:Created;HasExited=$false}
    $script:Status.runId='bbbbbbbbbbbbbbbbbbbbbbbb'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A status from another run must not advertise ready'
}
Invoke-Case 'mixed previous and current boot ownership fails closed' {
    $script:Record.WorkerCreatedUtc=$script:BootTime.AddHours(-1).ToUniversalTime().ToString('o')
    $actual=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $actual.Kind 'foreign' 'An old worker record must not retire a current-boot owner'
    Assert-Equal $actual.Ready $false 'Mixed-generation metadata cannot be ready'
}
Invoke-Case 'source directory dot path resolves to one handle identity' {
    $logical=$BackendPath
    $a=& $script:RealDirectoryResolver -Path $logical
    $b=& $script:RealDirectoryResolver -Path ($logical+'\.\')
    Assert-True ([string]::Equals($a,$b,[StringComparison]::OrdinalIgnoreCase)) 'Read-only directory handles must normalize equivalent directory paths'
}
Invoke-Case 'distinct source directories retain distinct physical identity' {
    $logical=$BackendPath
    $physical=Split-Path $BackendPath -Parent
    $a=& $script:RealDirectoryResolver -Path $logical
    $b=& $script:RealDirectoryResolver -Path $physical
    Assert-True (-not [string]::Equals($a,$b,[StringComparison]::OrdinalIgnoreCase)) 'Distinct installed directories must not be identified only by equivalent source-file hashes'
}
Invoke-Case 'Common root assignment anchors the script file rather than its containing directory' {
    $assignments=@($commonAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $_.Left.VariablePath.UserPath -eq 'script:MnaUiRoot'
    })
    Assert-Equal $assignments.Count 1 'Common must have one explicit installation-root assignment'
    $variables=@($assignments[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.VariableExpressionAst]},$true) | ForEach-Object { $_.VariablePath.UserPath })
    $commands=@($assignments[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() })
    Assert-True ($variables -contains 'PSCommandPath') 'Root identity must come from the current script file'
    Assert-True ($variables -notcontains 'PSScriptRoot') 'A parent-directory handle must not substitute for script-file identity'
    Assert-True ($commands -contains 'Resolve-MnaUiDirectoryPath' -and $commands -contains 'Split-Path') 'The root assignment must resolve the file and then select its physical parent'
}
Invoke-Case 'actual script-file anchored root agrees with its file handle physical directory' {
    $assignment=$commonAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $_.Left.VariablePath.UserPath -eq 'script:MnaUiRoot'
    }
    # Evaluate only the reviewed assignment RHS with a native read-only resolver.
    # Do not execute Common's top-level dot-source or any installed state reads.
    $actual=& {
        param($SourcePath,$Expression,$NativeResolver)
        function Resolve-MnaUiDirectoryPath { param([string]$Path) & $NativeResolver -Path $Path }
        # A generated scriptblock has no automatic PSCommandPath. Substitute only
        # that verified variable token with the explicit source-file argument.
        . ([scriptblock]::Create($Expression.Replace('$PSCommandPath','$SourcePath')))
    } $commonPath $assignment.Right.Extent.Text $script:RealDirectoryResolver
    $physicalFile=& $script:RealDirectoryResolver -Path $commonPath
    $expected=Split-Path -Path $physicalFile -Parent
    Assert-True ([string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) 'Evaluated script-file root must match the actual file handle parent'
    $logicalDirectory=Split-Path -Path $commonPath -Parent
    $directoryHandle=& $script:RealDirectoryResolver -Path $logicalDirectory
    $script:ReadOnlyEvidence.Add([pscustomobject]@{
        Case='ScriptFileAnchor';LogicalScript=$commonPath;PhysicalScript=$physicalFile
        ResolvedDirectoryHandle=$directoryHandle;EvaluatedRoot=$actual
        FileAndDirectoryMappingDiffer=(-not [string]::Equals($expected,$directoryHandle,[StringComparison]::OrdinalIgnoreCase))
    })
}
function Set-PreviousBootFixture {
    $old=$script:BootTime.AddHours(-1)
    $script:Record.WorkerCreatedUtc=$old.ToUniversalTime().ToString('o')
    $script:Owner.RootCreated=$old.ToString('o')
    $script:Status.updatedAt=$old.ToString('o')
    $script:AllowWrites=$true
}
Invoke-Case 'previous boot session preserves a current-boot recovery error and its message' {
    Set-PreviousBootFixture
    $script:Status.phase='error'
    $script:Status.message='加速控制端口仍被占用，已保留记录等待核对'
    $script:Status.updatedAt=(Get-Date).ToString('o')
    $script:Status | Add-Member NoteProperty BootIdentity $script:BootTime.ToUniversalTime().ToString('o') -Force
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'error' 'The current recovery failure must remain visible'
    Assert-Equal $actual.message $script:Status.message 'The exact current recovery error must remain visible'
    Assert-Equal $actual.ready $false 'A failed recovery cannot be ready'
    Assert-Equal $script:Writes.Count 0 'Reading a recovery error must not change records'
}
Invoke-Case 'previous boot error is displayed stopped rather than a current recovery failure' {
    Set-PreviousBootFixture
    $script:Status.phase='error'
    $script:Status.message='重启前的旧错误'
    $script:Status | Add-Member NoteProperty BootIdentity $script:BootTime.AddDays(-1).ToUniversalTime().ToString('o') -Force
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'stopped' 'A previous-boot error must not masquerade as a current recovery failure'
    Assert-Equal $actual.ready $false 'A previous-boot error cannot be ready'
}
Invoke-Case 'current boot label cannot preserve an error timestamp older than boot' {
    Set-PreviousBootFixture
    $script:Status.phase='error'
    $script:Status | Add-Member NoteProperty BootIdentity $script:BootTime.ToUniversalTime().ToString('o') -Force
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'stopped' 'A current-boot error must also have a current-boot timestamp'
    Assert-Equal $actual.ready $false 'Invalid recovery metadata cannot be ready'
}
Invoke-Case 'an error from a different run does not replace the previous-boot stopped state' {
    Set-PreviousBootFixture
    $script:Status.phase='error';$script:Status.runId='bbbbbbbbbbbbbbbbbbbbbbbb'
    $script:Status.updatedAt=(Get-Date).ToString('o')
    $script:Status | Add-Member NoteProperty BootIdentity $script:BootTime.ToUniversalTime().ToString('o') -Force
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'stopped' 'Recovery error preservation requires the same run ID'
    Assert-Equal $actual.ready $false 'A foreign recovery message cannot be ready'
}
function Set-PendingStartFixture {
    $script:Owner=$null
    $script:Record.WorkerPid=0;$script:Record.WorkerCreatedUtc=$null
    $script:Record | Add-Member NoteProperty BootIdentity $script:BootTime.ToUniversalTime().ToString('o') -Force
    $script:Status.phase='starting';$script:Status.updatedAt=(Get-Date).AddSeconds(-1).ToString('o')
    $script:Status | Add-Member NoteProperty BootIdentity $script:BootTime.ToUniversalTime().ToString('o') -Force
}
Invoke-Case 'fresh same-boot zero-PID publication window is pendingStart and never ready' {
    Set-PendingStartFixture
    $state=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $state.Kind 'pendingStart' 'Fresh zero-PID publication should be recognized before worker identity is committed'
    Assert-Equal $state.Ready $false 'Pending publication conveys no readiness'
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'starting' 'The bounded publication window should display starting'
    Assert-Equal $actual.ready $false 'The bounded publication window cannot advertise ready'
    Assert-Equal $script:ProcessQueries.Count 0 'Pending publication must not query a zero or unrelated PID'
}
Invoke-Case 'zero-PID publication older than five seconds requires recovery' {
    Set-PendingStartFixture
    $script:Status.updatedAt=(Get-Date).AddSeconds(-6).ToString('o')
    $state=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $state.Kind 'recoveryRequired' 'An expired publication window must not remain pending indefinitely'
    Assert-Equal (Get-MnaUiStatus).ready $false 'Expired publication cannot be ready'
}
Invoke-Case 'zero-PID publication with invalid update time requires recovery' {
    Set-PendingStartFixture
    $script:Status.updatedAt='invalid-date'
    $state=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $state.Kind 'recoveryRequired' 'Invalid time must not open a pending publication window'
    Assert-Equal (Get-MnaUiStatus).ready $false 'Invalid publication metadata cannot be ready'
}
Invoke-Case 'zero-PID publication requires the same status run ID' {
    Set-PendingStartFixture
    $script:Status.runId='bbbbbbbbbbbbbbbbbbbbbbbb'
    $state=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $state.Kind 'recoveryRequired' 'A different run cannot supply a pending publication window'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A mismatched publication cannot be ready'
}
Invoke-Case 'zero-PID publication requires a matching current status boot identity' {
    Set-PendingStartFixture
    $script:Status.BootIdentity=$script:BootTime.AddDays(-1).ToUniversalTime().ToString('o')
    $state=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $state.Kind 'recoveryRequired' 'A different status boot cannot supply a pending publication window'
    Assert-Equal (Get-MnaUiStatus).ready $false 'A foreign-boot publication cannot be ready'
}
Invoke-Case 'zero-PID publication is excluded when an owner already exists' {
    $savedOwner=$script:Owner
    Set-PendingStartFixture
    $script:Owner=$savedOwner
    $state=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $state.Kind 'recoveryRequired' 'Existing ownership requires recovery instead of a new publication grace period'
    Assert-Equal (Get-MnaUiStatus).ready $false 'Existing ownership with no worker cannot be ready'
}
Invoke-Case 'previous boot retirement archives metadata and never targets any old PID' {
    Set-PreviousBootFixture
    $script:Owner | Add-Member NoteProperty MustNotArchive 'unapproved-extra-field'
    $result=Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status
    Assert-Equal $result $true 'Clean previous-boot metadata should be retired'
    Assert-Equal $script:Writes.Count 4 'Retirement should archive, commit terminal owner, commit worker pointer, and write status'
    Assert-Equal $script:Writes[0].Value.Reason 'previousBoot' 'Archive must identify why the session ended'
    Assert-True (-not ($script:Writes[0].Value.Owner.PSObject.Properties.Name -contains 'MustNotArchive')) 'Archive must omit unapproved metadata fields'
    Assert-Equal $script:Writes[1].Value.RootPid 0 'Terminal owner must remove process authority'
    Assert-Equal @($script:Writes[1].Value.Owned).Count 0 'Terminal owner must have no owned processes'
    Assert-Equal $script:Writes[2].Value.WorkerPid 0 'Terminal pointer must remove worker authority'
    Assert-Equal $script:Writes[3].Phase 'stopped' 'Retirement must finish stopped'
    Assert-Equal $script:ProcessQueries.Count 0 'Previous-boot retirement must never inspect or terminate a recycled old PID'
    Assert-Equal (Get-MnaUiStatus).ready $false 'Retired state must not be ready'
    Assert-Equal (Get-MnaUiStatus).phase 'stopped' 'Retired state must remain stopped'
}
Invoke-Case 'retirement is idempotent after terminal commit' {
    Set-PreviousBootFixture
    $null=Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status
    $script:Writes.Clear()
    $result=Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status
    Assert-Equal $result $false 'Already retired state must not retire again'
    Assert-Equal $script:Writes.Count 0 'Already retired state must not create another archive or overwrite records'
}
Invoke-Case 'interruption after terminal owner resumes previous-boot retirement without PID operations' {
    Set-PreviousBootFixture
    $script:FailWriteJsonPath=$script:Paths.WorkerRecord
    Assert-Throws { Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status } 'Injected worker-record commit failure must interrupt the first attempt'
    Assert-Equal $script:Writes.Count 2 'Only the archive and terminal owner should have committed'
    Assert-Equal $script:Owner.RootPid 0 'Committed terminal owner must retain no process authority'
    Assert-Equal $script:Owner.RetiredPreviousBoot $true 'Owner must identify the interrupted retirement'
    Assert-Equal $script:Record.WorkerPid 4242 'The failed worker pointer write must preserve the previous pointer'
    $disposition=Get-MnaUiSessionDisposition -Record $script:Record -Owner $script:Owner -Status $script:Status -BootTime $script:BootTime
    Assert-Equal $disposition.Kind 'previousBoot' 'Terminal owner plus old worker pointer must remain resumable'
    Assert-Equal $disposition.Ready $false 'Interrupted retirement must never be ready'
    $script:Writes.Clear()
    Assert-Equal (Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status) $true 'The next attempt must finish retirement'
    Assert-Equal $script:Record.WorkerPid 0 'Resumed retirement must commit a terminal worker pointer'
    Assert-Equal $script:Status.phase 'stopped' 'Resumed retirement must commit stopped status'
    Assert-Equal $script:ProcessQueries.Count 0 'Neither interrupted nor resumed retirement may inspect an old PID'
    Assert-Equal (Get-MnaUiStatus).ready $false 'Resumed terminal state must never be ready'
}
Invoke-Case 'terminal ownership survives status write failure and allows the next Start preflight' {
    Set-PreviousBootFixture
    $script:FailStatusWrite=$true
    Assert-Throws { Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status } 'Injected status commit failure must interrupt the final write'
    Assert-Equal $script:Writes.Count 3 'Archive, terminal owner and terminal worker pointer should have committed'
    Assert-Equal $script:Owner.RootPid 0 'Terminal owner must retain no process authority'
    Assert-Equal $script:Record.WorkerPid 0 'Terminal worker pointer must retain no process authority'
    Assert-Equal $script:Status.phase 'connected' 'The failed status write must leave the old status fixture in place'
    $actual=Get-MnaUiStatus
    Assert-Equal $actual.phase 'stopped' 'Terminal ownership must override stale connected status'
    Assert-Equal $actual.ready $false 'Stale connected status must never be ready after terminal commit'
    Assert-MnaUiPreviousRunClear $script:Record
    Assert-Equal $script:ProcessQueries.Count 0 'Next Start preflight must not use previous-boot PIDs'
    Assert-Equal $script:Writes.Count 3 'Read-only status and Start preflight must not rewrite partial recovery evidence'
}
Invoke-Case 'retirement refuses a live exact worker without cleanup or writes' {
    $script:Worker=[pscustomobject]@{Id=4242;Path=$script:Record.WorkerExecutable;StartTime=$script:Created;HasExited=$false}
    $script:AllowWrites=$true
    Assert-Equal (Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status) $false 'Current live worker is outside previous-boot retirement'
    Assert-Equal $script:Writes.Count 0 'Current live worker records must be untouched'
}
Invoke-Case 'retirement blocks if any SDK or helper remains' {
    Set-PreviousBootFixture
    $script:SdkProcesses=@([pscustomobject]@{Id=6000;Name='multipath-helper'})
    Assert-Throws { Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status } 'An existing helper must block retirement'
    Assert-Equal $script:Writes.Count 0 'Blocked retirement must preserve all existing records'
}
foreach($adapter in @('mna_game_abcd12','mp_tun0')) {
    Invoke-Case ('retirement blocks remaining adapter '+$adapter) {
        Set-PreviousBootFixture
        $script:Adapters=@([pscustomobject]@{Name=$adapter})
        Assert-Throws { Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status } 'An accelerator adapter must block retirement'
        Assert-Equal $script:Writes.Count 0 'Blocked adapter state must preserve all existing records'
    }
}
foreach($protocol in @('TCP','UDP')) {
    foreach($port in @(9801,12345,9803)) {
        Invoke-Case ('retirement blocks remaining '+$protocol+' port '+$port) {
            Set-PreviousBootFixture
            $endpoint=[pscustomobject]@{LocalPort=$port;OwningProcess=6001}
            if($protocol -eq 'TCP'){$script:TcpListeners=@($endpoint)}else{$script:UdpEndpoints=@($endpoint)}
            Assert-Throws { Complete-MnaUiPreviousBootSession -Record $script:Record -Owner $script:Owner -Status $script:Status } 'An occupied accelerator control port must block retirement'
            Assert-Equal $script:Writes.Count 0 'Occupied ports must preserve all existing records'
        }
    }
}
Invoke-Case 'Chinese status survives strict UTF8 JSON round trip' {
    $script:Status.phase='error';$script:Status.ready=$false
    $script:Status.message='上次归属记录无法确认，未操作任何无归属的进程'
    $actual=Get-MnaUiStatus
    $utf8=[Text.UTF8Encoding]::new($false,$true)
    $roundtrip=$utf8.GetString($utf8.GetBytes(($actual | ConvertTo-Json -Depth 8))) | ConvertFrom-Json
    Assert-Equal $roundtrip.message $script:Status.message 'Chinese message must survive UTF8 serialization'
    Assert-True (-not $roundtrip.message.Contains([char]0xFFFD)) 'Message must not contain replacement characters'
}
Invoke-Case 'Control explicitly sets UTF8 before status output' {
    $source=[IO.File]::ReadAllText($controlPath,[Text.Encoding]::UTF8)
    $encoding=[regex]::Match($source,'\[Console\]::OutputEncoding\s*=\s*\[Text.UTF8Encoding\]::new\(\$false\)')
    $encodingAt=if($encoding.Success){$encoding.Index}else{-1}
    $firstOutputAt=$source.IndexOf('Get-MnaUiStatus | ConvertTo-Json',[StringComparison]::Ordinal)
    Assert-True ($encodingAt -ge 0 -and $encodingAt -lt $firstOutputAt) 'Console output UTF8 must be configured before any JSON response'
    Assert-True ($source -match '\$OutputEncoding\s*=\s*\[Console\]::OutputEncoding') 'PowerShell pipeline output encoding must match the console'
}

$report=[pscustomobject]@{
    Kind='offline-function-regression';CompletedAt=(Get-Date -Format o)
    Source=$commonPath;Total=$script:Results.Count;Passed=@($script:Results | Where-Object Passed).Count
    Failed=@($script:Results | Where-Object { -not $_.Passed }).Count
    Cases=@($script:Results.ToArray())
    ReadOnlyEvidence=@($script:ReadOnlyEvidence.ToArray())
    SourceHashes=@(@($commonPath,$sessionPath,$controlPath) | ForEach-Object {
        [pscustomobject]@{Path=$_;SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
    })
}
$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResultPath)))
[IO.File]::WriteAllText($ResultPath,($report | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 6
if($report.Failed){exit 1}
