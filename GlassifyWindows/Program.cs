namespace Glassify;

static class Program
{
    /// Glassify for Windows: a floating glass music widget. One see-through window and a tray icon; right-click the glass to quit.
    [STAThread]
    static void Main(string[] args)
    {
        using var once = new Mutex(true, "Glassify.Widget.SingleInstance", out bool first);
        if (!first && !args.Contains("--selftest")) return;
        ApplicationConfiguration.Initialize();
        Application.Run(new WidgetForm(args));
    }
}
