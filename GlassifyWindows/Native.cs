using System.Runtime.InteropServices;

namespace Glassify;

/// The handful of Windows calls the widget needs that .NET does not wrap.
static class Native
{
    public const int WS_POPUP = unchecked((int)0x80000000);
    public const int WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    public const int GWL_EXSTYLE = -20;
    public const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3, WM_DPICHANGED = 0x02E0, WM_DISPLAYCHANGE = 0x7E;
    public const uint SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOZORDER = 4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;
    public const uint WDA_NONE = 0, WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const int VK_LBUTTON = 1;

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DWM_BLURBEHIND { public uint dwFlags; public int fEnable; public IntPtr hRgnBlur; public int fTransitionOnMaximized; }

    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint colorKey, byte alpha, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmEnableBlurBehindWindow(IntPtr hwnd, ref DWM_BLURBEHIND bb);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);

    /// Makes a borderless window see-through wherever nothing is drawn (the same recipe the Tauri and winit toolkits use):
    /// "blur behind" is switched on for an empty region, which leaves no blur but makes Windows honour per-pixel transparency.
    public static void MakeSeeThrough(IntPtr hwnd)
    {
        var region = CreateRectRgn(0, 0, -1, -1);
        var bb = new DWM_BLURBEHIND { dwFlags = 1 | 2, fEnable = 1, hRgnBlur = region };
        DwmEnableBlurBehindWindow(hwnd, ref bb);
        DeleteObject(region);
    }

    public static void SetExStyle(IntPtr hwnd, int flags, bool on)
    {
        long cur = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        long next = on ? cur | (uint)flags : cur & ~(long)(uint)flags;
        if (next != cur) SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(next));
    }
}
