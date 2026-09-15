// Lightweight per-user setup. Runtime and vendor SDK are deliberately not embedded.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeltaResolveAccelerator.Setup
{
    internal static class SetupProgram
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length == 2 && args[0] == "--verify-payload")
            {
                try
                {
                    string directory = Path.Combine(Path.GetFullPath(args[1]), "payload-" + Guid.NewGuid().ToString("N"));
                    Extract(directory);
                    File.WriteAllText(Path.Combine(Path.GetFullPath(args[1]), "setup-verification.json"),
                        new JavaScriptSerializer().Serialize(new { passed = true, payloadDirectory = directory, networkStarted = false }), new UTF8Encoding(false));
                }
                catch { Environment.ExitCode = 1; }
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SetupForm());
        }

        internal static readonly string[] PayloadFiles = { "Accelerator.exe", "Accelerator.exe.config", "DeltaLauncher.exe", "DeltaResolve.ico", "Install-App.ps1" };
        internal static string ExistingInstall()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\DeltaResolveAccelerator"))
            {
                string registered = key == null ? null : key.GetValue("InstallPath") as string;
                if (!String.IsNullOrWhiteSpace(registered)) return Path.GetFullPath(registered);
            }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "DeltaResolveAccelerator");
        }

        internal static void Extract(string directory)
        {
            Directory.CreateDirectory(directory);
            Dictionary<string, object> manifest;
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.manifest"))
            using (StreamReader reader = new StreamReader(input, new UTF8Encoding(false, true)))
                manifest = new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()) as Dictionary<string, object>;
            foreach (string name in PayloadFiles)
            {
                byte[] bytes;
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload." + name))
                using (MemoryStream output = new MemoryStream()) { input.CopyTo(output); bytes = output.ToArray(); }
                string actual;
                using (SHA256 hash = SHA256.Create()) actual = BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "");
                if (manifest == null || !manifest.ContainsKey(name) || !String.Equals(actual, manifest[name] as string, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("安装文件校验失败，请重新下载安装器。");
                File.WriteAllBytes(Path.Combine(directory, name), bytes);
            }
        }

        internal static string Quote(string value)
        {
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append(c); }
                else { result.Append('\\', slashes); result.Append(c); }
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly TextBox path = new TextBox();
        private readonly Label status = new Label();
        private readonly Button install = new Button();
        private readonly Button browse = new Button();
        private readonly LinkLabel details = new LinkLabel();
        private string logPath;
        private readonly string existing;
        private bool installing;
        internal SetupForm()
        {
            existing = SetupProgram.ExistingInstall();
            Text = "三角洲加速器 · 安装与修复";
            ClientSize = new Size(580, 335); StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            BackColor = Color.FromArgb(247, 249, 246); ForeColor = Color.FromArgb(33, 54, 43);
            Font = new Font("Microsoft YaHei UI", 9.5f);
            AutoScaleMode = AutoScaleMode.Dpi;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            Label title = new Label { Text = "让每次更新都更简单", Font = new Font("Microsoft YaHei UI", 20, FontStyle.Bold), AutoSize = false };
            title.SetBounds(30, 24, 520, 45); Controls.Add(title);
            Label intro = new Label { Text = "轻量更新，复用已有运行环境。\r\n保留游戏路径与设备密钥，修复桌面和开始菜单入口。", AutoSize = false };
            intro.SetBounds(32, 80, 516, 50); Controls.Add(intro);
            Label location = new Label { Text = "安装位置", AutoSize = true }; location.SetBounds(32, 147, 150, 24); Controls.Add(location);
            path.SetBounds(32, 175, 408, 29); path.Text = existing; Controls.Add(path);
            browse.Text = "选择…"; browse.SetBounds(452, 172, 96, 34); Controls.Add(browse);
            browse.Click += delegate { using (FolderBrowserDialog dialog = new FolderBrowserDialog()) { dialog.Description = "选择现有加速器安装目录"; dialog.SelectedPath = path.Text; if (dialog.ShowDialog(this) == DialogResult.OK) path.Text = dialog.SelectedPath; } };
            status.SetBounds(32, 218, 516, 42); status.ForeColor = Color.FromArgb(104, 122, 110); status.Text = "首次使用本软件的电脑，需要先准备独立设备密钥及运行环境。"; Controls.Add(status);
            install.Text = "安装 / 修复"; install.SetBounds(360, 274, 188, 40); install.FlatStyle = FlatStyle.Flat;
            install.FlatAppearance.BorderSize = 0; install.BackColor = Color.FromArgb(46, 105, 76); install.ForeColor = Color.White; Controls.Add(install);
            install.Click += async delegate { await InstallAsync(); };
            details.Text = "查看安装记录"; details.SetBounds(32, 284, 170, 26); details.Visible = false;
            details.LinkColor = Color.FromArgb(46, 105, 76); Controls.Add(details);
            details.LinkClicked += delegate { if (logPath != null && File.Exists(logPath)) Process.Start("notepad.exe", SetupProgram.Quote(logPath)); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (installing) e.Cancel = true; };
        }

        private async Task InstallAsync()
        {
            installing = true; install.Enabled = browse.Enabled = path.Enabled = false;
            try
            {
                string target = Path.GetFullPath(path.Text.Trim());
                string runtime = Path.Combine(target, "runtime", "pwsh.exe");
                if (!File.Exists(runtime))
                    throw new InvalidOperationException("请选择现有加速器安装目录。此轻量安装器复用该目录中的运行环境。");
                string work = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeltaResolveAccelerator", "Setup", Guid.NewGuid().ToString("N"));
                status.Text = "正在校验安装文件并创建备份…";
                await Task.Run(delegate
                {
                    SetupProgram.Extract(work);
                    ProcessStartInfo start = new ProcessStartInfo(runtime,
                        "-NoProfile -NonInteractive -File " + SetupProgram.Quote(Path.Combine(work, "Install-App.ps1")) +
                        " -SourceDirectory " + SetupProgram.Quote(work) + " -InstallDirectory " + SetupProgram.Quote(target));
                    start.UseShellExecute = false; start.CreateNoWindow = true; start.WindowStyle = ProcessWindowStyle.Hidden;
                    start.RedirectStandardOutput = start.RedirectStandardError = true;
                    using (Process process = Process.Start(start))
                    {
                        Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
                        process.WaitForExit(); Task.WaitAll(stdout, stderr);
                        logPath = Path.Combine(work, "installation.log");
                        File.WriteAllText(logPath, stdout.Result + Environment.NewLine + stderr.Result, new UTF8Encoding(false));
                        if (process.ExitCode != 0)
                        {
                            string error = stderr.Result;
                            if (error.IndexOf("running", StringComparison.OrdinalIgnoreCase) >= 0) throw new InvalidOperationException("加速器或后台仍在运行，请正常退出后重试。");
                            if (error.IndexOf("registered", StringComparison.OrdinalIgnoreCase) >= 0) throw new InvalidOperationException("所选位置与已登记的安装目录不同，请选择原安装位置。");
                            if (error.IndexOf("physical", StringComparison.OrdinalIgnoreCase) >= 0 || error.IndexOf("reparse", StringComparison.OrdinalIgnoreCase) >= 0) throw new InvalidOperationException("安装目录被重定向或使用了链接，请选择真实的本机目录。");
                            throw new InvalidOperationException("安装未完成，具体原因已保存。请点击“查看安装记录”。");
                        }
                    }
                });
                status.Text = "安装完成。请从桌面或开始菜单打开加速器。";
                install.Text = "已完成";
            }
            catch (Exception ex) { status.Text = ex is InvalidOperationException ? ex.Message : "安装未完成（" + ex.GetType().Name + "），请检查安装目录后重试。"; install.Enabled = true; }
            finally { installing = false; browse.Enabled = path.Enabled = true; details.Visible = logPath != null; }
        }
    }
}
