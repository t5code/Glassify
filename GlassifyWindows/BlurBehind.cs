using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Glassify;

/// What softens the desktop showing through the slightly see-through glass (Drift and Vinyl let about 16% through).
/// In the design this is `backdrop-filter: blur(22px) saturate(1.5)`; a web page cannot blur the desktop, so a second,
/// empty window does it: it has exactly the outline of the glass, sits directly behind the widget, lets every click
/// through, and asks Windows to blur whatever is behind it.
sealed class BlurBehind : Form
{
    [StructLayout(LayoutKind.Sequential)] struct AccentPolicy { public int State, Flags; public uint Gradient; public int Animation; }
    [StructLayout(LayoutKind.Sequential)] struct CompositionData { public int Attribute; public IntPtr Data; public int Size; }
    [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref CompositionData data);

    Rectangle shape; int radius = -1;
    /// Test switch: also apply the see-through recipe to this window.
    public bool SeeThroughToo = true;

    public BlurBehind()
    {
        Text = "Glassify backdrop";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.Black;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.Style = Native.WS_POPUP;
            cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST | Native.WS_EX_NOACTIVATE | Native.WS_EX_TRANSPARENT;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Apply(true);
    }

    /// Switches the blur on (or off) for this window.
    public void Apply(bool on)
    {
        if (!IsHandleCreated) return;
        if (SeeThroughToo) Native.MakeSeeThrough(Handle);
        var policy = new AccentPolicy { State = on ? 3 : 0 };      // 3 = blur what is behind the window
        int size = Marshal.SizeOf<AccentPolicy>();
        var mem = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(policy, mem, false);
            var data = new CompositionData { Attribute = 19, Data = mem, Size = size };
            SetWindowCompositionAttribute(Handle, ref data);
        }
        catch { }
        finally { Marshal.FreeHGlobal(mem); }
    }

    /// Follows the glass: `glass` is its rectangle on screen, `r` its corner radius, both in screen pixels.
    public void Follow(Rectangle glass, int r)
    {
        glass.Inflate(-1, -1);                 // stay just inside the glass edge
        r = Math.Max(0, Math.Min(r - 1, Math.Min(glass.Width, glass.Height) / 2));
        if (glass == shape && r == radius) return;
        bool resized = glass.Size != shape.Size || r != radius;
        shape = glass; radius = r;
        if (glass.Width < 2 || glass.Height < 2) return;
        Bounds = glass;
        if (!resized) return;
        using var path = new GraphicsPath();
        int d = Math.Max(1, r * 2), w = glass.Width, h = glass.Height;
        if (r <= 0) path.AddRectangle(new Rectangle(0, 0, w, h));
        else
        {
            path.AddArc(0, 0, d, d, 180, 90);
            path.AddArc(w - d, 0, d, d, 270, 90);
            path.AddArc(w - d, h - d, d, d, 0, 90);
            path.AddArc(0, h - d, d, d, 90, 90);
            path.CloseFigure();
        }
        Region = new Region(path);
    }
}
