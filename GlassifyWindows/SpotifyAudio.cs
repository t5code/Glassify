using System.Diagnostics;

namespace Glassify;

/// Listens to the sound the music app itself produces (Spotify or Apple Music).
/// Windows 10 (2004) and later can hand an app the audio of one process and its children ("process loopback"), so nothing
/// else playing on the PC is heard and it works the same on speakers and headphones. If that is not available, it falls back
/// to everything the PC is playing. The capturing itself is done by the NAudio library.
sealed class SpotifyAudio : IDisposable
{
    readonly object gate = new();
    readonly float[] ring = new float[8192];
    int head;
    long lastWrite;
    Thread? thread;
    volatile bool run;
    int listeningTo;

    public double SampleRate { get; private set; } = 44100;
    public string Status { get; private set; } = "off";
    public long Packets { get; private set; }
    public float Peak { get; private set; }
    public bool Running => run;

    /// The main process of the music app named by `source` (an entry from Windows' media controls; empty = whichever is open).
    /// Its windows, audio and helper processes all hang off it. 0 when it is not running.
    public static int PlayerPid(string source)
    {
        string[] names = source.Contains("AppleMusic", StringComparison.OrdinalIgnoreCase) ? new[] { "AppleMusic" }
            : source.Contains("iTunes", StringComparison.OrdinalIgnoreCase) ? new[] { "iTunes" }
            : source.Contains("Spotify", StringComparison.OrdinalIgnoreCase) ? new[] { "Spotify" }
            : new[] { "Spotify", "AppleMusic", "iTunes" };
        foreach (var name in names)
        {
            int best = 0; DateTime bestStart = DateTime.MaxValue;
            foreach (var p in Process.GetProcessesByName(name))
            {
                try { if (p.StartTime < bestStart) { bestStart = p.StartTime; best = p.Id; } } catch { if (best == 0) best = p.Id; }
                finally { p.Dispose(); }
            }
            if (best != 0) return best;
        }
        return 0;
    }

    public static bool AnyPlayerRunning() => PlayerPid("") != 0;

    /// `source` says which music app to listen to (see PlayerPid).
    public void SetWanted(bool on, string source = "")
    {
        int pid = on ? PlayerPid(source) : 0;
        if (on && pid != 0 && run && pid == listeningTo) return;
        Stop();
        if (!on || pid == 0) return;
        listeningTo = pid;
        run = true;
        thread = new Thread(() => Capture(pid)) { IsBackground = true, Name = "Glassify audio" };
        thread.Start();
    }

    public void Stop()
    {
        run = false;
        var t = thread; thread = null;
        if (t != null && t != Thread.CurrentThread) t.Join(1500);
        lock (gate) { Array.Clear(ring); lastWrite = 0; }
        Status = "off";
    }

    public void Dispose() => Stop();

    /// The most recent `count` mono samples, oldest first. False when no fresh audio has arrived lately.
    public bool Latest(float[] dst, int count)
    {
        lock (gate)
        {
            if (!run || Stopwatch.GetElapsedTime(lastWrite).TotalSeconds > 0.25 || lastWrite == 0) return false;
            int n = ring.Length, i = ((head - count) % n + n) % n;
            for (int k = 0; k < count; k++) { dst[k] = ring[i]; if (++i == n) i = 0; }
            return true;
        }
    }

    void Capture(int pid)
    {
        NAudio.Wave.WasapiRecorder? recorder = null;
        try
        {
            try
            {
                // the music app and everything it started, and nothing else (Windows 10 version 2004 or later)
                recorder = new NAudio.Wave.WasapiRecorderBuilder()
                    .WithProcessLoopback((uint)pid, NAudio.CoreAudioApi.ProcessLoopbackMode.IncludeTargetProcessTree)
                    .WithFormat(NAudio.Wave.WaveFormat.CreateIeeeFloatWaveFormat(48000, 2))
                    .BuildAsync().GetAwaiter().GetResult();
                Listen(recorder);
                Status = "listening to the music app only";
            }
            catch (Exception e)
            {
                try { recorder?.Dispose(); } catch { }
                // older Windows: everything the PC is playing
                recorder = new NAudio.Wave.WasapiRecorderBuilder().WithLoopbackCapture().Build();
                Listen(recorder);
                Status = "listening to all PC sound (one-app capture not available: " + e.Message + ")";
            }
            while (run) Thread.Sleep(100);
        }
        catch (Exception e) { Status = "no audio capture: " + e.Message; }
        finally
        {
            try { recorder?.StopRecording(); } catch { }
            try { recorder?.Dispose(); } catch { }
        }
    }

    /// Starts a recorder and copies whatever it delivers, mixed down to mono, into the ring.
    void Listen(NAudio.Wave.WasapiRecorder recorder)
    {
        var wf = recorder.WaveFormat;
        SampleRate = wf.SampleRate;
        int ch = Math.Max(1, wf.Channels), bps = Math.Max(1, wf.BitsPerSample / 8);
        bool isFloat = bps == 4 && wf.Encoding != NAudio.Wave.WaveFormatEncoding.Pcm;
        recorder.DataAvailable += (buffer, flags, _, _) =>
        {
            bool silent = (Convert.ToInt32(flags) & 2) != 0;
            int frames = buffer.Length / (bps * ch);
            float peak = 0;
            lock (gate)
            {
                for (int i = 0; i < frames; i++)
                {
                    float v = 0;
                    if (!silent)
                    {
                        for (int c = 0; c < ch; c++)
                        {
                            var sample = buffer.Slice((i * ch + c) * bps, bps);
                            v += isFloat ? BitConverter.ToSingle(sample) : bps == 2 ? BitConverter.ToInt16(sample) / 32768f : bps == 4 ? BitConverter.ToInt32(sample) / 2147483648f : 0;
                        }
                        v /= ch;
                    }
                    ring[head] = v; if (++head == ring.Length) head = 0;
                    if (v > peak) peak = v; else if (-v > peak) peak = -v;
                }
                lastWrite = Stopwatch.GetTimestamp();
            }
            Peak = Math.Max(peak, Peak * 0.95f);
            Packets++;
        };
        recorder.StartRecording();
    }
}
