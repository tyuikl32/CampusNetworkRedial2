namespace CampusNetworkRedial;

[Flags]
internal enum RunModes
{
    None = 0,
    Normal = 1,
    Mbps200 = 2,
    Both = Normal | Mbps200
}

internal sealed class AppOptions
{
    public string? DialName { get; set; }
    public bool TestOnly { get; set; }
    public RunModes Modes { get; set; } = RunModes.Both;
    public bool NormalMode => Modes.HasFlag(RunModes.Normal);
    public bool Mbps200Mode => Modes.HasFlag(RunModes.Mbps200);
    public int BandwidthTestSeconds { get; set; } = 5;
    public double BandwidthThresholdMbps { get; set; } = 150;
    public Uri BandwidthTestUri { get; set; } = new("https://test.xidian.edu.cn/backend/garbage.php");
    public int TimeoutSeconds { get; set; } = 4;
    public int ProbeCount { get; set; } = 3;
    public int SettleSeconds { get; set; } = 3;
    public int ConfirmIntervalSeconds { get; set; } = 12;
    public int ThirdIntervalSeconds { get; set; } = 30;
    public int PauseSeconds { get; set; } = 2;
    public int MaxAttempts { get; set; } = 99;
    public bool HasCustomProbeUris { get; set; }

    public List<Uri> ProbeUris { get; } =
    [
        new Uri("http://abvolcapi.douyucdn.cn/"),
        new Uri("http://apiv2.douyucdn.cn/")
    ];

    public void SetProbeUris(IEnumerable<Uri> uris)
    {
        ProbeUris.Clear();
        ProbeUris.AddRange(uris);
    }
}
