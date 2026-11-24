using System.Drawing;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace Glassify;

/// The widget: one borderless, see-through, always-on-top window that shows only the glass.
/// The glass itself is the same web page the Mac app uses; this class is everything around it.
sealed partial class WidgetForm : Form
{
    // room around the glass for the page's own drop shadow; matches `.widget{left:56px;top:32px}` in index.html
    const double PADX = 56, PADT = 32, PADB = 80, ASPECT = 4.6;
    const string Origin = "https://glassify.app";

    readonly string[] args;
    readonly string dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Glassify");
    string? settingsJson;
    double? savedX, savedY;

    CoreWebView2Environment? env;
    CoreWebView2Controller? controller;
    CoreWebView2? core;

    readonly SpotifyAudio audio = new();
    readonly Spectrum spectrum = new();
    readonly SpotifyInfo spotify = new();
    readonly ScreenGrab grab = new();
    readonly NotifyIcon tray = new();
    readonly BlurBehind blur = new();
    readonly System.Windows.Forms.Timer mouseTimer = new() { Interval = 20 };
    readonly System.Windows.Forms.Timer shrinkTimer = new() { Interval = 800 };
    readonly System.Windows.Forms.Timer pollTimer = new() { Interval = 2000 };
    readonly System.Windows.Forms.Timer stopAudioTimer = new() { Interval = 4000 };
    Thread? ticker;
    volatile bool alive = true, tickerOn;

    // what the page last said about its layout, in CSS pixels
    double fitW = 600, fitStrip = 600 / ASPECT, fitPanel;
    double shapeW = 600, shapeH = 600 / ASPECT, shapeR = 300 / ASPECT;
    bool pageReady, playing, clearOn, dragging, keyboard;
    bool through;
    Point dragMouse, dragOrigin;
    int bandCount = 24, quiet;
    int messages;

    double Dpi => DeviceDpi / 96.0;

    public WidgetForm(string[] args)
    {
        this.args = args;
        LoadSaved();
        if (settingsJson != null)
        {
            try
            {
                using var doc = JsonDocument.Parse(settingsJson);
                if (doc.RootElement.TryGetProperty("scale", out var s) && s.TryGetDouble(out double sc) && sc >= 0.5 && sc <= 1.6) { fitW = Math.Round(600 * sc); fitStrip = fitW / ASPECT; }
                if (doc.RootElement.TryGetProperty("N", out var n) && n.TryGetInt32(out int nn) && nn >= 4 && nn <= 40) bandCount = nn;
            }
            catch { }
        }
        shapeW = fitW; shapeH = fitStrip; shapeR = fitStrip / 2;

        Text = "Glassify";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.Black;
        using (var ico = Assembly.GetExecutingAssembly().GetManifestResourceStream("Glassify.ico")) if (ico != null) Icon = new Icon(ico);
        Bounds = StartBounds();
        Owner = blur;                       // an owned window always stays in front of its owner: the blur sits right behind the glass

        tray.Icon = Icon;
        tray.Text = "Glassify";
        var menu = new ContextMenuStrip();
        menu.Items.Add("Quit Glassify", null, (_, _) => Close());
        tray.ContextMenuStrip = menu;
        tray.Visible = true;

        mouseTimer.Tick += (_, _) => MouseTick();
        shrinkTimer.Tick += (_, _) => { shrinkTimer.Stop(); SetWindowSize(WindowSize(fitPanel)); CaptureRegionChanged(); };
        pollTimer.Tick += (_, _) => { spotify.Poll(); KeepReachable(); };
        stopAudioTimer.Tick += (_, _) => { stopAudioTimer.Stop(); audio.SetWanted(false); };
    }

