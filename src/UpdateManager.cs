// Signed UI-only updates. .NET Framework 4.8 / C# 5; no external packages.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;

namespace DeltaResolveAccelerator
{
    public static class UpdateManager
    {
        private const string Repository = "QifengKuang/DeltaResolveAccelerator";
        private const string AppMutex = @"Local\DeltaResolveAccelerator-1";
        private const long MaxPackage = 32 * 1024 * 1024;
        private static readonly string[] AllowedFiles = { "Accelerator.exe", "Accelerator.exe.config" };
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 256 * 1024 };
#if UPDATE_TESTS
        internal static Func<string, int, byte[]> TestDownload;
        internal static string TestPublicKey;
        internal static string TestVersion;
        internal static string TestAppMutex;
        internal static Func<bool> TestBackendStopped;
        internal static Action<string> TestFault;
#endif

        public static bool AutomaticChecksEnabled(string root)
        {
            try { return !File.Exists(Path.Combine(UpdateRoot(root), "automatic.disabled")); }
            catch { return false; }
        }

        public static void SetAutomaticChecksEnabled(string root, bool enabled)
        {
            string directory = UpdateRoot(root);
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "automatic.disabled");
            GuardPath(path);
            if (enabled) { if (File.Exists(path)) File.Delete(path); }
            else AtomicText(path, "自动检查已关闭。仍可在设置中手动检查更新。\r\n");
        }

        public static string ReadStatus(string root)
        {
            try
            {
                string path = Path.Combine(UpdateRoot(root), "status.txt");
                GuardPath(path);
                if (File.Exists(path)) return ReadSmallText(path, 4096).Trim();
            }
            catch { }
            return "尚未检查更新";
        }

        public static void CheckInBackground(string root)
        {
            if (!AutomaticChecksEnabled(root)) return;
            ThreadPool.QueueUserWorkItem(delegate { RunAutomaticCheck(root); });
        }

        public static void RunAutomaticCheck(string root)
        {
            if (!AutomaticChecksEnabled(root)) return;
            try
            {
                    string stamp = Path.Combine(UpdateRoot(root), "last-check.txt");
                    GuardPath(stamp);
                    DateTime checkedAt;
                    if (File.Exists(stamp) && DateTime.TryParse(ReadSmallText(stamp, 128), CultureInfo.InvariantCulture,
                        DateTimeStyles.RoundtripKind, out checkedAt) && DateTime.UtcNow - checkedAt.ToUniversalTime() < TimeSpan.FromHours(6)) return;
                CheckNow(root);
            }
            catch { }
        }

        public static bool CheckNow(string root)
        {
            try
            {
                root = NormalizeRoot(root);
                using (Mutex gate = OpenUpdateMutex(root))
                {
                    if (!Acquire(gate, 0)) return false;
                    try
                    {
                        string directory = UpdateRoot(root);
                        Directory.CreateDirectory(directory);
                        WriteStatus(root, "正在检查官方更新…");
                        byte[] manifestBytes, signature;
                        Manifest manifest = ReadPublishedManifest(out manifestBytes, out signature);
                        Version current = CurrentVersion(root);
                        Version incoming = ParseVersion(manifest.version);
                        if (incoming <= current) { CompleteCheck(root, "当前已是最新版本（" + DisplayVersion(current) + "）。"); return false; }
                        string pending = Path.Combine(directory, "pending");
                        if (File.Exists(Path.Combine(pending, "manifest.json")))
                        {
                            try
                            {
                                Manifest previous = ReadManifest(pending);
                                ValidateExtractedFiles(pending, previous);
                                if (ParseVersion(previous.version) >= incoming) { CompleteCheck(root, "版本 " + previous.version + " 已准备好，下次启动时更新。"); return true; }
                            }
                            catch { }
                        }
                        WriteStatus(root, "正在下载版本 " + manifest.version + "…");
                        byte[] package = Download(manifest.packageUrl, (int)MaxPackage);
                        if (package.LongLength != manifest.packageSize || !HashMatches(package, manifest.packageSha256)) throw new InvalidDataException("更新包校验失败");
                        string staging = Path.Combine(directory, "staging");
                        ClearKnownDirectory(staging, true);
                        Directory.CreateDirectory(staging);
                        ExtractVerified(package, staging, manifest);
                        AtomicBytes(Path.Combine(staging, "manifest.json"), manifestBytes);
                        AtomicBytes(Path.Combine(staging, "manifest.sig"), signature);
                        ClearKnownDirectory(pending, true);
                        Directory.Move(staging, pending);
                        CompleteCheck(root, "版本 " + manifest.version + " 已准备好，下次启动时更新。");
                        return true;
                    }
                    finally { gate.ReleaseMutex(); }
                }
            }
            catch (Exception error)
            {
                SafeStatus(root, "更新检查未完成，现有版本仍可使用。" + FriendlyError(error));
                return false;
            }
        }

        // Called only by the stable launcher before starting the application.
        // Both the app mutex and the install-specific update mutex remain held during replacement.
        public static bool ApplyPending(string root)
        {
            try
            {
                root = NormalizeRoot(root);
                using (Mutex gate = OpenUpdateMutex(root))
                {
                    if (!Acquire(gate, 500)) return false;
                    try
                    {
                        string applicationMutexName = AppMutex;
#if UPDATE_TESTS
                        if (TestAppMutex != null) applicationMutexName = TestAppMutex;
#endif
                        using (Mutex application = new Mutex(false, applicationMutexName))
                        {
                            if (!Acquire(application, 0)) { SafeStatus(root, "更新已准备好；关闭加速器后，下次启动时安装。"); return false; }
                            try
                            {
                                string directory = UpdateRoot(root);
                                string pending = Path.Combine(directory, "pending");
                                string transaction = Path.Combine(directory, "transaction");
                                if (!File.Exists(Path.Combine(transaction, "journal.json")) && !Directory.Exists(pending)) return false;
                                if (!BackendStopped(root)) { SafeStatus(root, "连接或后台进程仍在运行，更新保留到安全退出后安装。"); return false; }
                                Recover(root);
                                if (!Directory.Exists(pending)) return false;
                                Manifest manifest = ReadManifest(pending);
                                if (ParseVersion(manifest.version) <= CurrentVersion(root)) { ClearKnownDirectory(pending, true); return false; }
                                ValidateExtractedFiles(pending, manifest);
                                ClearKnownDirectory(transaction, true);
                                Directory.CreateDirectory(transaction);
                                Journal journal = new Journal { version = manifest.version, entries = new List<JournalEntry>(), committed = false };
                                foreach (ManifestFile entry in manifest.files)
                                {
                                    string target = Path.Combine(root, entry.name);
                                    GuardPath(target);
                                    bool exists = File.Exists(target);
                                    string originalHash = null;
                                    if (exists)
                                    {
                                        originalHash = HashFile(target);
                                        File.Copy(target, Path.Combine(transaction, entry.name), false);
                                        if (HashFile(Path.Combine(transaction, entry.name)) != originalHash) throw new IOException("备份校验失败");
                                    }
                                    journal.entries.Add(new JournalEntry { name = entry.name, existed = exists, oldSha256 = originalHash, newSha256 = entry.sha256.ToLowerInvariant() });
                                }
                                AtomicText(Path.Combine(transaction, "journal.json"), Serialize(journal));
                                Fault("journal-written");
                                try
                                {
                                    foreach (ManifestFile entry in manifest.files)
                                    {
                                        ReplaceFrom(Path.Combine(pending, entry.name), Path.Combine(root, entry.name));
                                        if (HashFile(Path.Combine(root, entry.name)) != entry.sha256.ToLowerInvariant()) throw new IOException("替换后校验失败");
                                        Fault("replaced:" + entry.name);
                                    }
                                    journal.committed = true;
                                    AtomicText(Path.Combine(transaction, "journal.json"), Serialize(journal));
                                    Fault("committed");
                                    ClearKnownDirectory(transaction, true);
                                    ClearKnownDirectory(pending, true);
                                    SafeStatus(root, "已更新到版本 " + manifest.version + "。");
                                    return true;
                                }
                                catch
                                {
                                    Recover(root);
                                    throw;
                                }
                            }
                            finally { application.ReleaseMutex(); }
                        }
                    }
                    finally { gate.ReleaseMutex(); }
                }
            }
            catch (Exception error)
            {
                SafeStatus(root, "更新安装未完成，已保留恢复记录。" + FriendlyError(error));
                return false;
            }
        }

        public static bool IsLaunchSafe(string root)
        {
            try { return !File.Exists(Path.Combine(UpdateRoot(root), "transaction", "journal.json")); }
            catch { return false; }
        }

        private static void Recover(string root)
        {
            string transaction = Path.Combine(UpdateRoot(root), "transaction");
            string journalPath = Path.Combine(transaction, "journal.json");
            GuardPath(journalPath);
            if (!File.Exists(journalPath)) { if (Directory.Exists(transaction)) ClearKnownDirectory(transaction, true); return; }
            Journal journal = Deserialize<Journal>(File.ReadAllBytes(journalPath));
            if (journal == null || journal.entries == null || journal.entries.Count != AllowedFiles.Length) throw new InvalidDataException("更新恢复记录无效");
            HashSet<string> names = new HashSet<string>(StringComparer.Ordinal);
            bool installed = journal.committed;
            foreach (JournalEntry entry in journal.entries)
            {
                if (!IsAllowed(entry.name) || !names.Add(entry.name) || !ValidHash(entry.newSha256) || (entry.existed && !ValidHash(entry.oldSha256))) throw new InvalidDataException("更新恢复记录无效");
                string target = Path.Combine(root, entry.name);
                GuardPath(target);
                if (!File.Exists(target) || HashFile(target) != entry.newSha256) installed = false;
            }
            if (!installed)
            {
                bool alreadyRestored = true;
                foreach (JournalEntry entry in journal.entries)
                {
                    string target = Path.Combine(root, entry.name);
                    if (entry.existed ? !File.Exists(target) || HashFile(target) != entry.oldSha256 : File.Exists(target)) alreadyRestored = false;
                }
                // Verify every backup before changing any target. An interrupted rollback is repeatable.
                if (!alreadyRestored)
                {
                    foreach (JournalEntry entry in journal.entries)
                        if (entry.existed && HashFile(Path.Combine(transaction, entry.name)) != entry.oldSha256) throw new InvalidDataException("恢复备份校验失败");
                    foreach (JournalEntry entry in journal.entries)
                    {
                        string target = Path.Combine(root, entry.name);
                        if (entry.existed) ReplaceFrom(Path.Combine(transaction, entry.name), target);
                        else if (File.Exists(target)) File.Delete(target);
                    }
                }
                foreach (JournalEntry entry in journal.entries)
                    if (entry.existed ? HashFile(Path.Combine(root, entry.name)) != entry.oldSha256 : File.Exists(Path.Combine(root, entry.name))) throw new IOException("旧版本恢复未完成");
                SafeStatus(root, "上次更新未完成，已恢复可用版本。");
            }
            ClearKnownDirectory(transaction, true);
        }

        private static bool BackendStopped(string root)
        {
#if UPDATE_TESTS
            if (TestBackendStopped != null) return TestBackendStopped();
#endif
            // Same absent-status default as backend Get-MnaUiStatus. Unknown/error states do not authorize replacement.
            string backend = Path.Combine(root, "backend");
            string status = Path.Combine(backend, "results", "ui-status.json");
            GuardPath(status);
            if (File.Exists(status))
            {
                Dictionary<string, object> state = Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetBytes(ReadSmallText(status, 128 * 1024)));
                object phase;
                if (state == null || !state.TryGetValue("phase", out phase) || !String.Equals(Convert.ToString(phase), "stopped", StringComparison.OrdinalIgnoreCase)) return false;
            }
            string record = Path.Combine(backend, "private", "ui-worker.json");
            GuardPath(record);
            if (File.Exists(record))
            {
                Dictionary<string, object> worker = Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetBytes(ReadSmallText(record, 128 * 1024)));
                if (RecordedWorkerMayBeRunning(worker)) return false;
            }
            foreach (string name in new[] { "linkboost", "linkboost-core", "multipath-helper", "mp-speeder" })
            {
                Process[] processes = Process.GetProcessesByName(name);
                try { if (processes.Length != 0) return false; }
                finally { foreach (Process process in processes) process.Dispose(); }
            }
            return true;
        }

        internal static bool RecordedWorkerMayBeRunning(Dictionary<string, object> worker)
        {
            object value, createdValue; int pid; DateTimeOffset recordedCreation;
            if (worker == null || !worker.TryGetValue("WorkerPid", out value) || !Int32.TryParse(Convert.ToString(value), out pid) || pid < 1) return true;
            using (SafeFileHandle process = NativePaths.OpenProcess(0x1000, false, pid))
            {
                if (process.IsInvalid) return Marshal.GetLastWin32Error() != 87; // Missing PID is proof of exit; access denied is not.
                if (!worker.TryGetValue("WorkerCreatedUtc", out createdValue) || !DateTimeOffset.TryParse(Convert.ToString(createdValue), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out recordedCreation)) return true;
                long created, exited, kernel, user;
                if (!NativePaths.GetProcessTimes(process, out created, out exited, out kernel, out user)) return true;
                // A PID reused by an unrelated process must not indefinitely block an otherwise stopped app.
                if (DateTime.FromFileTimeUtc(created).Ticks != recordedCreation.UtcDateTime.Ticks) return false;
                uint exitCode;
                if (!NativePaths.GetExitCodeProcess(process, out exitCode)) return true;
                return exitCode == 259;
            }
        }

        private static Manifest ReadManifest(string directory)
        {
            string manifest = Path.Combine(directory, "manifest.json"), signature = Path.Combine(directory, "manifest.sig");
            GuardPath(manifest); GuardPath(signature);
            if (new FileInfo(manifest).Length > 64 * 1024 || new FileInfo(signature).Length > 1024) throw new InvalidDataException("更新清单过大");
            return ValidateManifest(File.ReadAllBytes(manifest), File.ReadAllBytes(signature));
        }

        private static Manifest ValidateManifest(byte[] bytes, byte[] signature)
        {
            if (bytes == null || bytes.Length > 64 * 1024 || signature == null || signature.Length > 1024) throw new InvalidDataException("更新签名无效");
            string publicKey = UpdatePublicKey.Xml;
#if UPDATE_TESTS
            if (TestPublicKey != null) publicKey = TestPublicKey;
#endif
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider())
            {
                rsa.PersistKeyInCsp = false;
                rsa.FromXmlString(publicKey);
                if (!rsa.VerifyData(bytes, CryptoConfig.MapNameToOID("SHA256"), signature)) throw new InvalidDataException("更新签名无效");
            }
            Manifest manifest = Deserialize<Manifest>(bytes);
            if (manifest == null || manifest.files == null || manifest.files.Count != AllowedFiles.Length || !ValidHash(manifest.packageSha256) || manifest.packageSize < 1 || manifest.packageSize > MaxPackage) throw new InvalidDataException("更新清单无效");
            ParseVersion(manifest.version);
            ValidateReleaseUrl(manifest.packageUrl);
            HashSet<string> names = new HashSet<string>(StringComparer.Ordinal);
            foreach (ManifestFile file in manifest.files)
                if (file == null || !IsAllowed(file.name) || !names.Add(file.name) || !ValidHash(file.sha256) || file.size < 1 || file.size > MaxPackage) throw new InvalidDataException("更新文件清单无效");
            return manifest;
        }

        private static void ExtractVerified(byte[] package, string directory, Manifest manifest)
        {
            using (MemoryStream stream = new MemoryStream(package, false))
            using (ZipArchive zip = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                if (zip.Entries.Count != AllowedFiles.Length) throw new InvalidDataException("更新包文件数量无效");
                HashSet<string> extracted = new HashSet<string>(StringComparer.Ordinal);
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    if (!IsAllowed(entry.FullName) || !extracted.Add(entry.FullName) || ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000) throw new InvalidDataException("更新包路径无效");
                    ManifestFile declared = manifest.files.Find(delegate(ManifestFile item) { return item.name == entry.FullName; });
                    if (declared == null || entry.Length != declared.size) throw new InvalidDataException("更新文件大小无效");
                    string target = Path.Combine(directory, entry.FullName);
                    GuardPath(target);
                    using (Stream source = entry.Open())
                    using (FileStream destination = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        byte[] buffer = new byte[32768]; int read; long written = 0;
                        while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            written += read;
                            if (written > declared.size) throw new InvalidDataException("更新文件超出大小限制");
                            destination.Write(buffer, 0, read);
                        }
                        if (written != declared.size) throw new InvalidDataException("更新文件不完整");
                        destination.Flush(true);
                    }
                }
            }
            ValidateExtractedFiles(directory, manifest);
        }

        private static void ValidateExtractedFiles(string directory, Manifest manifest)
        {
            foreach (ManifestFile file in manifest.files)
            {
                string path = Path.Combine(directory, file.name);
                GuardPath(path);
                if (!File.Exists(path) || new FileInfo(path).Length != file.size || HashFile(path) != file.sha256.ToLowerInvariant()) throw new InvalidDataException("已下载文件校验失败");
            }
            FileVersionInfo executable = FileVersionInfo.GetVersionInfo(Path.Combine(directory, "Accelerator.exe"));
            Version fileVersion = new Version(executable.FileMajorPart, executable.FileMinorPart, executable.FileBuildPart, executable.FilePrivatePart);
            if (fileVersion != ParseVersion(manifest.version)) throw new InvalidDataException("主程序版本与签名清单不一致");
        }

        private static byte[] Download(string url, int maximum)
        {
#if UPDATE_TESTS
            if (TestDownload != null) return TestDownload(url, maximum);
#endif
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            Uri current = new Uri(url);
            for (int redirects = 0; redirects < 6; redirects++)
            {
                ValidateDownloadUrl(current);
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(current);
                request.Method = "GET";
                request.UserAgent = "DeltaResolveAccelerator-Updater/1.1.0";
                request.Accept = "application/octet-stream, application/vnd.github+json";
                request.AllowAutoRedirect = false;
                request.Timeout = 12000;
                request.ReadWriteTimeout = 15000;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    int status = (int)response.StatusCode;
                    if (status >= 300 && status < 400) { current = new Uri(current, response.Headers["Location"]); continue; }
                    if (status != 200 || response.ContentLength > maximum) throw new InvalidDataException("更新下载响应无效");
                    using (Stream input = response.GetResponseStream())
                    using (MemoryStream output = new MemoryStream())
                    {
                        byte[] buffer = new byte[32768]; int count;
                        while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            if (output.Length + count > maximum) throw new InvalidDataException("更新下载超过大小限制");
                            output.Write(buffer, 0, count);
                        }
                        return output.ToArray();
                    }
                }
            }
            throw new InvalidDataException("更新下载重定向过多");
        }

        private static Manifest ReadPublishedManifest(out byte[] manifestBytes, out byte[] signature)
        {
            string feed = "https://raw.githubusercontent.com/" + Repository + "/updates/stable/";
            try
            {
                // The signed stable branch is authoritative. An older Release must not mask a newer feed deployment.
                manifestBytes = Download(feed + "delta-ui-manifest.json", 64 * 1024);
                signature = Download(feed + "delta-ui-manifest.sig", 1024);
                return ValidateManifest(manifestBytes, signature);
            }
            catch (WebException) { }
            string manifestUrl, signatureUrl;
            ResolveRelease(out manifestUrl, out signatureUrl);
            manifestBytes = Download(manifestUrl, 64 * 1024);
            signature = Download(signatureUrl, 1024);
            return ValidateManifest(manifestBytes, signature);
        }

        private static void ResolveRelease(out string manifestUrl, out string signatureUrl)
        {
            manifestUrl = null; signatureUrl = null;
            try
            {
                ReleaseInfo release = Deserialize<ReleaseInfo>(Download("https://api.github.com/repos/" + Repository + "/releases/latest", 192 * 1024));
                if (release != null && !release.draft && !release.prerelease && release.assets != null)
                    foreach (ReleaseAsset asset in release.assets)
                    {
                        if (asset.name == "delta-ui-manifest.json") { if (manifestUrl != null) throw new InvalidDataException("重复清单"); manifestUrl = asset.browser_download_url; }
                        if (asset.name == "delta-ui-manifest.sig") { if (signatureUrl != null) throw new InvalidDataException("重复签名"); signatureUrl = asset.browser_download_url; }
                    }
                if (manifestUrl != null && signatureUrl != null) { ValidateReleaseUrl(manifestUrl); ValidateReleaseUrl(signatureUrl); return; }
            }
            catch (WebException) { }
            throw new WebException("官方稳定更新暂时不可用");
        }

        private static void ValidateReleaseUrl(string url)
        {
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != "https" || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.Query.Length != 0 || uri.AbsolutePath.Contains("%")) throw new InvalidDataException("更新地址不属于官方发布页");
            if (uri.Host == "github.com" && uri.AbsolutePath.StartsWith("/" + Repository + "/releases/download/", StringComparison.Ordinal)) return;
            string prefix = "/" + Repository + "/updates/";
            if (uri.Host == "raw.githubusercontent.com")
            {
                if (uri.AbsolutePath == prefix + "stable/delta-ui-manifest.json" || uri.AbsolutePath == prefix + "stable/delta-ui-manifest.sig") return;
                Match package = Regex.Match(uri.AbsolutePath, "^" + Regex.Escape(prefix) + @"packages/(\d{1,5}\.\d{1,5}\.\d{1,5}(?:\.\d{1,5})?)/delta-ui-\1\.zip$");
                if (package.Success) return;
            }
            throw new InvalidDataException("更新地址不属于官方发布页");
        }

        private static void ValidateDownloadUrl(Uri uri)
        {
            if (uri.Scheme != "https" || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0) throw new InvalidDataException("更新下载地址无效");
            if (uri.Host == "api.github.com" && uri.AbsolutePath == "/repos/" + Repository + "/releases/latest" && uri.Query.Length == 0) return;
            if (uri.Host == "github.com") { ValidateReleaseUrl(uri.AbsoluteUri); return; }
            if (uri.Host == "raw.githubusercontent.com") { ValidateReleaseUrl(uri.AbsoluteUri); return; }
            if (uri.Host == "release-assets.githubusercontent.com" || uri.Host == "objects.githubusercontent.com" || uri.Host == "github-releases.githubusercontent.com") return;
            throw new InvalidDataException("更新下载地址不在允许列表中");
        }

        private static Version CurrentVersion(string root)
        {
#if UPDATE_TESTS
            if (TestVersion != null) return ParseVersion(TestVersion);
#endif
            string path = Path.Combine(root, "Accelerator.exe");
            GuardPath(path);
            if (!File.Exists(path)) return new Version(0, 0, 0, 0);
            FileVersionInfo info = FileVersionInfo.GetVersionInfo(path);
            return new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
        }

        private static Version ParseVersion(string value)
        {
            if (value == null || !Regex.IsMatch(value, @"^\d{1,5}\.\d{1,5}\.\d{1,5}(\.\d{1,5})?$")) throw new InvalidDataException("更新版本格式无效");
            Version parsed = new Version(value);
            return new Version(parsed.Major, parsed.Minor, parsed.Build, Math.Max(0, parsed.Revision));
        }

        private static string DisplayVersion(Version value) { return value.Major + "." + value.Minor + "." + value.Build; }
        private static bool IsAllowed(string name) { return Array.IndexOf(AllowedFiles, name) >= 0; }
        private static bool ValidHash(string hash) { return hash != null && Regex.IsMatch(hash, "^[a-fA-F0-9]{64}$"); }
        private static bool HashMatches(byte[] bytes, string hash) { return Hash(bytes) == hash.ToLowerInvariant(); }
        private static string Hash(byte[] bytes) { using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
        private static string HashFile(string path)
        {
            GuardPath(path);
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }

        private static T Deserialize<T>(byte[] bytes) { lock (Json) return Json.Deserialize<T>(new UTF8Encoding(false, true).GetString(bytes).TrimStart('\ufeff')); }
        private static string Serialize(object value) { lock (Json) return Json.Serialize(value); }
        private static string NormalizeRoot(string root)
        {
            if (String.IsNullOrWhiteSpace(root)) throw new ArgumentException("安装路径为空");
            string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (!Directory.Exists(full) || String.Equals(full, Path.GetPathRoot(full).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) throw new IOException("安装路径无效");
            GuardPath(full);
            return full;
        }
        private static string UpdateRoot(string root)
        {
            string path = Path.Combine(NormalizeRoot(root), "updates");
            GuardPath(path);
            return path;
        }
        internal static void GuardPath(string path)
        {
            string current = Path.GetFullPath(path);
            if ((File.Exists(current) || Directory.Exists(current)) && !String.Equals(current.TrimEnd('\\'), PhysicalPath(current).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) throw new IOException("安装目录被系统重定向，已停止操作；请修复安装路径");
            while (!String.IsNullOrEmpty(current))
            {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("更新路径包含链接，已停止替换");
                string parent = Path.GetDirectoryName(current);
                if (parent == current) break;
                current = parent;
            }
        }
        internal static string PhysicalPath(string path)
        {
            using (SafeFileHandle handle = NativePaths.CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
            {
                if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                StringBuilder buffer = new StringBuilder(32768);
                uint count = NativePaths.GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (count == 0 || count >= buffer.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                string actual = buffer.ToString();
                if (actual.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + actual.Substring(8);
                if (actual.StartsWith(@"\\?\", StringComparison.Ordinal)) return actual.Substring(4);
                return actual;
            }
        }
        internal static Mutex OpenUpdateMutex(string root) { return new Mutex(false, @"Local\DeltaResolveUpdate-" + Hash(Encoding.UTF8.GetBytes(NormalizeRoot(root).ToUpperInvariant())).Substring(0, 24)); }
        internal static bool Acquire(Mutex mutex, int milliseconds) { try { return mutex.WaitOne(milliseconds); } catch (AbandonedMutexException) { return true; } }
        private static void AtomicText(string path, string text) { AtomicBytes(path, new UTF8Encoding(false).GetBytes(text)); }
        private static void AtomicBytes(string path, byte[] bytes)
        {
            GuardPath(path);
            string temporary = path + ".new";
            GuardPath(temporary);
            using (FileStream stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None)) { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
            if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
        }
        private static void ReplaceFrom(string source, string destination)
        {
            GuardPath(source); GuardPath(destination);
            string temporary = destination + ".update-new";
            GuardPath(temporary);
            using (FileStream input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (FileStream output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None)) { input.CopyTo(output); output.Flush(true); }
            if (File.Exists(destination)) File.Replace(temporary, destination, null); else File.Move(temporary, destination);
        }
        private static void ClearKnownDirectory(string directory, bool remove)
        {
            GuardPath(directory);
            if (!Directory.Exists(directory)) return;
            foreach (string child in Directory.GetFileSystemEntries(directory))
            {
                GuardPath(child);
                string name = Path.GetFileName(child);
                if (Directory.Exists(child) || !(IsAllowed(name) || name == "manifest.json" || name == "manifest.sig" || name == "journal.json" || name == "manifest.json.new" || name == "manifest.sig.new" || name == "journal.json.new")) throw new IOException("更新目录含未知文件，已保留原文件");
            }
            foreach (string child in Directory.GetFiles(directory)) File.Delete(child);
            if (remove) Directory.Delete(directory, false);
        }
        private static string ReadSmallText(string path, int maximum)
        {
            GuardPath(path);
            if (new FileInfo(path).Length > maximum) throw new InvalidDataException("本地状态文件过大");
            return File.ReadAllText(path, Encoding.UTF8);
        }
        private static void WriteStatus(string root, string value) { string directory = UpdateRoot(root); Directory.CreateDirectory(directory); AtomicText(Path.Combine(directory, "status.txt"), value + "\r\n"); }
        private static void CompleteCheck(string root, string value) { WriteStatus(root, value); AtomicText(Path.Combine(UpdateRoot(root), "last-check.txt"), DateTime.UtcNow.ToString("o")); }
        private static void SafeStatus(string root, string value) { try { WriteStatus(root, value); } catch { } }
        private static string FriendlyError(Exception error)
        {
            if (error is WebException) return " 网络暂时不可用，请稍后重试。";
            if (error is UnauthorizedAccessException) return " 安装目录暂时不可写。";
            if (error is InvalidDataException || error is CryptographicException) return " 文件或签名校验未通过。";
            return " 可在设置中重新检查。";
        }
        private static void Fault(string point)
        {
#if UPDATE_TESTS
            if (TestFault != null) TestFault(point);
#endif
        }

        private sealed class ReleaseInfo { public bool draft { get; set; } public bool prerelease { get; set; } public List<ReleaseAsset> assets { get; set; } }
        private sealed class ReleaseAsset { public string name { get; set; } public string browser_download_url { get; set; } }
        private sealed class Manifest { public string version { get; set; } public string packageUrl { get; set; } public string packageSha256 { get; set; } public long packageSize { get; set; } public List<ManifestFile> files { get; set; } }
        private sealed class ManifestFile { public string name { get; set; } public string sha256 { get; set; } public long size { get; set; } }
        private sealed class Journal { public string version { get; set; } public bool committed { get; set; } public List<JournalEntry> entries { get; set; } }
        private sealed class JournalEntry { public string name { get; set; } public bool existed { get; set; } public string oldSha256 { get; set; } public string newSha256 { get; set; } }
        private static class NativePaths
        {
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint length, uint flags);
            [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeFileHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int processId);
            [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetProcessTimes(SafeFileHandle process, out long created, out long exited, out long kernel, out long user);
            [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetExitCodeProcess(SafeFileHandle process, out uint exitCode);
        }
    }
}
