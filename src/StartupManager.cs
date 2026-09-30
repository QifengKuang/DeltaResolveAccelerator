// Optional per-user startup. .NET Framework / C# 5; no task is created by reads.
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;
using System.Xml;

namespace DeltaResolveAccelerator
{
    internal static class StartupManager
    {
        private const string Schema = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        private const string Owner = "DeltaResolveAccelerator.Startup.v1";
#if STARTUP_TESTS
        internal static Func<string, string, string, string, string, string> TestScheduler;
        internal static string TestUserSid;
#endif

        internal static bool IsEnabled(string root)
        {
            root = NormalizeRoot(root);
            string sid = CurrentUserSid();
            string xml = RunScheduler("query", TaskName(root, sid), sid, "", "");
            return xml != null && OwnedTaskEnabled(xml, root, sid);
        }

        internal static void SetEnabled(string root, bool enabled)
        {
            root = NormalizeRoot(root);
            string sid = CurrentUserSid(), name = TaskName(root, sid);
            if (enabled && !File.Exists(Path.Combine(root, "DeltaLauncher.exe")))
                throw new FileNotFoundException("启动器文件缺失，请先修复安装。", Path.Combine(root, "DeltaLauncher.exe"));
            string previous = RunScheduler("query", name, sid, "", "");
            bool wasEnabled = previous != null && OwnedTaskEnabled(previous, root, sid);
            if (enabled && wasEnabled || !enabled && previous == null) return;
            string result = RunScheduler(enabled ? "enable" : "disable", name, sid,
                enabled ? BuildTaskXml(root, sid) : "", previous == null ? "" : Hash(previous));
            if (enabled ? result == null || !OwnedTaskEnabled(result, root, sid) : result != null)
                throw new IOException("开机自启动设置未能保存，请重新打开设置后重试。");
        }

        private static string CurrentUserSid()
        {
#if STARTUP_TESTS
            if (TestUserSid != null) return TestUserSid;
#endif
            using (WindowsIdentity user = WindowsIdentity.GetCurrent())
            {
                if (user.User == null || !Environment.UserInteractive)
                    throw new InvalidOperationException("请在当前 Windows 用户登录后设置开机自启动。");
                return user.User.Value;
            }
        }

