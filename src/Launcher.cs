using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeltaResolveAccelerator
{
    internal static class Launcher
    {
        [STAThread]
        private static void Main(string[] args)
        {
            string executable = Assembly.GetExecutingAssembly().Location;
            string root = Path.GetDirectoryName(Path.GetFullPath(executable));
            try
            {
                if (args.Length > 0 && args[0] == "--launch-check")
                {
                    if (args.Length != 3 || args[1] != "--report" || !Path.IsPathRooted(args[2])) throw new ArgumentException("诊断需要完整的报告路径");
                    string report = Path.GetFullPath(args[2]);
                    UpdateManager.GuardPath(report);
                    string app = Path.Combine(root, "Accelerator.exe");
                    string physicalRoot = UpdateManager.PhysicalPath(root), physicalLauncher = UpdateManager.PhysicalPath(executable);
                    string physicalApp = File.Exists(app) ? UpdateManager.PhysicalPath(app) : null;
                    File.WriteAllText(report, new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                        { "root", root }, { "physicalRoot", physicalRoot }, { "launcher", executable }, { "physicalLauncher", physicalLauncher }, { "physicalApp", physicalApp },
                        { "physicalPathsMatch", String.Equals(root, physicalRoot, StringComparison.OrdinalIgnoreCase) && String.Equals(executable, physicalLauncher, StringComparison.OrdinalIgnoreCase) && (physicalApp == null || String.Equals(app, physicalApp, StringComparison.OrdinalIgnoreCase)) },
                        { "appExists", File.Exists(app) }, { "iconExists", File.Exists(Path.Combine(root, "DeltaResolve.ico")) },
                        { "version", File.Exists(app) ? FileVersionInfo.GetVersionInfo(app).FileVersion : null },
                        { "automaticUpdates", UpdateManager.AutomaticChecksEnabled(root) }, { "updateStatus", UpdateManager.ReadStatus(root) },
                        { "launchSafe", UpdateManager.IsLaunchSafe(root) }, { "applicationStarted", false }, { "networkStarted", false }
                    }), new UTF8Encoding(false));
                    return;
                }
                UpdateManager.GuardPath(executable);
                if (args.Length == 1 && args[0] == "--check-only") { UpdateManager.RunAutomaticCheck(root); return; }
                if (args.Length == 1 && args[0] == "--repair-shortcuts")
                {
                    using (Mutex repair = UpdateManager.OpenUpdateMutex(root))
                    {
                        if (!UpdateManager.Acquire(repair, 5000)) throw new IOException("安装或更新仍在进行，请稍后重试修复图标。");
                        try { RepairShortcuts(root, executable); }
                        finally { repair.ReleaseMutex(); }
                    }
                    return;
                }
                if (args.Length > 1 || (args.Length == 1 && args[0] != "--launch")) throw new ArgumentException("无法识别启动参数");
                bool owner;
                using (Mutex launcher = new Mutex(true, @"Local\DeltaResolveLauncher-1", out owner))
                {
                    if (!owner) return;
                    try
                    {
                        UpdateManager.ApplyPending(root);
                        if (!UpdateManager.IsLaunchSafe(root)) throw new IOException("上次更新的恢复尚未完成。请确认加速已关闭，然后重新启动。\r\n" + UpdateManager.ReadStatus(root));
                        string app = Path.Combine(root, "Accelerator.exe");
                        UpdateManager.GuardPath(app);
                        if (!File.Exists(app)) throw new FileNotFoundException("主程序文件缺失，请运行安装程序修复。", app);
                        Process.Start(new ProcessStartInfo(app) { WorkingDirectory = root, UseShellExecute = true });
                        if (UpdateManager.AutomaticChecksEnabled(root))
                        {
                            // Checking/staging cannot change running application files. This helper never shows a window.
                            try { Process.Start(new ProcessStartInfo(executable, "--check-only") { WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }); }
                            catch { }
                        }
                    }
                    finally { launcher.ReleaseMutex(); }
                }
            }
            catch (System.ComponentModel.Win32Exception error)
            {
                // Cancelling Windows' normal UAC prompt is not an application error.
                if (error.NativeErrorCode != 1223) ShowFailure(root, error);
                Environment.ExitCode = error.NativeErrorCode == 1223 ? 0 : 1;
            }
            catch (Exception error) { ShowFailure(root, error); Environment.ExitCode = 1; }
        }

        private static void ShowFailure(string root, Exception error)
        {
            try
            {
                string directory = Path.Combine(root, "updates");
                UpdateManager.GuardPath(directory);
                Directory.CreateDirectory(directory);
                File.WriteAllText(Path.Combine(directory, "launcher-error.txt"), DateTime.UtcNow.ToString("o") + "\r\n" + error.GetType().Name + "\r\n" + error.Message, new UTF8Encoding(false));
            }
            catch { }
            // No modal dialogs for diagnostics or background checks.
            string command = Environment.CommandLine;
            if (command.IndexOf("--check-only", StringComparison.Ordinal) >= 0 || command.IndexOf("--launch-check", StringComparison.Ordinal) >= 0 || command.IndexOf("--repair-shortcuts", StringComparison.Ordinal) >= 0) return;
            MessageBox.Show("加速器暂时无法启动。\r\n" + error.Message, "三角洲加速器", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static void RepairShortcuts(string root, string executable)
        {
            string icon = Path.Combine(root, "DeltaResolve.ico");
            UpdateManager.GuardPath(icon);
            if (!File.Exists(icon))
                using (Icon associated = Icon.ExtractAssociatedIcon(executable))
                using (FileStream output = new FileStream(icon, FileMode.CreateNew, FileAccess.Write)) associated.Save(output);
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            CreateShortcut(Path.Combine(desktop, "三角洲加速器.lnk"), executable, root, icon);
            CreateShortcut(Path.Combine(programs, "三角洲加速器.lnk"), executable, root, icon);
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\DeltaResolveAccelerator")) key.SetValue("InstallPath", root, RegistryValueKind.String);
            NativeMethods.SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
        }

        private static void CreateShortcut(string path, string executable, string root, string icon)
        {
            // Shortcut parent can be the user's redirected Desktop/OneDrive folder. Only the installation target must be physical.
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temporary = Path.Combine(Path.GetDirectoryName(path), ".delta-" + Guid.NewGuid().ToString("N") + ".lnk");
            object shell = null, link = null, nativeLink = null;
            try
            {
                shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true));
                link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { temporary });
                SetProperty(link, "TargetPath", executable);
                SetProperty(link, "Arguments", "--launch");
                SetProperty(link, "WorkingDirectory", root);
                SetProperty(link, "IconLocation", icon + ",0");
                SetProperty(link, "Description", "三角洲加速器 · 稳定启动与自动更新");
                link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
                nativeLink = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
                IPersistFile file = (IPersistFile)nativeLink;
                file.Load(temporary, 0);
                IShellLinkDataList data = (IShellLinkDataList)nativeLink;
                uint flags;
                Marshal.ThrowExceptionForHR(data.GetFlags(out flags));
                // Do not follow executable file identities into update backups; elevation belongs to Accelerator.exe's manifest.
                flags = (flags | 0x00040000u | 0x00100000u) & ~0x00002000u;
                Marshal.ThrowExceptionForHR(data.SetFlags(flags));
                file.Save(temporary, true);
                if (File.Exists(path))
                {
                    string backupDirectory = Path.Combine(root, "updates", "shortcut-backups");
                    UpdateManager.GuardPath(backupDirectory);
                    Directory.CreateDirectory(backupDirectory);
                    string backupName = String.Equals(Path.GetDirectoryName(path), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), StringComparison.OrdinalIgnoreCase) ? "desktop.lnk" : "start-menu.lnk";
                    string backup = Path.Combine(backupDirectory, backupName);
                    UpdateManager.GuardPath(backup);
                    File.Copy(path, backup, true);
                    File.Replace(temporary, path, null);
                }
                else File.Move(temporary, path);
            }
            finally
            {
                if (nativeLink != null && Marshal.IsComObject(nativeLink)) Marshal.FinalReleaseComObject(nativeLink);
                if (link != null && Marshal.IsComObject(link)) Marshal.FinalReleaseComObject(link);
                if (shell != null && Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell);
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
        private static void SetProperty(object target, string name, object value) { target.GetType().InvokeMember(name, BindingFlags.SetProperty, null, target, new object[] { value }); }

        [ComImport, Guid("45E2B4AE-B1C3-11D0-B92F-00A0C90312E1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkDataList
        {
            [PreserveSig] int AddDataBlock(IntPtr data);
            [PreserveSig] int CopyDataBlock(uint signature, out IntPtr data);
            [PreserveSig] int RemoveDataBlock(uint signature);
            [PreserveSig] int GetFlags(out uint flags);
            [PreserveSig] int SetFlags(uint flags);
        }
        private static class NativeMethods
        {
            [DllImport("shell32.dll")] internal static extern void SHChangeNotify(uint eventId, uint flags, IntPtr first, IntPtr second);
        }
    }
}
