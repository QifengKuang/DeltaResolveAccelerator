#requires -Version 7.0
<# Isolated startup tests. No real scheduled task, registry, login preference,
   accelerator process, or network connection is created or changed. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$work=Join-Path $PSScriptRoot ('output/startup/'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work)
$source=[IO.File]::ReadAllText((Join-Path $repository 'src/StartupManager.cs'))
$harness=@'
namespace DeltaResolveAccelerator {
    public static class StartupTestHarness {
        public static bool CheckRegisteredXml(string xml, string root, string sid) {
            return StartupManager.OwnedTaskEnabled(xml,StartupManager.NormalizeRoot(root),sid);
        }
        public static string[] Run(string work) {
            var passed=new System.Collections.Generic.List<string>();
            System.Action<bool,string> check=(ok,name)=>{if(!ok)throw new System.Exception(name);passed.Add(name);};
            string root=System.IO.Path.Combine(work,"中文 加速器 & ' $ (测试)");
            System.IO.Directory.CreateDirectory(root);
            System.IO.File.WriteAllText(System.IO.Path.Combine(root,"DeltaLauncher.exe"),"synthetic launcher, never executed");
            string sid="S-1-5-21-100-200-300-400", otherSid="S-1-5-21-100-200-300-401";
            StartupManager.TestUserSid=sid;
            string xml=StartupManager.BuildTaskXml(root,sid);
            System.IO.File.WriteAllText(System.IO.Path.Combine(work,"task-definition.xml"),xml,new System.Text.UTF8Encoding(false));
            var doc=new System.Xml.XmlDocument();doc.LoadXml(xml);
            var ns=new System.Xml.XmlNamespaceManager(doc.NameTable);ns.AddNamespace("t","http://schemas.microsoft.com/windows/2004/02/mit/task");
            System.Func<string,string> value=p=>doc.SelectSingleNode("/t:Task/"+p,ns).InnerText;
            check(value("t:Actions/t:Exec/t:Command")==System.IO.Path.Combine(root,"DeltaLauncher.exe"),"Unicode and shell characters round-trip as XML data");
            check(value("t:Actions/t:Exec/t:Arguments")=="--launch" && value("t:Actions/t:Exec/t:WorkingDirectory")==root,"Stable launcher with app-only argument and working directory");
            check(value("t:Principals/t:Principal/t:LogonType")=="InteractiveToken" && value("t:Principals/t:Principal/t:RunLevel")=="HighestAvailable","Interactive elevated startup without storing passwords");
            check(value("t:Principals/t:Principal/t:UserId")==sid && value("t:Triggers/t:LogonTrigger/t:UserId")==sid,"Only the chosen Windows user logon triggers startup");
            check(doc.SelectNodes("/t:Task/t:Triggers/*",ns).Count==1 && doc.SelectNodes("/t:Task/t:Actions/*",ns).Count==1,"No boot, registration or network-connect action");
            check(value("t:Settings/t:DisallowStartIfOnBatteries")=="false" && value("t:Settings/t:StopIfGoingOnBatteries")=="false","Startup runs on battery and survives unplugging");
            check(value("t:Settings/t:ExecutionTimeLimit")=="PT0S" && value("t:Settings/t:WakeToRun")=="false","Task neither expires nor wakes the computer");
            check(StartupManager.TaskName(root,sid)==StartupManager.TaskName(root.ToUpperInvariant()+"\\",sid),"Task identity normalizes path case and trailing slash");
            check(StartupManager.TaskName(root,sid)!=StartupManager.TaskName(root,otherSid),"Task identity is scoped to a user");
            check(StartupManager.TaskName(root,sid)!=StartupManager.TaskName(root+"other",sid),"Task identity is scoped to an installation");
            using (var user=System.Security.Principal.WindowsIdentity.GetCurrent()) {
                string userSid=user.User.Value;
                string normalizedXml=StartupManager.BuildTaskXml(root,userSid);
                var normalized=new System.Xml.XmlDocument();normalized.LoadXml(normalizedXml);
                var normalizedNs=new System.Xml.XmlNamespaceManager(normalized.NameTable);
                normalizedNs.AddNamespace("t","http://schemas.microsoft.com/windows/2004/02/mit/task");
                System.Action<string,string> change=(path,text)=>{
                    var node=normalized.SelectSingleNode("/t:Task/"+path,normalizedNs);
                    if(text==null)node.ParentNode.RemoveChild(node);else node.InnerText=text;
                };
                change("t:Triggers/t:LogonTrigger/t:UserId",user.Name);
                change("t:Triggers/t:LogonTrigger/t:Enabled",null);
                change("t:Settings/t:Enabled",null);
                check(StartupManager.OwnedTaskEnabled(normalized.OuterXml,root,userSid),"Registered task account name and omitted true defaults are accepted");
                change("t:Principals/t:Principal/t:UserId",user.Name);
                check(StartupManager.OwnedTaskEnabled(normalized.OuterXml,root,userSid),"Principal account resolves to the same SID");
                string canonical=normalized.OuterXml;
                foreach(string parent in new string[]{"t:Settings","t:Triggers/t:LogonTrigger"}) {
                    foreach(string enabled in new string[]{"false","0","true","1"}) {
                        normalized.LoadXml(canonical);
                        var element=normalized.CreateElement("Enabled","http://schemas.microsoft.com/windows/2004/02/mit/task");
                        element.InnerText=enabled;
                        normalized.SelectSingleNode("/t:Task/"+parent,normalizedNs).AppendChild(element);
                        check(StartupManager.OwnedTaskEnabled(normalized.OuterXml,root,userSid)==(enabled=="true"||enabled=="1"),"Explicit XML boolean for "+parent+" is honored: "+enabled);
                    }
                }
                string foreignAccount=((System.Security.Principal.NTAccount)new System.Security.Principal.SecurityIdentifier("S-1-5-18").Translate(typeof(System.Security.Principal.NTAccount))).Value;
                string unknownAccount=System.Environment.MachineName+@"\NoDelta"+System.Guid.NewGuid().ToString("N").Substring(0,8);
                foreach(string identity in new string[]{"",null,foreignAccount,unknownAccount,"S-1-invalid"}) {
                    foreach(string identityPath in new string[]{"t:Principals/t:Principal/t:UserId","t:Triggers/t:LogonTrigger/t:UserId"}) {
                        normalized.LoadXml(canonical);change(identityPath,identity);
                        bool rejected=false;
                        try{StartupManager.OwnedTaskEnabled(normalized.OuterXml,root,userSid);}catch(System.InvalidOperationException){rejected=true;}
                        check(rejected,"Missing, unknown or foreign account rejected for "+identityPath);
                    }
                }
            }
            string current=null;int reads=0,writes=0;string latestOperation="",latestExpected="";
            StartupManager.TestScheduler=(operation,name,user,definition,expected)=>{
                check(name==StartupManager.TaskName(root,sid)&&user==sid,"Scheduler request uses exact user and task identity");
                if(operation=="query"){reads++;return current;}
                writes++;latestOperation=operation;latestExpected=expected;
                current=operation=="enable"?definition:null;return current;
            };
            check(!StartupManager.IsEnabled(root)&&reads==1&&writes==0,"Reading an absent task never enables startup");
            StartupManager.SetEnabled(root,false);
            check(writes==0,"Disabling an absent task is harmless");
            StartupManager.SetEnabled(root,true);
            check(writes==1&&latestOperation=="enable"&&latestExpected==""&&StartupManager.IsEnabled(root),"Explicit enable registers the first task");
            StartupManager.SetEnabled(root,true);
            check(writes==1,"Repeated enable does not rewrite an enabled task");
            current=current.Replace("<Enabled>true</Enabled>","<Enabled>false</Enabled>");
            check(!StartupManager.IsEnabled(root)&&writes==1,"Actual disabled task overrides previous UI state");
            StartupManager.SetEnabled(root,true);
            check(writes==2&&latestExpected.Length==64&&StartupManager.IsEnabled(root),"Re-enable sends a validated task snapshot hash");
            StartupManager.SetEnabled(root,false);
            check(writes==3&&latestOperation=="disable"&&latestExpected.Length==64&&!StartupManager.IsEnabled(root),"Disable removes only the validated owned task");
            foreach(string foreign in new string[]{xml.Replace(sid,otherSid),xml.Replace("--launch","--other"),xml.Replace("DeltaLauncher.exe","Other.exe"),xml.Replace("<Exec>","<Exec><Unknown/>" ).Replace("</Actions>","<Exec><Command>Other.exe</Command></Exec></Actions>"),xml.Replace("DeltaResolveAccelerator.Startup.v1","AnotherApp")}){
                current=foreign;bool rejected=false;
                try{StartupManager.SetEnabled(root,false);}catch(System.InvalidOperationException){rejected=true;}
                check(rejected&&writes==3,"Foreign task is never deleted");
                rejected=false;try{StartupManager.SetEnabled(root,true);}catch(System.InvalidOperationException){rejected=true;}
                check(rejected&&writes==3,"Foreign task is never overwritten");
            }
            current=xml;System.IO.File.Delete(System.IO.Path.Combine(root,"DeltaLauncher.exe"));
            bool missingRejected=false;try{StartupManager.SetEnabled(root,true);}catch(System.IO.FileNotFoundException){missingRejected=true;}
            check(missingRejected&&writes==3,"Missing launcher cannot be enabled");
            StartupManager.SetEnabled(root,false);
            check(writes==4&&current==null,"Owned task remains removable when launcher is missing");
            System.IO.File.WriteAllText(System.IO.Path.Combine(work,"scheduler-helper.ps1"),StartupManager.SchedulerScript,new System.Text.UTF8Encoding(true));
            return passed.ToArray();
        }
    }
}
'@
Add-Type -TypeDefinition ("#define STARTUP_TESTS`n"+$source+"`n"+$harness) -Language CSharp
$checks=[Collections.Generic.List[string]]::new()
$checks.AddRange([DeltaResolveAccelerator.StartupTestHarness]::Run($work))
$helper=Join-Path $work 'scheduler-helper.ps1'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if (@($errors).Count) { throw ('Scheduler helper syntax error: '+($errors.Message -join '; ')) }
$checks.Add('Embedded PowerShell helper parses successfully')

