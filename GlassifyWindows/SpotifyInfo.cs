using Windows.Media.Control;

namespace Glassify;

enum PlayState { NotRunning, Unknown, Playing, Paused }

/// Reads what the Spotify desktop app is playing from Windows' own media controls (the same source as the volume
/// flyout and the lock screen). No login, no developer account: title, artist, cover and play/pause all come from there.
sealed class SpotifyInfo
{
    public event Action<PlayState>? StateChanged;
    /// title, artist, cover as a data: URL (null when the track has none)
    public event Action<string, string, string?>? TrackChanged;

    GlobalSystemMediaTransportControlsSessionManager? manager;
    GlobalSystemMediaTransportControlsSession? session;
    string trackKey = "\u0001";
    int generation;

    public PlayState State { get; private set; } = PlayState.NotRunning;
    public (string title, string artist, string? cover)? Last { get; private set; }
    public string Source => session?.SourceAppUserModelId ?? "";

    public async Task StartAsync()
    {
        try
        {
            manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            manager.SessionsChanged += (_, _) => Pick();
            Pick();
        }
        catch { Publish(SpotifyAudio.SpotifyPid() != 0 ? PlayState.Unknown : PlayState.NotRunning); }
    }

    /// Spotify can be open without Windows listing it yet; the window calls this now and then.
    public void Poll() { if (manager != null && session == null) Pick(); else if (manager == null) Publish(SpotifyAudio.SpotifyPid() != 0 ? PlayState.Unknown : PlayState.NotRunning); }

    void Pick()
    {
        if (manager == null) return;
        GlobalSystemMediaTransportControlsSession? found = null;
        try { found = manager.GetSessions().FirstOrDefault(s => s.SourceAppUserModelId.Contains("Spotify", StringComparison.OrdinalIgnoreCase)); } catch { }
        if (found?.SourceAppUserModelId == session?.SourceAppUserModelId && found != null) { Refresh(); return; }
        session = found;
        if (found == null)
        {
            generation++; trackKey = "\u0001"; Last = null;
            Publish(SpotifyAudio.SpotifyPid() != 0 ? PlayState.Unknown : PlayState.NotRunning);
            TrackChanged?.Invoke("", "", null);
            return;
        }
        found.MediaPropertiesChanged += (s, _) => { if (s == session) Refresh(); };
        found.PlaybackInfoChanged += (s, _) => { if (s == session) Refresh(); };
        Refresh();
    }

    async void Refresh()
    {
        var s = session;
        if (s == null) return;
        int gen = ++generation;
        try
        {
            var status = s.GetPlaybackInfo()?.PlaybackStatus;
            Publish(status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing ? PlayState.Playing : PlayState.Paused);
            var props = await s.TryGetMediaPropertiesAsync();
            if (gen != generation || props == null) return;
            string title = props.Title ?? "", artist = props.Artist ?? "";
            string key = title + "\u001f" + artist + "\u001f" + (props.AlbumTitle ?? "");
            if (key == trackKey && Last?.cover != null) return;
            string? cover = null;
            if (props.Thumbnail != null)
            {
                try
                {
                    using var stream = await props.Thumbnail.OpenReadAsync();
                    if (stream.Size > 64 && stream.Size < 8_000_000)
                    {
                        using var net = stream.AsStreamForRead();
                        using var mem = new MemoryStream();
                        await net.CopyToAsync(mem);
                        string type = string.IsNullOrEmpty(stream.ContentType) || !stream.ContentType.StartsWith("image/") ? "image/jpeg" : stream.ContentType;
                        cover = "data:" + type + ";base64," + Convert.ToBase64String(mem.ToArray());
                    }
                }
                catch { }
            }
            if (gen != generation) return;
            if (key == trackKey && cover == null) return;      // same track, and still no cover: nothing new
            trackKey = key;
            Last = (title, artist, cover);
            TrackChanged?.Invoke(title, artist, cover);
        }
        catch { }
    }

    void Publish(PlayState s)
    {
        State = s;
        StateChanged?.Invoke(s);
    }
}