    // MARK: window basics

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.Style = Native.WS_POPUP;
            // a tool window (no taskbar button, not in Alt-Tab) that never takes the keyboard just by being clicked
            cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST | Native.WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;
    protected override void OnPaintBackground(PaintEventArgs e) { }      // nothing is painted: the window stays see-through
    protected override void OnPaint(PaintEventArgs e) { }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.MakeSeeThrough(Handle);
        SetThrough(true);                 // until the mouse is over the glass itself
    }

    protected override async void OnShown(EventArgs e)
    {
        base.OnShown(e);
        FollowBlur();
        blur.Show();
        try { await StartPage(); }
        catch (Exception ex)
        {
            Log("page could not start: " + ex);
            if (!SelfTest) MessageBox.Show("Glassify could not start its view.\n\nIt needs the Microsoft Edge WebView2 Runtime, which is part of Windows 11 and most Windows 10 PCs. If it is missing, install \"WebView2 Runtime\" from Microsoft and try again.\n\n" + ex.Message, "Glassify");
            Close();
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_MOUSEACTIVATE && !keyboard) { m.Result = Native.MA_NOACTIVATE; return; }
        base.WndProc(ref m);
        if (m.Msg == Native.WM_DPICHANGED) BeginInvoke(() => { SetWindowSize(WindowSize(fitPanel)); CaptureRegionChanged(); });
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (controller != null) controller.Bounds = new Rectangle(Point.Empty, ClientSize);
    }

    protected override void OnMove(EventArgs e)
    {
        base.OnMove(e);
        controller?.NotifyParentWindowPositionChanged();
        FollowBlur();
        CaptureRegionChanged();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (keyboard) { keyboard = false; Native.SetExStyle(Handle, Native.WS_EX_NOACTIVATE, true); }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        alive = false;
        SavePosition();
        tray.Visible = false;
        tray.Dispose();
        try { blur.Close(); } catch { }
        audio.Dispose();
        grab.Dispose();
        try { controller?.Close(); } catch { }
        base.OnFormClosed(e);
    }

    // MARK: the page

    async Task StartPage()
    {
        Directory.CreateDirectory(dataDir);
        env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(dataDir, "WebView2"));
        controller = await env.CreateCoreWebView2ControllerAsync(Handle);
        controller.DefaultBackgroundColor = Color.Transparent;
        controller.Bounds = new Rectangle(Point.Empty, ClientSize);
        controller.IsVisible = true;
        core = controller.CoreWebView2;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsSwipeNavigationEnabled = false;
        core.Settings.IsPinchZoomEnabled = false;

        // The page talks to "the app around it" through one channel; on the Mac that is WebKit's, here it is WebView2's.
        await core.AddScriptToExecuteOnDocumentCreatedAsync("""
            (function(){
              window.webkit={messageHandlers:{glassify:{postMessage:function(m){window.chrome.webview.postMessage(m);}}}};
              window.chrome.webview.addEventListener('message',function(e){
                var d=e.data,g=window.__gw; if(!g||!d) return;
                if(d.b) g.bands(d.b); else if(d.f) g.frame(); else if('p' in d) g.playing(d.p); else if('t' in d) g.track(d.t,d.a,d.c);
              });
            })();
            """);
        core.AddWebResourceRequestedFilter(Origin + "/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnResource;
        core.WebMessageReceived += OnMessage;
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith(Origin, StringComparison.OrdinalIgnoreCase)) e.Cancel = true; };
        core.ProcessFailed += (_, _) => { pageReady = false; try { core.Reload(); } catch { } };
        core.ContextMenuRequested += (_, e) =>
        {
            e.MenuItems.Clear();
            var quit = env.CreateContextMenuItem("Quit Glassify", null, CoreWebView2ContextMenuItemKind.Command);
            quit.CustomItemSelected += (_, _) => BeginInvoke(Close);
            e.MenuItems.Add(quit);
        };
        core.Navigate(Origin + "/index.html");

        grab.FrameReady += () => { if (alive && pageReady && clearOn) Post("{\"f\":1}"); };
        spotify.StateChanged += s => OnUi(() => SpotifyChanged(s));
        spotify.TrackChanged += (t, a, c) => OnUi(() => SendTrack(t, a, c));
        mouseTimer.Start();
        pollTimer.Start();
        _ = spotify.StartAsync();
        if (SelfTest) _ = RunSelfTest();
    }

    void OnUi(Action a) { if (!alive || IsDisposed) return; try { BeginInvoke(a); } catch { } }

    /// Hands a small JSON message to the page (from any thread).
    void Post(string json) => OnUi(() => { try { if (pageReady) core?.PostWebMessageAsJson(json); } catch { } });

    void OnResource(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        if (env == null) return;
        string path = new Uri(e.Request.Uri).AbsolutePath;
        if (path == "/frame")
        {
            var f = grab.Latest();
            if (f == null) { e.Response = env.CreateWebResourceResponse(null, 204, "No Content", "Cache-Control: no-store"); return; }
            var (data, w, h, rows) = f.Value;
            e.Response = env.CreateWebResourceResponse(new MemoryStream(data), 200, "OK",
                $"Content-Type: application/octet-stream\r\nCache-Control: no-store\r\nX-W: {w}\r\nX-H: {h}\r\nX-Rows: {rows.ToString("F4", CultureInfo.InvariantCulture)}");
        }
        else if (path is "/" or "/index.html")
        {
            string page;
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("index.html")!)
            using (var r = new StreamReader(s, Encoding.UTF8)) page = r.ReadToEnd();
            if (settingsJson != null)
            {
                // hand the page its saved settings before its script starts
                string lit = JsonSerializer.Serialize(settingsJson).Replace("</", "<\\/");
                page = page.Replace("/*GLASSIFY_SETTINGS*/", "try{localStorage.setItem('glasswake.v1'," + lit + ")}catch(e){}");
            }
            e.Response = env.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(page)), 200, "OK", "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store");
        }
        else e.Response = env.CreateWebResourceResponse(null, 404, "Not Found", "");
    }

    void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var m = doc.RootElement;
            if (m.ValueKind != JsonValueKind.Object || !m.TryGetProperty("t", out var tt)) return;
            messages++;
            double Num(string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out double d) && double.IsFinite(d) ? d : double.NaN;
            switch (tt.GetString())
            {
                case "ready":
                    pageReady = true;
                    SpotifyChanged(spotify.State);
                    if (spotify.Last is { } l) SendTrack(l.title, l.artist, l.cover);
                    Post(playing ? "{\"p\":true}" : "{\"p\":false}");
                    if (clearOn && grab.Latest() != null) Post("{\"f\":1}");
                    break;
                case "save":
                    if (m.TryGetProperty("json", out var j) && j.GetString() is { Length: < 20000 } text) { settingsJson = text; Save(); }
                    break;
                case "fit":
                    {
                        double w = Num("w"), s = Num("strip"), p = Num("panel");
                        if (w >= 200 && w <= 1200 && s > 20 && p >= 0 && p < 2000) ApplyFit(w, s, p);
                        break;
                    }
                case "shape":
                    {
                        double w = Num("w"), h = Num("h"), r = Num("r");
                        if (w > 0 && h > 0) { shapeW = w; shapeH = h; shapeR = double.IsNaN(r) ? 0 : r; FollowBlur(); }
                        break;
                    }
                case "clear":
                    clearOn = m.TryGetProperty("on", out var on) && on.ValueKind == JsonValueKind.True;
                    // while Clear is showing, the widget is left out of every screen capture (so it never sees itself)
                    Native.SetWindowDisplayAffinity(Handle, clearOn && !NoExclude ? Native.WDA_EXCLUDEFROMCAPTURE : Native.WDA_NONE);
                    if (blur.IsHandleCreated) Native.SetWindowDisplayAffinity(blur.Handle, clearOn && !NoExclude ? Native.WDA_EXCLUDEFROMCAPTURE : Native.WDA_NONE);
                    if (clearOn) CaptureRegionChanged();
                    grab.SetWanted(clearOn);
                    break;
                case "drag":
                    if ((Native.GetAsyncKeyState(Native.VK_LBUTTON) & 0x8000) != 0 && Native.GetCursorPos(out var p0))
                    {
                        dragging = true; dragMouse = new Point(p0.X, p0.Y); dragOrigin = Location;
                        mouseTimer.Interval = 8;
                    }
                    break;
                case "dragEnd":
                    EndDrag();
                    break;
                case "nudge":
                    {
                        double dx = Num("dx"), dy = Num("dy");
                        if (!double.IsNaN(dx) && !double.IsNaN(dy)) { Location = new Point(Left + (int)Math.Round(dx * Dpi), Top + (int)Math.Round(dy * Dpi)); KeepReachable(); SavePosition(); }
                        break;
                    }
                case "key":
                    // a click in the settings lets the widget take the keyboard (sliders, colour fields)
                    if (!keyboard)
                    {
                        keyboard = true;
                        Native.SetExStyle(Handle, Native.WS_EX_NOACTIVATE, false);
                        Native.SetForegroundWindow(Handle);
                        try { controller?.MoveFocus(CoreWebView2MoveFocusReason.Programmatic); } catch { }
                    }
                    break;
            }
        }
        catch (Exception ex) { Log("message: " + ex.Message); }
    }

    // MARK: window geometry (screen pixels; the page thinks in CSS pixels, one CSS pixel = Dpi screen pixels)

    Size WindowSize(double panel) => new(
        (int)Math.Ceiling((Math.Ceiling(fitW) + 2 * PADX) * Dpi),
        (int)Math.Ceiling((Math.Ceiling(fitStrip + panel) + PADT + PADB) * Dpi));

    Rectangle StartBounds()
    {
        var size = WindowSize(0);
        Point? topLeft = null;
        if (savedX is { } x && savedY is { } y && HandleOnScreen(new Point((int)x, (int)y))) topLeft = new Point((int)x, (int)y);
        if (topLeft == null)
        {
            var area = (Screen.PrimaryScreen ?? Screen.AllScreens[0]).WorkingArea;
            topLeft = new Point(area.Left + (int)((area.Width - fitW * Dpi) / 2), area.Top + (int)(64 * Dpi));
        }
        return new Rectangle(topLeft.Value.X - (int)Math.Round(PADX * Dpi), topLeft.Value.Y - (int)Math.Round(PADT * Dpi), size.Width, size.Height);
    }

    Point GlassTopLeft => new(Left + (int)Math.Round(PADX * Dpi), Top + (int)Math.Round(PADT * Dpi));

    /// True when the small move bar at the top of the glass is somewhere a mouse can reach.
    bool HandleOnScreen(Point glassTopLeft)
    {
        var handle = new Point(glassTopLeft.X + (int)(fitW * Dpi / 2), glassTopLeft.Y + (int)(11 * Dpi));
        return Screen.AllScreens.Any(s => Rectangle.Inflate(s.Bounds, -8, -8).Contains(handle));
    }

    void KeepReachable()
    {
        if (dragging || HandleOnScreen(GlassTopLeft)) return;
        var area = Screen.FromPoint(GlassTopLeft).WorkingArea;
        int gx = Math.Clamp(GlassTopLeft.X, area.Left + 8, Math.Max(area.Left + 8, area.Right - (int)(fitW * Dpi) - 8));
        int gy = Math.Clamp(GlassTopLeft.Y, area.Top + 8, Math.Max(area.Top + 8, area.Bottom - (int)(fitStrip * Dpi) - 8));
        Location = new Point(gx - (int)Math.Round(PADX * Dpi), gy - (int)Math.Round(PADT * Dpi));
        SavePosition();
    }

    void SetWindowSize(Size s)
    {
        if (Size == s) return;
        Size = s;                               // the top-left corner stays put
        if (controller != null) controller.Bounds = new Rectangle(Point.Empty, ClientSize);
    }

    /// The page says how big the glass is (and how tall its open settings are). Grow at once, shrink once the motion has finished.
    void ApplyFit(double w, double strip, double panel)
    {
        fitW = w; fitStrip = strip; fitPanel = panel;
        var target = WindowSize(panel);
        SetWindowSize(new Size(Math.Max(Width, target.Width), Math.Max(Height, target.Height)));
        shrinkTimer.Stop(); shrinkTimer.Start();
        CaptureRegionChanged();
        SavePosition();
    }

    /// Keeps the blur window exactly under the glass.
    void FollowBlur()
    {
        var g = GlassTopLeft;
        double rad = Math.Min(shapeR, Math.Min(shapeH / 2, shapeW / 2));
        blur.Follow(new Rectangle(g.X, g.Y, (int)Math.Round(shapeW * Dpi), (int)Math.Round(shapeH * Dpi)), (int)Math.Round(rad * Dpi));
    }

    /// Tells the screen capture which part of the screen sits behind the glass.
    void CaptureRegionChanged()
    {
        if (!clearOn) return;
        // 0.7 of a strip more than the glass covers (the glass bends what lies just below it into view), in whole picture rows
        double px = Math.Min(996, Math.Ceiling(((Height / Dpi - PADT - PADB) / Math.Max(1, fitStrip) + 0.7) * 166));
        double rows = px / 166;
        var g = GlassTopLeft;
        grab.SetRegion(new Rectangle(g.X, g.Y, (int)Math.Round(fitW * Dpi), (int)Math.Round(fitStrip * rows * Dpi)), rows);
    }

    // MARK: mouse: only the glass itself takes clicks; the clear margin around it lets them through

    bool GlassContains(Point p)
    {
        var g = GlassTopLeft;
        double x = (p.X - g.X) / Dpi, y = (p.Y - g.Y) / Dpi;
        if (x < 0 || y < 0 || x > shapeW || y > shapeH) return false;
        double rad = Math.Min(shapeR, Math.Min(shapeH / 2, shapeW / 2));
        double cx = Math.Clamp(x, rad, shapeW - rad), cy = Math.Clamp(y, rad, shapeH - rad);
        return Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) <= rad;
    }

    void SetThrough(bool on)
    {
        if (through == on && IsHandleCreated && ((Native.GetWindowLongPtr(Handle, Native.GWL_EXSTYLE).ToInt64() & Native.WS_EX_TRANSPARENT) != 0) == on) return;
        through = on;
        Native.SetExStyle(Handle, Native.WS_EX_TRANSPARENT | (LayeredToo ? Native.WS_EX_LAYERED : 0), on);
        if (on && LayeredToo && LayeredAlpha) Native.SetLayeredWindowAttributes(Handle, 0, 255, 2);
    }

    void MouseTick()
    {
        if (!Native.GetCursorPos(out var p)) return;
        bool down = (Native.GetAsyncKeyState(Native.VK_LBUTTON) & 0x8000) != 0;
        if (dragging)
        {
            if (!down) { EndDrag(); return; }
            Location = new Point(dragOrigin.X + p.X - dragMouse.X, dragOrigin.Y + p.Y - dragMouse.Y);
            return;
        }
        if (down) return;                       // never change sides in the middle of a press
        SetThrough(!GlassContains(new Point(p.X, p.Y)));
    }

    void EndDrag()
    {
        if (!dragging) return;
        dragging = false;
        mouseTimer.Interval = 20;
        SavePosition();
    }

    // MARK: Spotify -> page

    void SpotifyChanged(PlayState s)
    {
        switch (s)
        {
            case PlayState.Playing:
                stopAudioTimer.Stop(); audio.SetWanted(true); StartTicker(); SetPlaying(true);
                break;
            case PlayState.Unknown:
                // Spotify is open but Windows does not say what it is doing: listen, and let the sound itself decide
                stopAudioTimer.Stop(); audio.SetWanted(true); StartTicker();
                break;
            default:
                tickerOn = false; spectrum.Reset(); SetPlaying(false);
                stopAudioTimer.Stop(); stopAudioTimer.Start();      // pauses are often short: keep listening for a moment
                Post("{\"b\":[0]}");
                break;
        }
    }

    void SetPlaying(bool p)
    {
        if (p == playing) return;
        playing = p;
        Post(p ? "{\"p\":true}" : "{\"p\":false}");
    }

    void SendTrack(string title, string artist, string? cover)
    {
        if (!pageReady) return;
        Post(JsonSerializer.Serialize(new { t = title, a = artist, c = cover }));
    }

    /// About sixty times a second while music may be playing: analyse the newest sound and hand the bar energies to the page.
    void StartTicker()
    {
        tickerOn = true;
        if (ticker is { IsAlive: true }) return;
        ticker = new Thread(() =>
        {
            var sb = new StringBuilder(256);
            while (alive)
            {
                Thread.Sleep(15);
                if (!tickerOn || !pageReady) { if (!tickerOn) Thread.Sleep(100); continue; }
                var b = spectrum.Bands(audio, bandCount);
                if (spotify.State == PlayState.Unknown)
                {
                    if (b != null && b.Any(v => v > 0.02f)) { quiet = 0; OnUi(() => SetPlaying(true)); }
                    else if (++quiet > 90) OnUi(() => SetPlaying(false));
                }
                if (b == null) continue;
                sb.Clear().Append("{\"b\":[");
                for (int i = 0; i < b.Length; i++) { if (i > 0) sb.Append(','); sb.Append(b[i] <= 0 ? "0" : b[i].ToString("F3", CultureInfo.InvariantCulture)); }
                sb.Append("]}");
                Post(sb.ToString());
            }
        }) { IsBackground = true, Name = "Glassify bars" };
        ticker.Start();
    }

    // MARK: remembered between launches

    void LoadSaved()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(dataDir, "glassify.json")));
            var r = doc.RootElement;
            if (r.TryGetProperty("settings", out var s) && s.ValueKind == JsonValueKind.String) settingsJson = s.GetString();
            if (r.TryGetProperty("x", out var x) && x.TryGetDouble(out double xv)) savedX = xv;
            if (r.TryGetProperty("y", out var y) && y.TryGetDouble(out double yv)) savedY = yv;
        }
        catch { }
    }

    void Save()
    {
        if (SelfTest) return;
        try
        {
            Directory.CreateDirectory(dataDir);
            File.WriteAllText(Path.Combine(dataDir, "glassify.json"), JsonSerializer.Serialize(new { settings = settingsJson, x = savedX, y = savedY }));
        }
        catch { }
    }

    void SavePosition()
    {
        if (!IsHandleCreated) return;
        var g = GlassTopLeft;
        if (savedX == g.X && savedY == g.Y) return;
        savedX = g.X; savedY = g.Y;
        Save();
    }

    static void Log(string s) { try { System.Diagnostics.Trace.WriteLine("Glassify: " + s); } catch { } }
}
