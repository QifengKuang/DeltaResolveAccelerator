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
using System.Runtime.InteropServices;
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
            float previewScale = 0;
            string previewSize = null;
            bool resizeTest = false, interactivePreview = false, nativePreview = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--preview" && i + 1 < args.Length) previewPath = args[++i];
                else if (args[i] == "--preview-state" && i + 1 < args.Length) previewState = args[++i];
                else if (args[i] == "--self-test" && i + 1 < args.Length) selfTestPath = args[++i];
                else if (args[i] == "--preview-scale" && i + 1 < args.Length)
                    previewScale = Single.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture);
                else if (args[i] == "--preview-size" && i + 1 < args.Length) previewSize = args[++i];
                else if (args[i] == "--preview-resize-test") resizeTest = true;
                else if (args[i] == "--preview-interactive") interactivePreview = true;
                else if (args[i] == "--preview-native") nativePreview = true;
            }
            if (selfTestPath != null) { Environment.ExitCode = OfflineTests.Run(selfTestPath); return; }
            if (previewPath != null)
            {
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                try
                {
                // Preview deliberately bypasses mutex, settings, credentials and backend.
                using (MainForm form = new MainForm(true, previewState, previewScale))
                {
                    if (previewSize != null) form.SetPreviewSize(previewSize);
                    if (interactivePreview) { form.Text += " · 界面预览"; Application.Run(form); return; }
                    form.ShowInTaskbar = false;
                    form.StartPosition = FormStartPosition.Manual;
                    form.Location = new Point(-30000, -30000);
                    form.Opacity = nativePreview ? 1 : 0;
                    form.Show();
                    Application.DoEvents();
                    if (resizeTest) form.VerifyRepeatedResize();
                    string absolute = Path.GetFullPath(previewPath);
                    Directory.CreateDirectory(Path.GetDirectoryName(absolute));
                    using (Bitmap bitmap = new Bitmap(form.Width, form.Height))
                    {
                        if (nativePreview) form.PaintNativePreview(bitmap);
                        else form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                        bitmap.Save(absolute, ImageFormat.Png);
                    }
                    File.WriteAllText(absolute + ".layout.json", form.LayoutReport(), Encoding.UTF8);
                    form.Close();
                }
                }
                catch (Exception ex)
                {
                    string failurePath = Path.GetFullPath(previewPath) + ".error.txt";
                    Directory.CreateDirectory(Path.GetDirectoryName(failurePath));
                    File.WriteAllText(failurePath, ex.ToString(), Encoding.UTF8);
                    Environment.ExitCode = 1;
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
        internal static readonly Color Background = Color.FromArgb(247, 249, 246);
        internal static readonly Color Card = Color.FromArgb(255, 255, 253);
        internal static readonly Color Raised = Color.FromArgb(237, 242, 236);
        internal static readonly Color Border = Color.FromArgb(223, 232, 222);
        internal static readonly Color Text = Color.FromArgb(33, 54, 43);
        internal static readonly Color Muted = Color.FromArgb(104, 122, 110);
        internal static readonly Color Teal = Color.FromArgb(46, 105, 76);
        internal static readonly Color Mint = Color.FromArgb(229, 241, 224);
        internal static readonly Color DarkTeal = Color.FromArgb(35, 82, 61);
        internal static readonly Color Error = Color.FromArgb(170, 64, 53);
        internal static readonly Color Amber = Color.FromArgb(140, 103, 37);
        internal static Font Font(float size, bool bold)
        {
            // Pixel fonts and bounds use the same explicit scale; point fonts otherwise grow
            // independently of late-created controls on a high-DPI Windows desktop.
            return new Font("Microsoft YaHei UI", size * 96f / 72f,
                bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        }
        internal static float Scale(Control control)
        {
            MainForm form = control.FindForm() as MainForm;
            return form == null ? 1f : form.UiScale;
        }
        internal static void PaintBackdrop(Control child, Graphics graphics)
        {
            Control parent = child.Parent;
            if (parent == null) { graphics.Clear(Background); return; }
            Surface surface = parent as Surface;
            if (surface == null)
            {
                graphics.Clear(parent.BackColor.A == 255 ? parent.BackColor : Background);
                return;
            }
            GraphicsState saved = graphics.Save();
            graphics.TranslateTransform(-child.Left, -child.Top);
            surface.PaintSurface(graphics);
            graphics.Restore(saved);
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
        internal int Radius = 22;
        internal bool Outline;
        internal Color GradientEnd = Color.Empty;
        internal Surface()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.Opaque, true);
            BackColor = Palette.Background;
        }
        internal void PaintSurface(Graphics graphics)
        {
            if (Width < 2 || Height < 2) return;
            Palette.PaintBackdrop(this, graphics);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float scale = Palette.Scale(this);
            using (GraphicsPath path = Palette.Rounded(new RectangleF(.5f, .5f, Width - 1, Height - 1), Radius * scale))
            using (Brush brush = GradientEnd.IsEmpty ? (Brush)new SolidBrush(Fill) :
                new LinearGradientBrush(ClientRectangle, Fill, GradientEnd, 18f))
            using (Pen pen = new Pen(Stroke))
            { graphics.FillPath(brush, path); if (Outline) graphics.DrawPath(pen, path); }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            PaintSurface(e.Graphics);
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
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Opaque, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Font = Palette.Font(10.5f, true);
            Cursor = Cursors.Hand;
            TabStop = true;
            UseVisualStyleBackColor = false;
            BackColor = Palette.Background;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            // ButtonBase's transparent themed buffer can leave black pixels in live WM_PAINT.
            // Paint the entire rectangle explicitly, including the parent gradient at corners.
            Palette.PaintBackdrop(this, e.Graphics);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color fill = Primary ? Palette.Teal : Palette.Raised;
            if (!Enabled) fill = Color.FromArgb(220, 230, 219);
            else if (hover) fill = Primary ? Palette.DarkTeal : Color.FromArgb(222, 232, 220);
            using (GraphicsPath path = Palette.Rounded(new RectangleF(.5f, .5f, Width - 1, Height - 1), 13 * Palette.Scale(this)))
            using (Brush brush = new SolidBrush(fill))
            { e.Graphics.FillPath(brush, path); }
            Color text = Primary && Enabled ? Palette.Card : (Enabled ? Palette.Text : Palette.Muted);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            if (Focused && ShowFocusCues)
            {
                Rectangle focus = ClientRectangle; focus.Inflate(-5, -5);
                ControlPaint.DrawFocusRectangle(e.Graphics, focus, text, fill);
            }
        }
    }

    // Standard window actions remain keyboard-accessible without the native white title bar.
    internal sealed class WindowButton : Button
    {
        internal bool CloseAction;
        private bool hover;
        internal WindowButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer, true);
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0;
            BackColor = Palette.Background; Cursor = Cursors.Hand;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(hover ? (CloseAction ? Color.FromArgb(248, 229, 222) : Palette.Raised) : BackColor);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            float s = Palette.Scale(this), x = Width / 2f, y = Height / 2f;
            using (Pen pen = new Pen(CloseAction && hover ? Palette.Error : Palette.Muted, 1.35f * s))
            {
                e.Graphics.DrawLine(pen, x - 4 * s, CloseAction ? y - 4 * s : y, x + 4 * s, CloseAction ? y + 4 * s : y);
                if (CloseAction) e.Graphics.DrawLine(pen, x - 4 * s, y + 4 * s, x + 4 * s, y - 4 * s);
            }
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -6, -6));
        }
    }

    internal sealed class ResizeHandle : Control
    {
        internal int Edge;
        private Point dragOrigin;
        private Rectangle originalBounds;
        private bool dragging;
        internal ResizeHandle(int edge)
        {
            Edge = edge; BackColor = Palette.Background; TabStop = false;
            Cursor = edge == 10 || edge == 11 ? Cursors.SizeWE : edge == 12 || edge == 15 ? Cursors.SizeNS :
                edge == 13 || edge == 17 ? Cursors.SizeNWSE : Cursors.SizeNESW;
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            Form form = FindForm(); if (form == null) return;
            dragOrigin = PointToScreen(e.Location); originalBounds = form.Bounds;
            dragging = true; Capture = true;
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            MainForm form = FindForm() as MainForm;
            if (!dragging || !Capture || form == null) return;
            Point current = PointToScreen(e.Location);
            form.Bounds = MainForm.DragBounds(originalBounds, Edge, current.X - dragOrigin.X, current.Y - dragOrigin.Y,
                form.MinimumSize, form.MaximumSize);
        }
        protected override void OnMouseUp(MouseEventArgs e) { dragging = false; Capture = false; base.OnMouseUp(e); }
        protected override void OnMouseCaptureChanged(EventArgs e) { if (!Capture) dragging = false; base.OnMouseCaptureChanged(e); }
    }

    internal sealed class BrandMark : Control
    {
        internal BrandMark()
        {
            SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint |
                ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            BackColor = Color.Transparent; TabStop = false;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            g.ScaleTransform(Width / 48f, Height / 48f);
            using (GraphicsPath tile = Palette.Rounded(new RectangleF(0, 0, 48, 48), 13))
            using (Brush fill = new SolidBrush(Palette.Mint)) g.FillPath(fill, tile);
            using (Pen pen = new Pen(Palette.Teal, 2.5f))
            {
                pen.LineJoin = LineJoin.Round;
                g.DrawPolygon(pen, new PointF[] { new PointF(24, 10), new PointF(38, 35), new PointF(10, 35) });
            }
            using (Brush dot = new SolidBrush(Palette.Teal)) g.FillEllipse(dot, 22.5f, 25, 3, 3);
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
            GraphicsState saved = g.Save();
            // All illustration geometry shares one coordinate space, including at high DPI.
            g.ScaleTransform(Width / 244f, Height / 226f);
            float cx = 122, cy = 108;
            using (Brush halo = new SolidBrush(Color.FromArgb(45, 255, 255, 253)))
                g.FillEllipse(halo, 13, 0, 218, 218);
            using (Pen ring = new Pen(Color.FromArgb(92, 181, 201, 174), 1))
            {
                g.DrawEllipse(ring, cx - 100, cy - 100, 200, 200);
                g.DrawEllipse(ring, cx - 79, cy - 79, 158, 158);
            }
            using (Brush shadow = new SolidBrush(Color.FromArgb(18, 68, 102, 66)))
                g.FillEllipse(shadow, cx - 59, cy - 55, 118, 118);
            using (Brush disc = new LinearGradientBrush(new RectangleF(cx - 58, cy - 58, 116, 116),
                Color.FromArgb(254, 255, 250), Color.FromArgb(237, 247, 230), 65f))
                g.FillEllipse(disc, cx - 58, cy - 58, 116, 116);
            using (Pen symbol = new Pen(Palette.Teal, 4))
            {
                symbol.StartCap = symbol.EndCap = LineCap.Round; symbol.LineJoin = LineJoin.Round;
                g.DrawLines(symbol, new PointF[] { new PointF(cx - 22, cy + 14), new PointF(cx, cy - 25),
                    new PointF(cx + 22, cy + 14), new PointF(cx - 22, cy + 14) });
            }
            using (Brush dot = new SolidBrush(Palette.Teal)) g.FillEllipse(dot, cx - 3, cy + 1, 6, 6);
            if (Waiting)
            {
                using (Pen spinner = new Pen(Palette.Teal, 2.5f))
                { spinner.StartCap = spinner.EndCap = LineCap.Round; g.DrawArc(spinner, cx - 79, cy - 79, 158, 158, AnimationPhase * 360, 82); }
            }
            DrawNode(g, new PointF(202, 48), Connected ? Palette.Teal : Color.FromArgb(139, 171, 130), 4);
            DrawNode(g, new PointF(52, 175), Color.FromArgb(139, 171, 130), 3);
            g.Restore(saved);
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
            if (Phase == "checking") return "正在检查并恢复连接";
            if (!String.IsNullOrWhiteSpace(state.ProgressStage)) return state.ProgressStage;
            if (!String.IsNullOrWhiteSpace(state.Message)) return state.Message;
            return Phase == "stopping" ? "正在请求关闭并恢复连接设置" : "正在请求建立解析连接";
        }
        internal string ReferenceText()
        {
            if (Phase == "checking") return "若上次意外中断，将自动恢复连接设置。";
            if (Phase == "stopping") return "恢复完成后会自动停止动画。";
            return LastSuccessfulWaitSeconds.HasValue ? "上次等待 " + Math.Ceiling(LastSuccessfulWaitSeconds.Value).ToString("0") +
                " 秒，仅供参考" : "正在建立连接，耗时取决于网络";
        }
    }

    internal sealed class MintToggle : CheckBox
    {
        internal MintToggle()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.ResizeRedraw | ControlStyles.Opaque, true);
            Cursor = Cursors.Hand;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Palette.PaintBackdrop(this, e.Graphics);
            float scale = Palette.Scale(this);
            float width = 40 * scale, height = 22 * scale;
            RectangleF track = new RectangleF(Width - width - 2, (Height - height) / 2, width, height);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath shape = Palette.Rounded(track, height / 2))
            using (Brush fill = new SolidBrush(Checked ? Palette.Teal : Palette.Border)) e.Graphics.FillPath(fill, shape);
            float inset = 3 * scale, diameter = height - inset * 2;
            using (Brush knob = new SolidBrush(Color.White)) e.Graphics.FillEllipse(knob,
                Checked ? track.Right - diameter - inset : track.Left + inset, track.Top + inset, diameter, diameter);
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(0, 0, Math.Max(1, (int)track.Left - 12), Height),
                ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle, ForeColor, BackColor);
        }
    }

    internal sealed class MainForm : Form
    {
        internal float UiScale = 1f;
        private float displayScale = 1f;
        private bool layoutReady, resizingLayout;
        private readonly List<DesignControl> designControls = new List<DesignControl>();
        private readonly List<ResizeHandle> resizeHandles = new List<ResizeHandle>();
        private List<Font> scaledFonts = new List<Font>();
        private readonly List<string> resizeIssues = new List<string>();
        private int resizeChecks;
        private int ResizeGrip { get { return Math.Max(5, (int)Math.Round(6 * displayScale)); } }
        [DllImport("user32.dll")] private static extern bool ReleaseCapture();
        [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr handle, int index);
        [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr handle, IntPtr hdc, uint flags);
        [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr handle, int attribute, ref int value, int size);
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
        private readonly System.Windows.Forms.Timer updateTimer = new System.Windows.Forms.Timer();
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
        private readonly Panel gameSettingsPanel = new Panel();
        private readonly Panel softwareSettingsPanel = new Panel();
        private readonly FlatButton gameSettingsTab = new FlatButton();
        private readonly FlatButton softwareSettingsTab = new FlatButton();
        private readonly FlatButton findGamesButton = new FlatButton();
        private readonly FlatButton checkUpdatesButton = new FlatButton();
        private readonly FlatButton repairShortcutButton = new FlatButton();
        private readonly MintToggle automaticUpdates = new MintToggle();
        private readonly Label softwareStatus = MakeLabel("", 9, false, Palette.Muted);
        private readonly List<GamePathRow> gameRows = new List<GamePathRow>();
        private readonly ToolTip pathToolTip = new ToolTip();
        private readonly TextBox keyBox = new TextBox();
        private readonly FlatButton primary = new FlatButton();
        private readonly FlatButton settingsButton = new FlatButton();
        private readonly FlatButton copyError = new FlatButton();
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
        private bool softwareTabOpen, findingGames, softwareBusy, updatingPreference;
        private Dictionary<string, string> configuredPlatforms = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private byte[] importedKey;

        internal MainForm(bool previewMode, string previewState) : this(previewMode, previewState, 0) { }
        internal MainForm(bool previewMode, string previewState, float previewScale)
        {
            SuspendLayout();
            preview = previewMode;
            root = AppDomain.CurrentDomain.BaseDirectory;
            settingsPath = Path.Combine(root, "user-settings.json");
            privateDirectory = Path.Combine(root, "backend", "private");
            keyPath = Path.Combine(privateDirectory, "device-key.dpapi.bin");
            Text = "三角洲 · 主入口优化";
            BackColor = Palette.Background;
            ForeColor = Palette.Text;
            Font = Palette.Font(10, false);
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(860, 664);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;
            DoubleBuffered = true;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            shell.Dock = DockStyle.Fill; shell.Padding = new Padding(28, 8, 28, 20);
            shell.BackColor = Palette.Background; Controls.Add(shell);

            Panel chrome = new Panel { Dock = DockStyle.Top, Height = 36, BackColor = Palette.Background };
            Label chromeTitle = MakeLabel("DELTA  /  私人加速器", 7.5f, false, Palette.Muted);
            chromeTitle.SetBounds(29, 6, 270, 24);
            MouseEventHandler drag = delegate(object sender, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, new IntPtr(2), IntPtr.Zero); }
            };
            chrome.MouseDown += drag; chromeTitle.MouseDown += drag; chrome.Controls.Add(chromeTitle);
            WindowButton closeButton = new WindowButton { CloseAction = true, AccessibleName = "关闭窗口", TabIndex = 9 };
            WindowButton minimizeButton = new WindowButton { AccessibleName = "最小化", TabIndex = 8 };
            closeButton.SetBounds(812, 2, 40, 32); minimizeButton.SetBounds(772, 2, 40, 32);
            closeButton.Anchor = minimizeButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            closeButton.Click += delegate { Close(); }; minimizeButton.Click += delegate { WindowState = FormWindowState.Minimized; };
            chrome.Controls.Add(closeButton); chrome.Controls.Add(minimizeButton); Controls.Add(chrome);
            chrome.Resize += delegate { closeButton.Left = chrome.ClientSize.Width - Px(48); minimizeButton.Left = chrome.ClientSize.Width - Px(88); };

            Panel header = new Panel { Dock = DockStyle.Top, Height = 86, BackColor = Palette.Background };
            BrandMark brandIcon = new BrandMark();
            brandIcon.SetBounds(0, 10, 48, 48);
            header.Controls.Add(brandIcon);
            headline = MakeLabel("三角洲", 22, true, Palette.Text);
            headline.SetBounds(64, 0, 480, 46); header.Controls.Add(headline);
            Label sub = MakeLabel("主入口优化  ·  让连接轻一点", 9, false, Palette.Muted);
            sub.SetBounds(65, 47, 480, 24); header.Controls.Add(sub);
            settingsButton.Text = "设置"; settingsButton.SetBounds(712, 13, 92, 38);
            settingsButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            settingsButton.Click += delegate { if (!busy && state.Phase == "stopped") OpenSettings(); };
            header.Controls.Add(settingsButton);
            header.Resize += delegate { settingsButton.Left = header.ClientSize.Width - settingsButton.Width; };
            Panel bottom = new Panel { Dock = DockStyle.Bottom, Height = 26, BackColor = Palette.Background };
            footer = MakeLabel("私人专线   /   试用至 2026-11-13   ·   独立设备密钥", 8, false, Palette.Muted);
            footer.Dock = DockStyle.Fill; footer.TextAlign = ContentAlignment.BottomCenter; bottom.Controls.Add(footer);
            Panel body = new Panel { Dock = DockStyle.Fill, BackColor = Palette.Background };
            shell.Controls.Add(body); shell.Controls.Add(bottom); shell.Controls.Add(header);
            dashboard.Dock = DockStyle.Fill; settings.Dock = DockStyle.Fill;
            dashboard.BackColor = settings.BackColor = Palette.Background;
            body.Controls.Add(dashboard); body.Controls.Add(settings);

            hero.SetBounds(0, 0, 804, 276); hero.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
            hero.Fill = Palette.Mint; hero.GradientEnd = Color.FromArgb(240, 246, 230); hero.Radius = 26;
            dashboard.Controls.Add(hero);
            Label eyebrow = MakeLabel("连接状态", 9, false, Palette.Muted);
            eyebrow.SetBounds(28, 23, 250, 26); hero.Controls.Add(eyebrow);
            phasePill = MakeLabel("待机", 9, true, Palette.Muted);
            phasePill.SetBounds(618, 24, 158, 26); phasePill.TextAlign = ContentAlignment.MiddleRight;
            phasePill.Anchor = AnchorStyles.Top | AnchorStyles.Right; hero.Controls.Add(phasePill);
            stateTitle = MakeLabel("准备就绪", 28, true, Palette.Text);
            stateTitle.SetBounds(26, 59, 470, 64); hero.Controls.Add(stateTitle);
            stateMessage = MakeLabel("开启后，主入口解析经香港，对局流量保持直连。", 10, false, Palette.Muted);
            stateMessage.SetBounds(29, 126, 472, 58); hero.Controls.Add(stateMessage);
            primary.Primary = true; primary.Text = "开启加速";
            primary.SetBounds(28, 204, 206, 48);
            primary.Click += async delegate { await ToggleAsync(); }; hero.Controls.Add(primary);
            connectionDetail = MakeLabel("只优化入口解析", 9, false, Palette.Muted);
            connectionDetail.SetBounds(252, 214, 225, 28); hero.Controls.Add(connectionDetail);
            art.SetBounds(533, 48, 244, 226); art.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            hero.Controls.Add(art); art.SendToBack();

            resolverCard.SetBounds(0, 292, 394, 108); battleCard.SetBounds(410, 292, 394, 108);
            dashboard.Controls.Add(resolverCard); dashboard.Controls.Add(battleCard);
            AddRouteCard(resolverCard, "入口解析", "香港中转", "仅优化指定入口解析", Palette.Teal);
            AddRouteCard(battleCard, "对局流量", "本机直连", "实际延迟以游戏内显示为准", Palette.Text);
            infoCard.SetBounds(0, 416, 804, 72); infoCard.Fill = Palette.Raised; infoCard.Radius = 18;
            dashboard.Controls.Add(infoCard);
            infoText = MakeLabel("准备好后开启加速，再启动游戏。\r\n加速器会保持运行，关闭窗口时会先安全停止。", 9, false, Palette.Muted);
            infoText.SetBounds(24, 12, 630, 48); infoText.AutoEllipsis = true; infoCard.Controls.Add(infoText);
            copyError.Text = "复制错误"; copyError.SetBounds(667, 18, 113, 36);
            copyError.Click += delegate { CopyError(); }; infoCard.Controls.Add(copyError);

            setupCard.Dock = DockStyle.Fill; settings.Controls.Add(setupCard);
            Label setupTitle = MakeLabel("偏好设置", 20, true, Palette.Text);
            setupTitle.SetBounds(27, 13, 380, 40); setupCard.Controls.Add(setupTitle);
            gameSettingsTab.Text = "游戏与密钥"; gameSettingsTab.SetBounds(488, 17, 144, 36);
            softwareSettingsTab.Text = "软件"; softwareSettingsTab.SetBounds(644, 17, 131, 36);
            gameSettingsTab.Click += delegate { SelectSettingsTab(false); };
            softwareSettingsTab.Click += delegate { SelectSettingsTab(true); };
            setupCard.Controls.Add(gameSettingsTab); setupCard.Controls.Add(softwareSettingsTab);
            gameSettingsPanel.SetBounds(29, 70, 746, 334); gameSettingsPanel.BackColor = Palette.Card;
            softwareSettingsPanel.SetBounds(29, 70, 746, 334); softwareSettingsPanel.BackColor = Palette.Card;
            setupCard.Controls.Add(gameSettingsPanel); setupCard.Controls.Add(softwareSettingsPanel);
            Label gameLabel = MakeLabel("游戏位置 · 只需设置已安装的平台", 9, false, Palette.Muted);
            gameLabel.SetBounds(0, 0, 520, 32); gameSettingsPanel.Controls.Add(gameLabel);
            findGamesButton.Text = "自动查找"; findGamesButton.SetBounds(610, 0, 136, 32);
            findGamesButton.Click += async delegate { await FindGamesAsync(); }; gameSettingsPanel.Controls.Add(findGamesButton);
            CreateGameRow("Steam", 42); CreateGameRow("WeGame", 134);
            Label keyLabel = MakeLabel("独立设备密钥", 10, true, Palette.Text);
            keyLabel.SetBounds(0, 227, 500, 28); gameSettingsPanel.Controls.Add(keyLabel);
            importKeyButton.Text = "导入已有密钥";
            importKeyButton.SetBounds(586, 225, 160, 30);
            importKeyButton.Font = Palette.Font(8.5f, false);
            importKeyButton.Click += delegate { ImportKey(); };
            gameSettingsPanel.Controls.Add(importKeyButton);
            AddTextField(gameSettingsPanel, keyBox, 0, 263, 746, 39, true);
            keyHint = MakeLabel("每台电脑一份密钥，请勿与朋友共用。密钥仅加密保存在本机。", 8.5f, false, Palette.Muted);
            keyHint.SetBounds(0, 309, 746, 24); gameSettingsPanel.Controls.Add(keyHint);
            keyBox.TextChanged += delegate { if (keyBox.TextLength > 0) ClearImportedKey(); };
            settingsError = MakeLabel("", 9, false, Palette.Error);
            settingsError.SetBounds(29, 409, 746, 24); settingsError.AutoEllipsis = true; setupCard.Controls.Add(settingsError);
            saveButton.Primary = true; saveButton.Text = "保存设置";
            saveButton.SetBounds(29, 441, 206, 38); saveButton.Click += delegate { SaveSettings(); };
            setupCard.Controls.Add(saveButton);
            cancelSettings.Text = "返回"; cancelSettings.SetBounds(250, 441, 105, 38);
            cancelSettings.Click += delegate { ClearImportedKey(); keyBox.Clear(); settingsOpen = false; ShowCurrentView(); }; setupCard.Controls.Add(cancelSettings);
            BuildSoftwareSettings();

            dashboard.Resize += delegate { LayoutDashboard(); };
            body.Resize += delegate { LayoutSettings(); };
            timer.Interval = 8000; timer.Tick += async delegate
            {
                await RefreshStatusAsync();
                if (softwareTabOpen && settingsOpen && !softwareBusy && !preview && !closing)
                    try { softwareStatus.Text = UpdateManager.ReadStatus(root); } catch { }
            };
            updateTimer.Interval = 30 * 60 * 1000;
            updateTimer.Tick += delegate { if (!preview && !closing) UpdateManager.CheckInBackground(root); };
            animationTimer.Interval = 40;
            animationTimer.Tick += delegate { RefreshWaitingPresentation(); };
            Shown += async delegate
            {
                LayoutDashboard(); LayoutSettings();
                if (preview) return;
                UpdateManager.CheckInBackground(root);
                updateTimer.Start();
                try { await RefreshStatusAsync(true); }
                finally { initialStatusPending = false; ApplyState(); }
                if (!closing) timer.Start();
            };
            FormClosing += ClosingAsync;
            if (preview)
            {
                configured = true;
                configuredGamePaths.Add(@"D:\SteamLibrary\steamapps\common\Delta Force\Game\DeltaForce\Binaries\Win64\DeltaForceClient-Win64-Shipping.exe");
                string requested = (previewState ?? "stopped").ToLowerInvariant();
                settingsOpen = requested == "setup" || requested == "settings" || requested == "software";
                state.Phase = requested == "connected" ? "connected" : requested == "error" ? "error" : requested == "starting" ? "starting" : requested == "stopping" ? "stopping" : "stopped";
                initialStatusPending = requested == "checking";
                state.Ready = state.Phase == "connected";
                state.Message = state.Phase == "error" ? "暂时无法连接香港解析服务。请检查网络后重试。" : "";
                if (state.Phase == "starting")
                {
                    state.ProgressStage = "正在等待香港解析服务就绪";
                    state.OperationStartedAt = DateTimeOffset.Now.AddSeconds(-12);
                }
                if (settingsOpen) configured = requested != "setup";
                LoadPathRows(requested == "setup" ? new List<string>() : configuredGamePaths);
                if (requested == "settings") { gameRows[1].Path = @"E:\WeGameApps\三角洲行动\Game\DeltaForce\Binaries\Win64\DeltaForceClient-Win64-Shipping.exe"; RefreshGameRows(); }
                softwareTabOpen = requested == "software";
                errorText = state.Message;
                footer.Text = "界面预览 · 模拟状态 · 未连接服务   /   试用至 2026-11-13";
            }
            else { LoadSettings(); initialStatusPending = true; }
            if (softwareTabOpen) RefreshSoftwareSettings();
            ApplyState();
            ResumeLayout(false); PerformLayout(); LayoutDashboard(); LayoutSettings();
            float scale;
            using (Graphics graphics = CreateGraphics()) scale = graphics.DpiX / 96f;
            if (preview && previewScale >= .75f && previewScale <= 3f) scale = previewScale;
            InitializeDisplayScale(scale);
        }

        private static Label MakeLabel(string text, float size, bool bold, Color color)
        {
            return new Label { Text = text, Font = Palette.Font(size, bold), ForeColor = color,
                BackColor = Color.Transparent, AutoSize = false, UseMnemonic = false,
                TextAlign = ContentAlignment.MiddleLeft };
        }
        private static void AddRouteCard(Surface parent, string heading, string value, string note, Color accent)
        {
            Label name = MakeLabel(heading, 8.5f, false, Palette.Muted); name.SetBounds(24, 13, 335, 23);
            Label title = MakeLabel(value, 17, true, accent); title.SetBounds(22, 37, 337, 36);
            Label hint = MakeLabel(note, 8.5f, false, Palette.Muted); hint.SetBounds(24, 76, 340, 22);
            parent.Controls.Add(name); parent.Controls.Add(title); parent.Controls.Add(hint);
        }
        private static void AddTextField(Control parent, TextBox box, int x, int y, int width, int height, bool secret)
        {
            Surface field = new Surface { Fill = Palette.Background, Radius = 10, Outline = true };
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
            hero.Height = Math.Max(Px(276), dashboard.ClientSize.Height - Px(212));
            int gap = Px(16), half = (width - gap) / 2;
            resolverCard.SetBounds(0, hero.Bottom + gap, half, Px(108));
            battleCard.SetBounds(half + gap, hero.Bottom + gap, width - half - gap, Px(108));
            infoCard.Top = resolverCard.Bottom + gap;
            int extraHero = hero.Height - Px(276);
            stateTitle.Top = Px(59) + extraHero / 2;
            stateMessage.Top = Px(126) + extraHero / 2;
            primary.Top = Px(204) + extraHero / 2; connectionDetail.Top = primary.Top + Px(10);
            copyError.Left = width - Px(137); infoText.Width = width - Px(copyError.Visible ? 180 : 48);
            phasePill.Left = width - Px(186); art.Left = width - Px(271); art.Top = Px(48) + extraHero / 2;
        }
        private void LayoutSettings()
        {
            int width = setupCard.ClientSize.Width;
            if (width < 300) return;
            softwareSettingsTab.Left = width - Px(160); gameSettingsTab.Left = width - Px(316);
            gameSettingsPanel.Width = softwareSettingsPanel.Width = width - Px(58);
            int content = gameSettingsPanel.ClientSize.Width;
            findGamesButton.Left = content - Px(136);
            foreach (GamePathRow row in gameRows)
            {
                row.Card.Width = content;
                row.Status.Left = content - Px(250); row.Status.Width = Px(232);
                row.ChooseFile.Left = content - Px(253); row.ChooseFolder.Left = content - Px(171); row.Clear.Left = content - Px(74);
                row.PathLabel.Width = content - Px(285);
            }
            keyBox.Parent.Width = content;
            keyHint.Width = content;
            importKeyButton.Left = content - Px(160);
            settingsError.Width = width - Px(58);
            softwareStatus.Width = content;
            repairShortcutButton.Left = content - Px(176);
        }
        private sealed class GamePathRow
        {
            internal string Slot, Platform, Path = "";
            internal Surface Card;
            internal Label Title, Status, PathLabel;
            internal FlatButton ChooseFile, ChooseFolder, Clear;
        }
        private void CreateGameRow(string platform, int top)
        {
            GamePathRow row = new GamePathRow { Slot = platform, Platform = platform,
                Card = new Surface { Fill = Palette.Background, Radius = 14 },
                Title = MakeLabel(platform, 10, true, Palette.Text),
                Status = MakeLabel("未设置", 8.5f, false, Palette.Muted),
                PathLabel = MakeLabel("选择游戏程序或安装文件夹", 8.5f, false, Palette.Muted),
                ChooseFile = new FlatButton(), ChooseFolder = new FlatButton(), Clear = new FlatButton() };
            row.Card.SetBounds(0, top, 746, 82); row.Title.SetBounds(16, 5, 440, 28);
            row.Status.SetBounds(496, 5, 232, 28); row.Status.TextAlign = ContentAlignment.MiddleRight;
            row.PathLabel.SetBounds(16, 41, 461, 27); row.PathLabel.AutoEllipsis = true;
            row.ChooseFile.Text = "选程序"; row.ChooseFile.SetBounds(493, 39, 76, 30);
            row.ChooseFolder.Text = "选文件夹"; row.ChooseFolder.SetBounds(575, 39, 91, 30);
            row.Clear.Text = "移除"; row.Clear.SetBounds(672, 39, 58, 30);
            row.ChooseFile.Font = row.ChooseFolder.Font = row.Clear.Font = Palette.Font(8.5f, false);
            row.ChooseFile.Click += async delegate { await BrowseGameAsync(row, false); };
            row.ChooseFolder.Click += async delegate { await BrowseGameAsync(row, true); };
            row.Clear.Click += delegate { row.Path = ""; row.Platform = row.Slot; RefreshGameRows(); settingsError.Text = "已移除，保存后生效。"; };
            row.Card.Controls.Add(row.Title); row.Card.Controls.Add(row.Status); row.Card.Controls.Add(row.PathLabel);
            row.Card.Controls.Add(row.ChooseFile); row.Card.Controls.Add(row.ChooseFolder); row.Card.Controls.Add(row.Clear);
            gameSettingsPanel.Controls.Add(row.Card); gameRows.Add(row);
        }
        private void LoadPathRows(IList<string> paths)
        {
            foreach (GamePathRow row in gameRows) { row.Path = ""; row.Platform = row.Slot; }
            foreach (string path in paths)
            {
                string platform;
                if (!configuredPlatforms.TryGetValue(path, out platform)) platform = GameDiscovery.DetectPlatform(path);
                GamePathRow available = gameRows.Find(delegate(GamePathRow row) { return row.Path.Length == 0 && row.Slot == platform; });
                if (available == null) available = gameRows.Find(delegate(GamePathRow row) { return row.Path.Length == 0; });
                if (available == null) { settingsError.Text = GamePathLimitMessage; break; }
                available.Path = path; available.Platform = platform;
            }
            RefreshGameRows();
        }
        private void RefreshGameRows()
        {
            foreach (GamePathRow row in gameRows)
            {
                bool present = row.Path.Length > 0;
                bool valid = present && (preview ? row == gameRows[0] : ValidGamePath(row.Path));
                row.Title.Text = present && row.Platform.Length == 0 ? "已保存路径 · 未分类" : present ? row.Platform : row.Slot;
                row.Status.Text = !present ? "未设置 · 可选" : valid ? "●  可用" : "●  路径失效 · 重新选择";
                row.Status.ForeColor = !present ? Palette.Muted : valid ? Palette.Teal : Palette.Amber;
                row.PathLabel.Text = present ? row.Path : "选择游戏程序或安装文件夹";
                row.ChooseFile.Text = present ? "替换" : "选程序";
                row.Clear.Enabled = present && !busy && !findingGames;
                pathToolTip.SetToolTip(row.PathLabel, present ? row.Path : "可以选择游戏安装文件夹，自动定位游戏程序。");
            }
        }
        private void BuildSoftwareSettings()
        {
            Label version = MakeLabel("三角洲加速器  " + Application.ProductVersion, 16, true, Palette.Text);
            version.SetBounds(0, 0, 730, 34); softwareSettingsPanel.Controls.Add(version);
            automaticUpdates.Text = "自动检查更新"; automaticUpdates.Font = Palette.Font(10, true);
            automaticUpdates.ForeColor = Palette.Text; automaticUpdates.BackColor = Palette.Card;
            automaticUpdates.SetBounds(0, 56, 730, 29); softwareSettingsPanel.Controls.Add(automaticUpdates);
            Label updateNote = MakeLabel("启动时检查新版本，更新就绪后将在下次启动时安装。", 9, false, Palette.Muted);
            updateNote.SetBounds(0, 91, 730, 27); softwareSettingsPanel.Controls.Add(updateNote);
            checkUpdatesButton.Text = "检查更新"; checkUpdatesButton.Primary = true;
            checkUpdatesButton.SetBounds(0, 133, 170, 38); softwareSettingsPanel.Controls.Add(checkUpdatesButton);
            checkUpdatesButton.Click += async delegate { await CheckSoftwareUpdateAsync(); };
            softwareStatus.SetBounds(0, 181, 746, 44); softwareStatus.AutoEllipsis = true; softwareSettingsPanel.Controls.Add(softwareStatus);
            Label shortcutTitle = MakeLabel("桌面快捷方式", 11, true, Palette.Text);
            shortcutTitle.SetBounds(0, 245, 520, 28); softwareSettingsPanel.Controls.Add(shortcutTitle);
            Label shortcutHint = MakeLabel("重新建立桌面和开始菜单入口，之后更新可继续使用同一个快捷方式。", 9, false, Palette.Muted);
            shortcutHint.SetBounds(0, 285, 730, 44); softwareSettingsPanel.Controls.Add(shortcutHint);
            repairShortcutButton.Text = "修复快捷方式"; repairShortcutButton.SetBounds(570, 241, 176, 38);
            repairShortcutButton.Click += async delegate { await RepairShortcutAsync(); }; softwareSettingsPanel.Controls.Add(repairShortcutButton);
            automaticUpdates.CheckedChanged += delegate
            {
                if (preview || updatingPreference) return;
                try { UpdateManager.SetAutomaticChecksEnabled(root, automaticUpdates.Checked); softwareStatus.Text = automaticUpdates.Checked ? "已开启自动检查更新。" : "已关闭自动检查，可随时手动检查。"; }
                catch { softwareStatus.Text = "偏好未保存，请检查安装目录写入权限。"; RefreshSoftwareSettings(); }
            };
        }
        private void RefreshSoftwareSettings()
        {
            updatingPreference = true;
            try
            {
                automaticUpdates.Checked = preview || UpdateManager.AutomaticChecksEnabled(root);
                softwareStatus.Text = preview ? "当前已是最新版本 · 自动更新已开启" : UpdateManager.ReadStatus(root);
            }
            catch { softwareStatus.Text = "无法读取更新状态，请稍后重试。"; }
            finally { updatingPreference = false; }
        }
        private void SelectSettingsTab(bool software, bool refresh = true)
        {
            softwareTabOpen = software;
            gameSettingsPanel.Visible = !software; softwareSettingsPanel.Visible = software;
            gameSettingsTab.Primary = !software; softwareSettingsTab.Primary = software;
            gameSettingsTab.Invalidate(); softwareSettingsTab.Invalidate();
            saveButton.Visible = !software;
            cancelSettings.Visible = configured || software;
            settingsError.Visible = !software;
            if (software && refresh) RefreshSoftwareSettings();
        }
        private async Task CheckSoftwareUpdateAsync()
        {
            if (preview || softwareBusy || closing) return;
            softwareBusy = true; checkUpdatesButton.Enabled = repairShortcutButton.Enabled = false;
            softwareStatus.Text = "正在检查更新…";
            try
            {
                await Task.Run(delegate { return UpdateManager.CheckNow(root); });
                if (!IsDisposed) softwareStatus.Text = UpdateManager.ReadStatus(root);
            }
            catch { if (!IsDisposed) softwareStatus.Text = "暂时无法检查更新，请稍后重试。"; }
            finally { softwareBusy = false; if (!IsDisposed) checkUpdatesButton.Enabled = repairShortcutButton.Enabled = true; }
        }
        private async Task RepairShortcutAsync()
        {
            if (preview || softwareBusy || closing) return;
            softwareBusy = true; checkUpdatesButton.Enabled = repairShortcutButton.Enabled = false;
            softwareStatus.Text = "正在修复桌面和开始菜单快捷方式…";
            try
            {
                int exitCode = await Task.Run(delegate
                {
                    string launcher = Path.Combine(root, "DeltaLauncher.exe");
                    using (Process process = Process.Start(new ProcessStartInfo(launcher, "--repair-shortcuts")
                    { WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
                    {
                        if (!process.WaitForExit(15000)) return -1;
                        return process.ExitCode;
                    }
                });
                if (!IsDisposed) softwareStatus.Text = exitCode == 0 ? "桌面和开始菜单快捷方式已修复。" : "快捷方式修复未完成，请稍后重试。";
            }
            catch { if (!IsDisposed) softwareStatus.Text = "未找到完整安装程序，请重新运行安装包以修复入口。"; }
            finally { softwareBusy = false; if (!IsDisposed) checkUpdatesButton.Enabled = repairShortcutButton.Enabled = true; }
        }
        private int Px(int designPixels) { return (int)Math.Round(designPixels * UiScale); }

        private sealed class DesignControl
        {
            internal Control Control;
            internal Rectangle Bounds;
            internal Padding Padding;
            internal string FontFamily;
            internal float FontSize;
            internal FontStyle FontStyle;
        }
        private static void CollectDesign(Control control, List<DesignControl> controls)
        {
            controls.Add(new DesignControl { Control = control, Bounds = control.Bounds, Padding = control.Padding,
                FontFamily = control.Font.FontFamily.Name, FontSize = control.Font.Size, FontStyle = control.Font.Style });
            foreach (Control child in control.Controls) CollectDesign(child, controls);
        }
        private void InitializeDisplayScale(float scale)
        {
            CollectDesign(this, designControls);
            displayScale = scale;
            foreach (int edgeId in new int[] { 10, 11, 12, 15, 13, 14, 16, 17 })
            {
                ResizeHandle handle = new ResizeHandle(edgeId);
                resizeHandles.Add(handle); Controls.Add(handle); handle.BringToFront();
            }
            int edge = ResizeGrip * 2;
            Size maximum = new Size((int)Math.Round(1280 * scale) + edge, (int)Math.Round(960 * scale) + edge);
            if (!preview)
            {
                Size workArea = Screen.FromControl(this).WorkingArea.Size;
                maximum = new Size(Math.Min(maximum.Width, workArea.Width), Math.Min(maximum.Height, workArea.Height));
            }
            MaximumSize = maximum;
            MinimumSize = new Size(Math.Min((int)Math.Round(720 * scale) + edge, maximum.Width),
                Math.Min((int)Math.Round(556 * scale) + edge, maximum.Height));
            ClientSize = new Size(Math.Min((int)Math.Round(860 * scale) + edge, maximum.Width),
                Math.Min((int)Math.Round(664 * scale) + edge, maximum.Height));
            layoutReady = true;
            LayoutForWindowSize();
        }
        protected override void OnClientSizeChanged(EventArgs e)
        {
            base.OnClientSizeChanged(e);
            if (layoutReady && !resizingLayout && WindowState != FormWindowState.Minimized) LayoutForWindowSize();
        }
        private void LayoutForWindowSize()
        {
            if (resizingLayout || ClientSize.Width < 1 || ClientSize.Height < 1) return;
            resizingLayout = true;
            List<Font> newFonts = new List<Font>();
            Dictionary<string, Font> fontCache = new Dictionary<string, Font>();
            try
            {
                // Immutable logical rectangles/font sizes prevent cumulative shrink/growth.
                UiScale = Math.Max(.1f, Math.Min((ClientSize.Width - ResizeGrip * 2) / 860f,
                    (ClientSize.Height - ResizeGrip * 2) / 664f));
                foreach (DesignControl item in designControls) item.Control.SuspendLayout();
                foreach (DesignControl item in designControls)
                {
                    Control control = item.Control;
                    if (control != this) control.Bounds = new Rectangle(Px(item.Bounds.X), Px(item.Bounds.Y), Px(item.Bounds.Width), Px(item.Bounds.Height));
                    string key = item.FontFamily + "/" + item.FontSize.ToString(System.Globalization.CultureInfo.InvariantCulture) + "/" + item.FontStyle;
                    Font font;
                    if (!fontCache.TryGetValue(key, out font))
                    {
                        font = new Font(item.FontFamily, item.FontSize * UiScale, item.FontStyle, GraphicsUnit.Pixel);
                        fontCache.Add(key, font); newFonts.Add(font);
                    }
                    control.Font = font;
                    control.Padding = control == this ? new Padding(ResizeGrip) :
                        new Padding(Px(item.Padding.Left), Px(item.Padding.Top), Px(item.Padding.Right), Px(item.Padding.Bottom));
                }
                for (int i = designControls.Count - 1; i >= 0; i--) designControls[i].Control.ResumeLayout(false);
                PerformLayout();
                foreach (DesignControl item in designControls) item.Control.PerformLayout();
                LayoutDashboard(); LayoutSettings();
                LayoutResizeHandles();
                // WinForms can ignore a Font assignment when its value equals the old one.
                // Only release objects no control actually references after all assignments.
                List<Font> activeFonts = new List<Font>();
                foreach (DesignControl item in designControls) activeFonts.Add(item.Control.Font);
                newFonts.AddRange(scaledFonts);
                scaledFonts = new List<Font>();
                foreach (Font font in newFonts)
                {
                    bool inUse = activeFonts.Exists(delegate(Font active) { return Object.ReferenceEquals(active, font); });
                    if (inUse) scaledFonts.Add(font); else font.Dispose();
                }
                Invalidate(true);
            }
            finally { resizingLayout = false; }
        }
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.Style &= ~(0x00c00000 | 0x00040000); // No caption, border or native thick frame.
                return cp;
            }
        }
        private void LayoutResizeHandles()
        {
            int g = ResizeGrip, w = ClientSize.Width, h = ClientSize.Height;
            foreach (ResizeHandle handle in resizeHandles)
            {
                switch (handle.Edge)
                {
                    case 10: handle.SetBounds(0, g, g, Math.Max(1, h - 2 * g)); break;
                    case 11: handle.SetBounds(w - g, g, g, Math.Max(1, h - 2 * g)); break;
                    case 12: handle.SetBounds(g, 0, Math.Max(1, w - 2 * g), g); break;
                    case 15: handle.SetBounds(g, h - g, Math.Max(1, w - 2 * g), g); break;
                    case 13: handle.SetBounds(0, 0, g, g); break;
                    case 14: handle.SetBounds(w - g, 0, g, g); break;
                    case 16: handle.SetBounds(0, h - g, g, g); break;
                    case 17: handle.SetBounds(w - g, h - g, g, g); break;
                }
            }
        }
        internal static Rectangle DragBounds(Rectangle original, int edge, int dx, int dy, Size minimum, Size maximum)
        {
            bool left = edge == 10 || edge == 13 || edge == 16;
            bool right = edge == 11 || edge == 14 || edge == 17;
            bool top = edge == 12 || edge == 13 || edge == 14;
            bool bottom = edge == 15 || edge == 16 || edge == 17;
            int width = Math.Max(minimum.Width, Math.Min(maximum.Width, original.Width + (left ? -dx : right ? dx : 0)));
            int height = Math.Max(minimum.Height, Math.Min(maximum.Height, original.Height + (top ? -dy : bottom ? dy : 0)));
            return new Rectangle(left ? original.Right - width : original.Left,
                top ? original.Bottom - height : original.Top, width, height);
        }
        internal int ResizeHitTest(Point point)
        {
            int grip = ResizeGrip;
            bool left = point.X >= 0 && point.X < grip;
            bool right = point.X >= ClientSize.Width - grip && point.X < ClientSize.Width;
            bool top = point.Y >= 0 && point.Y < grip;
            bool bottom = point.Y >= ClientSize.Height - grip && point.Y < ClientSize.Height;
            if (left && top) return 13; if (right && top) return 14;
            if (left && bottom) return 16; if (right && bottom) return 17;
            if (left) return 10; if (right) return 11;
            if (top) return 12; if (bottom) return 15;
            return 1;
        }
        protected override void WndProc(ref Message message)
        {
            // All window chrome is client-drawn; child grips provide resizing without a native frame.
            if (message.Msg == 0x0083 || message.Msg == 0x0085) { message.Result = IntPtr.Zero; return; }
            if (message.Msg == 0x0086) { message.Result = new IntPtr(1); return; }
            if (message.Msg == 0x0084 && layoutReady && WindowState == FormWindowState.Normal)
            {
                long coordinates = message.LParam.ToInt64();
                Point screen = new Point(unchecked((short)(coordinates & 0xffff)), unchecked((short)((coordinates >> 16) & 0xffff)));
                int hit = ResizeHitTest(PointToClient(screen));
                if (hit != 1) { message.Result = new IntPtr(hit); return; }
            }
            base.WndProc(ref message);
        }
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                int rounded = 2, noBorder = unchecked((int)0xFFFFFFFE);
                DwmSetWindowAttribute(Handle, 33, ref rounded, 4);
                DwmSetWindowAttribute(Handle, 34, ref noBorder, 4);
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }
        internal void SetPreviewSize(string size)
        {
            if (!preview) throw new InvalidOperationException("Resize preview requires preview mode.");
            if (size == "minimum") Size = MinimumSize;
            else if (size == "maximum") Size = MaximumSize;
            else if (size == "wide") Size = new Size(MaximumSize.Width, MinimumSize.Height);
            else if (size == "tall") Size = new Size(MinimumSize.Width, MaximumSize.Height);
            else
            {
                string[] parts = size.Split('x');
                if (parts.Length != 2) throw new ArgumentException("Expected WIDTHxHEIGHT or minimum/maximum/wide/tall.");
                Size = new Size(Int32.Parse(parts[0]), Int32.Parse(parts[1]));
            }
        }
        internal void VerifyRepeatedResize()
        {
            Size original = Size;
            Dictionary<Control, Rectangle> bounds = new Dictionary<Control, Rectangle>();
            Dictionary<Control, float> fonts = new Dictionary<Control, float>();
            foreach (DesignControl item in designControls) { bounds[item.Control] = item.Control.Bounds; fonts[item.Control] = item.Control.Font.Size; }
            for (int pass = 0; pass < 3; pass++)
            {
                foreach (string size in new string[] { "minimum", "wide", "tall", "maximum" })
                {
                    SetPreviewSize(size); Application.DoEvents();
                    List<string> issues = new List<string>(); InspectLayout(this, issues, new List<object>());
                    foreach (string issue in issues) resizeIssues.Add(size + ": " + issue);
                    resizeChecks++;
                }
                Size = original; Application.DoEvents();
                LayoutForWindowSize(); // Reassign equal-value fonts: WinForms can retain old objects.
                using (Graphics graphics = CreateGraphics())
                    foreach (DesignControl item in designControls) item.Control.Font.GetHeight(graphics);
                foreach (DesignControl item in designControls)
                    if (item.Control.Bounds != bounds[item.Control] || Math.Abs(item.Control.Font.Size - fonts[item.Control]) > .01f)
                        resizeIssues.Add("Layout drift: " + item.Control.GetType().Name + " / " + item.Control.Text);
                resizeChecks++;
            }
            if (scaledFonts.Count > designControls.Count) resizeIssues.Add("Owned font pool grew beyond active controls.");
            if (Region != null) resizeIssues.Add("Native rounding must not use a clipped window Region.");
            if (MinimumSize.Width >= MaximumSize.Width || MinimumSize.Height >= MaximumSize.Height) resizeIssues.Add("Window resizing remains locked.");
            Point[] edges = { new Point(1, 1), new Point(Width / 2, 1), new Point(Width - 2, 1),
                new Point(1, Height / 2), new Point(Width - 2, Height / 2),
                new Point(1, Height - 2), new Point(Width / 2, Height - 2), new Point(Width - 2, Height - 2) };
            int[] expected = { 13, 12, 14, 10, 11, 16, 15, 17 };
            for (int i = 0; i < edges.Length; i++)
            {
                Point screen = PointToScreen(edges[i]);
                IntPtr packed = new IntPtr(unchecked((screen.Y << 16) | (screen.X & 0xffff)));
                if (SendMessage(Handle, 0x84, IntPtr.Zero, packed).ToInt32() != expected[i]) resizeIssues.Add("Resize edge hit-test failed: " + expected[i]);
                ResizeHandle grip = resizeHandles.Find(delegate(ResizeHandle item) { return item.Visible && item.Bounds.Contains(edges[i]); });
                if (grip == null || grip.Edge != expected[i]) resizeIssues.Add("Resize grip does not cover edge: " + expected[i]);
                Rectangle origin = new Rectangle(100, 100, (MinimumSize.Width + MaximumSize.Width) / 2,
                    (MinimumSize.Height + MaximumSize.Height) / 2);
                foreach (int delta in new int[] { -10000, -30, 30, 10000 })
                {
                    Rectangle resized = DragBounds(origin, expected[i], delta, delta, MinimumSize, MaximumSize);
                    if (resized.Width < MinimumSize.Width || resized.Width > MaximumSize.Width ||
                        resized.Height < MinimumSize.Height || resized.Height > MaximumSize.Height)
                        resizeIssues.Add("Resize grip exceeded limits: " + expected[i]);
                    if ((expected[i] == 10 || expected[i] == 13 || expected[i] == 16) && resized.Right != origin.Right)
                        resizeIssues.Add("Left grip lost opposite anchor.");
                    if ((expected[i] == 12 || expected[i] == 13 || expected[i] == 14) && resized.Bottom != origin.Bottom)
                        resizeIssues.Add("Top grip lost opposite anchor.");
                }
                resizeChecks++;
            }
        }
        internal string LayoutReport()
        {
            List<string> issues = new List<string>();
            List<object> labels = new List<object>();
            List<object> grips = new List<object>();
            foreach (ResizeHandle grip in resizeHandles) grips.Add(new { edge = grip.Edge, visible = grip.Visible,
                x = grip.Left, y = grip.Top, width = grip.Width, height = grip.Height, handleCreated = grip.IsHandleCreated });
            InspectLayout(this, issues, labels);
            issues.AddRange(resizeIssues);
            int style = GetWindowLong(Handle, -16);
            if ((style & (0x00c00000 | 0x00040000)) != 0) issues.Add("Native title bar/frame is present.");
            return new JavaScriptSerializer().Serialize(new {
                scale = UiScale, width = Width, height = Height, state = state.Phase,
                displayScale = displayScale, minimumWidth = MinimumSize.Width, minimumHeight = MinimumSize.Height,
                maximumWidth = MaximumSize.Width, maximumHeight = MaximumSize.Height, resizeChecks = resizeChecks,
                grips = grips, nativeCaption = (style & 0x00c00000) != 0, nativeThickFrame = (style & 0x00040000) != 0,
                settings = settingsOpen, networkStarted = false, passed = issues.Count == 0, issues = issues, labels = labels });
        }
        internal void PaintNativePreview(Bitmap bitmap)
        {
            if (!preview) throw new InvalidOperationException("Native capture requires preview mode.");
            SendMessage(Handle, 0x86, new IntPtr(1), IntPtr.Zero);
            Invalidate(true); Update();
            foreach (DesignControl item in designControls) { item.Control.Invalidate(); item.Control.Update(); }
            Application.DoEvents();
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                graphics.Clear(Color.Magenta);
                IntPtr dc = graphics.GetHdc();
                bool painted;
                try { painted = PrintWindow(Handle, dc, 0); }
                finally { graphics.ReleaseHdc(dc); }
                if (!painted) throw new InvalidOperationException("Native window painting failed.");
            }
            Point buttonLocation = PointToClient(primary.PointToScreen(Point.Empty));
            Point headerSample = new Point(Width / 2, ResizeGrip + Px(8));
            if (bitmap.GetPixel(headerSample.X, headerSample.Y).ToArgb() != Palette.Background.ToArgb())
                resizeIssues.Add("Native header background differs from warm white.");
            if (dashboard.Visible)
            {
                Point[] corners = { new Point(1, 1), new Point(primary.Width - 2, 1),
                    new Point(1, primary.Height - 2), new Point(primary.Width - 2, primary.Height - 2) };
                foreach (Point corner in corners)
                {
                    Color pixel = bitmap.GetPixel(buttonLocation.X + corner.X, buttonLocation.Y + corner.Y);
                    if (pixel.R < 150 || pixel.G < 150 || pixel.B < 150) resizeIssues.Add("Native button corner was not painted with its parent background.");
                }
            }
        }
        private static void InspectLayout(Control parent, List<string> issues, List<object> labels)
        {
            foreach (Control child in parent.Controls)
            {
                if (!child.Visible) continue;
                if (child.Left < -1 || child.Top < -1 || child.Right > parent.ClientSize.Width + 1 || child.Bottom > parent.ClientSize.Height + 1)
                    issues.Add("Control outside parent: " + child.GetType().Name + " / " + child.Text);
                Label label = child as Label;
                if (label != null && label.Text.Length > 0)
                {
                    Size needed = TextRenderer.MeasureText(label.Text, label.Font, new Size(label.Width, Int32.MaxValue),
                        TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                    bool fits = needed.Height <= label.Height && needed.Width <= label.Width;
                    if (!fits && !label.AutoEllipsis) issues.Add("Text clipping: " + label.Text);
                    labels.Add(new { text = label.Text, width = label.Width, height = label.Height,
                        neededWidth = needed.Width, neededHeight = needed.Height, fits = fits, ellipsis = label.AutoEllipsis });
                }
                if (child is Button && child.Text.Length > 0)
                {
                    Size needed = TextRenderer.MeasureText(child.Text, child.Font);
                    if (needed.Width > child.Width - 8 || needed.Height > child.Height - 4) issues.Add("Button text clipping: " + child.Text);
                }
                InspectLayout(child, issues, labels);
            }
        }
        private bool IsExpired()
        {
            return DateTimeOffset.Now >= DateTimeOffset.Parse(TrialDeadline, System.Globalization.CultureInfo.InvariantCulture);
        }
        private void ShowCurrentView()
        {
            settings.Visible = settingsOpen; dashboard.Visible = !settingsOpen;
            if (settingsOpen) settings.BringToFront(); else dashboard.BringToFront();
            settingsButton.Text = "设置";
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
            stateTitle.Text = initialStatusPending ? "正在检查连接" : active ? "已连接" : state.Phase == "starting" ? "正在连接" :
                state.Phase == "stopping" ? "正在关闭" : state.Phase == "error" ? "连接需要处理" : "尚未开启";
            phasePill.Text = active ? "香港解析 · 已就绪" : state.Phase == "error" ? "需要处理" :
                transitioning ? "处理中" : "待机";
            phasePill.ForeColor = active ? Palette.Teal : state.Phase == "error" ? Palette.Error : Palette.Muted;
            stateMessage.Text = active ? "主入口解析经香港，对局流量保持直连。" :
                state.Phase == "starting" ? "正在建立解析连接，请稍候。" :
                state.Phase == "stopping" ? "正在恢复连接设置，请稍候。" :
                state.Phase == "error" ? "请查看下方提示，处理后再试。" :
                "通过香港优化主入口解析，\r\n游戏对局保持本机直连。";
            connectionDetail.Text = active ? "解析通道运行中" : "只优化入口解析";
            primary.Text = state.Phase == "starting" ? "正在开启…" : state.Phase == "stopping" ? "正在关闭…" :
                active ? "关闭加速" : state.Phase == "error" ? "关闭并恢复" : configured ? "开启加速" : "完成设备设置";
            primary.Enabled = !transitioning && !closing;
            settingsButton.Enabled = !busy && !closing && state.Phase == "stopped";
            saveButton.Enabled = !busy && !closing && !findingGames && state.Phase == "stopped";
            findGamesButton.Enabled = saveButton.Enabled && !findingGames;
            foreach (GamePathRow row in gameRows)
            {
                row.ChooseFile.Enabled = row.ChooseFolder.Enabled = saveButton.Enabled && !findingGames;
                row.Clear.Enabled = saveButton.Enabled && !findingGames && row.Path.Length > 0;
            }
            importKeyButton.Enabled = saveButton.Enabled;
            keyBox.ReadOnly = !saveButton.Enabled;
            cancelSettings.Visible = configured;
            SelectSettingsTab(softwareTabOpen, false);
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
                    configuredPlatforms = ReadPathPlatforms(data);
                    connectionWait.LastSuccessfulWaitSeconds = ReadSuccessfulStartupWait(data);
                }
                LoadPathRows(configuredGamePaths);
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
            LoadPathRows(configuredGamePaths); keyBox.Clear(); ClearImportedKey(); settingsError.Text = "";
            settingsOpen = true; ApplyState();
        }
        private async Task BrowseGameAsync(GamePathRow row, bool folder)
        {
            if (preview || busy || findingGames || state.Phase != "stopped") return;
            if (folder)
            {
                using (FolderBrowserDialog dialog = new FolderBrowserDialog())
                {
                    dialog.Description = "选择 " + row.Slot + " 的三角洲安装文件夹";
                    dialog.ShowNewFolderButton = false;
                    if (ValidGamePath(row.Path)) dialog.SelectedPath = Path.GetDirectoryName(row.Path);
                    if (dialog.ShowDialog(this) != DialogResult.OK) return;
                    string selected = dialog.SelectedPath;
                    findingGames = true; settingsError.Text = "正在定位所选文件夹中的游戏程序…"; ApplyState();
                    try
                    {
                        List<GameLocation> matches = await Task.Run(delegate { return GameDiscovery.FindInFolder(selected, row.Slot); });
                        if (IsDisposed || closing) return;
                        if (matches.Count == 0) { settingsError.Text = "此文件夹未找到游戏，请选择三角洲安装文件夹或直接选择游戏程序。"; return; }
                        if (matches.Count > 1) { settingsError.Text = "此文件夹包含多个游戏程序，请进入具体安装文件夹或使用“选程序”。"; return; }
                        SetGameRow(row, matches[0].Path, row.Slot);
                    }
                    catch { if (!IsDisposed) settingsError.Text = "无法读取所选文件夹，原有位置已保留。"; }
                    finally { findingGames = false; if (!IsDisposed) ApplyState(); }
                }
                return;
            }
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "选择 " + row.Slot + " 三角洲游戏程序";
                dialog.Filter = "三角洲游戏程序 (DeltaForceClient-Win64-Shipping.exe)|DeltaForceClient-Win64-Shipping.exe";
                dialog.CheckFileExists = true;
                if (ValidGamePath(row.Path)) dialog.FileName = row.Path;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    if (!ValidGamePath(dialog.FileName)) { settingsError.Text = "请选择 DeltaForceClient-Win64-Shipping.exe。"; return; }
                    SetGameRow(row, dialog.FileName, row.Slot);
                }
            }
        }
        private bool SetGameRow(GamePathRow row, string path, string platform)
        {
            string full = Path.GetFullPath(path);
            if (gameRows.Exists(delegate(GamePathRow other) { return other != row && String.Equals(other.Path, full, StringComparison.OrdinalIgnoreCase); }))
            { settingsError.Text = "这个游戏程序已在另一个位置中，无需重复添加。"; return false; }
            row.Path = full; row.Platform = platform; RefreshGameRows();
            settingsError.Text = "位置已选择，保存后生效。"; return true;
        }
        private async Task FindGamesAsync()
        {
            if (preview || busy || findingGames || state.Phase != "stopped") return;
            findingGames = true; findGamesButton.Text = "查找中…"; settingsError.Text = "正在检查运行中的游戏和平台安装记录…"; ApplyState();
            try
            {
                List<GameLocation> found = await Task.Run(delegate { return GameDiscovery.Discover(); });
                if (IsDisposed || closing) return;
                found.Sort(delegate(GameLocation first, GameLocation second) { return String.IsNullOrEmpty(first.Platform).CompareTo(String.IsNullOrEmpty(second.Platform)); });
                int added = 0;
                foreach (GameLocation location in found)
                {
                    if (gameRows.Exists(delegate(GamePathRow row) { return String.Equals(row.Path, location.Path, StringComparison.OrdinalIgnoreCase); })) continue;
                    GamePathRow available = gameRows.Find(delegate(GamePathRow row) { return row.Path.Length == 0 && row.Slot == location.Platform; });
                    if (available == null && location.Platform.Length == 0) available = gameRows.Find(delegate(GamePathRow row) { return row.Path.Length == 0; });
                    if (available != null && SetGameRow(available, location.Path, location.Platform)) added++;
                }
                settingsError.Text = added > 0 ? "找到 " + added + " 个可用游戏位置，保存后生效。" : found.Count > 0 ?
                    "已找到安装；现有位置已保留，需要更换时请使用“替换”。" : "未找到安装记录，可启动游戏后重试，或手动选择安装文件夹。";
            }
            catch { if (!IsDisposed) settingsError.Text = "自动查找未完成，现有位置已保留，可手动选择。"; }
            finally { findingGames = false; if (!IsDisposed) { findGamesButton.Text = "自动查找"; ApplyState(); } }
        }
        internal static bool ValidGamePath(string path)
        {
            return GameDiscovery.IsGameExecutable(path);
        }
        private void SaveSettings()
        {
            if (preview || busy || findingGames || state.Phase != "stopped") return;
            List<string> paths = new List<string>();
            Dictionary<string, string> platforms = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (GamePathRow row in gameRows)
            {
                if (row.Path.Length == 0) continue;
                if (!ValidGamePath(row.Path)) { settingsError.Text = "有游戏路径已失效，请重新选择或移除后再保存。"; return; }
                AddGamePath(paths, row.Path); platforms[row.Path] = row.Platform;
            }
            string secret = keyBox.Text.Trim();
            string validation = paths.Count > 0 ? ValidateSetupPaths(paths, secret, File.Exists(keyPath) || importedKey != null) :
                ValidateSecretInput(secret, File.Exists(keyPath) || importedKey != null);
            if (validation != null) { settingsError.Text = validation; return; }
            byte[] plain = null;
            try
            {
                if (File.Exists(settingsPath)) ReadJson(settingsPath); // Fail before replacing any key if settings are unreadable.
                if (secret.Length > 0 || importedKey != null)
                {
                    plain = importedKey != null ? (byte[])importedKey.Clone() : Encoding.UTF8.GetBytes(secret);
                    SaveEncryptedKey(privateDirectory, keyPath, plain);
                }
                SavePathSettingsJson(settingsPath, paths, platforms);
                configuredGamePaths = paths; configuredPlatforms = platforms; configured = paths.Count > 0; settingsOpen = !configured;
                keyBox.Clear(); ClearImportedKey(); settingsError.Text = ""; errorText = ""; state.Phase = "stopped";
                keyHint.Text = "本机已保存独立密钥。留空保留当前密钥；输入新密钥可替换。";
                if (!configured) settingsError.Text = "已保存。选择一个游戏位置后即可开启加速。";
                ApplyState();
            }
            catch (Exception ex) { settingsError.Text = "设置保存失败（" + ex.GetType().Name + "），请确认安装目录可写。"; }
            finally { if (plain != null) Array.Clear(plain, 0, plain.Length); secret = null; }
        }
        internal static string ValidateSetupInput(string game, string secret, bool existingKey)
        {
            if (!ValidGamePath(game)) return "请选择正确的 DeltaForceClient-Win64-Shipping.exe。";
            return ValidateSecretInput(secret, existingKey);
        }
        private static string ValidateSecretInput(string secret, bool existingKey)
        {
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
        internal static Dictionary<string, string> ReadPathPlatforms(Dictionary<string, object> data)
        {
            Dictionary<string, string> platforms = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            object raw;
            if (!data.TryGetValue("gamePathPlatforms", out raw)) return platforms;
            Dictionary<string, object> saved = raw as Dictionary<string, object>;
            if (saved == null) return platforms;
            foreach (KeyValuePair<string, object> item in saved)
            {
                string platform = item.Value as string;
                if (platform == "Steam" || platform == "WeGame" || platform == "") platforms[item.Key] = platform;
            }
            return platforms;
        }
        internal static void SavePathSettingsJson(string path, IEnumerable<string> games, IDictionary<string, string> platforms)
        {
            List<string> normalized = new List<string>();
            foreach (string game in games)
            {
                if (!ValidGamePath(game)) throw new InvalidDataException("A selected game executable is unavailable.");
                AddGamePath(normalized, game);
            }
            if (normalized.Count > MaximumGamePaths) throw new InvalidDataException(GamePathLimitMessage);
            Dictionary<string, object> data = File.Exists(path) ? ReadJson(path) : new Dictionary<string, object>();
            Dictionary<string, string> savedPlatforms = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string game in normalized)
            {
                string platform;
                if (!platforms.TryGetValue(game, out platform)) platform = GameDiscovery.DetectPlatform(game);
                savedPlatforms[game] = platform == "Steam" || platform == "WeGame" ? platform : "";
            }
            data["gameExecutable"] = normalized.Count > 0 ? normalized[0] : "";
            data["gameExecutables"] = normalized.ToArray(); data["gamePathPlatforms"] = savedPlatforms;
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
        private async Task RefreshStatusAsync(bool recoverAbandonedSession = false)
        {
            if (preview || busy || closing || !await operationGate.WaitAsync(0)) return;
            try
            {
                if (recoverAbandonedSession)
                {
                    // Only the first display recovers abandoned state; timer polls remain read-only.
                    busy = true; ApplyState();
                    // UI-only updates can retain an older backend without the recovery action.
                    if (File.Exists(Path.Combine(root, "backend", "Mna-SessionRecovery.ps1")))
                        await InvokeBackendAsync("Recover");
                }
                await InvokeBackendAsync("Status");
            }
            catch (Exception ex) { SetError(UserError(ex)); }
            finally
            {
                if (recoverAbandonedSession) busy = false;
                operationGate.Release(); ApplyState();
            }
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
            closing = true; timer.Stop(); updateTimer.Stop(); ApplyState();
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
            if (disposing) { timer.Dispose(); animationTimer.Dispose(); updateTimer.Dispose(); pathToolTip.Dispose(); ClearImportedKey(); }
            base.Dispose(disposing);
            if (disposing) { foreach (Font font in scaledFonts) font.Dispose(); scaledFonts.Clear(); }
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
                bool initialCheckAnimated = reopened.IsWaiting && reopened.StepText(new BackendState()).Contains("恢复");
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
                Dictionary<string, string> platforms = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                platforms[game] = "Steam"; platforms[secondGame] = "";
                MainForm.SavePathSettingsJson(settings, new string[] { game, secondGame }, platforms);
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                results["pathRowsPreserveUnknownPlatform"] = MainForm.ReadPathPlatforms(data)[secondGame] == "" && MainForm.ReadPathPlatforms(data)[game] == "Steam";
                MainForm.SavePathSettingsJson(settings, new string[] { secondGame }, platforms);
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                results["explicitPathRemovalUpdatesLegacyAndArray"] = MainForm.ReadGamePaths(data).Count == 1 &&
                    (string)data["gameExecutable"] == secondGame && !MainForm.ReadPathPlatforms(data).ContainsKey(game);
                string beforeInvalid = File.ReadAllText(settings, Encoding.UTF8);
                bool unavailableRejected = false;
                try { MainForm.SavePathSettingsJson(settings, new string[] { game, Path.Combine(test, "not-installed", GameDiscovery.ExecutableName) }, platforms); }
                catch (InvalidDataException) { unavailableRejected = true; }
                results["unavailablePathCannotSilentlyEraseSettings"] = unavailableRejected && File.ReadAllText(settings, Encoding.UTF8) == beforeInvalid;
                MainForm.SavePathSettingsJson(settings, new string[0], platforms);
                data = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(settings, Encoding.UTF8)) as Dictionary<string, object>;
                results["explicitClearAllPathsPersists"] = MainForm.ReadGamePaths(data).Count == 0 && (string)data["gameExecutable"] == "";
                results["pathRowsPreserveOtherSettings"] = (string)data["unrelatedSetting"] == "preserved" && MainForm.ReadSuccessfulStartupWait(data) == 12.3;
                string brokenSettings = Path.Combine(test, "broken-settings.json"); File.WriteAllText(brokenSettings, "{broken");
                bool unreadableRejected = false;
                try { MainForm.SavePathSettingsJson(brokenSettings, new string[] { game }, platforms); }
                catch { unreadableRejected = true; }
                results["unreadableSettingsNeverOverwrittenByPathSave"] = unreadableRejected && File.ReadAllText(brokenSettings) == "{broken";
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
