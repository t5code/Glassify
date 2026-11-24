using System.Diagnostics;
using System.Drawing;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Glassify;

/// Clear mode: a live picture of the screen behind the glass, without the widget in it.
/// Windows' desktop duplication hands over the monitor's picture only when something on it changed; the widget's own
/// window is marked "exclude from capture", so it never appears. Only the patch behind the widget is read back, pictures
/// identical to the last one are dropped, and while that patch stays still the checking slows right down.
sealed class ScreenGrab : IDisposable
{
    const int OutW = 768;          // the page works at 2 x 384 across and 2 x 83 (=166) per strip-height
    readonly object gate = new();
    Thread? thread;
    volatile bool run;
    Rectangle region;              // what the page needs, in screen pixels, starting at the glass's top-left corner
    double rows = 1.7;
    byte[] latest = Array.Empty<byte>();
    int latestW, latestH; double latestRows;

    public string Status { get; private set; } = "off";
    public long Seen { get; private set; }
    public long Sent { get; private set; }
    public bool Still { get; private set; }
    /// Raised (on the capture thread) whenever a new picture is ready for the page.
    public event Action? FrameReady;

    public void SetRegion(Rectangle r, double rowCount) { lock (gate) { region = r; rows = rowCount; } }

    public void SetWanted(bool on)
    {
        if (on == run) return;
        if (on)
        {
            run = true;
            thread = new Thread(Loop) { IsBackground = true, Name = "Glassify screen" };
            thread.Start();
        }
        else
        {
            run = false;
            var t = thread; thread = null;
            t?.Join(1500);
            lock (gate) { latest = Array.Empty<byte>(); latestW = 0; }
            Status = "off";
        }
    }

    public (byte[] data, int w, int h, double rows)? Latest()
    {
        lock (gate) return latestW > 0 ? (latest, latestW, latestH, latestRows) : null;
    }

    public void Dispose() => SetWanted(false);

    void Loop()
    {
        while (run)
        {
            try { Session(); }
            catch (Exception e) { Status = "screen capture restarting: " + e.Message; }
            for (int i = 0; i < 10 && run; i++) Thread.Sleep(100);
        }
    }

