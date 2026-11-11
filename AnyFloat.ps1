<#
    AnyFloat —— 把任意窗口变成"实时缩略图"式悬浮窗（视频 PiP 观感）

    原理：
      源窗口不缩放、不搬走。它原地被"隐形"——WS_EX_LAYERED + alpha=1 让它看不见，
      WS_EX_TRANSPARENT 让点击穿透，EnableWindow(FALSE) 冻结输入。
      关键是它仍留在屏幕内，所以 Chromium / DirectX 应用会继续渲染，
      我们定时用 PrintWindow(PW_RENDERFULLCONTENT) 抓帧、等比缩小画到自己的悬浮窗里。

      （实测：把窗口移到屏幕外会让 Chromium 停止渲染、抓帧变成过期残帧；
        而原位透明化后画面依然实时且完整。）

    热键：
      Win+Shift+F  当前前台窗口 → 变成实时缩略图悬浮窗；再按复原
                   （被占用时自动降级 Ctrl+Alt+F → Win+Alt+A）
      Win+Shift+G  复原全部

    悬浮后：
      · 源窗口原地变透明 + 点击穿透 + 输入冻结，肉眼看不到也点不到
      · 从任务栏和 Alt+Tab 移除，只剩悬浮窗
      · 悬停约 220ms 放大（仍是缩放画面），鼠标移开缩回
      · 单击任意位置 → 动画展开回原位，恢复源窗口样式并激活

    配置：见下方 "===== 可调参数 ====="，改完重启脚本即可。
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$DebugLog,
    [int]$FloatHwnd = 0
)

