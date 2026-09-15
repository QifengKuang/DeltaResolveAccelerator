using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace DeltaResolveAccelerator
{
    internal sealed class GameLocation
    {
        internal string Path;
        internal string Platform;
        internal string Source;
    }

    // Searches installation hints only. No drive-wide recursion, junctions, or game execution.
    internal static class GameDiscovery
    {
        internal const string ExecutableName = "DeltaForceClient-Win64-Shipping.exe";
        private const int MaximumRoots = 48;
        private static readonly string[] RelativeExecutables = {
            ExecutableName,
            @"Game\DeltaForce\Binaries\Win64\" + ExecutableName,
            @"DeltaForce\Binaries\Win64\" + ExecutableName,
            @"Binaries\Win64\" + ExecutableName,
            @"Delta Force\Game\DeltaForce\Binaries\Win64\" + ExecutableName,
            @"DeltaForce\Game\DeltaForce\Binaries\Win64\" + ExecutableName,
            @"三角洲行动\Game\DeltaForce\Binaries\Win64\" + ExecutableName
        };

        internal static bool IsGameExecutable(string path)
        {
            try { return !String.IsNullOrWhiteSpace(path) && File.Exists(path) &&
                String.Equals(System.IO.Path.GetFileName(path), ExecutableName, StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        }

        internal static string DetectPlatform(string path)
        {
            string normalized = (path ?? "").Replace('/', '\\').ToLowerInvariant();
            if (normalized.Contains(@"\steamapps\common\")) return "Steam";
            if (normalized.Contains(@"\wegame\") || normalized.Contains(@"\wegameapps\") ||
                normalized.Contains(@"\tgp\")) return "WeGame";
            return "";
        }

        internal static List<string> ParseLibraryFolders(string text)
        {
            List<string> folders = new List<string>();
            if (text == null || text.Length > 1048576) return folders;
            foreach (Match match in Regex.Matches(text, "\"(?:path|[0-9]+)\"\\s*\"((?:\\\\.|[^\"\\\\])*)\""))
            {
                string value = Unescape(match.Groups[1].Value);
                if (IsLocalPath(value)) AddDistinct(folders, value);
                if (folders.Count >= MaximumRoots) break;
            }
            return folders;
        }

        internal static string ParseInstallDirectory(string text)
        {
            if (text == null || text.Length > 1048576) return "";
            Match match = Regex.Match(text, "\"installdir\"\\s*\"((?:\\\\.|[^\"\\\\])*)\"", RegexOptions.IgnoreCase);
            string value = match.Success ? Unescape(match.Groups[1].Value) : "";
            if (value.Length == 0 || value == "." || value == ".." || value.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return "";
            return value;
        }

        private static string Unescape(string text) { return text.Replace(@"\\", @"\").Replace("\\\"", "\""); }
        private static bool IsLocalPath(string path)
        {
            try { return !String.IsNullOrWhiteSpace(path) && Path.IsPathRooted(path) &&
                path.Length >= 3 && Char.IsLetter(path[0]) && path[1] == ':' && (path[2] == '\\' || path[2] == '/'); }
            catch { return false; }
        }
        private static bool IsSafeDirectory(string path)
        {
            if (!IsLocalPath(path)) return false;
            try
            {
                DirectoryInfo directory = new DirectoryInfo(path);
                if (!directory.Exists) return false;
                for (; directory != null; directory = directory.Parent)
                    if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) return false;
                return true;
            }
            catch { return false; }
        }

        private static void AddDistinct(List<string> paths, string path)
        {
            if (!IsLocalPath(path)) return;
            try
            {
                string full = Path.GetFullPath(path);
                if (!paths.Exists(delegate(string old) { return String.Equals(old, full, StringComparison.OrdinalIgnoreCase); })) paths.Add(full);
            }
            catch { }
        }
        private static void AddLocation(List<GameLocation> found, string path, string platform, string source)
        {
            if (!IsGameExecutable(path) || !IsSafeDirectory(Path.GetDirectoryName(path))) return;
            try { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return; } catch { return; }
            string full = Path.GetFullPath(path);
            string detected = DetectPlatform(full);
            if (detected.Length > 0) platform = detected;
            GameLocation existing = found.Find(delegate(GameLocation item) { return String.Equals(item.Path, full, StringComparison.OrdinalIgnoreCase); });
            if (existing != null)
            {
                if (existing.Platform.Length == 0 && !String.IsNullOrEmpty(platform)) existing.Platform = platform;
                return;
            }
            found.Add(new GameLocation { Path = full, Platform = platform ?? "", Source = source });
        }

        internal static List<GameLocation> FindInFolder(string folder, string platform)
        {
            List<GameLocation> found = new List<GameLocation>();
            ScanFolder(folder, platform, "所选文件夹", found, Stopwatch.StartNew());
            return found;
        }

        private static void ScanFolder(string folder, string platform, string source, List<GameLocation> found, Stopwatch clock)
        {
            if (!IsSafeDirectory(folder) || clock.ElapsedMilliseconds > 5000) return;
            string full = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar);
            // A selected drive root is too broad; ask the user for an install folder instead.
            if (String.Equals(full, Path.GetPathRoot(full).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) return;
            foreach (string suffix in RelativeExecutables) AddLocation(found, Path.Combine(full, suffix), platform, source);
            Queue<KeyValuePair<string, int>> pending = new Queue<KeyValuePair<string, int>>();
            pending.Enqueue(new KeyValuePair<string, int>(full, 0));
            int visited = 0;
            while (pending.Count > 0 && visited++ < 192 && clock.ElapsedMilliseconds <= 5000 && found.Count < 12)
            {
                KeyValuePair<string, int> next = pending.Dequeue();
                if (!IsSafeDirectory(next.Key)) continue;
                AddLocation(found, Path.Combine(next.Key, ExecutableName), platform, source);
                if (next.Value >= 5) continue;
                try
                {
                    int siblings = 0;
                    foreach (string child in Directory.EnumerateDirectories(next.Key))
                    {
                        if (++siblings > 96 || pending.Count >= 192) break;
                        if (IsSafeDirectory(child)) pending.Enqueue(new KeyValuePair<string, int>(child, next.Value + 1));
                    }
                }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }

        internal static List<GameLocation> Discover()
        {
            List<GameLocation> found = new List<GameLocation>();
            Stopwatch clock = Stopwatch.StartNew();
            try
            {
                Process[] processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(ExecutableName));
                foreach (Process process in processes)
                {
                    using (process)
                    {
                        try { string path = process.MainModule.FileName; AddLocation(found, path, DetectPlatform(path), "运行中的游戏"); } catch { }
                    }
                }
            }
            catch { }
            List<string> steamRoots = new List<string>();
            AddRegistryValue(steamRoots, @"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath");
            AddRegistryValue(steamRoots, @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath");
            AddRegistryValue(steamRoots, @"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath");
            AddDistinct(steamRoots, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam"));
            foreach (string steam in steamRoots.ToArray())
            {
                string text = ReadSmallFile(Path.Combine(steam, "steamapps", "libraryfolders.vdf"));
                foreach (string library in ParseLibraryFolders(text)) if (steamRoots.Count < MaximumRoots) AddDistinct(steamRoots, library);
            }
            foreach (string library in steamRoots)
            {
                if (clock.ElapsedMilliseconds > 5000) break;
                string apps = Path.Combine(library, "steamapps"), common = Path.Combine(apps, "common");
                foreach (string name in new string[] { "Delta Force", "DeltaForce", "三角洲行动" })
                    ScanFolder(Path.Combine(common, name), "Steam", "Steam 游戏库", found, clock);
                if (!IsSafeDirectory(apps)) continue;
                try
                {
                    int count = 0;
                    foreach (string manifest in Directory.EnumerateFiles(apps, "appmanifest_*.acf"))
                    {
                        if (++count > 512 || clock.ElapsedMilliseconds > 5000) break;
                        string text = ReadSmallFile(manifest), install = ParseInstallDirectory(text);
                        if (install.Length == 0 || (!Regex.IsMatch(text, "delta[ _-]*force|三角洲", RegexOptions.IgnoreCase))) continue;
                        ScanFolder(Path.Combine(common, install), "Steam", "Steam 游戏清单", found, clock);
                    }
                }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            List<string> wegameRoots = new List<string>();
            foreach (string key in new string[] { @"HKEY_CURRENT_USER\Software\Tencent\WeGame", @"HKEY_LOCAL_MACHINE\SOFTWARE\Tencent\WeGame",
                @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Tencent\WeGame", @"HKEY_CURRENT_USER\Software\Tencent\TGP",
                @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Tencent\TGP" })
                foreach (string name in new string[] { "InstallPath", "InstallLocation", "InstallDir", "GamePath" }) AddRegistryValue(wegameRoots, key, name);
            foreach (string launcherFolder in wegameRoots.ToArray())
            {
                try
                {
                    string parent = Path.GetDirectoryName(launcherFolder.TrimEnd('\\', '/'));
                    if (!String.IsNullOrEmpty(parent) && wegameRoots.Count < MaximumRoots) AddDistinct(wegameRoots, Path.Combine(parent, "WeGameApps"));
                }
                catch { }
            }
            foreach (string folder in wegameRoots)
            {
                if (clock.ElapsedMilliseconds > 5000) break;
                ScanFolder(folder, "WeGame", "WeGame 安装记录", found, clock);
            }
            List<GameLocation> uninstallRoots = ReadUninstallRoots();
            foreach (GameLocation install in uninstallRoots)
            {
                if (clock.ElapsedMilliseconds > 5000) break;
                ScanFolder(install.Path, install.Platform, "已安装游戏记录", found, clock);
            }
            return found;
        }

        private static void AddRegistryValue(List<string> roots, string key, string name)
        {
            if (roots.Count >= MaximumRoots) return;
            try { AddDistinct(roots, Convert.ToString(Registry.GetValue(key, name, null))); } catch { }
        }
        private static List<GameLocation> ReadUninstallRoots()
        {
            List<GameLocation> roots = new List<GameLocation>();
            foreach (RegistryKey hive in new RegistryKey[] { Registry.CurrentUser, Registry.LocalMachine })
                foreach (string branch in new string[] { @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" })
                {
                    try
                    {
                        using (RegistryKey entries = hive.OpenSubKey(branch))
                        {
                            if (entries == null) continue;
                            int visited = 0;
                            foreach (string entryName in entries.GetSubKeyNames())
                            {
                                if (++visited > 1024 || roots.Count >= MaximumRoots) break;
                                using (RegistryKey entry = entries.OpenSubKey(entryName))
                                {
                                    if (entry == null) continue;
                                    string title = Convert.ToString(entry.GetValue("DisplayName", ""));
                                    if (!Regex.IsMatch(title, "WeGame|腾讯游戏平台|三角洲|Delta[ _-]*Force", RegexOptions.IgnoreCase)) continue;
                                    string folder = Convert.ToString(entry.GetValue("InstallLocation", ""));
                                    if (IsLocalPath(folder)) roots.Add(new GameLocation { Path = folder,
                                        Platform = Regex.IsMatch(title, "WeGame|腾讯游戏平台", RegexOptions.IgnoreCase) ? "WeGame" : "" });
                                }
                            }
                        }
                    }
                    catch { }
                }
            return roots;
        }
        private static string ReadSmallFile(string path)
        {
            try { if (File.Exists(path) && new FileInfo(path).Length <= 1048576 && IsSafeDirectory(Path.GetDirectoryName(path))) return File.ReadAllText(path); } catch { }
            return "";
        }
    }
}
