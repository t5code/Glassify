namespace Glassify;

/// Turns the latest audio into one energy value per bar.
/// It reproduces what preview.html did when it played a song: a Web Audio analyser (2048-point FFT, Blackman window,
/// smoothing 0.7, -100…-30 dB mapped to 0…255) followed by the preview's own `songBands` shaping. Same maths as the Mac app.
sealed class Spectrum
{
    const int N = 2048;
    readonly float[] window = new float[N], samples = new float[N], re = new float[N], im = new float[N];
    readonly float[] smooth = new float[N / 2], bytes = new float[N / 2];
    readonly float[] cosT = new float[N / 2], sinT = new float[N / 2];
    readonly int[] rev = new int[N];
    bool wasSilent = true;

    public Spectrum()
    {
        for (int i = 0; i < N; i++)
        {
            double x = 2 * Math.PI * i / N;
            window[i] = (float)(0.42 - 0.5 * Math.Cos(x) + 0.08 * Math.Cos(2 * x));
        }
        for (int i = 0; i < N / 2; i++) { cosT[i] = (float)Math.Cos(-2 * Math.PI * i / N); sinT[i] = (float)Math.Sin(-2 * Math.PI * i / N); }
        int bits = 11;
        for (int i = 0; i < N; i++) { int r = 0; for (int b = 0; b < bits; b++) if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b); rev[i] = r; }
    }

    public void Reset() { Array.Clear(smooth); wasSilent = true; }

    /// The bar energies, or null when there is nothing new to say (silence that was already reported).
    public float[]? Bands(SpotifyAudio audio, int count)
    {
        if (!audio.Latest(samples, N)) Array.Clear(samples);
        for (int i = 0; i < N; i++) { re[rev[i]] = samples[i] * window[i]; im[rev[i]] = 0; }
        for (int size = 2; size <= N; size <<= 1)
        {
            int half = size >> 1, step = N / size;
            for (int start = 0; start < N; start += size)
                for (int k = 0, t = 0; k < half; k++, t += step)
                {
                    int a = start + k, b = a + half;
                    float wr = cosT[t], wi = sinT[t];
                    float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
                }
        }
        bool loud = false;
        for (int k = 0; k < N / 2; k++)
        {
            float mag = MathF.Sqrt(re[k] * re[k] + im[k] * im[k]) / N;
            float s = 0.7f * smooth[k] + 0.3f * mag;
            smooth[k] = float.IsFinite(s) ? s : 0;
            float db = s > 0 ? 20 * MathF.Log10(s) : float.NegativeInfinity;
            float v = MathF.Floor(255f / 70f * (db + 100));
            bytes[k] = float.IsFinite(v) ? Math.Clamp(v, 0, 255) : 0;
            if (bytes[k] > 0) loud = true;
        }
        if (!loud)
        {
            if (wasSilent) return null;
            wasSilent = true;
            return new float[count];
        }
        wasSilent = false;
        float hz = (float)audio.SampleRate / N, lo = 45, hi = 11000;
        var result = new float[count];
        for (int i = 0; i < count; i++)
        {
            float f0 = lo * MathF.Pow(hi / lo, (float)i / count), f1 = lo * MathF.Pow(hi / lo, (float)(i + 1) / count);
            int a = (int)MathF.Floor(f0 / hz), b = Math.Max(a + 1, (int)MathF.Ceiling(f1 / hz));
            float sum = 0;
            for (int k = a; k < b; k++) if (k < bytes.Length) sum += bytes[k];
            float v = sum / (b - a) / 255;
            result[i] = Math.Min(1, MathF.Pow(v, 1.7f) * (0.85f + 0.7f * i / count));
        }
        return result;
    }
}