# ===== 可调参数 =====
$PillWidth    = 420      # 胶囊宽度（像素），高度按源窗口比例自动算
$PillHeightMax = 320     # 胶囊高度上限
$Margin       = 18       # 距离屏幕边缘的留白
$SlotGap      = 10       # 多个悬浮窗之间的间距
$MaxFloats    = 6        # 最多同时悬浮几个窗口
$DwellMs      = 90       # 悬停多久后放大
$AnimMs       = 190      # 动画时长基准（毫秒）
$ExpandWidth  = 1100     # 放大后的最大宽度
$ExpandHeight = 780      # 放大后的最大高度
$CaptureFps   = 12       # 抓帧频率（帧/秒），越高越流畅越吃 CPU
$ExpandFps    = 20       # 放大状态下的抓帧频率
$GlowPad      = 12       # 虚化边框厚度（像素）
$ContentAlpha = 0.90     # 悬浮窗画面的不透明度（0.9 = 半透明）
# ====================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    Add-Type -Namespace AF -Name Dpi -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);
'@
    [void][AF.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch { }

$code = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// 简易诊断日志（%TEMP%\anyfloat.log）
public static class AnyFloat
{
    static readonly object gate = new object();
    public static bool Enabled = false;
    public static void Log(string msg)
    {
        if (!Enabled) return;
        try
        {
            lock (gate)
            {
                System.IO.File.AppendAllText(
                    System.IO.Path.Combine(System.IO.Path.GetTempPath(), "anyfloat.log"),
                    DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg + Environment.NewLine);
            }
        }
        catch { }
    }
}

// 悬浮窗：分层窗口（per-pixel alpha）。窗口的位置和尺寸由合成线程通过
// UpdateLayeredWindow 一步设置，画布只合成"画面+虚化框"这一小块。
public class PiP : Form
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize; public int biWidth; public int biHeight; public short biPlanes;
        public short biBitCount; public int biCompression; public int biSizeImage;
        public int biXPelsPerMeter; public int biYPelsPerMeter; public int biClrUsed; public int biClrImportant;
    }

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);

    const int ULW_ALPHA = 2;
    const byte AC_SRC_OVER = 0, AC_SRC_ALPHA = 1;
    const int WM_MOUSEACTIVATE = 0x0021, WM_LBUTTONDOWN = 0x0201;

    public IntPtr Source;
    public IntPtr Hwnd;
    public volatile bool Running = true;
    public volatile int Fps = 12;
    public volatile bool Animating;
    public int GlowPad = 12;
    public double ContentAlpha = 0.90;
    public string SourceTitle = "";
    public event EventHandler Clicked;

    Thread capturer, composer;
    readonly object gate = new object();
    Bitmap frame;
    int frameVersion;
    Rectangle imageScreen = new Rectangle(0, 0, 1, 1);   // 画面矩形（屏幕坐标）
    int rectVersion;

    IntPtr memDc = IntPtr.Zero, dib = IntPtr.Zero, bits = IntPtr.Zero;
    Bitmap canvas;
    Graphics gfx;
    int canvasW, canvasH;

    public PiP()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        TopMost = true;
        Text = "AnyFloatPip";
        SetStyle(ControlStyles.Selectable, false);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x00080000; // WS_EX_LAYERED
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_MOUSEACTIVATE) { m.Result = new IntPtr(3); return; }
        if (m.Msg == WM_LBUTTONDOWN)
        {
            if (Clicked != null) Clicked(this, EventArgs.Empty);
            return;
        }
        base.WndProc(ref m);
    }

    // 画面矩形，屏幕坐标
    public Rectangle ImageRect
    {
        get { lock (gate) { return imageScreen; } }
        set { lock (gate) { if (imageScreen != value) { imageScreen = value; rectVersion++; } } }
    }

    public Rectangle ScreenImageRect { get { return ImageRect; } }

    public void SetImageScreen(Rectangle screen) { ImageRect = screen; }

    // 同步抓一帧，保证悬浮窗一出现就有内容
    public void PrimeFrame() { try { Grab(); } catch { } }

    public void StartCapture()
    {
        capturer = new Thread(CaptureLoop); capturer.IsBackground = true; capturer.Start();
        composer = new Thread(ComposeLoop); composer.IsBackground = true; composer.Start();
    }

    void CaptureLoop()
    {
        while (Running)
        {
            try { Grab(); } catch { }
            int delay = Math.Max(20, 1000 / Math.Max(1, Fps));
            for (int i = 0; i < delay; i += 10) { if (!Running) return; Thread.Sleep(Math.Min(10, delay - i)); }
        }
    }

    void Grab()
    {
        if (!Running || Source == IntPtr.Zero) return;
        RECT cr;
        if (!GetClientRect(Source, out cr)) return;
        int w = cr.R - cr.L, h = cr.B - cr.T;
        if (w <= 0 || h <= 0) return;

        Bitmap shot = new Bitmap(w, h);
        using (Graphics g = Graphics.FromImage(shot))
        {
            IntPtr hdc = g.GetHdc();
            PrintWindow(Source, hdc, 3);
            g.ReleaseHdc(hdc);
        }
        lock (gate)
        {
            if (frame != null) frame.Dispose();
            frame = shot;
            frameVersion++;
        }
    }

    void ComposeLoop()
    {
        int lastF = -1, lastR = -1;
        while (Running)
        {
            Rectangle img; int fv, rv; Bitmap fr; bool anim = Animating;
            lock (gate) { img = imageScreen; fv = frameVersion; rv = rectVersion; fr = frame; }

            if (img.Width > 2 && img.Height > 2 && (fv != lastF || rv != lastR))
            {
                try
                {
                    int pad = GlowPad;
                    Rectangle win = Rectangle.Inflate(img, pad, pad);
                    if (canvas == null || canvasW < win.Width || canvasH < win.Height) EnsureCanvas(win.Width, win.Height);

                    gfx.CompositingMode = CompositingMode.SourceCopy;
                    using (SolidBrush clear = new SolidBrush(Color.Transparent))
                        gfx.FillRectangle(clear, 0, 0, win.Width, win.Height);
                    gfx.CompositingMode = CompositingMode.SourceOver;

                    Rectangle local = new Rectangle(pad, pad, img.Width, img.Height);
                    DrawGlow(gfx, local);
                    if (fr != null) DrawContent(gfx, fr, local);

                    PaintLayered(win);
                    lastF = fv; lastR = rv;
                    if (AnyFloat.Enabled && anim) AnyFloat.Log("compose " + img.Width + "x" + img.Height);
                }
                catch { }
            }
            Thread.Sleep(2);
        }
        DisposeCanvas();
    }

    void EnsureCanvas(int w, int h)
    {
        DisposeCanvas();
        BITMAPINFOHEADER bmi = new BITMAPINFOHEADER();
        bmi.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        bmi.biWidth = w;
        bmi.biHeight = -h;
        bmi.biPlanes = 1;
        bmi.biBitCount = 32;
        bmi.biCompression = 0;
        IntPtr screenDc = GetDC(IntPtr.Zero);
        memDc = CreateCompatibleDC(screenDc);
        dib = CreateDIBSection(memDc, ref bmi, 0, out bits, IntPtr.Zero, 0);
        ReleaseDC(IntPtr.Zero, screenDc);
        SelectObject(memDc, dib);
        canvas = new Bitmap(w, h, w * 4, PixelFormat.Format32bppPArgb, bits);
        gfx = Graphics.FromImage(canvas);
        gfx.SmoothingMode = SmoothingMode.AntiAlias;
        canvasW = w; canvasH = h;
    }

    void DisposeCanvas()
    {
        if (gfx != null) { gfx.Dispose(); gfx = null; }
        if (canvas != null) { canvas.Dispose(); canvas = null; }
        if (dib != IntPtr.Zero) { DeleteObject(dib); dib = IntPtr.Zero; }
        if (memDc != IntPtr.Zero) { DeleteDC(memDc); memDc = IntPtr.Zero; }
        canvasW = canvasH = 0;
    }

    static GraphicsPath RoundRect(Rectangle r, int radius)
    {
        GraphicsPath p = new GraphicsPath();
        int d = radius * 2;
        if (r.Width < d || r.Height < d) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    void DrawGlow(Graphics g, Rectangle img)
    {
        int pad = GlowPad;
        for (int i = pad; i >= 1; i--)
        {
            int alpha = (int)(54.0 * (1.0 - (i - 1) / (double)pad));
            if (alpha <= 0) continue;
            Rectangle r = Rectangle.Inflate(img, i, i);
            using (GraphicsPath p = RoundRect(r, 10 + i / 2))
            using (Pen pen = new Pen(Color.FromArgb(alpha, 150, 200, 255), 1f))
            {
                g.DrawPath(pen, p);
            }
        }
    }

    void DrawContent(Graphics g, Bitmap fr, Rectangle img)
    {
        if (img.Width < 2 || img.Height < 2) return;
        using (GraphicsPath clip = RoundRect(img, 8))
        {
            Region old = g.Clip;
            g.SetClip(clip, CombineMode.Replace);
            using (ImageAttributes ia = new ImageAttributes())
            {
                ColorMatrix cm = new ColorMatrix();
                cm.Matrix33 = (float)ContentAlpha;
                ia.SetColorMatrix(cm);
                g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(fr, img, 0, 0, fr.Width, fr.Height, GraphicsUnit.Pixel, ia);
            }
            g.SetClip(old, CombineMode.Replace);
            old.Dispose();
            using (Pen pen = new Pen(Color.FromArgb(95, 200, 230, 255), 1f))
            {
                g.DrawPath(pen, clip);
            }
        }
    }

    void PaintLayered(Rectangle win)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        POINT src = new POINT(); src.X = 0; src.Y = 0;
        POINT dst = new POINT(); dst.X = win.X; dst.Y = win.Y;
        SIZE size = new SIZE(); size.cx = win.Width; size.cy = win.Height;
        BLENDFUNCTION blend = new BLENDFUNCTION();
        blend.BlendOp = AC_SRC_OVER; blend.BlendFlags = 0;
        blend.SourceConstantAlpha = 255; blend.AlphaFormat = AC_SRC_ALPHA;
        UpdateLayeredWindow(Hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, ULW_ALPHA);
        ReleaseDC(IntPtr.Zero, screenDc);
    }

    public void StopCapture()
    {
        Running = false;
        try { if (capturer != null && capturer.IsAlive) capturer.Join(600); } catch { }
        try { if (composer != null && composer.IsAlive) composer.Join(600); } catch { }
        lock (gate) { if (frame != null) { frame.Dispose(); frame = null; } }
    }
}
public class FloatTool : NativeWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
        public Rectangle ToRect() { return new Rectangle(Left, Top, Width, Height); }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public int dwFlags;
    }

    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList
    {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
    }

    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool EnableWindow(IntPtr h, bool enable);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, out bool result, uint winIni);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder buf, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder buf, int max);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int idx);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr val);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetProp(IntPtr h, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetProp(IntPtr h, string name, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr RemoveProp(IntPtr h, string name);
    [DllImport("dwmapi.dll")] static extern int DwmFlush();
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

    static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004,
               SWP_NOACTIVATE = 0x0010, SWP_FRAMECHANGED = 0x0020, SWP_NOOWNERZORDER = 0x0200,
               SWP_NOCOPYBITS = 0x0100;
    const int SW_RESTORE = 9, SW_MAXIMIZE = 3;
    const uint MONITOR_DEFAULTTONEAREST = 2;
    const int WM_HOTKEY = 0x0312;
    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8, MOD_NOREPEAT = 0x4000;
    const uint SPI_GETCLIENTAREAANIMATION = 0x1042;
    const int VK_F = 0x46, VK_G = 0x47, VK_A = 0x41;
    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOOLWINDOW = 0x00000080, WS_EX_APPWINDOW = 0x00040000;
    const int WS_EX_LAYERED = 0x00080000, WS_EX_TRANSPARENT = 0x00000020;
    const uint LWA_ALPHA = 0x2;

    public enum Mode { Idle, ToPill, Pill, ToExpand, Expanded, ToNormal }

    public int PillWidth = 420;
    public int PillHeightMax = 320;
    public int Margin = 18;
    public int SlotGap = 10;
    public int MaxFloats = 6;
    public int DwellMs = 90;
    public int AnimMs = 190;
    public int ExpandWidth = 1100;
    public int ExpandHeight = 780;
    public int CaptureFps = 12;
    public int GlowPad = 12;
    public double ContentAlpha = 0.90;
    public int ExpandFps = 15;
    public int GraceMs = 260;

    public class Floating
    {
        public IntPtr Target;
        public RECT Saved;
        public bool SavedMax;
        public Rectangle Pill, Expand, Work;
        public int Corner, Slot;
        public Mode Mode, AnimTarget;
        public Rectangle AnimFrom, AnimTo;
        public int AnimStart, AnimDuration;
        public int HoverSince = -1, LeaveSince = -1;
        public PiP Box;
        public IntPtr BoxHandle;
        public int AnimGen;
        public volatile bool AnimDone;
        public IntPtr OrigExStyle;
        public bool Frozen, HiddenFromSwitcher;
    }

    List<Floating> floats = new List<Floating>();
    Stopwatch clock = Stopwatch.StartNew();
    bool animationsEnabled = true;
    System.Windows.Forms.Timer tick;
    NotifyIcon tray;
    ITaskbarList taskbar;

    public bool HotkeyRegistered;
    public bool RestoreAllRegistered;
    public string HotkeyText = "Win+Shift+F";

    public FloatTool()
    {
        CreateHandle(new CreateParams());

        try { timeBeginPeriod(1); } catch { }   // 提高计时精度，动画更稳

        bool ok = RegisterHotKey(Handle, 1, MOD_WIN | MOD_SHIFT | MOD_NOREPEAT, VK_F);
        if (!ok) { ok = RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_F); if (ok) HotkeyText = "Ctrl+Alt+F"; }
        if (!ok) { ok = RegisterHotKey(Handle, 1, MOD_WIN | MOD_ALT | MOD_NOREPEAT, VK_A); if (ok) HotkeyText = "Win+Alt+A"; }
        HotkeyRegistered = ok;

        RestoreAllRegistered = RegisterHotKey(Handle, 2, MOD_WIN | MOD_SHIFT | MOD_NOREPEAT, VK_G);
        if (!RestoreAllRegistered) RestoreAllRegistered = RegisterHotKey(Handle, 2, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_G);

        bool sysAnim;
        animationsEnabled = SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, out sysAnim, 0) && sysAnim;

        try
        {
            Type t = Type.GetTypeFromCLSID(new Guid("56FDF344-FD6D-11d0-958A-006097C9A090"));
            taskbar = (ITaskbarList)Activator.CreateInstance(t);
            taskbar.HrInit();
        }
        catch { taskbar = null; }

        tick = new System.Windows.Forms.Timer();
        tick.Interval = 10;
        tick.Tick += OnTick;
        tick.Start();

        BuildTray();
        RecoverOrphans();
    }

    // 上次进程被强杀时，被悬浮的窗口会停在"透明+禁用"状态；启动时把它们救回来
    void RecoverOrphans()
    {
        try
        {
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (GetProp(h, "AnyFloatFloating") == IntPtr.Zero) return true;
                try
                {
                    EnableWindow(h, true);
                    SetLayeredWindowAttributes(h, 0, 255, LWA_ALPHA);
                    long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
                    SetWindowLongPtr(h, GWL_EXSTYLE,
                        new IntPtr((ex & ~(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW)) | WS_EX_APPWINDOW));
                    SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0,
                        SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                    if (taskbar != null) { try { taskbar.AddTab(h); } catch { } }
                    RemoveProp(h, "AnyFloatFloating");
                    AnyFloat.Log("recovered orphan hwnd=" + h.ToInt64());
                }
                catch { }
                return true;
            }, IntPtr.Zero);
        }
        catch { }
    }

    void BuildTray()
    {
        tray = new NotifyIcon();
        tray.Icon = SystemIcons.Application;
        tray.Text = "AnyFloat - " + HotkeyText + " 切换悬浮";
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("切换悬浮 / 复原 (" + HotkeyText + ")", null, delegate { Toggle(); });
        menu.Items.Add("复原全部", null, delegate { ExitAll(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, delegate { Shutdown(); });
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            int id = m.WParam.ToInt32();
            if (id == 1) Toggle();
            else if (id == 2) ExitAll();
            return;
        }
        base.WndProc(ref m);
    }

    public string SelfTest()
    {
        StringBuilder sb = new StringBuilder();
        sb.AppendLine("hotkey_registered=" + HotkeyRegistered + " (" + HotkeyText + ")");
        sb.AppendLine("restore_all_registered=" + RestoreAllRegistered);
        sb.AppendLine("animations_enabled=" + animationsEnabled);
        sb.AppendLine("taskbar_com=" + (taskbar != null));
        Rectangle w = WorkArea(GetForegroundWindow());
        sb.AppendLine("workarea=" + w.X + "," + w.Y + "," + w.Width + "," + w.Height);
        sb.AppendLine("pill=" + PillWidth + " maxH=" + PillHeightMax + " fps=" + CaptureFps + "/" + ExpandFps);
        return sb.ToString();
    }

    public int FloatingCount { get { return floats.Count; } }

    // 用自带 logo 替换系统默认托盘图标
    public void SetTrayIcon(string path)
    {
        try
        {
            if (tray != null && System.IO.File.Exists(path)) tray.Icon = new Icon(path);
        }
        catch { }
    }

    // 测试用：直接对指定窗口启动悬浮，不依赖前台焦点
    public void FloatHwnd(IntPtr h)
    {
        if (h != IntPtr.Zero && IsWindow(h) && floats.Count < MaxFloats) EnterFloat(h);
    }

    void OnTick(object sender, EventArgs e)
    {
        Floating[] snapshot = floats.ToArray();
        foreach (Floating f in snapshot)
        {
            if (f.Target == IntPtr.Zero || !IsWindow(f.Target)) { Remove(f); continue; }

            switch (f.Mode)
            {
                case Mode.ToPill:
                case Mode.ToExpand:
                case Mode.ToNormal:
                    Progress(f);
                    break;
                case Mode.Pill:
                case Mode.Expanded:
                    if (f.Box != null && !f.Box.IsDisposed) f.Box.Invalidate();
                    if (f.Mode == Mode.Pill) PollPill(f);
                    else PollExpanded(f);
                    break;
            }
        }
    }

    void Toggle()
    {
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero || fg == Handle) return;

        Floating existing = Find(fg);
        if (existing != null) { ExitFloat(existing); return; }

        if (!IsWindowVisible(fg)) return;
        if (IsShellWindow(fg)) return;
        if (floats.Count >= MaxFloats) return;

        EnterFloat(fg);
    }

    Floating Find(IntPtr h)
    {
        foreach (Floating f in floats) if (f.Target == h) return f;
        return null;
    }

    bool IsShellWindow(IntPtr h)
    {
        StringBuilder cls = new StringBuilder(256);
        GetClassName(h, cls, 256);
        string c = cls.ToString();
        return c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Windows.UI.Core.CoreWindow";
    }

    string TitleOf(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        return sb.ToString();
    }

    void EnterFloat(IntPtr fg)
    {
        Floating f = new Floating();
        f.Target = fg;
        f.SavedMax = IsZoomed(fg);

        RECT r;
        if (!GetWindowRect(fg, out r)) return;
        f.Saved = r;

        RECT cr;
        if (!GetClientRect(fg, out cr)) return;

        f.Work = WorkArea(fg);
        f.Corner = CornerOf(r.ToRect(), f.Work);
        f.Slot = SlotCount(f.Corner);
        ComputeRects(f, new Rectangle(0, 0, Math.Max(1, cr.Right), Math.Max(1, cr.Bottom)));

        // 先把悬浮窗建起来并抓一帧（此时源窗口还完全正常，抓帧最快），
        // 再动源窗口样式 —— 这样按下热键后画面立刻出现，不会先卡在样式切换上。
        f.Box = new PiP();
        f.Box.Source = fg;
        f.Box.SourceTitle = TitleOf(fg);
        f.Box.Fps = CaptureFps;
        f.Box.GlowPad = GlowPad;
        f.Box.ContentAlpha = ContentAlpha;
        f.Box.ImageRect = r.ToRect();
        f.Box.PrimeFrame();
        Floating captured = f;
        f.Box.Clicked += delegate { ExitFloat(captured); };
        f.Box.Show();
        f.Box.Hwnd = f.Box.Handle;
        f.BoxHandle = f.Box.Handle;
        f.Box.StartCapture();

        // 原位隐形：LAYERED(alpha=1) 让画面不可见，TRANSPARENT 让点击穿透，
        // 关键是窗口仍留在屏幕内 → Chromium/DirectX 应用继续渲染，抓帧才是实时的。
        f.OrigExStyle = GetWindowLongPtr(fg, GWL_EXSTYLE);
        long ex = f.OrigExStyle.ToInt64();
        SetProp(fg, "AnyFloatFloating", new IntPtr(1));
        SetWindowLongPtr(fg, GWL_EXSTYLE,
            new IntPtr((ex & ~WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT));
        SetWindowPos(fg, IntPtr.Zero, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        SetLayeredWindowAttributes(fg, 0, 1, LWA_ALPHA);

        // 冻结输入（同时让焦点离开它）
        EnableWindow(fg, false);
        f.Frozen = true;

        if (taskbar != null) { try { taskbar.DeleteTab(fg); } catch { } }
        f.HiddenFromSwitcher = true;

        floats.Add(f);
        UpdateTrayText();
        StartAnim(f, f.Pill, Mode.Pill);
    }

    void ExitFloat(Floating f)
    {
        if (!IsWindow(f.Target)) { Remove(f); return; }

        if (f.Box != null && !f.Box.IsDisposed)
        {
            f.Box.Fps = ExpandFps;
            StartAnim(f, f.Saved.ToRect(), Mode.Idle);
        }
        else Remove(f);
    }

    void ExitAll()
    {
        foreach (Floating f in floats.ToArray()) ExitFloat(f);
    }

    void Remove(Floating f)
    {
        int corner = f.Corner;
        Cleanup(f);
        floats.Remove(f);
        Repack(corner);
        UpdateTrayText();
    }

    // 关掉悬浮窗、把源窗口解冻并恢复任务栏（幂等）
    void Cleanup(Floating f)
    {
        f.AnimGen++;   // 取消进行中的动画线程

        if (f.Box != null)
        {
            try { f.Box.StopCapture(); f.Box.Hide(); f.Box.Dispose(); } catch { }
            f.Box = null;
        }

        if (IsWindow(f.Target))
        {
            if (f.Frozen) { try { EnableWindow(f.Target, true); } catch { } f.Frozen = false; }

            if (f.HiddenFromSwitcher)
            {
                try
                {
                    SetLayeredWindowAttributes(f.Target, 0, 255, LWA_ALPHA);
                    SetWindowLongPtr(f.Target, GWL_EXSTYLE, f.OrigExStyle);
                    SetWindowPos(f.Target, IntPtr.Zero, 0, 0, 0, 0,
                        SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                    if (taskbar != null) { try { taskbar.AddTab(f.Target); } catch { } }
                    RemoveProp(f.Target, "AnyFloatFloating");
                }
                catch { }
                f.HiddenFromSwitcher = false;
            }
        }
    }

    void Repack(int corner)
    {
        int slot = 0;
        foreach (Floating f in floats.ToArray())
        {
            if (f.Corner != corner) continue;
            if (f.Slot != slot)
            {
                f.Slot = slot;
                ComputeRects(f, f.Saved.ToRect());
                if (f.Mode == Mode.Pill || f.Mode == Mode.ToPill) StartAnim(f, f.Pill, Mode.Pill);
            }
            slot++;
        }
    }

    int SlotCount(int corner)
    {
        int n = 0;
        foreach (Floating f in floats) if (f.Corner == corner) n++;
        return n;
    }

    void UpdateTrayText()
    {
        if (tray == null) return;
        string s = floats.Count == 0
            ? "AnyFloat - " + HotkeyText + " 切换悬浮"
            : "AnyFloat - 悬浮中 " + floats.Count + " 个 (" + HotkeyText + ")";
        if (s.Length > 63) s = s.Substring(0, 63);
        tray.Text = s;
    }

    // ---------- 动画（独立线程 + DwmFlush 对齐垂直同步） ----------
    // 动画只改"图像矩形"，窗口本身全程不动 —— 缩放是纯位图操作
    void StartAnim(Floating f, Rectangle to, Mode endMode) { StartAnim(f, to, endMode, false); }

    void StartAnim(Floating f, Rectangle to, Mode endMode, bool snappy)
    {
        if (f.Box == null || f.Box.IsDisposed) return;

        Rectangle from = f.Box.ScreenImageRect;
        f.AnimFrom = from;
        f.AnimTo = to;
        f.AnimTarget = endMode;
        f.AnimDone = false;



        int dist = (int)Math.Sqrt(
            Math.Pow(to.X - from.X, 2) +
            Math.Pow(to.Y - from.Y, 2) +
            Math.Pow(to.Width - from.Width, 2) +
            Math.Pow(to.Height - from.Height, 2));
        int duration = snappy
            ? Math.Max(90, Math.Min(150, AnimMs - 40))
            : Math.Max(160, Math.Min(340, AnimMs + dist / 8));

        f.Mode = endMode == Mode.Pill ? Mode.ToPill
               : endMode == Mode.Expanded ? Mode.ToExpand
               : Mode.ToNormal;

        f.Box.Animating = true;

        if (!animationsEnabled)
        {
            f.Box.SetImageScreen(to);
            f.Box.Animating = false;
            f.AnimDone = true;
            return;
        }

        int gen = ++f.AnimGen;
        Floating captured = f;
        Rectangle fromRect = from;

        Thread anim = new Thread(delegate()
        {
            Stopwatch sw = Stopwatch.StartNew();
            double lastFrame = 0;
            while (true)
            {
                if (captured.AnimGen != gen) return;   // 被新的动画取代

                double p = sw.Elapsed.TotalMilliseconds / (double)duration;
                bool done = p >= 1.0;
                if (done) p = 1.0;

                Rectangle rr = Interpolate(fromRect, to, EaseOutCubic(p));
                captured.Box.SetImageScreen(rr);
                if (AnyFloat.Enabled)
                    AnyFloat.Log("anim t=" + sw.ElapsedMilliseconds + " " + rr.X + "," + rr.Y + " " + rr.Width + "x" + rr.Height);

                if (done) { captured.AnimDone = true; return; }

                double now = sw.Elapsed.TotalMilliseconds;
                int wait = (int)Math.Round(8.0 - (now - lastFrame));
                lastFrame = now;
                if (wait > 0) Thread.Sleep(wait);
            }
        });
        anim.IsBackground = true;
        anim.Start();
    }

    void Progress(Floating f)
    {
        if (f.Box == null || f.Box.IsDisposed) { Remove(f); return; }
        if (!f.AnimDone) return;

        f.Box.Animating = false;
        f.Box.SetImageScreen(f.AnimTo);   // 收尾对齐到精确尺寸
        f.Mode = f.AnimTarget;
        OnAnimDone(f);
    }

    void OnAnimDone(Floating f)
    {
        if (f.Mode == Mode.Idle)
        {
            IntPtr h = f.Target;

            // 窗口一直待在原位（只是透明了），所以复原 = 恢复样式并激活
            Cleanup(f);
            if (IsWindow(h)) Activate(h);
            floats.Remove(f);
            Repack(f.Corner);
            UpdateTrayText();
        }
        else if (f.Mode == Mode.Pill)
        {
            f.HoverSince = -1;
            if (f.Box != null) f.Box.Fps = CaptureFps;
        }
        else if (f.Mode == Mode.Expanded)
        {
            f.LeaveSince = -1;
            if (f.Box != null) f.Box.Fps = ExpandFps;
        }
    }

    void Activate(IntPtr h)
    {
        try
        {
            uint pid;
            IntPtr fg = GetForegroundWindow();
            uint tidFg = GetWindowThreadProcessId(fg, out pid);
            uint tidMe = GetCurrentThreadId();
            bool attached = false;
            if (tidFg != 0 && tidFg != tidMe) attached = AttachThreadInput(tidMe, tidFg, true);
            SetForegroundWindow(h);
            if (attached) AttachThreadInput(tidMe, tidFg, false);
        }
        catch { }
    }

    // ---------- 悬停 ----------
    void PollPill(Floating f)
    {
        if (f.Box == null) return;
        Rectangle r = f.Box.ScreenImageRect;
        POINT p;
        GetCursorPos(out p);

        if (r.Contains(p.X, p.Y))
        {
            if (f.HoverSince < 0) f.HoverSince = (int)clock.ElapsedMilliseconds;
            else if (clock.ElapsedMilliseconds - f.HoverSince >= DwellMs)
            {
                f.HoverSince = -1;
                StartAnim(f, f.Expand, Mode.Expanded, true);
            }
        }
        else f.HoverSince = -1;
    }

    void PollExpanded(Floating f)
    {
        if (f.Box == null) return;
        Rectangle r = f.Box.ScreenImageRect;
        POINT p;
        GetCursorPos(out p);

        if (r.Contains(p.X, p.Y))
        {
            f.LeaveSince = -1;
        }
        else
        {
            if (f.LeaveSince < 0) f.LeaveSince = (int)clock.ElapsedMilliseconds;
            else if (clock.ElapsedMilliseconds - f.LeaveSince > GraceMs)
            {
                f.LeaveSince = -1;
                StartAnim(f, f.Pill, Mode.Pill, true);
            }
        }
    }

    // ---------- 几何 ----------
    Rectangle WorkArea(IntPtr h)
    {
        IntPtr mon = MonitorFromWindow(h == IntPtr.Zero ? Handle : h, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (mon != IntPtr.Zero && GetMonitorInfo(mon, ref mi)) return mi.rcWork.ToRect();
        return Screen.PrimaryScreen.WorkingArea;
    }

    static int CornerOf(Rectangle orig, Rectangle work)
    {
        int cx = orig.X + orig.Width / 2;
        int cy = orig.Y + orig.Height / 2;
        bool right = cx >= work.X + work.Width / 2;
        bool bottom = cy >= work.Y + work.Height / 2;
        return (bottom ? 2 : 0) + (right ? 1 : 0);
    }

    // 悬浮窗尺寸严格保持源窗口比例（等比缩放，不拉伸）
    void ComputeRects(Floating f, Rectangle orig)
    {
        bool right = (f.Corner & 1) != 0;
        bool bottom = (f.Corner & 2) != 0;
        double aspect = orig.Width / (double)Math.Max(1, orig.Height);

        int pw = Math.Max(200, Math.Min(PillWidth, f.Work.Width - 2 * Margin));
        int ph = (int)Math.Round(pw / aspect);
        if (ph > PillHeightMax) { ph = PillHeightMax; pw = (int)Math.Round(ph * aspect); }

        int px = right ? f.Work.Right - Margin - pw : f.Work.X + Margin;
        int py = bottom
            ? f.Work.Bottom - Margin - ph - f.Slot * (ph + SlotGap)
            : f.Work.Y + Margin + f.Slot * (ph + SlotGap);
        py = Math.Max(f.Work.Y + Margin, Math.Min(py, f.Work.Bottom - Margin - ph));
        f.Pill = new Rectangle(px, py, pw, ph);

        int ew = Math.Min(ExpandWidth, f.Work.Width - 2 * Margin);
        int eh = (int)Math.Round(ew / aspect);
        if (eh > ExpandHeight) { eh = Math.Min(ExpandHeight, f.Work.Height - 2 * Margin); ew = (int)Math.Round(eh * aspect); }
        ew = Math.Max(pw, ew); eh = Math.Max(ph, eh);
        int ex = right ? f.Work.Right - Margin - ew : f.Work.X + Margin;
        int ey = bottom ? f.Work.Bottom - Margin - eh : f.Work.Y + Margin;
        f.Expand = new Rectangle(ex, ey, ew, eh);
    }

    static double EaseOutCubic(double t)
    {
        double u = 1 - t;
        return 1 - u * u * u;
    }

    static int Lerp(int a, int b, double t) { return a + (int)Math.Round((b - a) * t); }

    static Rectangle Interpolate(Rectangle a, Rectangle b, double t)
    {
        return new Rectangle(
            Lerp(a.X, b.X, t),
            Lerp(a.Y, b.Y, t),
            Math.Max(1, Lerp(a.Width, b.Width, t)),
            Math.Max(1, Lerp(a.Height, b.Height, t)));
    }

    void Shutdown()
    {
        foreach (Floating f in floats.ToArray()) Cleanup(f);
        floats.Clear();
        try { tick.Stop(); } catch { }
        try { UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2); } catch { }
        try { if (tray != null) { tray.Visible = false; tray.Dispose(); } } catch { }
        Application.Exit();
    }
}
'@

Add-Type -TypeDefinition $code -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll') -Language CSharp

if ($DebugLog) { [AnyFloat]::Enabled = $true }

$tool = New-Object FloatTool
$tool.PillWidth     = $PillWidth
$tool.PillHeightMax = $PillHeightMax
$tool.Margin        = $Margin
$tool.SlotGap       = $SlotGap
$tool.MaxFloats     = $MaxFloats
$tool.DwellMs       = $DwellMs
$tool.AnimMs        = $AnimMs
$tool.ExpandWidth   = $ExpandWidth
$tool.ExpandHeight  = $ExpandHeight
$tool.CaptureFps    = $CaptureFps
$tool.GlowPad       = $GlowPad
$tool.ContentAlpha  = $ContentAlpha
$tool.ExpandFps     = $ExpandFps

# 托盘图标：使用 assets 里的 logo（缺失则回退到系统默认）
$iconPath = Join-Path $PSScriptRoot 'assets\anyfloat.ico'
if (Test-Path $iconPath) { $tool.SetTrayIcon($iconPath) }

if ($SelfTest) {
    $tool.SelfTest()
    [void][System.Windows.Forms.Application]::Exit()
    return
}

if ($FloatHwnd -ne 0) {
    # 等消息循环跑起来后再触发，避免动画线程在窗口尚未合成时启动
    $boot = New-Object System.Windows.Forms.Timer
    $boot.Interval = 1500
    $boot.Add_Tick({
        $boot.Stop()
        $boot.Dispose()
        $tool.FloatHwnd([IntPtr]$FloatHwnd)
    })
    $boot.Start()
}

if (-not $tool.HotkeyRegistered) {
    Write-Host "热键注册失败（可能被其他程序占用），请修改脚本中的热键组合。" -ForegroundColor Yellow
}

[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