    /// One capture session on the monitor the widget is on; returns when the widget moves to another monitor or Windows
    /// takes the picture away (resolution change, lock screen, a full-screen game…), and Loop starts a fresh one.
    unsafe void Session()
    {
        Rectangle want; lock (gate) want = region;
        if (want.Width < 8) { Thread.Sleep(100); return; }
        var centre = new Point(want.Left + want.Width / 2, want.Top + Math.Min(want.Height, 40) / 2);

        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        // find the monitor the widget is on (and the graphics adapter driving it); fall back to the first monitor
        IDXGIAdapter1? adapter = null; IDXGIOutput? output = null; Rectangle desk = default;
        for (uint a = 0; factory.EnumAdapters1(a, out var ad).Success; a++)
        {
            bool kept = false;
            for (uint o = 0; ad.EnumOutputs(o, out var op).Success; o++)
            {
                var c = op.Description.DesktopCoordinates;
                var rect = Rectangle.FromLTRB(c.Left, c.Top, c.Right, c.Bottom);
                bool hit = rect.Contains(centre);
                if (!hit && output != null) { op.Dispose(); continue; }
                output?.Dispose();
                if (adapter != null && adapter != ad) adapter.Dispose();
                output = op; adapter = ad; desk = rect; kept = true;
                if (hit) goto found;
            }
            if (!kept) ad.Dispose();
        }
        found:
        if (adapter == null || output == null) throw new InvalidOperationException("no monitor found");

        using (adapter) using (output)
        {
            D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport, null!, out ID3D11Device? device, out ID3D11DeviceContext? context).CheckError();
            using var dev = device!; using var ctx = context!;
            using var output1 = output.QueryInterface<IDXGIOutput1>();
            using var dup = output1.DuplicateOutput(dev);
            Status = "capturing";

            ID3D11Texture2D? keep = null;       // the monitor's last picture, kept on the graphics card so a moved widget can be re-cut from it
            ID3D11Texture2D? staging = null; int stW = 0, stH = 0;
            byte[] prev = Array.Empty<byte>(); string prevKey = "";
            int unchanged = 0;
            var clock = Stopwatch.StartNew(); long next = 0;
            Rectangle lastWant = default; double lastRows = 0;
            try
            {
                while (run)
                {
                    Rectangle r; double rowCount; lock (gate) { r = region; rowCount = rows; }
                    var c2 = new Point(r.Left + r.Width / 2, r.Top + Math.Min(r.Height, 40) / 2);
                    if (!desk.Contains(c2) && Screen.AllScreens.Any(s => s.Bounds.Contains(c2))) return;   // moved to another monitor

                    long now = clock.ElapsedMilliseconds;
                    if (now < next) { Thread.Sleep((int)Math.Min(next - now, 30)); continue; }

                    bool moved = r != lastWant || rowCount != lastRows;
                    var res = dup.AcquireNextFrame(moved && keep != null ? 0u : 100u, out var info, out IDXGIResource? frame);
                    bool fresh = false;
                    if (res.Success)
                    {
                        if (frame != null && (info.LastPresentTime != 0 || keep == null))    // otherwise only the mouse pointer moved
                        {
                            using var tex = frame.QueryInterface<ID3D11Texture2D>();
                            var d = tex.Description;
                            if (d.Format != Format.B8G8R8A8_UNorm) { Status = "screen format not supported: " + d.Format; frame.Dispose(); dup.ReleaseFrame(); Thread.Sleep(2000); continue; }
                            keep ??= dev.CreateTexture2D(new Texture2DDescription
                            {
                                Width = d.Width, Height = d.Height, MipLevels = 1, ArraySize = 1, Format = d.Format,
                                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Default, BindFlags = BindFlags.ShaderResource,
                            });
                            ctx.CopyResource(keep, tex);
                            fresh = true;
                        }
                        frame?.Dispose();
                        dup.ReleaseFrame();
                    }
                    else if (res.Code != Vortice.DXGI.ResultCode.WaitTimeout.Code) return;       // Windows took the picture away; start over
                    if (keep == null || (!fresh && !moved)) continue;
                    next = clock.ElapsedMilliseconds + (Still ? 120 : 33);
                    lastWant = r; lastRows = rowCount;
                    if (fresh) Seen++;

                    // read back only the patch behind the widget (clipped to this monitor)
                    var clip = Rectangle.Intersect(r, desk);
                    int W = OutW, H = Math.Max(2, (int)Math.Round(166 * rowCount));
                    int cw = Math.Max(0, clip.Width), ch = Math.Max(0, clip.Height);
                    byte[] crop = new byte[cw * ch * 4];
                    if (cw > 0 && ch > 0)
                    {
                        if (staging == null || stW != cw || stH != ch)
                        {
                            staging?.Dispose();
                            staging = dev.CreateTexture2D(new Texture2DDescription
                            {
                                Width = (uint)cw, Height = (uint)ch, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
                                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging, CPUAccessFlags = CpuAccessFlags.Read,
                            });
                            stW = cw; stH = ch;
                        }
                        ctx.CopySubresourceRegion(staging, 0, 0, 0, 0, keep, 0, new Vortice.Mathematics.Box(clip.Left - desk.Left, clip.Top - desk.Top, 0, clip.Right - desk.Left, clip.Bottom - desk.Top, 1));
                        var map = ctx.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
                        fixed (byte* dst = crop)
                            for (int y = 0; y < ch; y++) Buffer.MemoryCopy((byte*)map.DataPointer + y * (long)map.RowPitch, dst + y * cw * 4, cw * 4, cw * 4);
                        ctx.Unmap(staging, 0);
                    }

                    // nothing new behind the glass? then there is nothing to send
                    string key = $"{clip.Left},{clip.Top},{cw},{ch},{r.Left},{r.Top},{r.Width},{r.Height},{H}";
                    if (key == prevKey && crop.AsSpan().SequenceEqual(prev))
                    {
                        if (++unchanged >= 45) Still = true;
                        continue;
                    }
                    prevKey = key; prev = crop; unchanged = 0; Still = false;

                    var picture = new byte[W * H * 4];
                    for (int i = 0; i < picture.Length; i += 4) { picture[i] = 0x0d; picture[i + 1] = 0x0e; picture[i + 2] = 0x13; picture[i + 3] = 255; }   // the preview's fill for "nothing there"
                    if (cw > 0 && ch > 0 && r.Width > 0 && r.Height > 0)
                    {
                        int dx0 = Math.Clamp((int)Math.Round((clip.Left - r.Left) / (double)r.Width * W), 0, W - 1);
                        int dy0 = Math.Clamp((int)Math.Round((clip.Top - r.Top) / (double)r.Height * H), 0, H - 1);
                        int dw = Math.Clamp((int)Math.Round(cw / (double)r.Width * W), 1, W - dx0);
                        int dh = Math.Clamp((int)Math.Round(ch / (double)r.Height * H), 1, H - dy0);
                        Resample(crop, cw, ch, picture, W, dx0, dy0, dw, dh);
                    }
                    lock (gate) { latest = picture; latestW = W; latestH = H; latestRows = rowCount; }
                    Sent++;
                    FrameReady?.Invoke();
                }
            }
            finally { staging?.Dispose(); keep?.Dispose(); }
        }
    }

    /// Scales a BGRA picture into a rectangle of an RGBA one. Shrinking averages every source pixel that falls under a
    /// destination pixel (so thin lines and text do not shimmer); enlarging blends neighbours.
    static void Resample(byte[] src, int sw, int sh, byte[] dst, int dstStride, int dx, int dy, int dw, int dh)
    {
        static (int[] start, float[][] weight) Taps(int from, int to)
        {
            double scale = (double)from / to, support = Math.Max(1.0, scale);
            var start = new int[to]; var weight = new float[to][];
            for (int i = 0; i < to; i++)
            {
                double centre = (i + 0.5) * scale - 0.5;
                int a = Math.Max(0, (int)Math.Ceiling(centre - support)), b = Math.Min(from - 1, (int)Math.Floor(centre + support));
                if (b < a) { a = b = Math.Clamp((int)Math.Round(centre), 0, from - 1); }
                var w = new float[b - a + 1]; float sum = 0;
                for (int j = a; j <= b; j++) { float v = (float)Math.Max(0, 1 - Math.Abs(j - centre) / support); w[j - a] = v; sum += v; }
                if (sum <= 0) { w[0] = 1; sum = 1; }
                for (int j = 0; j < w.Length; j++) w[j] /= sum;
                start[i] = a; weight[i] = w;
            }
            return (start, weight);
        }
        var (xs, xw) = Taps(sw, dw);
        var (ys, yw) = Taps(sh, dh);
        var mid = new float[sh * dw * 3];                 // horizontal pass: every source row, at destination width
        for (int y = 0; y < sh; y++)
        {
            int row = y * sw * 4, o = y * dw * 3;
            for (int x = 0; x < dw; x++)
            {
                float b = 0, g = 0, r = 0; var w = xw[x]; int p = row + xs[x] * 4;
                for (int k = 0; k < w.Length; k++, p += 4) { b += src[p] * w[k]; g += src[p + 1] * w[k]; r += src[p + 2] * w[k]; }
                mid[o++] = r; mid[o++] = g; mid[o++] = b;
            }
        }
        for (int y = 0; y < dh; y++)                      // vertical pass, written as RGBA
        {
            var w = yw[y]; int o = ((dy + y) * dstStride + dx) * 4;
            for (int x = 0; x < dw; x++)
            {
                float r = 0, g = 0, b = 0; int p = (ys[y] * dw + x) * 3;
                for (int k = 0; k < w.Length; k++, p += dw * 3) { r += mid[p] * w[k]; g += mid[p + 1] * w[k]; b += mid[p + 2] * w[k]; }
                dst[o++] = (byte)(r + 0.5f); dst[o++] = (byte)(g + 0.5f); dst[o++] = (byte)(b + 0.5f); dst[o++] = 255;
            }
        }
    }
}
