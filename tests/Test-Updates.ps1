[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $PSScriptRoot 'output/updates'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$harness = Join-Path $output 'UpdateTests.cs'
$testSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using DeltaResolveAccelerator;

internal static class UpdateTests
{
    private const string Feed = "https://raw.githubusercontent.com/QifengKuang/DeltaResolveAccelerator/updates/stable/";
    private const string PackageUrl = "https://raw.githubusercontent.com/QifengKuang/DeltaResolveAccelerator/updates/packages/1.1.0/delta-ui-1.1.0.zip";
    private static RSACryptoServiceProvider key;
    private static readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private static int passed;
    private static string workspace;
    private static readonly byte[] OldExe = Encoding.UTF8.GetBytes("old known good UI");
    private static readonly byte[] OldConfig = Encoding.UTF8.GetBytes("old known good configuration");
    private static byte[] NewExe;
    private static readonly byte[] NewConfig = Encoding.UTF8.GetBytes("verified replacement configuration");
    private static Dictionary<string,byte[]> download;

    public static int Main(string[] args)
    {
        UpdateManager.TestAppMutex = @"Local\DeltaResolveUpdateTests-" + Process.GetCurrentProcess().Id;
        if (args.Length == 3 && args[0] == "--crash")
        {
            UpdateManager.TestPublicKey = File.ReadAllText(Path.Combine(args[1], "test-public.xml"));
            UpdateManager.TestVersion = "1.0.0";
            UpdateManager.TestBackendStopped = delegate { return true; };
            UpdateManager.TestFault = delegate(string point) { if (point == args[2]) Environment.Exit(17); };
            UpdateManager.ApplyPending(args[1]);
            return 18;
        }
        workspace = args[0];
        NewExe = File.ReadAllBytes(Path.Combine(workspace,"FixtureApp.exe"));
        try
        {
            using (key = new RSACryptoServiceProvider(2048))
            {
                key.PersistKeyInCsp = false;
                UpdateManager.TestPublicKey = key.ToXmlString(false);
                UpdateManager.TestVersion = "1.0.0";
                UpdateManager.TestBackendStopped = delegate { return true; };
                Run("signed fallback stage and apply", ValidApply);
                Run("bad signature rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", null, false); download[Feed+"delta-ui-manifest.sig"][0] ^= 1; Reject(r); });
                Run("modified signed manifest rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", null, false); download[Feed+"delta-ui-manifest.json"][10] ^= 1; Reject(r); });
                Run("package hash rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", null, false); download[PackageUrl][10] ^= 1; Reject(r); });
                Run("per-file hash rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", null, true); Reject(r); });
                Run("older version rejected", delegate { string r = Fixture(); FeedPackage("0.9.9", null, false); Reject(r); });
                Run("equal version normalized and rejected", delegate { string r = Fixture(); FeedPackage("1.0.0.0", null, false); Reject(r); });
                Run("zip traversal rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", new[]{"../Accelerator.exe","Accelerator.exe.config"}, false); Reject(r); Assert(!File.Exists(Path.Combine(r,"updates","Accelerator.exe")),"zip escaped staging"); });
                Run("zip duplicate rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", new[]{"Accelerator.exe","Accelerator.exe"}, false); Reject(r); });
                Run("zip unexpected file rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", new[]{"backend.ps1","Accelerator.exe.config"}, false); Reject(r); });
                Run("zip symlink rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", null, false, true); Reject(r); });
                Run("nonofficial package address rejected", delegate { string r = Fixture(); FeedPackage("1.1.0", null, false, false, "https://example.com/evil.zip"); Reject(r); });
                Run("network failure keeps existing application", delegate { string r = Fixture(); UpdateManager.TestDownload = delegate(string u,int m) { throw new WebException("simulated offline"); }; Reject(r); Assert(UpdateManager.IsLaunchSafe(r),"network blocked launch"); });
                Run("active application defers update", ActiveApp);
                Run("active backend defers update", delegate { string r = Stage(); UpdateManager.TestBackendStopped = delegate { return false; }; Assert(!UpdateManager.ApplyPending(r),"active backend update"); AssertOld(r); UpdateManager.TestBackendStopped = delegate { return true; }; });
                Run("tampered staged file rejected before replacement", delegate { string r = Stage(); File.WriteAllText(Path.Combine(r,"updates","pending","Accelerator.exe"),"tampered"); Assert(!UpdateManager.ApplyPending(r),"tampered staged update"); AssertOld(r); });
                Run("replacement failure rolls back both files", Rollback);
                Run("process termination after journal recovers", delegate { CrashRecovery("journal-written", false); });
                Run("process termination during replacement recovers", delegate { CrashRecovery("replaced:Accelerator.exe", false); });
                Run("process termination after commit retains new version", delegate { CrashRecovery("committed", true); });
                Run("corrupt recovery backup blocks launching mixed version", CorruptRecovery);
                Run("auto-update preference defaults on and persists opt-out", Preferences);
                Run("reparse staging directory refused", Reparse);
                Run("manual checks ignore six-hour automatic throttle", Throttle);
                Run("network failure does not create six-hour success stamp", FailedCheckRetries);
                Run("official signed GitHub Release used if stable feed unavailable", ReleaseFallback);
                Run("prerelease GitHub Release ignored", PrereleaseRejected);
                Run("stable signed feed is authoritative over older release", FeedAuthoritative);
                Run("signed oversized package refused before download", delegate { string r=Fixture();FeedPackage("1.1.0",null,false);Resign(delegate(Dictionary<string,object> m){m["packageSize"]=33554433;});Reject(r); });
                Run("staged signature tampering rejected", delegate { string r=Stage();File.WriteAllBytes(Path.Combine(r,"updates","pending","manifest.sig"),new byte[]{1,2,3});Assert(!UpdateManager.ApplyPending(r),"bad staged signature installed");AssertOld(r); });
                Run("rollback cleanup interruption permits verified old app", RollbackCleanup);
                Run("actual backend status path blocks connected update", ProductionBackendStatus);
                Run("actual backend worker path blocks surviving worker update", ProductionBackendWorker);
                Run("signed executable version mismatch rejected", delegate { string r=Fixture();FeedPackage("1.2.0",null,false);Reject(r); });
                Run("reused stale worker PID does not block update", WorkerPidReuse);
                Run("live exact worker identity blocks update", ExactWorkerIdentity);
            }
            File.WriteAllText(Path.Combine(workspace,"update-test-summary.json"),json.Serialize(new {passed=passed,failed=0,realApplicationStarted=false,networkStarted=false,realSettingsRead=false}));
            Console.WriteLine("Update tests: "+passed+" passed; no real network, app, SDK or user configuration accessed.");
            return 0;
        }
        catch(Exception error) { Console.Error.WriteLine(error.ToString()); return 1; }
    }

    private static void Run(string name,Action test)
    {
        UpdateManager.TestFault=null;
        UpdateManager.TestBackendStopped=delegate{return true;};
        test(); passed++; Console.WriteLine("PASS "+name);
    }
    private static string Fixture()
    {
        string r=Path.Combine(workspace,"case-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(r);
        File.WriteAllBytes(Path.Combine(r,"Accelerator.exe"),OldExe);File.WriteAllBytes(Path.Combine(r,"Accelerator.exe.config"),OldConfig);
        File.WriteAllText(Path.Combine(r,"user-settings.json"),"synthetic preferences");
        Directory.CreateDirectory(Path.Combine(r,"backend"));File.WriteAllText(Path.Combine(r,"backend","custom-fix.ps1"),"synthetic machine-specific backend fix");
        Directory.CreateDirectory(Path.Combine(r,"private"));File.WriteAllText(Path.Combine(r,"private","test-placeholder.txt"),"synthetic private marker; not a key");
        File.WriteAllText(Path.Combine(r,"test-public.xml"),key.ToXmlString(false));
        return r;
    }
    private static void FeedPackage(string version,string[] names,bool wrongFileHash,bool symlink=false,string packageUrl=PackageUrl)
    {
        byte[] zip;
        using(MemoryStream stream=new MemoryStream())
        {
            using(ZipArchive archive=new ZipArchive(stream,ZipArchiveMode.Create,true))
            {
                string[] files=names??new[]{"Accelerator.exe","Accelerator.exe.config"};
                for(int i=0;i<files.Length;i++)
                {
                    ZipArchiveEntry entry=archive.CreateEntry(files[i]);
                    if(symlink&&i==0)entry.ExternalAttributes=unchecked((int)(0xa1ffu<<16));
                    using(Stream output=entry.Open()){byte[] bytes=i==0?NewExe:NewConfig;output.Write(bytes,0,bytes.Length);}
                }
            }
            zip=stream.ToArray();
        }
        byte[] manifest=Encoding.UTF8.GetBytes(json.Serialize(new{version=version,packageUrl=packageUrl,packageSha256=Hash(zip),packageSize=zip.Length,files=new[]{
            new{name="Accelerator.exe",sha256=wrongFileHash?Hash(OldExe):Hash(NewExe),size=NewExe.Length},
            new{name="Accelerator.exe.config",sha256=Hash(NewConfig),size=NewConfig.Length}}}));
        byte[] signature=key.SignData(manifest,CryptoConfig.MapNameToOID("SHA256"));
        download=new Dictionary<string,byte[]>{{Feed+"delta-ui-manifest.json",manifest},{Feed+"delta-ui-manifest.sig",signature},{packageUrl,zip}};
        UpdateManager.TestDownload=delegate(string u,int maximum){if(u.Contains("api.github.com"))throw new WebException("404 no GitHub Release");byte[] found=download[u];if(found.Length>maximum)throw new InvalidDataException("too large");return (byte[])found.Clone();};
    }
    private static string Stage(){string r=Fixture();FeedPackage("1.1.0",null,false);Assert(UpdateManager.CheckNow(r),"valid signed package did not stage: "+UpdateManager.ReadStatus(r));return r;}
    private static void Reject(string r){Assert(!UpdateManager.CheckNow(r),"bad update accepted");AssertOld(r);Assert(UpdateManager.IsLaunchSafe(r),"rejection blocked known-good app");}
    private static void AssertOld(string r){Assert(Hash(File.ReadAllBytes(Path.Combine(r,"Accelerator.exe")))==Hash(OldExe),"old exe changed");Assert(Hash(File.ReadAllBytes(Path.Combine(r,"Accelerator.exe.config")))==Hash(OldConfig),"old config changed");Preserved(r);}
    private static void AssertNew(string r){Assert(Hash(File.ReadAllBytes(Path.Combine(r,"Accelerator.exe")))==Hash(NewExe),"new exe absent");Assert(Hash(File.ReadAllBytes(Path.Combine(r,"Accelerator.exe.config")))==Hash(NewConfig),"new config absent");Preserved(r);}
    private static void Preserved(string r){Assert(File.ReadAllText(Path.Combine(r,"backend","custom-fix.ps1"))=="synthetic machine-specific backend fix","backend modified");Assert(File.ReadAllText(Path.Combine(r,"user-settings.json"))=="synthetic preferences","preferences modified");Assert(File.ReadAllText(Path.Combine(r,"private","test-placeholder.txt"))=="synthetic private marker; not a key","private marker modified");}
    private static void ValidApply(){string r=Stage();Assert(UpdateManager.ApplyPending(r),"valid update failed: "+UpdateManager.ReadStatus(r));AssertNew(r);Assert(UpdateManager.IsLaunchSafe(r),"completed update unsafe");Assert(!Directory.Exists(Path.Combine(r,"updates","transaction")),"transaction remained");}
    private static void ActiveApp()
    {
        string r=Stage();ManualResetEvent held=new ManualResetEvent(false),release=new ManualResetEvent(false);
        Thread owner=new Thread(delegate(){using(Mutex mutex=new Mutex(false,UpdateManager.TestAppMutex)){mutex.WaitOne();held.Set();release.WaitOne();mutex.ReleaseMutex();}});
        owner.Start();Assert(held.WaitOne(5000),"could not hold app mutex");
        try{Assert(!UpdateManager.ApplyPending(r),"active app update");AssertOld(r);}finally{release.Set();owner.Join();held.Dispose();release.Dispose();}
    }
    private static void Rollback(){string r=Stage();UpdateManager.TestFault=delegate(string p){if(p=="replaced:Accelerator.exe")throw new IOException("injected second-file failure");};Assert(!UpdateManager.ApplyPending(r),"failure reported success");AssertOld(r);Assert(UpdateManager.IsLaunchSafe(r),"successful rollback unsafe");}
    private static void Crash(string r,string point)
    {
        using(Process child=Process.Start(new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location,"--crash \""+r+"\" \""+point+"\""){UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden}))
        {Assert(child.WaitForExit(10000),"crash fixture timeout");Assert(child.ExitCode==17,"crash injection not reached: "+child.ExitCode);}
    }
    private static void CrashRecovery(string point,bool committed)
    {
        string r=Stage();Crash(r,point);Assert(!UpdateManager.IsLaunchSafe(r),"unfinished transaction marked safe");
        Directory.Move(Path.Combine(r,"updates","pending"),Path.Combine(r,"held-pending"));
        UpdateManager.ApplyPending(r);if(committed)AssertNew(r);else AssertOld(r);Assert(UpdateManager.IsLaunchSafe(r),"recovery failed: "+UpdateManager.ReadStatus(r));
    }
    private static void CorruptRecovery()
    {
        string r=Stage();Crash(r,"replaced:Accelerator.exe");File.WriteAllText(Path.Combine(r,"updates","transaction","Accelerator.exe"),"corrupt backup");
        Assert(!UpdateManager.ApplyPending(r),"corrupt recovery succeeded");Assert(!UpdateManager.IsLaunchSafe(r),"mixed app allowed to launch");Preserved(r);
    }
    private static void Preferences(){string r=Fixture();Assert(UpdateManager.AutomaticChecksEnabled(r),"default not enabled");UpdateManager.SetAutomaticChecksEnabled(r,false);Assert(!UpdateManager.AutomaticChecksEnabled(r),"opt-out not retained");UpdateManager.TestDownload=delegate(string u,int m){throw new Exception("automatic opt-out made network request");};UpdateManager.RunAutomaticCheck(r);UpdateManager.SetAutomaticChecksEnabled(r,true);Assert(UpdateManager.AutomaticChecksEnabled(r),"re-enable failed");}
    private static void Reparse()
    {
        string r=Fixture(),outside=Path.Combine(workspace,"outside-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(outside);Directory.CreateDirectory(Path.Combine(r,"updates"));
        string junction=Path.Combine(r,"updates","staging");
        // The target is a new empty fixture directory; no deletion or move is delegated to cmd.
        using(Process p=Process.Start(new ProcessStartInfo("cmd.exe","/d /c mklink /J \""+junction+"\" \""+outside+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true})) {p.WaitForExit();Assert(p.ExitCode==0,"junction fixture creation failed");}
        FeedPackage("1.1.0",null,false);Reject(r);Assert(Directory.GetFileSystemEntries(outside).Length==0,"reparse target was modified");
        Directory.Delete(junction,false);
    }
    private static void Throttle()
    {
        string r=Stage();int calls=0;Func<string,int,byte[]> previous=UpdateManager.TestDownload;UpdateManager.TestDownload=delegate(string u,int m){calls++;return previous(u,m);};
        UpdateManager.RunAutomaticCheck(r);Assert(calls==0,"automatic check ignored throttle");UpdateManager.CheckNow(r);Assert(calls>0,"manual check was throttled");
    }
    private static void FailedCheckRetries()
    {
        string r=Fixture();int calls=0;UpdateManager.TestDownload=delegate(string u,int m){calls++;throw new WebException("simulated offline");};
        UpdateManager.RunAutomaticCheck(r);int first=calls;UpdateManager.RunAutomaticCheck(r);Assert(first>0&&calls>first,"failed automatic check suppressed retries");Assert(!File.Exists(Path.Combine(r,"updates","last-check.txt")),"failed check stamped success");AssertOld(r);
    }
    private static void ConfigureRelease(bool prerelease)
    {
        string release="https://github.com/QifengKuang/DeltaResolveAccelerator/releases/download/v1.1.0/";
        byte[] manifest=download[Feed+"delta-ui-manifest.json"],signature=download[Feed+"delta-ui-manifest.sig"];
        download[release+"delta-ui-manifest.json"]=manifest;download[release+"delta-ui-manifest.sig"]=signature;
        byte[] response=Encoding.UTF8.GetBytes(json.Serialize(new{draft=false,prerelease=prerelease,assets=new[]{new{name="delta-ui-manifest.json",browser_download_url=release+"delta-ui-manifest.json"},new{name="delta-ui-manifest.sig",browser_download_url=release+"delta-ui-manifest.sig"}}}));
        UpdateManager.TestDownload=delegate(string u,int m){if(u.StartsWith(Feed))throw new WebException("feed unavailable");if(u.Contains("api.github.com"))return response;return (byte[])download[u].Clone();};
    }
    private static void ReleaseFallback(){string r=Fixture();FeedPackage("1.1.0",null,false);ConfigureRelease(false);Assert(UpdateManager.CheckNow(r),"signed release fallback failed");Assert(UpdateManager.ApplyPending(r),"signed release install failed");AssertNew(r);}
    private static void PrereleaseRejected(){string r=Fixture();FeedPackage("1.1.0",null,false);ConfigureRelease(true);Reject(r);}
    private static void FeedAuthoritative(){string r=Fixture();FeedPackage("1.1.0",null,false);Func<string,int,byte[]> previous=UpdateManager.TestDownload;bool releaseRead=false;UpdateManager.TestDownload=delegate(string u,int m){if(u.Contains("api.github.com")){releaseRead=true;throw new Exception("older release should not override signed stable feed");}return previous(u,m);};Assert(UpdateManager.CheckNow(r),"stable feed stage failed");Assert(!releaseRead,"unnecessary release discovery");}
    private static void Resign(Action<Dictionary<string,object>> change){Dictionary<string,object> manifest=json.Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(download[Feed+"delta-ui-manifest.json"]));change(manifest);byte[] bytes=Encoding.UTF8.GetBytes(json.Serialize(manifest));download[Feed+"delta-ui-manifest.json"]=bytes;download[Feed+"delta-ui-manifest.sig"]=key.SignData(bytes,CryptoConfig.MapNameToOID("SHA256"));}
    private static void RollbackCleanup(){string r=Stage();Crash(r,"journal-written");File.Delete(Path.Combine(r,"updates","transaction","Accelerator.exe"));Directory.Move(Path.Combine(r,"updates","pending"),Path.Combine(r,"held-pending"));UpdateManager.ApplyPending(r);AssertOld(r);Assert(UpdateManager.IsLaunchSafe(r),"verified old files blocked by partial backup cleanup");}
    private static void ProductionBackendStatus()
    {
        string r=Stage();Directory.CreateDirectory(Path.Combine(r,"backend","results"));
        File.WriteAllText(Path.Combine(r,"backend","results","ui-status.json"),"{\"phase\":\"connected\"}");
        UpdateManager.TestBackendStopped=null;
        Assert(!UpdateManager.ApplyPending(r),"connected real backend-relative status ignored");AssertOld(r);
    }
    private static void ProductionBackendWorker()
    {
        string r=Stage();Directory.CreateDirectory(Path.Combine(r,"backend","results"));Directory.CreateDirectory(Path.Combine(r,"backend","private"));
        File.WriteAllText(Path.Combine(r,"backend","results","ui-status.json"),"{\"phase\":\"stopped\"}");
        File.WriteAllText(Path.Combine(r,"backend","private","ui-worker.json"),"{\"WorkerPid\":"+Process.GetCurrentProcess().Id+"}");
        UpdateManager.TestBackendStopped=null;
        Assert(!UpdateManager.ApplyPending(r),"surviving real backend-relative worker ignored");AssertOld(r);
    }
    private static void WorkerPidReuse(){Dictionary<string,object> record=new Dictionary<string,object>{{"WorkerPid",Process.GetCurrentProcess().Id},{"WorkerCreatedUtc",DateTime.UtcNow.AddYears(-1).ToString("o")}};Assert(!UpdateManager.RecordedWorkerMayBeRunning(record),"reused stale pid treated as original worker");}
    private static void ExactWorkerIdentity(){using(Process current=Process.GetCurrentProcess()){Dictionary<string,object> record=new Dictionary<string,object>{{"WorkerPid",current.Id},{"WorkerCreatedUtc",current.StartTime.ToUniversalTime().ToString("o")}};Assert(UpdateManager.RecordedWorkerMayBeRunning(record),"exact live worker identity ignored");}}
    private static string Hash(byte[] b){using(SHA256 h=SHA256.Create())return BitConverter.ToString(h.ComputeHash(b)).Replace("-","").ToLowerInvariant();}
    private static void Assert(bool condition,string message){if(!condition)throw new Exception(message);}
}
'@
[IO.File]::WriteAllText($harness,$testSource,[Text.UTF8Encoding]::new($false))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$fixtureSource = Join-Path $output 'FixtureApp.cs'
[IO.File]::WriteAllText($fixtureSource,'using System.Reflection; [assembly:AssemblyVersion("1.1.0.0")] [assembly:AssemblyFileVersion("1.1.0.0")] internal static class FixtureApp { private static void Main() {} }',[Text.UTF8Encoding]::new($false))
& $compiler '/nologo' '/target:winexe' '/platform:x64' ('/out:'+(Join-Path $output 'FixtureApp.exe')) $fixtureSource
if ($LASTEXITCODE -ne 0) { throw 'Synthetic versioned test file compilation failed' }
$executable = Join-Path $output 'UpdateTests.exe'
$arguments = @('/nologo','/target:exe','/platform:x64','/optimize+','/codepage:65001','/define:UPDATE_TESTS',('/out:'+$executable),
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Security.dll','/reference:System.Web.Extensions.dll','/reference:System.IO.Compression.dll',
    (Join-Path $root 'src/UpdateManager.cs'),(Join-Path $root 'src/UpdatePublicKey.cs'),$harness)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Update test compilation failed' }
& $executable $output
if ($LASTEXITCODE -ne 0) { throw 'Update regression failed' }
Get-Content -LiteralPath (Join-Path $output 'update-test-summary.json')
