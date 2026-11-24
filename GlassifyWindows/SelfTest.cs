using System.Drawing;
using System.Drawing.Imaging;
using System.Text;
using Microsoft.Web.WebView2.Core;

namespace Glassify;

/// `Glassify.exe --selftest <folder>`: used only by the automatic build on GitHub, which has no person, no Spotify and
/// no sound. It puts a colour card behind the widget, drives the page through its states, and saves screenshots and a
/// report into the folder so the result can be looked at afterwards. Normal launches never come here.
sealed partial class WidgetForm
{
    bool SelfTest => args.Contains("--selftest");
    string TestDir => args.SkipWhile(a => a != "--selftest").Skip(1).FirstOrDefault() ?? ".";
    bool NoExclude => args.Contains("--no-exclude");

    /// How the clear margin is made click-through: the extended style alone, or together with "layered" (and its alpha call).
    bool LayeredToo = true;
    bool LayeredAlpha = false;

    async Task RunSelfTest()
    {
        var log = new StringBuilder();
        void Note(string s) { log.AppendLine(s); try { File.WriteAllText(Path.Combine(TestDir, "report.txt"), log.ToString()); } catch { } }
        try
        {
            Directory.CreateDirectory(TestDir);
            Note($"windows {Environment.OSVersion.Version}  dpi-scale {Dpi}  screen {Screen.PrimaryScreen?.Bounds}");
            // a colour card under the widget, so see-through shows in screenshots
            var card = new Form { FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, ShowInTaskbar = false, Text = "card" };
            card.Bounds = new Rectangle(Left - 40, Top - 40, Width + 80, Height + 360);
            card.Paint += (_, e) =>
            {
                int w = card.Width, h = card.Height;
                e.Graphics.Clear(Color.FromArgb(219, 30, 30));
                using var g = new SolidBrush(Color.FromArgb(20, 200, 30)); e.Graphics.FillRectangle(g, w / 2, 0, w / 2, h / 2);
                using var m = new SolidBrush(Color.FromArgb(219, 30, 230)); e.Graphics.FillRectangle(m, 0, h / 2, w / 2, h / 2);
                using var c = new SolidBrush(Color.FromArgb(20, 200, 230)); e.Graphics.FillRectangle(c, w / 2, h / 2, w / 2, h / 2);
            };
            card.Show();
            Native.SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);

            for (int i = 0; i < 100 && !pageReady; i++) await Task.Delay(200);
            Note($"page ready: {pageReady}  messages from page: {messages}  window {Bounds}  fit {fitW}x{fitStrip:F1}  shape {shapeW}x{shapeH} r{shapeR:F1}");
            if (!pageReady) { await Shot("screen_notready.png"); return; }

            string webgl = await core!.ExecuteScriptAsync("(function(){var c=document.getElementById('gl');return c.width+'x'+c.height+' nogl='+!!document.querySelector('.nogl')+' ua='+navigator.userAgent})()");
            Note("page canvas: " + webgl);
            await core.ExecuteScriptAsync("__gw.playing(true); window.__t=setInterval(function(){var a=[],t=performance.now()/1000;for(var i=0;i<24;i++)a.push(0.45+0.4*Math.sin(t*3+i*0.5));__gw.bands(a)},16); __gw.track('Test Track','Test Artist',null); 1");
            await Task.Delay(2500);
            await Preview("page_drift.png");
            await Shot("screen_drift.png");

            // the blur behind the glass: off, on, and on without the see-through recipe
            blur.Apply(false); await Task.Delay(500); await Shot("screen_blur_off.png");
            blur.Apply(true); await Task.Delay(500); await Shot("screen_blur_on.png");
            Note($"blur window {blur.Bounds} visible {blur.Visible}");

            // click-through: which window does Windows find in the clear margin and on the glass, and does the widget stay visible?
            mouseTimer.Stop();
            var margin = new Native.POINT { X = Left + 8, Y = Top + Height - 8 };
            var centre = new Native.POINT { X = GlassTopLeft.X + (int)(fitW * Dpi / 2), Y = GlassTopLeft.Y + (int)(fitStrip * Dpi / 2) };
            string Under(Native.POINT p) { var h = Native.GetAncestor(Native.WindowFromPoint(p), 2); return h == Handle ? "widget" : h == blur.Handle ? "blur" : h == card.Handle ? "card" : "other"; }
            Native.SetExStyle(Handle, Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED, false);
            await Task.Delay(300);
            Note($"taking clicks: margin->{Under(margin)} glass->{Under(centre)}");
            foreach (var (name, layered, alpha) in new[] { ("style-only", false, false), ("layered", true, false), ("layered+alpha", true, true) })
            {
                LayeredToo = layered; LayeredAlpha = alpha; through = false;
                SetThrough(true);
                await Task.Delay(400);
                string a = Under(margin), b = Under(centre);
                await Shot($"screen_through_{name}.png");
                SetThrough(false);
                Native.SetExStyle(Handle, Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED, false);
                await Task.Delay(300);
                Note($"click-through {name}: margin->{a} glass->{b}; after switching back: margin->{Under(margin)} glass->{Under(centre)}");
                await Shot($"screen_back_{name}.png");
            }
            LayeredToo = true; LayeredAlpha = false; through = false;
            mouseTimer.Start();

            await core.ExecuteScriptAsync("document.getElementById('btnSettings').click(); 1");
            await Task.Delay(1600);
            Note($"settings open: window {Bounds}  panel {fitPanel}  shape {shapeW}x{shapeH} r{shapeR:F1}");
            await Preview("page_open.png");
            await Shot("screen_open.png");
            await core.ExecuteScriptAsync("document.getElementById('btnSettings').click(); 1");
            await Task.Delay(1400);

            await core.ExecuteScriptAsync("document.getElementById('mode-vinyl').click(); 1");
            await Task.Delay(1600);
            await Shot("screen_vinyl.png");

            await core.ExecuteScriptAsync("document.getElementById('mode-clear').click(); 1");
            await Task.Delay(3500);
            Note($"clear: capture status '{grab.Status}'  pictures seen {grab.Seen} sent {grab.Sent} still {grab.Still}");
            if (grab.Latest() is { } f)
            {
                using var bmp = new Bitmap(f.w, f.h, PixelFormat.Format32bppArgb);
                var bits = bmp.LockBits(new Rectangle(0, 0, f.w, f.h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                var bgra = new byte[f.data.Length];
                for (int i = 0; i < bgra.Length; i += 4) { bgra[i] = f.data[i + 2]; bgra[i + 1] = f.data[i + 1]; bgra[i + 2] = f.data[i]; bgra[i + 3] = 255; }
                for (int y = 0; y < f.h; y++) System.Runtime.InteropServices.Marshal.Copy(bgra, y * f.w * 4, bits.Scan0 + y * bits.Stride, f.w * 4);
                bmp.UnlockBits(bits);
                bmp.Save(Path.Combine(TestDir, "clear_picture.png"), ImageFormat.Png);
                Note($"clear picture {f.w}x{f.h} rows {f.rows:F3}");
            }
            await Preview("page_clear.png");
            await Shot("screen_clear_excluded.png");

            // can Windows hand over one process's sound here? (tried on this very process; there is no Spotify on the build machine)
            try
            {
                using var rec = await new NAudio.Wave.WasapiRecorderBuilder().WithProcessLoopback((uint)Environment.ProcessId, NAudio.CoreAudioApi.ProcessLoopbackMode.IncludeTargetProcessTree)
                    .WithFormat(NAudio.Wave.WaveFormat.CreateIeeeFloatWaveFormat(48000, 2)).BuildAsync();
                rec.StartRecording(); await Task.Delay(300); rec.StopRecording();
                Note("process audio capture: available, format " + rec.WaveFormat);
            }
            catch (Exception e) { Note("process audio capture: " + e.GetType().Name + " " + e.Message); }
            Note($"spotify: state {spotify.State} source '{spotify.Source}'  audio: {audio.Status}");
            Note("done");
        }
        catch (Exception e) { Note("SELFTEST FAILED: " + e); }
        finally { Close(); }
    }

    async Task Preview(string name)
    {
        try
        {
            using var fs = File.Create(Path.Combine(TestDir, name));
            await core!.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
        }
        catch { }
    }

    /// A real screenshot of the area around the widget (what a person would see).
    async Task Shot(string name)
    {
        await Task.Delay(120);
        try
        {
            var r = new Rectangle(Left - 40, Top - 40, Width + 80, Height + 80);
            using var bmp = new Bitmap(r.Width, r.Height);
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Location, Point.Empty, r.Size);
            bmp.Save(Path.Combine(TestDir, name), ImageFormat.Png);
        }
        catch { }
    }
}