# Run the actual helper logic against local fake COM objects. Calling COM is
# intercepted; create/update/delete requests only update an in-memory XML value.
$mock=@'
param([string]$Helper,[string]$Operation,[string]$Existing,[string]$Expected,[string]$Payload)
$operation=$Operation;$name='Synthetic-Startup';$sid='S-1-5-21-100-200-300-400';$expected=$Expected;$payload=$Payload
$global:startupFakeXml=if($Existing){[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Existing))}else{$null}
$global:startupFakeWrites=0
function New-Object {
    param([string]$ComObject)
    if($ComObject -ne 'Schedule.Service'){throw 'Unexpected COM request'}
    $service=[pscustomobject]@{}
    $service|Add-Member ScriptMethod Connect {}
    $service|Add-Member ScriptMethod GetFolder {
        param($path)
        if($path -ne '\'){throw 'Unexpected task folder'}
        $folder=[pscustomobject]@{}
        $folder|Add-Member ScriptMethod GetTask {
            param($taskName)
            if($taskName -ne 'Synthetic-Startup'){throw 'Unexpected task name'}
            if($null -eq $global:startupFakeXml){throw [Runtime.InteropServices.COMException]::new('Missing',-2147024894)}
            return [pscustomobject]@{Xml=$global:startupFakeXml}
        }
        $folder|Add-Member ScriptMethod RegisterTask {
            param($taskName,$xml,$flags,$user,$password,$logon,$sddl)
            if($taskName -ne 'Synthetic-Startup' -or $user -ne 'S-1-5-21-100-200-300-400' -or $null -ne $password -or $logon -ne 3){throw 'Unexpected registration arguments'}
            $wanted=if($null -eq $global:startupFakeXml){34}else{36}
            if($flags -ne $wanted){throw 'Registration must use create OR update and suppress registration triggers'}
            $global:startupFakeWrites++;$global:startupFakeXml=$xml
            return [pscustomobject]@{Xml=$xml}
        }
        $folder|Add-Member ScriptMethod DeleteTask {
            param($taskName,$flags)
            if($taskName -ne 'Synthetic-Startup' -or $flags -ne 0){throw 'Unexpected deletion arguments'}
            $global:startupFakeWrites++;$global:startupFakeXml=$null
        }
        return $folder
    }
    return $service
}
$LASTEXITCODE=0
. $Helper
[Console]::Write('|WRITES='+$global:startupFakeWrites)
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
'@
$mockPath=Join-Path $work 'mock-scheduler.ps1'
[IO.File]::WriteAllText($mockPath,$mock,[Text.UTF8Encoding]::new($false))
$ps=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Invoke-FakeScheduler([string]$Operation,[string]$Existing='', [string]$Expected='', [string]$Payload='') {
    $argsList=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$mockPath,'-Helper',$helper,'-Operation',$Operation)
    if($Existing){$argsList+=@('-Existing',$Existing)}
    if($Expected){$argsList+=@('-Expected',$Expected)}
    if($Payload){$argsList+=@('-Payload',$Payload)}
    $output=& $ps @argsList
    return [pscustomobject]@{Code=$LASTEXITCODE;Text=([string]$output)}
}
function Assert-Helper([string]$Name,$Actual,[int]$Code,[string]$Result) {
    if($Actual.Code -ne $Code -or $Actual.Text -notlike $Result){throw ('FAIL: '+$Name+' '+($Actual|ConvertTo-Json -Compress))}
    $checks.Add($Name)
}
$synthetic='<Task>中文 &amp; spaces</Task>'
$payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($synthetic))
$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($synthetic))).ToLowerInvariant()
Assert-Helper 'Helper missing-task read does not mutate' (Invoke-FakeScheduler 'query') 0 'ABSENT|WRITES=0'
Assert-Helper 'Helper existing-task read does not mutate' (Invoke-FakeScheduler 'query' $payload) 0 ('XML|'+$payload+'|WRITES=0')
Assert-Helper 'Helper creates only an absent task' (Invoke-FakeScheduler 'enable' '' '' $payload) 0 ('XML|'+$payload+'|WRITES=1')
Assert-Helper 'Helper updates only the checked snapshot' (Invoke-FakeScheduler 'enable' $payload $hash $payload) 0 ('XML|'+$payload+'|WRITES=1')
Assert-Helper 'Helper deletes only the checked snapshot' (Invoke-FakeScheduler 'disable' $payload $hash) 0 'ABSENT|WRITES=1'
Assert-Helper 'Helper refuses a changed task before mutation' (Invoke-FakeScheduler 'disable' $payload ('0'*64)) 1 'ERROR|*|WRITES=0'
# NewTask only creates an in-memory definition; no RegisterTask call is made.
$service=$null;$definition=$null
try {
    $service=New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $definition=$service.NewTask(0)
    $definition.XmlText=[IO.File]::ReadAllText((Join-Path $work 'task-definition.xml'))
    [xml]$normalized=$definition.XmlText
    $ns=[Xml.XmlNamespaceManager]::new($normalized.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    if($normalized.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId',$ns).InnerText -ne 'S-1-5-21-100-200-300-400' -or
       $normalized.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$ns).InnerText -ne '--launch' -or
       $normalized.SelectSingleNode('/t:Task/t:RegistrationInfo/t:URI',$ns).InnerText -notlike '\DeltaResolveAccelerator-Startup-*') { throw 'Windows changed task ownership identity.' }
    $checks.Add('Windows Task Scheduler accepts task XML without registering it')
    $checks.Add('Windows-normalized XML preserves principal and launcher identity')
} finally {
    foreach($item in @($definition,$service)){if($null -ne $item){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}}
}
# Compile the production helper and read only a uniquely named absent task.
$smoke=@'
namespace DeltaResolveAccelerator {
    internal static class StartupSmoke {
        private static int Main(string[] args) {
            if (StartupManager.IsEnabled(args[0])) return 1;
            System.Console.Write("ABSENT");return 0;
        }
    }
}
'@
$smokeSource=Join-Path $work 'StartupSmoke.cs'
$smokeExe=Join-Path $work 'StartupSmoke.exe'
[IO.File]::WriteAllText($smokeSource,$smoke,[Text.UTF8Encoding]::new($false))
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $compiler /nologo /target:exe /platform:x64 /codepage:65001 ('/out:'+$smokeExe) (Join-Path $repository 'src/StartupManager.cs') $smokeSource
if($LASTEXITCODE -ne 0){throw 'Startup production helper compilation failed.'}
$smokeOutput=& $smokeExe $work
if($LASTEXITCODE -ne 0 -or $smokeOutput -ne 'ABSENT'){throw 'Production startup read-only smoke failed.'}
$checks.Add('Production helper reads absent startup task without mutation')
$report=[pscustomobject]@{passed=$true;checks=$checks.Count;results=$checks;realStartupSettingsChanged=$false;acceleratorStarted=$false;networkStarted=$false}
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $work 'result.json') -Encoding utf8
$report|Select-Object passed,checks,realStartupSettingsChanged,acceleratorStarted,networkStarted|ConvertTo-Json
