// .NET Framework 4.8 / C# 5. No external UI packages.
// References: System, System.Core, System.Drawing, System.Windows.Forms,
// System.Security, System.Web.Extensions.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeltaResolveAccelerator
{
    internal static class Program
    {
        internal const string MutexName = @"Local\DeltaResolveAccelerator-1";
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string previewPath = null, previewState = "stopped", selfTestPath = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--preview" && i + 1 < args.Length) previewPath = args[++i];
                else if (args[i] == "--preview-state" && i + 1 < args.Length) previewState = args[++i];
                else if (args[i] == "--self-test" && i + 1 < args.Length) selfTestPath = args[++i];
            }
            if (selfTestPath != null) { Environment.ExitCode = OfflineTests.Run(selfTestPath); return; }
            if (previewPath != null)
            {
                // Preview deliberately bypasses mutex, settings, credentials and backend.
                using (MainForm form = new MainForm(true, previewState))
                {
                    form.ShowInTaskbar = false;
                    form.StartPosition = FormStartPosition.Manual;
                    form.Location = new Point(-30000, -30000);
                    form.Opacity = 0;
                    form.Show();
                    Application.DoEvents();
                    string absolute = Path.GetFullPath(previewPath);
                    Directory.CreateDirectory(Path.GetDirectoryName(absolute));
                    using (Bitmap bitmap = new Bitmap(form.Width, form.Height))
                    {
                        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                        bitmap.Save(absolute, ImageFormat.Png);
                    }
                    form.Close();
                }
                return;
            }
            bool ownsMutex;
            using (Mutex mutex = new Mutex(true, MutexName, out ownsMutex))
            {
                if (!ownsMutex)
                {
                    MessageBox.Show("加速器已经打开，请使用现有窗口。", "三角洲 · 主入口优化",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                try { Application.Run(new MainForm(false, null)); }
                catch (Exception ex)
                {
                    MessageBox.Show("界面无法继续运行。\r\n错误类型：" + ex.GetType().Name,
                        "三角洲 · 主入口优化", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally { mutex.ReleaseMutex(); }
            }
        }
    }

    internal static class Palette
    {
        internal static readonly Color Background = Color.FromArgb(9, 16, 29);
        internal static readonly Color Card = Color.FromArgb(16, 28, 44);
        internal static readonly Color Raised = Color.FromArgb(21, 36, 53);
        internal static readonly Color Border = Color.FromArgb(39, 58, 75);
        internal static readonly Color Text = Color.FromArgb(232, 242, 247);
        internal static readonly Color Muted = Color.FromArgb(144, 165, 180);
        internal static readonly Color Teal = Color.FromArgb(62, 221, 190);
        internal static readonly Color DarkTeal = Color.FromArgb(10, 45, 45);
        internal static readonly Color Error = Color.FromArgb(255, 152, 133);
        internal static readonly Color Amber = Color.FromArgb(239, 197, 115);
        internal static Font Font(float size, bool bold)
        {
            return new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
        }
        internal static GraphicsPath Rounded(RectangleF rect, float radius)
        {
            float d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
            GraphicsPath path = new GraphicsPath();
            path.AddArc(rect.X, rect.Y, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class Surface : Panel
    {
        internal Color Fill = Palette.Card;
        internal Color Stroke = Palette.Border;
        internal int Radius = 18;
        internal Surface()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = Palette.Rounded(new RectangleF(.5f, .5f, Width - 1, Height - 1), Radius))
            using (Brush brush = new SolidBrush(Fill))
            using (Pen pen = new Pen(Stroke))
            { e.Graphics.FillPath(brush, path); e.Graphics.DrawPath(pen, path); }
            base.OnPaint(e);
        }
    }

    internal sealed class FlatButton : Button
    {
        internal bool Primary;
        private bool hover;
        internal FlatButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Font = Palette.Font(10.5f, true);
            Cursor = Cursors.Hand;
            TabStop = true;
            BackColor = Palette.Card;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color fill = Primary ? Palette.Teal : Palette.Raised;
            if (!Enabled) fill = Color.FromArgb(36, 58, 66);
            else if (hover) fill = Primary ? Color.FromArgb(101, 239, 213) : Color.FromArgb(32, 51, 69);
            using (GraphicsPath path = Palette.Rounded(new RectangleF(.5f, .5f, Width - 1, Height - 1), 11))
            using (Brush brush = new SolidBrush(fill))
            using (Pen pen = new Pen(Primary ? fill : Palette.Border))
            { e.Graphics.FillPath(brush, path); e.Graphics.DrawPath(pen, path); }
            Color text = Primary && Enabled ? Color.FromArgb(5, 35, 33) : (Enabled ? Palette.Text : Palette.Muted);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            if (Focused && ShowFocusCues)
            {
                Rectangle focus = ClientRectangle; focus.Inflate(-5, -5);
                ControlPaint.DrawFocusRectangle(e.Graphics, focus, text, fill);
            }
        }
    }

    internal sealed class RouteArt : Control
    {
        internal bool Connected;
        internal bool Waiting;
        internal float AnimationPhase;
        internal RouteArt()
        {
            SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint |
                ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            BackColor = Color.Transparent;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            float cx = Width * .53f, cy = Height * .47f;
            Color accent = Connected || Waiting ? Palette.Teal : Color.FromArgb(75, 116, 135);
            using (Pen ring = new Pen(Color.FromArgb(30, 71, 85), 1))
            {
                for (int i = 0; i < 3; i++)
                {
                    float r = 35 + i * 26;
                    g.DrawEllipse(ring, cx - r, cy - r, r * 2, r * 2);
                }
            }
            PointF a = new PointF(cx - 71, cy + 35), b = new PointF(cx + 50, cy - 48);
            PointF c = new PointF(cx + 79, cy + 42);
            using (Pen route = new Pen(Color.FromArgb(75, accent), 2))
            {
                route.DashStyle = DashStyle.Dash;
                g.DrawLine(route, a, b);
            }
            using (Pen route = new Pen(accent, 2)) g.DrawLine(route, a, c);
            if (Waiting)
            {
                using (Pen spinner = new Pen(accent, 3))
                    g.DrawArc(spinner, cx - 17, cy - 17, 34, 34, AnimationPhase * 360, 245);
                DrawNode(g, new PointF(a.X + (b.X - a.X) * AnimationPhase,
                    a.Y + (b.Y - a.Y) * AnimationPhase), accent, 4);
            }
            DrawNode(g, a, accent, 6); DrawNode(g, b, accent, 6); DrawNode(g, c, accent, 6);
            using (Font font = Palette.Font(8.5f, false))
            using (Brush muted = new SolidBrush(Palette.Muted))
            {
                g.DrawString("本机", font, muted, a.X - 14, a.Y + 17);
                g.DrawString("香港解析", font, muted, b.X - 26, b.Y - 27);
                g.DrawString("对局", font, muted, c.X - 13, c.Y + 17);
            }
        }
        private static void DrawNode(Graphics g, PointF point, Color color, float radius)
        {
            using (Brush glow = new SolidBrush(Color.FromArgb(25, color)))
                g.FillEllipse(glow, point.X - 15, point.Y - 15, 30, 30);
            using (Brush brush = new SolidBrush(color))
                g.FillEllipse(brush, point.X - radius, point.Y - radius, radius * 2, radius * 2);
        }
    }

    internal sealed class BackendState
    {
        internal string Phase = "stopped";
        internal string Message = "";
        internal bool Ready;
        internal string Gateway = "";
        internal string ExitIp = "";
        internal string UpdatedAt = "";
        internal string ProgressStage = "";
        internal DateTimeOffset? OperationStartedAt;
    }

    internal sealed class ConnectionWaitState
    {
        internal string Phase = "";
        internal DateTimeOffset? StartedAt;
        private DateTimeOffset? observedBackendOrigin;
        internal double? LastSuccessfulWaitSeconds;
        internal bool RecordStartupTiming;
        internal bool IsWaiting { get { return Phase == "checking" || Phase == "starting" || Phase == "stopping"; } }
        internal void Update(BackendState state, bool checking, DateTimeOffset now)
        {
            string next = checking ? "checking" : state.Phase == "connected" && !state.Ready ? "starting" : state.Phase;
            if (next == "checking" || next == "starting" || next == "stopping")
            {
                if (next != "starting") RecordStartupTiming = false;
                DateTimeOffset? reported = next != "checking" && state.OperationStartedAt.HasValue &&
                    state.OperationStartedAt.Value <= now ? state.OperationStartedAt : null;
                if (next != Phase || !StartedAt.HasValue)
                {
                    StartedAt = reported ?? now;
                    observedBackendOrigin = reported;
                }
                else if (reported.HasValue)
                {
                    // A health recheck can begin between two status polls, without the
                    // UI observing the intervening ready state. A new origin is a new operation.
                    if (observedBackendOrigin.HasValue && reported.Value != observedBackendOrigin.Value)
                    {
                        StartedAt = reported; RecordStartupTiming = false;
                    }
                    else if (reported.Value < StartedAt.Value) StartedAt = reported;
                    observedBackendOrigin = reported;
                }
                Phase = next;
                return;
            }
            // Only a confirmed ready connection completes a successful startup wait.
            if (RecordStartupTiming && Phase == "starting" && state.Phase == "connected" && state.Ready && StartedAt.HasValue)
                LastSuccessfulWaitSeconds = Math.Max(0, (now - StartedAt.Value).TotalSeconds);
            Phase = ""; StartedAt = null; observedBackendOrigin = null; RecordStartupTiming = false;
        }
        internal int ElapsedSeconds(DateTimeOffset now)
        {
            return StartedAt.HasValue ? (int)Math.Min(Int32.MaxValue, Math.Max(0, (now - StartedAt.Value).TotalSeconds)) : 0;
        }
        internal string StepText(BackendState state)
        {
            if (!IsWaiting) return "";
            if (Phase == "checking") return "正在读取本机连接状态";
            if (!String.IsNullOrWhiteSpace(state.ProgressStage)) return state.ProgressStage;
            if (!String.IsNullOrWhiteSpace(state.Message)) return state.Message;
            return Phase == "stopping" ? "正在请求关闭并恢复连接设置" : "正在请求建立解析连接";
        }
        internal string ReferenceText()
        {
            if (Phase == "checking") return "读取完成后显示当前连接状态。";
            if (Phase == "stopping") return "恢复完成后会自动停止动画。";
            return LastSuccessfulWaitSeconds.HasValue ? "上次等待 " + Math.Ceiling(LastSuccessfulWaitSeconds.Value).ToString("0") +
                " 秒，仅供参考" : "正在建立连接，耗时取决于网络";
        }
    }

    internal sealed class MainForm : Form
    {
        internal const string TrialDeadline = "2026-11-13T00:00:00+11:00";
        private const int MaximumGamePaths = 2;
        private const string GamePathLimitMessage = "最多保留两个不同的游戏程序路径（Steam 和 WeGame）。请先移除要替换的路径。";
        private readonly bool preview;
        private readonly string root;
        private readonly string settingsPath;
        private readonly string privateDirectory;
        private readonly string keyPath;
        private readonly SemaphoreSlim operationGate = new SemaphoreSlim(1, 1);
        private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer animationTimer = new System.Windows.Forms.Timer();
        private readonly Stopwatch animationClock = Stopwatch.StartNew();
        private readonly ConnectionWaitState connectionWait = new ConnectionWaitState();
        private readonly Panel shell = new Panel();
        private readonly Panel dashboard = new Panel();
        private readonly Panel settings = new Panel();
        private readonly Surface hero = new Surface();
        private readonly Surface resolverCard = new Surface();
        private readonly Surface battleCard = new Surface();
        private readonly Surface infoCard = new Surface();
        private readonly Surface setupCard = new Surface();
        private readonly RouteArt art = new RouteArt();
        private readonly Label headline;
        private readonly Label phasePill;
        private readonly Label stateTitle;
        private readonly Label stateMessage;
        private readonly Label connectionDetail;
        private readonly Label infoText;
        private readonly Label footer;
        private readonly Label settingsError;
        private readonly Label keyHint;
        private readonly TextBox gamePathBox = new TextBox();
        private readonly TextBox keyBox = new TextBox();
        private readonly FlatButton primary = new FlatButton();
        private readonly FlatButton settingsButton = new FlatButton();
        private readonly FlatButton copyError = new FlatButton();
        private readonly FlatButton browseButton = new FlatButton();
        private readonly FlatButton saveButton = new FlatButton();
        private readonly FlatButton cancelSettings = new FlatButton();
        private readonly FlatButton importKeyButton = new FlatButton();
        private BackendState state = new BackendState();
        private List<string> configuredGamePaths = new List<string>();
        private string errorText = "";
        private bool configured;
        private bool busy;
        private bool settingsOpen;
        private bool closing;
        private bool allowClose;
        private bool startedThisSession;
        private bool initialStatusPending;
        private byte[] importedKey;

        internal MainForm(bool previewMode, string previewState)
        {
            preview = previewMode;
            root = AppDomain.CurrentDomain.BaseDirectory;
            settingsPath = Path.Combine(root, "user-settings.json");
            privateDirectory = Path.Combine(root, "backend", "private");
            keyPath = Path.Combine(privateDirectory, "device-key.dpapi.bin");
            Text = "三角洲 · 主入口优化";
            BackColor = Palette.Background;
            ForeColor = Palette.Text;
            Font = Palette.Font(10, false);
            AutoScaleDimensions = new SizeF(96, 96);
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(840, 640);
            MinimumSize = new Size(790, 645);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            DoubleBuffered = true;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            shell.Dock = DockStyle.Fill; shell.Padding = new Padding(28, 23, 28, 18);
            shell.BackColor = Palette.Background; Controls.Add(shell);

            Panel header = new Panel { Dock = DockStyle.Top, Height = 82, BackColor = Palette.Background };
            PictureBox brandIcon = new PictureBox { BackColor = Palette.Background, SizeMode = PictureBoxSizeMode.Zoom, TabStop = false };
            brandIcon.SetBounds(0, 10, 40, 40);
            if (Icon != null) brandIcon.Image = Icon.ToBitmap();
            brandIcon.Disposed += delegate { if (brandIcon.Image != null) brandIcon.Image.Dispose(); };
            header.Controls.Add(brandIcon);
            headline = MakeLabel("三角洲 · 主入口优化", 19, true, Palette.Text);
            headline.SetBounds(56, 0, 480, 36); header.Controls.Add(headline);
            Label sub = MakeLabel("PRIVATE ACCESS  /  私人解析加速器", 8.5f, false, Palette.Muted);
            sub.SetBounds(57, 40, 480, 22); header.Controls.Add(sub);
            settingsButton.Text = "设置"; settingsButton.SetBounds(692, 3, 90, 36);
            settingsButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            settingsButton.Click += delegate { if (!busy && state.Phase == "stopped") OpenSettings(); };
            header.Controls.Add(settingsButton);
            header.Resize += delegate { settingsButton.Left = header.ClientSize.Width - settingsButton.Width - 2; };
            Panel bottom = new Panel { Dock = DockStyle.Bottom, Height = 32, BackColor = Palette.Background };
            footer = MakeLabel("试用至 2026-11-13   ·   每台设备使用独立密钥", 8.5f, false, Palette.Muted);
            footer.Dock = DockStyle.Fill; footer.TextAlign = ContentAlignment.BottomLeft; bottom.Controls.Add(footer);
            Panel body = new Panel { Dock = DockStyle.Fill, BackColor = Palette.Background };
            shell.Controls.Add(body); shell.Controls.Add(bottom); shell.Controls.Add(header);
            dashboard.Dock = DockStyle.Fill; settings.Dock = DockStyle.Fill;
            dashboard.BackColor = settings.BackColor = Palette.Background;
            body.Controls.Add(dashboard); body.Controls.Add(settings);

            hero.SetBounds(0, 0, 784, 266); hero.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
            dashboard.Controls.Add(hero);
            Label eyebrow = MakeLabel("当前连接", 9, false, Palette.Muted);
            eyebrow.SetBounds(25, 21, 250, 23); hero.Controls.Add(eyebrow);
            phasePill = MakeLabel("待机", 9, true, Palette.Muted);
            phasePill.SetBounds(604, 22, 150, 24); phasePill.TextAlign = ContentAlignment.MiddleRight;
            phasePill.Anchor = AnchorStyles.Top | AnchorStyles.Right; hero.Controls.Add(phasePill);
            stateTitle = MakeLabel("尚未开启", 28, true, Palette.Text);
            stateTitle.SetBounds(23, 55, 465, 56); hero.Controls.Add(stateTitle);
            stateMessage = MakeLabel("开启后，主入口解析经香港，对局流量保持直连。", 10, false, Palette.Muted);
            stateMessage.SetBounds(26, 119, 480, 44); hero.Controls.Add(stateMessage);
            primary.Primary = true; primary.Text = "开启加速";
            primary.SetBounds(26, 188, 245, 52);
            primary.Click += async delegate { await ToggleAsync(); }; hero.Controls.Add(primary);
            connectionDetail = MakeLabel("只优化入口解析", 9, false, Palette.Muted);
            connectionDetail.SetBounds(290, 199, 225, 28); hero.Controls.Add(connectionDetail);
            art.SetBounds(511, 50, 236, 186); art.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            hero.Controls.Add(art); art.SendToBack();

            resolverCard.SetBounds(0, 282, 384, 92); battleCard.SetBounds(400, 282, 384, 92);
            dashboard.Controls.Add(resolverCard); dashboard.Controls.Add(battleCard);
            AddRouteCard(resolverCard, "入口解析", "香港中转", "仅处理入口解析请求", Palette.Teal);
            AddRouteCard(battleCard, "对局流量", "本机直连", "实际延迟以游戏内显示为准", Palette.Text);
            infoCard.SetBounds(0, 390, 784, 86); infoCard.Fill = Color.FromArgb(12, 23, 37);
            dashboard.Controls.Add(infoCard);
            infoText = MakeLabel("准备好后开启加速，再启动游戏。\r\n加速器会保持运行，关闭窗口时会先安全停止。", 9.5f, false, Palette.Muted);
            infoText.SetBounds(22, 16, 610, 57); infoCard.Controls.Add(infoText);
            copyError.Text = "复制错误"; copyError.SetBounds(643, 24, 117, 36);
            copyError.Click += delegate { CopyError(); }; infoCard.Controls.Add(copyError);

            setupCard.Dock = DockStyle.Fill; settings.Controls.Add(setupCard);
            Label setupTitle = MakeLabel("先完成设备设置", 22, true, Palette.Text);
            setupTitle.SetBounds(27, 24, 620, 42); setupCard.Controls.Add(setupTitle);
            Label setupIntro = MakeLabel("选择游戏程序，填入分配给这台电脑的独立设备密钥。", 10, false, Palette.Muted);
            setupIntro.SetBounds(29, 76, 710, 28); setupCard.Controls.Add(setupIntro);
            Label gameLabel = MakeLabel("游戏程序（每行一个，最多两个：Steam / WeGame）", 10, true, Palette.Text);
            gameLabel.SetBounds(29, 124, 500, 26); setupCard.Controls.Add(gameLabel);
            AddTextField(setupCard, gamePathBox, 29, 153, 575, 80, false);
            gamePathBox.Multiline = true; gamePathBox.WordWrap = false;
            gamePathBox.ScrollBars = ScrollBars.Horizontal; gamePathBox.Height = 60;
            gamePathBox.Font = Palette.Font(8.5f, false); gamePathBox.MaxLength = 16384;
            browseButton.Text = "选择程序"; browseButton.SetBounds(620, 157, 130, 40);
            browseButton.Click += delegate { BrowseGame(); }; setupCard.Controls.Add(browseButton);
            Label exeHint = MakeLabel("Steam / WeGame 按实际运行的进程自动匹配；选择程序可追加路径。\r\n每行选择一个 DeltaForceClient-Win64-Shipping.exe。", 8.5f, false, Palette.Muted);
            exeHint.SetBounds(31, 238, 704, 34); setupCard.Controls.Add(exeHint);
            Label keyLabel = MakeLabel("独立设备密钥", 10, true, Palette.Text);
            keyLabel.SetBounds(29, 273, 500, 26); setupCard.Controls.Add(keyLabel);
            importKeyButton.Text = "导入已有密钥";
            importKeyButton.SetBounds(590, 268, 160, 31);
            importKeyButton.Font = Palette.Font(8.5f, false);
            importKeyButton.Click += delegate { ImportKey(); };
            setupCard.Controls.Add(importKeyButton);
            AddTextField(setupCard, keyBox, 29, 304, 721, 40, true);
            keyHint = MakeLabel("每台电脑一份密钥，请勿与朋友共用。密钥仅加密保存在本机。", 8.5f, false, Palette.Muted);
            keyHint.SetBounds(31, 351, 704, 28); setupCard.Controls.Add(keyHint);
            keyBox.TextChanged += delegate { if (keyBox.TextLength > 0) ClearImportedKey(); };
            settingsError = MakeLabel("", 9, false, Palette.Error);
            settingsError.SetBounds(30, 384, 715, 35); setupCard.Controls.Add(settingsError);
            saveButton.Primary = true; saveButton.Text = "保存设置";
            saveButton.SetBounds(29, 429, 220, 46); saveButton.Click += delegate { SaveSettings(); };
            setupCard.Controls.Add(saveButton);
            cancelSettings.Text = "返回"; cancelSettings.SetBounds(264, 429, 105, 46);
            cancelSettings.Click += delegate { ClearImportedKey(); keyBox.Clear(); settingsOpen = false; ShowCurrentView(); }; setupCard.Controls.Add(cancelSettings);

            dashboard.Resize += delegate { LayoutDashboard(); };
            body.Resize += delegate { LayoutSettings(); };
            timer.Interval = 8000; timer.Tick += async delegate { await RefreshStatusAsync(); };
            animationTimer.Interval = 40;
            animationTimer.Tick += delegate { RefreshWaitingPresentation(); };
            Shown += async delegate
            {
                LayoutDashboard(); LayoutSettings();
                if (preview) return;
                try { await RefreshStatusAsync(); }
                finally { initialStatusPending = false; ApplyState(); }
                if (!closing) timer.Start();
            };
            FormClosing += ClosingAsync;
            if (preview)
            {
                configured = true;
                configuredGamePaths.Add("已选择三角洲游戏程序");
                gamePathBox.Text = configuredGamePaths[0];
                string requested = (previewState ?? "stopped").ToLowerInvariant();
                settingsOpen = requested == "setup" || requested == "settings";
                state.Phase = requested == "connected" ? "connected" : requested == "error" ? "error" : requested == "starting" ? "starting" : "stopped";
                state.Ready = state.Phase == "connected";
                state.Message = state.Phase == "error" ? "暂时无法连接香港解析服务。请检查网络后重试。" : "";
                if (state.Phase == "starting")
                {
                    state.ProgressStage = "正在等待香港解析服务就绪";
                    state.OperationStartedAt = DateTimeOffset.Now.AddSeconds(-12);
                }
                if (settingsOpen) { configured = false; gamePathBox.Text = ""; }
                errorText = state.Message;
                sub.Text = "界面预览 · 模拟状态 · 未连接服务";
            }
            else { LoadSettings(); initialStatusPending = true; }
            ApplyState();
        }

        private static Label MakeLabel(string text, float size, bool bold, Color color)
        {
            return new Label { Text = text, Font = Palette.Font(size, bold), ForeColor = color,
                BackColor = Color.Transparent, AutoSize = false, UseMnemonic = false };
        }
        private static void AddRouteCard(Surface parent, string heading, string value, string note, Color accent)
        {
            Label name = MakeLabel(heading, 9, false, Palette.Muted); name.SetBounds(21, 16, 85, 22);
            Label title = MakeLabel(value, 14, true, accent); title.SetBounds(112, 11, 238, 32);
            Label hint = MakeLabel(note, 8.5f, false, Palette.Muted); hint.SetBounds(21, 54, 344, 24);
            parent.Controls.Add(name); parent.Controls.Add(title); parent.Controls.Add(hint);
        }
        private static void AddTextField(Control parent, TextBox box, int x, int y, int width, int height, bool secret)
        {
            Surface field = new Surface { Fill = Palette.Background, Radius = 9 };
            field.SetBounds(x, y, width, height);
            box.BorderStyle = BorderStyle.None; box.BackColor = Palette.Background; box.ForeColor = Palette.Text;
            box.Font = Palette.Font(10, false); box.SetBounds(12, 10, width - 24, 23);
            box.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            box.UseSystemPasswordChar = secret; box.MaxLength = secret ? 8192 : 1024;
            field.Controls.Add(box); parent.Controls.Add(field);
        }
        private void LayoutDashboard()
        {
            int width = dashboard.ClientSize.Width;
            if (width < 100) return;
            hero.Width = infoCard.Width = width;
            int gap = Px(16), half = (width - gap) / 2;
            resolverCard.Width = half; battleCard.SetBounds(half + gap, Px(282), width - half - gap, Px(92));
            copyError.Left = width - Px(141); infoText.Width = width - Px(copyError.Visible ? 185 : 44);
            phasePill.Left = width - Px(176); art.Left = width - Px(273);
        }
        private void LayoutSettings()
        {
            int width = setupCard.ClientSize.Width;
            if (width < 300) return;
            gamePathBox.Parent.Width = width - Px(209); browseButton.Left = width - Px(164);
            keyBox.Parent.Width = width - Px(63);
            importKeyButton.Left = width - Px(194);
            settingsError.Width = width - Px(60);
        }
        private int Px(int designPixels) { return (int)Math.Round(designPixels * DeviceDpi / 96.0); }
        private bool IsExpired()
        {
            return DateTimeOffset.Now >= DateTimeOffset.Parse(TrialDeadline, System.Globalization.CultureInfo.InvariantCulture);
        }
        private void ShowCurrentView()
        {
            settings.Visible = settingsOpen; dashboard.Visible = !settingsOpen;
            if (settingsOpen) settings.BringToFront(); else dashboard.BringToFront();
            settingsButton.Text = settingsOpen ? "设备设置" : "设置";
        }
        private void ApplyState()
        {
            double? previousWait = connectionWait.LastSuccessfulWaitSeconds;
            connectionWait.Update(state, initialStatusPending, DateTimeOffset.Now);
            if (!preview && connectionWait.LastSuccessfulWaitSeconds.HasValue && previousWait != connectionWait.LastSuccessfulWaitSeconds)
            {
                // A reference timing is optional; failure to save it never changes connection status.
                try { SaveSuccessfulStartupWait(settingsPath, connectionWait.LastSuccessfulWaitSeconds.Value); } catch { }
            }
            bool active = state.Phase == "connected" && state.Ready;
            bool transitioning = busy || connectionWait.IsWaiting;
            art.Connected = active; art.Invalidate();
            stateTitle.Text = initialStatusPending ? "正在读取状态" : active ? "已连接" : state.Phase == "starting" ? "正在连接" :
                state.Phase == "stopping" ? "正在关闭" : state.Phase == "error" ? "连接需要处理" : "尚未开启";
            phasePill.Text = active ? "香港解析 · 已就绪" : state.Phase == "error" ? "需要处理" :
                transitioning ? "处理中" : "待机";
            phasePill.ForeColor = active ? Palette.Teal : state.Phase == "error" ? Palette.Error : Palette.Muted;
            stateMessage.Text = active ? "主入口解析经香港，对局流量保持直连。" :
                state.Phase == "starting" ? "正在建立解析连接，请稍候。" :
                state.Phase == "stopping" ? "正在恢复连接设置，请稍候。" :
                state.Phase == "error" ? "请查看下方提示，处理后再试。" :
                "开启后，主入口解析经香港，对局流量保持直连。";
            connectionDetail.Text = active ? "解析通道运行中" : "只优化入口解析";
            primary.Text = state.Phase == "starting" ? "正在开启…" : state.Phase == "stopping" ? "正在关闭…" :
                active ? "关闭加速" : state.Phase == "error" ? "关闭并恢复" : configured ? "开启加速" : "完成设备设置";
            primary.Enabled = !transitioning && !closing;
            settingsButton.Enabled = !busy && !closing && state.Phase == "stopped";
            saveButton.Enabled = !busy && !closing && state.Phase == "stopped";
            browseButton.Enabled = saveButton.Enabled; gamePathBox.ReadOnly = !saveButton.Enabled;
            importKeyButton.Enabled = saveButton.Enabled;
            keyBox.ReadOnly = !saveButton.Enabled;
            cancelSettings.Visible = configured;
            copyError.Visible = state.Phase == "error" && !String.IsNullOrEmpty(errorText);
            infoText.ForeColor = copyError.Visible ? Palette.Error : Palette.Muted;
            infoText.Text = copyError.Visible ? Short(errorText, 190) : active ?
                "当前仅中转入口解析，游戏对局保持直连。\r\n实际延迟与网络质量请以游戏内显示为准。" :
                "准备好后开启加速，再启动游戏。\r\n关闭窗口时会先安全停止加速。";
            if (IsExpired())
            {
                footer.Text = "试用已结束（2026-11-13）  ·  请联系服务提供者";
                if (state.Phase == "stopped") { primary.Text = "试用已结束"; primary.Enabled = false; }
            }
            if (state.Phase != "stopped") settingsOpen = false;
            ShowCurrentView(); LayoutDashboard(); LayoutSettings();
            RefreshWaitingPresentation();
            if (connectionWait.IsWaiting) animationTimer.Start(); else animationTimer.Stop();
        }
        private void RefreshWaitingPresentation()
        {
            art.Waiting = connectionWait.IsWaiting;
            if (art.Waiting)
            {
                art.AnimationPhase = (float)(animationClock.Elapsed.TotalSeconds % 1.4 / 1.4);
                string step = connectionWait.StepText(state).Replace('\r', ' ').Replace('\n', ' ');
                stateMessage.Text = Short(step, 34) + "\r\n" + connectionWait.ReferenceText();
                connectionDetail.Text = "已等待 " + connectionWait.ElapsedSeconds(DateTimeOffset.Now).ToString() + " 秒";
            }
            art.Invalidate();
        }
        private static string Short(string text, int length)
        {
            if (String.IsNullOrEmpty(text)) return "";
            return text.Length > length ? text.Substring(0, length) + "…" : text;
        }
        private void SetError(string message)
        {
            state.Phase = "error"; state.Ready = false;
            state.Message = message; errorText = message; ApplyState();
        }
        private void LoadSettings()
        {
            try
            {
                if (File.Exists(settingsPath))
                {
                    Dictionary<string, object> data = ReadJson(settingsPath);
                    configuredGamePaths = ReadGamePaths(data);
                    connectionWait.LastSuccessfulWaitSeconds = ReadSuccessfulStartupWait(data);
                }
                if (configuredGamePaths.Count == 0) AddGamePath(configuredGamePaths, FindSteamGame());
                gamePathBox.Text = String.Join(Environment.NewLine, configuredGamePaths);
                configured = ValidateSetupPaths(configuredGamePaths, "", File.Exists(keyPath)) == null;
                settingsOpen = !configured;
                keyHint.Text = File.Exists(keyPath) ?
                    "本机已保存独立密钥。留空保留当前密钥；输入新密钥可替换。" :
                    "每台电脑一份密钥，请勿与朋友共用。密钥仅加密保存在本机。";
            }
            catch { configured = false; settingsOpen = true; settingsError.Text = "无法读取本机配置，请重新选择游戏程序。"; }
        }
        private void OpenSettings()
        {
            gamePathBox.Text = String.Join(Environment.NewLine, configuredGamePaths); keyBox.Clear(); ClearImportedKey(); settingsError.Text = "";
            settingsOpen = true; ApplyState();
        }
        private void BrowseGame()
        {
            if (preview || busy || state.Phase != "stopped") return;
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "选择 Steam 或 WeGame 三角洲游戏程序（追加到列表）";
                dialog.Filter = "游戏程序 (*.exe)|*.exe"; dialog.CheckFileExists = true;
                List<string> paths = ParseGamePathText(gamePathBox.Text);
                if (paths.Count > 0 && File.Exists(paths[paths.Count - 1])) dialog.FileName = paths[paths.Count - 1];
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    if (!paths.Exists(delegate(string item) { return String.Equals(item, dialog.FileName, StringComparison.OrdinalIgnoreCase); }))
                        paths.Add(dialog.FileName);
                    string validation = ValidateSetupPaths(paths, "", true);
                    if (validation != null) { settingsError.Text = validation; return; }
                    gamePathBox.Text = String.Join(Environment.NewLine, paths);
                    settingsError.Text = "";
                }
            }
        }
        internal static bool ValidGamePath(string path)
        {
            return !String.IsNullOrWhiteSpace(path) && File.Exists(path) &&
                String.Equals(Path.GetFileName(path), "DeltaForceClient-Win64-Shipping.exe", StringComparison.OrdinalIgnoreCase);
        }
        private void SaveSettings()
        {
            if (preview || busy || state.Phase != "stopped") return;
            List<string> paths = ParseGamePathText(gamePathBox.Text);
            string secret = keyBox.Text.Trim();
            string validation = ValidateSetupPaths(paths, secret, File.Exists(keyPath) || importedKey != null);
            if (validation != null) { settingsError.Text = validation; return; }
            byte[] plain = null;
            try
            {
                if (secret.Length > 0 || importedKey != null)
                {
                    plain = importedKey != null ? (byte[])importedKey.Clone() : Encoding.UTF8.GetBytes(secret);
                    SaveEncryptedKey(privateDirectory, keyPath, plain);
                }
                SaveSettingsJson(settingsPath, paths);
                configuredGamePaths = ReadGamePaths(ReadJson(settingsPath)); configured = true; settingsOpen = false;
                keyBox.Clear(); ClearImportedKey(); settingsError.Text = ""; errorText = ""; state.Phase = "stopped";
                keyHint.Text = "本机已保存独立密钥。留空保留当前密钥；输入新密钥可替换。";
                ApplyState();
            }
            catch (Exception ex) { settingsError.Text = "设置保存失败（" + ex.GetType().Name + "），请确认安装目录可写。"; }
            finally { if (plain != null) Array.Clear(plain, 0, plain.Length); secret = null; }
        }
        internal static string ValidateSetupInput(string game, string secret, bool existingKey)
        {
            if (!ValidGamePath(game)) return "请选择正确的 DeltaForceClient-Win64-Shipping.exe。";
            if (String.IsNullOrWhiteSpace(secret) && !existingKey) return "请输入分配给这台电脑的独立设备密钥。";
            if (!String.IsNullOrEmpty(secret) && (secret.Length > 8192 || secret.IndexOfAny(new char[] { '\r', '\n', '\0' }) >= 0))
                return "设备密钥格式无效，请重新粘贴完整密钥。";
            return null;
        }
        internal static List<string> ParseGamePathText(string text)
        {
            List<string> paths = new List<string>();
            foreach (string line in (text ?? "").Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                if (!String.IsNullOrWhiteSpace(line)) paths.Add(line.Trim());
            return paths;
        }
        internal static string ValidateSetupPaths(IList<string> games, string secret, bool existingKey)
        {
            if (games == null || games.Count == 0) return "请选择至少一个游戏程序。";
            List<string> normalized = new List<string>();
            foreach (string game in games)
            {
                if (!ValidGamePath(game)) return "请选择正确的 DeltaForceClient-Win64-Shipping.exe。";
                AddGamePath(normalized, game);
            }
            if (normalized.Count > MaximumGamePaths) return GamePathLimitMessage;
            return ValidateSetupInput(normalized[0], secret, existingKey);
        }
        private static void AddGamePath(List<string> games, string game)
        {
            if (String.IsNullOrWhiteSpace(game)) return;
            string fullPath = Path.GetFullPath(game.Trim());
            if (!games.Exists(delegate(string item) { return String.Equals(item, fullPath, StringComparison.OrdinalIgnoreCase); }))
                games.Add(fullPath);
        }
        internal static List<string> ReadGamePaths(Dictionary<string, object> data)
        {
            List<string> games = new List<string>();
            AddGamePath(games, GetString(data, "gameExecutable"));
            object value;
            if (data.TryGetValue("gameExecutables", out value))
            {
                object[] saved = value as object[];
                if (saved != null) foreach (object item in saved) if (item is string) AddGamePath(games, (string)item);
            }
            return games;
        }
        internal static void SaveSettingsJson(string path, string game)
        {
            List<string> games = new List<string>();
            AddGamePath(games, game);
            if (File.Exists(path)) foreach (string saved in ReadGamePaths(ReadJson(path))) AddGamePath(games, saved);
            SaveSettingsJson(path, games);
        }
        internal static void SaveSettingsJson(string path, IEnumerable<string> games)
        {
            List<string> normalized = new List<string>();
            foreach (string game in games) AddGamePath(normalized, game);
            if (normalized.Count == 0) throw new InvalidDataException("A game executable is required.");
            if (normalized.Count > MaximumGamePaths) throw new InvalidDataException(GamePathLimitMessage);
            Dictionary<string, object> data = File.Exists(path) ? ReadJson(path) : new Dictionary<string, object>();
            data["gameExecutable"] = normalized[0]; data["gameExecutables"] = normalized.ToArray();
            data["trialDeadline"] = TrialDeadline;
            AtomicWrite(path, new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(data)));
        }
        internal static double? ReadSuccessfulStartupWait(Dictionary<string, object> data)
        {
            object value;
            if (!data.TryGetValue("lastSuccessfulStartupWaitSeconds", out value) ||
                !(value is int || value is long || value is double || value is decimal)) return null;
            double seconds = Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture);
            return !Double.IsNaN(seconds) && !Double.IsInfinity(seconds) && seconds >= 0 && seconds <= 7200 ? (double?)seconds : null;
        }
        internal static void SaveSuccessfulStartupWait(string path, double seconds)
        {
            if (!File.Exists(path) || Double.IsNaN(seconds) || Double.IsInfinity(seconds) || seconds < 0 || seconds > 7200) return;
            Dictionary<string, object> data = ReadJson(path);
            data["lastSuccessfulStartupWaitSeconds"] = Math.Round(seconds, 1);
            AtomicWrite(path, new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(data)));
        }
        internal static void SaveEncryptedKey(string directory, string path, byte[] plain)
        {
            ValidateKeyBytes(plain);
            Directory.CreateDirectory(directory);
            DirectoryInfo check = new DirectoryInfo(directory);
            for (; check != null; check = check.Parent)
                if ((check.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Private path crosses a reparse point.");
            SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
            DirectorySecurity directoryAcl = new DirectorySecurity(); directoryAcl.SetAccessRuleProtection(true, false); directoryAcl.SetOwner(sid);
            directoryAcl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(directory, directoryAcl);
            byte[] encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            AtomicWrite(path, encrypted);
            FileSecurity fileAcl = new FileSecurity(); fileAcl.SetAccessRuleProtection(true, false); fileAcl.SetOwner(sid);
            fileAcl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
            File.SetAccessControl(path, fileAcl);
        }
        internal static void ValidateKeyBytes(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length > 32768) throw new InvalidDataException("Invalid device key length.");
            if (new UTF8Encoding(false, true).GetCharCount(bytes) > 8192) throw new InvalidDataException("Invalid device key length.");
            bool meaningful = false;
            foreach (byte b in bytes)
            {
                if (b < 32 || b == 127) throw new InvalidDataException("Invalid device key control character.");
                if (b != 32) meaningful = true;
            }
            if (!meaningful) throw new InvalidDataException("Empty device key.");
        }
        private void ClearImportedKey()
        {
            if (importedKey != null) { Array.Clear(importedKey, 0, importedKey.Length); importedKey = null; }
        }
        private void ImportKey()
        {
            if (preview || busy || state.Phase != "stopped") return;
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "导入当前 Windows 账户已有的设备密钥";
                dialog.Filter = "加密设备密钥 (device-key.dpapi.bin)|device-key.dpapi.bin|加密密钥 (*.bin)|*.bin";
                dialog.CheckFileExists = true;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                byte[] clear = null;
                try
                {
                    if (new FileInfo(dialog.FileName).Length > 65536) throw new InvalidDataException("Key file is too large.");
                    clear = ProtectedData.Unprotect(File.ReadAllBytes(dialog.FileName), null, DataProtectionScope.CurrentUser);
                    ValidateKeyBytes(clear); ClearImportedKey(); keyBox.Clear(); importedKey = clear; clear = null;
                    keyHint.Text = "已有密钥已在内存中验证，点击“保存设置”后才会导入。";
                    settingsError.Text = "";
                }
                catch { settingsError.Text = "无法导入：请选择由当前 Windows 账户加密的有效设备密钥。"; }
                finally { if (clear != null) Array.Clear(clear, 0, clear.Length); }
            }
        }
        private static void AtomicWrite(string path, byte[] bytes)
        {
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temp, bytes);
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        private static string FindSteamGame()
        {
            HashSet<string> roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                object user = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null);
                object machine = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null);
                if (user != null) roots.Add(Convert.ToString(user));
                if (machine != null) roots.Add(Convert.ToString(machine));
                string defaultSteam = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
                if (Directory.Exists(defaultSteam)) roots.Add(defaultSteam);
                List<string> initial = new List<string>(roots);
                foreach (string steam in initial)
                {
                    string vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
                    if (!File.Exists(vdf) || new FileInfo(vdf).Length > 1048576) continue;
                    foreach (Match match in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s*\"([^\"]+)\""))
                        roots.Add(match.Groups[1].Value.Replace(@"\\", @"\"));
                }
                foreach (string library in roots)
                {
                    foreach (string gameFolder in new string[] { "Delta Force", "DeltaForce" })
                    {
                        string candidate = Path.Combine(new string[] { library, "steamapps", "common", gameFolder,
                            "Game", "DeltaForce", "Binaries", "Win64", "DeltaForceClient-Win64-Shipping.exe" });
                        if (ValidGamePath(candidate)) return candidate;
                    }
                }
            }
            catch { }
            return "";
        }
        private async Task ToggleAsync()
        {
            if (preview || busy || closing) return;
            if (!configured && state.Phase == "stopped") { OpenSettings(); return; }
            if (state.Phase == "stopped" && IsExpired()) return;
            if (!await operationGate.WaitAsync(0)) return;
            busy = true;
            try
            {
                if (state.Phase == "connected" || state.Phase == "error")
                {
                    BeginLocalOperation("stopping");
                    await InvokeBackendAsync("Stop");
                    await WaitUntilStoppedAsync();
                    startedThisSession = false;
                }
                else
                {
                    if (IsExpired()) return;
                    BeginLocalOperation("starting"); startedThisSession = true;
                    await InvokeBackendAsync("Start");
                }
            }
            catch (Exception ex) { SetError(UserError(ex)); }
            finally { busy = false; operationGate.Release(); ApplyState(); }
        }
        private async Task RefreshStatusAsync()
        {
            if (preview || busy || closing || !await operationGate.WaitAsync(0)) return;
            try { await InvokeBackendAsync("Status"); }
            catch (Exception ex) { SetError(UserError(ex)); }
            finally { operationGate.Release(); ApplyState(); }
        }
        private void BeginLocalOperation(string phase)
        {
            state.Phase = phase; state.Ready = false; state.Message = "";
            state.ProgressStage = ""; state.OperationStartedAt = null;
            connectionWait.RecordStartupTiming = phase == "starting";
            ApplyState();
        }
        private async Task InvokeBackendAsync(string action)
        {
            string runtime = Path.Combine(root, "runtime", "pwsh.exe");
            string script = Path.Combine(root, "backend", "Control-Accelerator.ps1");
            if (!File.Exists(runtime) || !File.Exists(script))
                throw new InvalidOperationException("找不到配套运行文件。请通过桌面快捷方式打开，不要单独移动 Accelerator.exe；若仍有此提示，请重新安装。");
            ProcessStartInfo start = new ProcessStartInfo(runtime,
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" -Action " + action);
            start.WorkingDirectory = root; start.UseShellExecute = false; start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.RedirectStandardOutput = start.RedirectStandardError = true;
            start.StandardOutputEncoding = start.StandardErrorEncoding = new UTF8Encoding(false);
            using (Process process = new Process())
            {
                process.StartInfo = start;
                if (!process.Start()) throw new InvalidOperationException("无法启动本机加速服务。");
                Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                Task<string> stderr = process.StandardError.ReadToEndAsync();
                bool ended = await Task.Run(delegate { return process.WaitForExit(120000); });
                if (!ended)
                {
                    // Only the exact UI-created control process is affected; backend must own worker cleanup.
                    try { process.Kill(); } catch { }
                    throw new InvalidOperationException("操作超过两分钟，状态尚未确认。请稍后重试关闭。");
                }
                await Task.WhenAll(stdout, stderr);
                // Control emits fresh sanitized JSON. A persisted status file can be stale,
                // and does not exist on first install; it is never a fallback authority.
                state = ParseBackendResponse(stdout.Result);
                if (process.ExitCode != 0 && state.Phase != "error")
                    throw new InvalidOperationException("本机服务操作失败（退出码 " + process.ExitCode + "），状态需要重新确认。");
                if (state.Phase == "error")
                    errorText = String.IsNullOrWhiteSpace(state.Message) ? "本机服务报告连接错误，请重试。" : Short(state.Message, 4000);
                else errorText = "";
            }
        }
        internal static BackendState ParseBackendResponse(string text)
        {
            if (String.IsNullOrWhiteSpace(text) || text.Length > 1048576)
                throw new InvalidOperationException("本机服务没有返回有效状态，请稍后重试。");
            Dictionary<string, object> data;
            try { data = new JavaScriptSerializer().DeserializeObject(text.Trim().TrimStart('\ufeff')) as Dictionary<string, object>; }
            catch { throw new InvalidOperationException("本机服务返回的状态格式无效，请重试。"); }
            if (data == null) throw new InvalidOperationException("本机服务返回的状态格式无效，请重试。");
            string phase = GetString(data, "phase");
            if (phase.Length == 0) phase = GetString(data, "state");
            if (phase.Length == 0) phase = GetString(data, "status");
            phase = phase.ToLowerInvariant();
            if (phase != "stopped" && phase != "starting" && phase != "connected" && phase != "stopping" && phase != "error")
                throw new InvalidOperationException("本机服务返回了无法识别的状态，请重试。");
            string mode = GetString(data, "routingMode");
            if (mode.Length > 0 && !String.Equals(mode, "ResolveOnly", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("当前后端模式不符合仅解析加速设置。");
            BackendState next = new BackendState();
            next.Phase = phase; next.Message = GetString(data, "message");
            next.Ready = String.Equals(GetString(data, "ready"), "true", StringComparison.OrdinalIgnoreCase);
            next.Gateway = GetString(data, "gateway"); next.ExitIp = GetString(data, "exitIp");
            next.UpdatedAt = GetString(data, "updatedAt");
            next.ProgressStage = GetString(data, "progressStage");
            DateTimeOffset operationStart;
            if (DateTimeOffset.TryParse(GetString(data, "operationStartedAt"), System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out operationStart)) next.OperationStartedAt = operationStart;
            if (next.Phase == "connected" && !next.Ready) next.Phase = "starting";
            return next;
        }
        private async Task WaitUntilStoppedAsync()
        {
            DateTime until = DateTime.UtcNow.AddSeconds(60);
            while (state.Phase != "stopped")
            {
                if (state.Phase == "error")
                    throw new InvalidOperationException(String.IsNullOrWhiteSpace(state.Message) ?
                        "停止连接时出现错误，请处理后重试。" : Short(state.Message, 4000));
                if (DateTime.UtcNow >= until) throw new InvalidOperationException("一分钟内尚未确认停止，窗口将保持打开。请重试关闭。");
                ApplyState(); await Task.Delay(750); await InvokeBackendAsync("Status");
            }
        }
        private static Dictionary<string, object> ReadJson(string path)
        {
            if (new FileInfo(path).Length > 1048576) throw new InvalidDataException("Status file is too large.");
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                Dictionary<string, object> data = new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()) as Dictionary<string, object>;
                if (data == null) throw new InvalidDataException("Expected JSON object.");
                return data;
            }
        }
        private static string GetString(Dictionary<string, object> data, string name)
        {
            foreach (KeyValuePair<string, object> entry in data)
                if (String.Equals(entry.Key, name, StringComparison.OrdinalIgnoreCase))
                    return entry.Value == null ? "" : Convert.ToString(entry.Value, System.Globalization.CultureInfo.InvariantCulture);
            return "";
        }
        private static string UserError(Exception ex)
        {
            if (ex is InvalidOperationException) return Short(ex.Message, 4000);
            return "操作未完成（" + ex.GetType().Name + "）。请检查安装文件和网络后重试。";
        }
        private void CopyError()
        {
            if (String.IsNullOrWhiteSpace(errorText)) return;
            try
            {
                Clipboard.SetText("三角洲 · 主入口优化\r\n时间：" + DateTimeOffset.Now.ToString("o") +
                    "\r\n状态：" + state.Phase + "\r\n" + errorText);
                copyError.Text = "已复制";
            }
            catch { copyError.Text = "复制失败"; }
        }
        private async void ClosingAsync(object sender, FormClosingEventArgs e)
        {
            if (preview || allowClose) return;
            e.Cancel = true;
            if (closing) return;
            closing = true; timer.Stop(); ApplyState();
            await operationGate.WaitAsync();
            busy = true;
            try
            {
                // Status/Stop are scoped by this app's backend, including an older UI's surviving worker.
                await InvokeBackendAsync("Status");
                if (state.Phase != "stopped" || startedThisSession)
                {
                    BeginLocalOperation("stopping");
                    await InvokeBackendAsync("Stop");
                    await WaitUntilStoppedAsync();
                }
                if (state.Phase != "stopped") throw new InvalidOperationException("服务尚未确认停止，窗口将保持打开。请重试关闭。");
                allowClose = true; startedThisSession = false;
            }
            catch (Exception ex) { SetError(UserError(ex)); }
            finally
            {
                busy = false; operationGate.Release();
                if (allowClose) BeginInvoke(new Action(Close));
                else { closing = false; timer.Start(); ApplyState(); }
            }
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); animationTimer.Dispose(); ClearImportedKey(); }
            base.Dispose(disposing);
        }
    }

    internal static class OfflineTests
    {
        internal static int Run(string requestedDirectory)
        {
            // All generated files are restricted to a new child of the explicitly supplied test directory.
            string parent = Path.GetFullPath(requestedDirectory);
            Directory.CreateDirectory(parent);
            for (DirectoryInfo item = new DirectoryInfo(parent); item != null; item = item.Parent)
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Test path crosses a reparse point.");
            string test = Path.Combine(parent, "ui-self-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(test);
            Dictionary<string, object> results = new Dictionary<string, object>();
            byte[] plain = null, unprotected = null;
            try
            {
                string gameDirectory = Path.Combine(test, "测试 游戏 (独立测试)");
                Directory.CreateDirectory(gameDirectory);
                string game = Path.Combine(gameDirectory, "DeltaForceClient-Win64-Shipping.exe");
                File.WriteAllBytes(game, new byte[] { 0, 1, 2 }); // Never executed.
                string privateDir = Path.Combine(test, "private");
                string key = Path.Combine(privateDir, "device-key.dpapi.bin");
                plain = Encoding.UTF8.GetBytes("OFFLINE-TEST-DEVICE-KEY-NOT-A-REAL-CREDENTIAL");
                MainForm.SaveEncryptedKey(privateDir, key, plain);
                unprotected = ProtectedData.Unprotect(File.ReadAllBytes(key), null, DataProtectionScope.CurrentUser);
                bool equal = plain.Length == unprotected.Length;
                for (int i = 0; equal && i < plain.Length; i++) equal = plain[i] == unprotected[i];
                results["dpapiCurrentUserRoundTrip"] = equal;
                SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
                DirectorySecurity acl = Directory.GetAccessControl(privateDir);
                bool aclValid = acl.AreAccessRulesProtected;
                AuthorizationRuleCollection rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier));
                foreach (FileSystemAccessRule rule in rules)
                    if (!sid.Equals(rule.IdentityReference) || rule.AccessControlType != AccessControlType.Allow) aclValid = false;
                results["privateAclCurrentSidOnly"] = aclValid && rules.Count == 1;
                string settings = Path.Combine(test, "user-settings.json");
                MainForm.SaveSettingsJson(settings, game);
                Dictionary<string, object> data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                results["chineseSpacesAndParenthesesJsonRoundTrip"] = data != null && (string)data["gameExecutable"] == game;
                results["fixedTrialDeadline"] = data != null && (string)data["trialDeadline"] == MainForm.TrialDeadline;
                Dictionary<string, object> legacy = new Dictionary<string, object>(); legacy["gameExecutable"] = game;
                results["legacySinglePathLoads"] = MainForm.ReadGamePaths(legacy).Count == 1 && MainForm.ReadGamePaths(legacy)[0] == game;
                string secondDirectory = Path.Combine(test, "WeGame 安装 (另一个入口)");
                Directory.CreateDirectory(secondDirectory);
                string secondGame = Path.Combine(secondDirectory, "DeltaForceClient-Win64-Shipping.exe");
                File.WriteAllBytes(secondGame, new byte[] { 0, 1, 2 }); // Never executed.
                data["unrelatedSetting"] = "preserved";
                File.WriteAllText(settings, new JavaScriptSerializer().Serialize(data), new UTF8Encoding(false));
                MainForm.SaveSettingsJson(settings, new string[] { game, secondGame, game.ToUpperInvariant() });
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                List<string> both = MainForm.ReadGamePaths(data);
                results["twoPathsSavedAndDeduplicated"] = both.Count == 2 && both[0] == game && both[1] == secondGame;
                results["unrelatedSettingsPreserved"] = (string)data["unrelatedSetting"] == "preserved";
                MainForm.SaveSettingsJson(settings, MainForm.ParseGamePathText(String.Join(Environment.NewLine, both)));
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                both = MainForm.ReadGamePaths(data);
                results["twoPathsSurviveSettingsTextRoundTrip"] = both.Count == 2 && both[0] == game && both[1] == secondGame;
                MainForm.SaveSettingsJson(settings, secondGame);
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                both = MainForm.ReadGamePaths(data);
                results["singlePathSaveKeepsOtherInstall"] = both.Count == 2 && both[0] == secondGame && both[1] == game && (string)data["gameExecutable"] == secondGame;
                Dictionary<string, object> arrayOnly = new Dictionary<string, object>(); arrayOnly["gameExecutables"] = new string[] { game, secondGame };
                results["arrayOnlySettingsLoad"] = MainForm.ReadGamePaths(arrayOnly).Count == 2;
                results["invalidSecondPathRejected"] = MainForm.ValidateSetupPaths(new string[] { game, Path.Combine(test, "missing.exe") }, "", true) != null;
                string sameGame = Path.Combine(gameDirectory, ".", "DeltaForceClient-Win64-Shipping.exe");
                results["equivalentPathsDoNotExceedLimit"] = MainForm.ValidateSetupPaths(new string[] { game, secondGame, game.ToUpperInvariant(), sameGame }, "", true) == null;
                string thirdDirectory = Path.Combine(test, "第三个安装");
                Directory.CreateDirectory(thirdDirectory);
                string thirdGame = Path.Combine(thirdDirectory, "DeltaForceClient-Win64-Shipping.exe");
                File.WriteAllBytes(thirdGame, new byte[] { 0, 1, 2 }); // Never executed.
                string beforeRejectedSave = File.ReadAllText(settings, Encoding.UTF8);
                bool thirdSaveRejected = false;
                try { MainForm.SaveSettingsJson(settings, new string[] { game, secondGame, thirdGame }); }
                catch (InvalidDataException) { thirdSaveRejected = true; }
                results["thirdDistinctPathRejectedWithoutChangingSettings"] =
                    MainForm.ValidateSetupPaths(new string[] { game, secondGame, thirdGame }, "", true) != null &&
                    thirdSaveRejected && File.ReadAllText(settings, Encoding.UTF8) == beforeRejectedSave;
                results["missingKeyRejected"] = MainForm.ValidateSetupInput(game, "", false) != null;
                results["missingGameRejected"] = MainForm.ValidateSetupInput(Path.Combine(test, "missing.exe"), "FAKE-KEY", false) != null;
                results["blankKeyPreservesExisting"] = MainForm.ValidateSetupInput(game, "", true) == null;
                string missingStatus = Path.Combine(test, "never-created-status.json");
                BackendState firstInstall = MainForm.ParseBackendResponse("{\"phase\":\"stopped\",\"ready\":false,\"routingMode\":\"ResolveOnly\"}");
                results["firstInstallWithoutStatusFile"] = !File.Exists(missingStatus) && firstInstall.Phase == "stopped";
                string staleFile = Path.Combine(test, "ui-status.json");
                File.WriteAllText(staleFile, "{\"phase\":\"connected\",\"ready\":true}");
                BackendState current = MainForm.ParseBackendResponse("{\"phase\":\"error\",\"ready\":false,\"message\":\"worker missing\"}");
                results["freshStdoutOverridesStaleConnectedFile"] = current.Phase == "error";
                results["startingIsValid"] = MainForm.ParseBackendResponse("{\"phase\":\"starting\",\"ready\":false}").Phase == "starting";
                results["stoppingIsValid"] = MainForm.ParseBackendResponse("{\"phase\":\"stopping\",\"ready\":false}").Phase == "stopping";
                bool invalidRejected = false;
                try { MainForm.ParseBackendResponse(""); } catch (InvalidOperationException) { invalidRejected = true; }
                results["invalidStdoutDoesNotFallbackToStaleFile"] = invalidRejected;
                DateTimeOffset epoch = new DateTimeOffset(2026, 9, 15, 0, 0, 0, TimeSpan.Zero);
                ConnectionWaitState wait = new ConnectionWaitState();
                BackendState pending = MainForm.ParseBackendResponse("{\"phase\":\"starting\",\"ready\":false}");
                wait.RecordStartupTiming = true;
                wait.Update(pending, false, epoch);
                pending.ProgressStage = "正在验证解析通道";
                wait.Update(pending, false, epoch.AddSeconds(7));
                results["waitingClockAdvancesWithoutBackendPoll"] = wait.IsWaiting && wait.ElapsedSeconds(epoch.AddSeconds(13)) == 13;
                results["stageUpdatesKeepOperationClock"] = wait.StepText(pending) == "正在验证解析通道" && wait.StartedAt == epoch;
                wait.Update(new BackendState { Phase = "error", Message = "请求失败" }, false, epoch.AddSeconds(14));
                results["failureStopsAnimationWithoutSuccessfulTiming"] = !wait.IsWaiting && !wait.StartedAt.HasValue && !wait.LastSuccessfulWaitSeconds.HasValue;
                wait.RecordStartupTiming = true;
                wait.Update(pending, false, epoch.AddSeconds(20));
                wait.Update(new BackendState { Phase = "stopping" }, false, epoch.AddSeconds(23));
                bool stopClockReset = wait.IsWaiting && wait.ElapsedSeconds(epoch.AddSeconds(25)) == 2;
                wait.Update(new BackendState { Phase = "stopped" }, false, epoch.AddSeconds(26));
                results["cancellationResetsStopClockWithoutSuccess"] = stopClockReset && !wait.IsWaiting && !wait.LastSuccessfulWaitSeconds.HasValue;
                wait.RecordStartupTiming = true;
                wait.Update(pending, false, epoch.AddSeconds(30));
                wait.Update(new BackendState { Phase = "connected", Ready = false }, false, epoch.AddSeconds(34));
                bool unreadyStillWaiting = wait.IsWaiting && !wait.LastSuccessfulWaitSeconds.HasValue;
                wait.Update(new BackendState { Phase = "connected", Ready = true }, false, epoch.AddSeconds(42));
                bool readyEnded = !wait.IsWaiting && wait.LastSuccessfulWaitSeconds == 12;
                wait.Update(pending, false, epoch.AddSeconds(50));
                results["onlyReadyConnectionRecordsReferenceWait"] = unreadyStillWaiting && readyEnded &&
                    wait.ElapsedSeconds(epoch.AddSeconds(50)) == 0 && wait.ReferenceText().Contains("12 秒，仅供参考");
                BackendState resumed = MainForm.ParseBackendResponse("{\"phase\":\"starting\",\"ready\":false,\"progressStage\":\"正在等待服务就绪\",\"operationStartedAt\":\"2026-09-15T00:00:00+00:00\"}");
                ConnectionWaitState reopened = new ConnectionWaitState();
                reopened.Update(new BackendState(), true, epoch.AddSeconds(18));
                bool initialCheckAnimated = reopened.IsWaiting && reopened.StepText(new BackendState()).Contains("读取");
                reopened.Update(resumed, false, epoch.AddSeconds(20));
                results["reopenedOperationUsesBackendOrigin"] = initialCheckAnimated && reopened.ElapsedSeconds(epoch.AddSeconds(20)) == 20 && reopened.StepText(resumed) == "正在等待服务就绪";
                ConnectionWaitState future = new ConnectionWaitState();
                future.Update(new BackendState { Phase = "starting", OperationStartedAt = epoch.AddMinutes(1) }, false, epoch);
                results["futureOriginDoesNotCreateNegativeWait"] = future.ElapsedSeconds(epoch.AddSeconds(3)) == 3;
                ConnectionWaitState alreadyReady = new ConnectionWaitState();
                alreadyReady.Update(new BackendState(), true, epoch);
                alreadyReady.Update(new BackendState { Phase = "connected", Ready = true }, false, epoch.AddSeconds(2));
                results["initialStatusReadDoesNotInventConnectionDuration"] = !alreadyReady.IsWaiting && !alreadyReady.LastSuccessfulWaitSeconds.HasValue;
                wait.Update(new BackendState { Phase = "connected", Ready = true }, false, epoch.AddSeconds(80));
                results["healthRecheckDoesNotReplaceStartupReference"] = !wait.IsWaiting && wait.LastSuccessfulWaitSeconds == 12;
                MainForm.SaveSuccessfulStartupWait(settings, 12.3);
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                both = MainForm.ReadGamePaths(data);
                results["startupTimingPersistsWithoutLosingSettings"] = MainForm.ReadSuccessfulStartupWait(data) == 12.3 &&
                    both.Count == 2 && both[0] == secondGame && both[1] == game && (string)data["unrelatedSetting"] == "preserved";
                MainForm.SaveSettingsJson(settings, both);
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                results["settingsSaveKeepsStartupTiming"] = MainForm.ReadSuccessfulStartupWait(data) == 12.3;
                data["lastSuccessfulStartupWaitSeconds"] = -4;
                bool invalidTimingIgnored = !MainForm.ReadSuccessfulStartupWait(data).HasValue;
                data["lastSuccessfulStartupWaitSeconds"] = "not a duration";
                results["invalidSavedTimingIsIgnored"] = invalidTimingIgnored && !MainForm.ReadSuccessfulStartupWait(data).HasValue;
                ConnectionWaitState missedReady = new ConnectionWaitState(); missedReady.RecordStartupTiming = true;
                missedReady.Update(new BackendState { Phase = "starting", OperationStartedAt = epoch }, false, epoch);
                missedReady.Update(new BackendState { Phase = "starting", OperationStartedAt = epoch.AddSeconds(9) }, false, epoch.AddSeconds(12));
                bool recheckClockReset = missedReady.ElapsedSeconds(epoch.AddSeconds(12)) == 3;
                missedReady.Update(new BackendState { Phase = "connected", Ready = true }, false, epoch.AddSeconds(15));
                results["changedBackendOriginDoesNotMislabelHealthRecheck"] = recheckClockReset && !missedReady.LastSuccessfulWaitSeconds.HasValue;
            }
            catch (Exception ex) { results["failureType"] = ex.GetType().Name; }
            finally
            {
                if (plain != null) Array.Clear(plain, 0, plain.Length);
                if (unprotected != null) Array.Clear(unprotected, 0, unprotected.Length);
            }
            bool passed = results.Count >= 34;
            foreach (object value in results.Values) if (!(value is bool) || !(bool)value) passed = false;
            results["passed"] = passed; results["networkStarted"] = false; results["realAppSettingsRead"] = false;
            results["testDirectory"] = test;
            string report = Path.Combine(test, "self-test-result.json");
            File.WriteAllText(report, new JavaScriptSerializer().Serialize(results), new UTF8Encoding(false));
            Console.WriteLine(report);
            return passed ? 0 : 1;
        }
    }
}