        internal static string NormalizeRoot(string root)
        {
            if (String.IsNullOrWhiteSpace(root) || !Path.IsPathRooted(root)) throw new ArgumentException("安装路径必须是完整路径。");
            string value = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (value.Length < 3 || value.StartsWith(@"\\", StringComparison.Ordinal)) throw new ArgumentException("开机自启动需要本地安装路径。");
            // Never register an elevated startup action through a junction/symlink.
            for (string item = value; !String.IsNullOrEmpty(item); item = Path.GetDirectoryName(item))
                if (Directory.Exists(item) && (File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("开机自启动的安装路径不能经过链接目录。");
            string launcher = Path.Combine(value, "DeltaLauncher.exe");
            if (File.Exists(launcher) && (File.GetAttributes(launcher) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("开机自启动的启动器不能是链接文件。");
            return value;
        }

        internal static string TaskName(string root, string sid)
        {
            return "DeltaResolveAccelerator-Startup-" + Hash(sid + "\n" + NormalizeRoot(root).ToUpperInvariant()).Substring(0, 32);
        }

        internal static string BuildTaskXml(string root, string sid)
        {
            root = NormalizeRoot(root);
            StringBuilder text = new StringBuilder();
            using (XmlWriter writer = XmlWriter.Create(text, new XmlWriterSettings { OmitXmlDeclaration = true, Indent = true }))
            {
                writer.WriteStartElement("Task", Schema); writer.WriteAttributeString("version", "1.2");
                writer.WriteStartElement("RegistrationInfo");
                writer.WriteElementString("Author", Owner);
                writer.WriteElementString("Description", "用户选择在登录 Windows 后打开三角洲加速器；不会自动连接。");
                writer.WriteElementString("URI", "\\" + TaskName(root, sid));
                writer.WriteEndElement();
                writer.WriteStartElement("Triggers"); writer.WriteStartElement("LogonTrigger");
                writer.WriteElementString("Enabled", "true"); writer.WriteElementString("UserId", sid);
                writer.WriteEndElement(); writer.WriteEndElement();
                writer.WriteStartElement("Principals"); writer.WriteStartElement("Principal"); writer.WriteAttributeString("id", "CurrentUser");
                writer.WriteElementString("UserId", sid); writer.WriteElementString("LogonType", "InteractiveToken");
                writer.WriteElementString("RunLevel", "HighestAvailable");
                writer.WriteEndElement(); writer.WriteEndElement();
                writer.WriteStartElement("Settings");
                writer.WriteElementString("MultipleInstancesPolicy", "IgnoreNew");
                writer.WriteElementString("DisallowStartIfOnBatteries", "false");
                writer.WriteElementString("StopIfGoingOnBatteries", "false");
                writer.WriteElementString("AllowHardTerminate", "false");
                writer.WriteElementString("StartWhenAvailable", "false");
                writer.WriteElementString("RunOnlyIfNetworkAvailable", "false");
                writer.WriteElementString("AllowStartOnDemand", "false");
                writer.WriteElementString("Enabled", "true"); writer.WriteElementString("Hidden", "false");
                writer.WriteElementString("RunOnlyIfIdle", "false"); writer.WriteElementString("WakeToRun", "false");
                writer.WriteElementString("ExecutionTimeLimit", "PT0S");
                writer.WriteEndElement();
                writer.WriteStartElement("Actions"); writer.WriteAttributeString("Context", "CurrentUser"); writer.WriteStartElement("Exec");
                writer.WriteElementString("Command", Path.Combine(root, "DeltaLauncher.exe"));
                writer.WriteElementString("Arguments", "--launch"); writer.WriteElementString("WorkingDirectory", root);
                writer.WriteEndElement(); writer.WriteEndElement(); writer.WriteEndElement();
            }
            return text.ToString();
        }

        internal static bool OwnedTaskEnabled(string xml, string root, string sid)
        {
            if (xml.Length > 65536) throw new IOException("开机自启动任务内容异常。");
            XmlDocument task = new XmlDocument { XmlResolver = null };
            using (XmlReader reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null })) task.Load(reader);
            XmlNamespaceManager ns = new XmlNamespaceManager(task.NameTable); ns.AddNamespace("t", Schema);
            Func<string, string> value = path => { XmlNode node = task.SelectSingleNode("/t:Task/" + path, ns); return node == null ? "" : node.InnerText; };
            bool own = value("t:RegistrationInfo/t:Author") == Owner &&
                value("t:RegistrationInfo/t:URI") == "\\" + TaskName(root, sid) &&
                task.SelectNodes("/t:Task/t:Actions/*", ns).Count == 1 &&
                task.SelectNodes("/t:Task/t:Principals/*", ns).Count == 1 &&
                task.SelectNodes("/t:Task/t:Triggers/*", ns).Count == 1 &&
                SameUser(value("t:Principals/t:Principal/t:UserId"), sid) &&
                value("t:Principals/t:Principal/t:LogonType") == "InteractiveToken" &&
                value("t:Principals/t:Principal/t:RunLevel") == "HighestAvailable" &&
                SameUser(value("t:Triggers/t:LogonTrigger/t:UserId"), sid) &&
                String.Equals(value("t:Actions/t:Exec/t:Command"), Path.Combine(root, "DeltaLauncher.exe"), StringComparison.OrdinalIgnoreCase) &&
                value("t:Actions/t:Exec/t:Arguments") == "--launch" &&
                String.Equals(value("t:Actions/t:Exec/t:WorkingDirectory").TrimEnd('\\', '/'), root, StringComparison.OrdinalIgnoreCase);
            if (!own) throw new InvalidOperationException("存在同名但内容不同的启动任务。为避免影响其他设置，未修改该任务。");
            return EnabledByDefault(task.SelectSingleNode("/t:Task/t:Settings/t:Enabled", ns)) &&
                EnabledByDefault(task.SelectSingleNode("/t:Task/t:Triggers/t:LogonTrigger/t:Enabled", ns));
        }

        private static bool SameUser(string userId, string expectedSid)
        {
            if (String.IsNullOrWhiteSpace(userId)) return false;
            try
            {
                // Task Scheduler may export DOMAIN\name in place of the SID.
                // Resolve through Windows; a matching display name alone is not ownership.
                SecurityIdentifier resolved = userId.StartsWith("S-1-", StringComparison.OrdinalIgnoreCase) ?
                    new SecurityIdentifier(userId) :
                    (SecurityIdentifier)new NTAccount(userId).Translate(typeof(SecurityIdentifier));
                return resolved.Equals(new SecurityIdentifier(expectedSid));
            }
            catch (IdentityNotMappedException) { return false; }
            catch (ArgumentException) { return false; }
            catch (System.Security.SecurityException) { return false; }
        }

        private static bool EnabledByDefault(XmlNode setting)
        {
            // Both task and trigger Enabled default to true; Windows may omit them.
            if (setting == null) return true;
            try { return XmlConvert.ToBoolean(setting.InnerText.Trim()); }
            catch (FormatException) { throw new InvalidOperationException("开机自启动任务的启用状态无效，未修改该任务。"); }
        }

        private static string Hash(string value)
        {
            using (SHA256 hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(value))).Replace("-", "").ToLowerInvariant();
        }

        private static string Base64(string value) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(value)); }

        private static string RunScheduler(string operation, string name, string sid, string xml, string expectedHash)
        {
#if STARTUP_TESTS
            if (TestScheduler != null) return TestScheduler(operation, name, sid, xml, expectedHash);
            throw new InvalidOperationException("Startup tests must provide an isolated scheduler.");
#else
            // COM is isolated in a short-lived, hidden OS helper so a stalled service
            // cannot leave an unbounded UI thread or a pending in-process mutation.
            string script = "$operation='" + operation + "';$name='" + name + "';$sid='" + sid + "';$expected='" + expectedHash + "';$payload='" + Base64(xml) + "';" + SchedulerScript;
            string arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            if (arguments.Length > 30000) throw new IOException("开机自启动配置过长。");
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo(powershell, arguments) {
                UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            using (Process process = Process.Start(start))
            {
                Task<string> output = process.StandardOutput.ReadToEndAsync();
                Task<string> errors = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(10000))
                {
                    try { process.Kill(); process.WaitForExit(1000); } catch { }
                    throw new TimeoutException("Windows 开机自启动设置响应超时，请重新打开设置确认结果。");
                }
                if (!Task.WaitAll(new Task[] { output, errors }, 1000)) throw new IOException("无法读取 Windows 开机自启动设置结果。");
                string result = output.Result.Trim();
                if (result.StartsWith("ERROR|", StringComparison.Ordinal))
                    throw new IOException("无法设置开机自启动：" + Encoding.UTF8.GetString(Convert.FromBase64String(result.Substring(6))));
                if (process.ExitCode != 0) throw new IOException("无法访问 Windows 任务计划程序，请确认服务可用后重试。");
                if (result == "ABSENT") return null;
                if (!result.StartsWith("XML|", StringComparison.Ordinal) || result.Length > 100000) throw new IOException("Windows 开机自启动设置返回了无效结果。");
                return Encoding.UTF8.GetString(Convert.FromBase64String(result.Substring(4)));
            }
#endif
        }

        // Query never calls registration/deletion. Mutations compare the actual
        // task XML with the validated snapshot, then use create OR update only.
        internal const string SchedulerScript = @"
$ErrorActionPreference='Stop';$service=$null;$folder=$null;$task=$null;$registered=$null;$failed=$false
function Encode([string]$value) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) }
function XmlHash([string]$value) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($value))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
try {
    $service=New-Object -ComObject 'Schedule.Service';$service.Connect();$folder=$service.GetFolder('\')
    try { $task=$folder.GetTask($name) }
    catch {
        $errorValue=$_.Exception
        while ($errorValue.InnerException) { $errorValue=$errorValue.InnerException }
        if ($errorValue.HResult -ne -2147024894) { throw }
    }
    $current=if ($null -eq $task) { $null } else { [string]$task.Xml }
    if ($operation -eq 'query') { }
    elseif ($operation -eq 'enable' -or $operation -eq 'disable') {
        $actual=if ($null -eq $current) { '' } else { XmlHash $current }
        if ($actual -cne $expected) { throw '启动任务已发生变化，请重新打开设置后重试。' }
        if ($operation -eq 'disable') {
            if ($null -ne $task) { $folder.DeleteTask($name,0) }
            $current=$null
        } else {
            $flags=if ($null -eq $task) { 34 } else { 36 }
            $definition=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
            $registered=$folder.RegisterTask($name,$definition,$flags,$sid,$null,3,$null)
            $current=[string]$registered.Xml
        }
    } else { throw '无效的启动设置操作。' }
    if ($null -eq $current) { [Console]::Write('ABSENT') } else { [Console]::Write('XML|'+(Encode $current)) }
} catch { $failed=$true;[Console]::Write('ERROR|'+(Encode $_.Exception.Message)) }
finally {
    foreach ($item in @($registered,$task,$folder,$service)) {
        if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) }
    }
}
if ($failed) { exit 1 }
";
    }
}
