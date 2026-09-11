namespace CampusNetworkRedial;

internal sealed class RedialCoordinator
{
    private readonly AppOptions _options;
    private readonly IProbeClient _probeClient;
    private readonly IBandwidthProbeClient _bandwidthProbeClient;
    private readonly IRasdialClient _rasdial;
    private readonly TextWriter _writer;

    public RedialCoordinator(
        AppOptions options,
        IProbeClient probeClient,
        IBandwidthProbeClient bandwidthProbeClient,
        IRasdialClient rasdial,
        TextWriter writer)
    {
        _options = options;
        _probeClient = probeClient;
        _bandwidthProbeClient = bandwidthProbeClient;
        _rasdial = rasdial;
        _writer = writer;
    }

    public async Task<bool> RunAsync(string dialName, CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync($"运行模式：{DescribeModes()}。");

        // The existing connection gets the first chance; a successful connection is
        // never needlessly interrupted just to start the search.
        await _writer.WriteLineAsync("先测试当前连接，不主动重拨。");
        if (await TestEnabledModesAsync(fullNormalConfirmation: false, cancellationToken))
        {
            await WriteSuccessAsync("当前连接已满足启用的测试条件。");
            return true;
        }

        return await RedialUntilModesPassAsync(dialName, cancellationToken);
    }

    public async Task<bool> RunTestOnlyAsync(CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync($"只测试当前连接，模式：{DescribeModes()}。");
        return await TestEnabledModesAsync(fullNormalConfirmation: _options.NormalMode, cancellationToken);
    }

    /// <summary>Runs the three-round ordinary confirmation used by --test-only.</summary>
    public Task<bool> TestCurrentExitAsync(CancellationToken cancellationToken) =>
        TestNormalThreeRoundsAsync(cancellationToken);

    /// <summary>Runs one ordinary probe batch used by automatic mode.</summary>
    public Task<bool> TestCurrentExitOnceAsync(CancellationToken cancellationToken) =>
        TestNormalOnceAsync(cancellationToken);

    private async Task<bool> RedialUntilModesPassAsync(string dialName, CancellationToken cancellationToken)
    {
        for (var attempt = 1; attempt <= _options.MaxAttempts; attempt++)
        {
            await _writer.WriteLineAsync($"\n[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] 第 {attempt}/{_options.MaxAttempts} 次重拨尝试");

            var disconnected = await _rasdial.DisconnectAsync(dialName, cancellationToken);
            await WriteRasdialOutputAsync(disconnected);
            await DelayWithCountdownAsync(2, cancellationToken);

            var connected = await _rasdial.ConnectAsync(dialName, cancellationToken);
            await WriteRasdialOutputAsync(connected);
            if (connected.ExitCode != 0)
            {
                await _writer.WriteLineAsync("拨号失败。");
                if (attempt < _options.MaxAttempts) await DelayWithCountdownAsync(_options.PauseSeconds, cancellationToken);
                continue;
            }

            await _writer.WriteLineAsync("拨号成功，等待连接稳定。");
            await DelayWithCountdownAsync(_options.SettleSeconds, cancellationToken);
            if (await TestEnabledModesAsync(fullNormalConfirmation: false, cancellationToken))
            {
                await WriteSuccessAsync("连接已满足启用的测试条件，停止重拨。");
                return true;
            }

            await _writer.WriteLineAsync("本次连接未满足启用的测试条件。");
            if (attempt < _options.MaxAttempts) await DelayWithCountdownAsync(_options.PauseSeconds, cancellationToken);
        }

        await _writer.WriteLineAsync($"已达到最大重拨次数 {_options.MaxAttempts}，仍未找到满足条件的连接。");
        return false;
    }

    private async Task<bool> TestEnabledModesAsync(bool fullNormalConfirmation, CancellationToken cancellationToken)
    {
        if (_options.Modes == RunModes.Both)
        {
            return await TestBothModesConcurrentlyAsync(cancellationToken);
        }

        if (_options.Mbps200Mode)
        {
            return await TestBandwidthOnlyAsync(cancellationToken);
        }

        if (_options.NormalMode)
        {
            return fullNormalConfirmation
                ? await TestNormalThreeRoundsAsync(cancellationToken)
                : await TestNormalOnceAsync(cancellationToken);
        }

        return true;
    }

    private async Task<bool> TestBothModesConcurrentlyAsync(CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync("并行开始 200 Mbps 测速和普通连通性三轮确认……");
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var bandwidthTask = _bandwidthProbeClient.MeasureDownloadAsync(
            TimeSpan.FromSeconds(_options.BandwidthTestSeconds), linkedCancellation.Token);
        var normalTask = TestNormalThreeRoundsAsync(linkedCancellation.Token);
        var firstCompleted = await Task.WhenAny(bandwidthTask, normalTask);

        if (firstCompleted == bandwidthTask)
        {
            var result = await bandwidthTask;
            var bandwidthPassed = await ReportBandwidthResultAsync(result);
            if (!bandwidthPassed)
            {
                linkedCancellation.Cancel();
                await IgnoreInternalCancellationAsync(normalTask);
                return false;
            }

            return await normalTask;
        }

        var normalPassed = await normalTask;
        if (!normalPassed)
        {
            linkedCancellation.Cancel();
            await IgnoreInternalCancellationAsync(bandwidthTask);
            return false;
        }

        var finalBandwidthResult = await bandwidthTask;
        return await ReportBandwidthResultAsync(finalBandwidthResult);
    }

    private async Task<bool> ReportBandwidthResultAsync(BandwidthResult result)
    {
        await _writer.WriteLineAsync(
            $"测速结果：{result.MegabitsPerSecond:0.##} Mbps，耗时 {result.ElapsedSeconds:0.##} 秒（{result.Note}）。");
        var passed = result.Succeeded && result.MegabitsPerSecond > _options.BandwidthThresholdMbps;
        await _writer.WriteLineAsync(
            passed
                ? "200 Mbps 测试通过。"
                : $"200 Mbps 测试未通过（需要超过 {_options.BandwidthThresholdMbps:0.#} Mbps）。");
        return passed;
    }

    private static async Task IgnoreInternalCancellationAsync(Task task)
    {
        try
        {
            await task;
        }
        catch (OperationCanceledException)
        {
            // The sibling test was intentionally cancelled after the other test failed.
        }
    }

    private async Task<bool> TestBandwidthOnlyAsync(CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync($"开始 200 Mbps 下载测速（{_options.BandwidthTestSeconds} 秒，阈值 > {_options.BandwidthThresholdMbps:0.#} Mbps）……");
        var result = await _bandwidthProbeClient.MeasureDownloadAsync(
            TimeSpan.FromSeconds(_options.BandwidthTestSeconds), cancellationToken);
        await _writer.WriteLineAsync(
            $"测速结果：{result.MegabitsPerSecond:0.##} Mbps，耗时 {result.ElapsedSeconds:0.##} 秒（{result.Note}）。");
        var passed = result.Succeeded && result.MegabitsPerSecond > _options.BandwidthThresholdMbps;
        await _writer.WriteLineAsync(
            passed
                ? "200 Mbps 测试通过。"
                : $"200 Mbps 测试未通过（需要超过 {_options.BandwidthThresholdMbps:0.#} Mbps）。");
        return passed;
    }

    private async Task<bool> TestNormalOnceAsync(CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync("开始一次普通连通性检查……");
        var results = await _probeClient.ProbeAsync(
            _options.ProbeCount,
            TimeSpan.FromSeconds(_options.TimeoutSeconds),
            cancellationToken);
        await PrintResultsAsync(results);
        var passed = results.All(result => result.Ok);
        await _writer.WriteLineAsync($"普通连通性检查：{results.Count(result => result.Ok)}/{results.Count}，{(passed ? "通过" : "失败")}。");
        return passed;
    }

    private async Task<bool> TestNormalThreeRoundsAsync(CancellationToken cancellationToken)
    {
        for (var round = 1; round <= 3; round++)
        {
            await _writer.WriteLineAsync($"普通连通性三轮确认：第 {round}/3 轮……");
            var results = await _probeClient.ProbeAsync(
                _options.ProbeCount,
                TimeSpan.FromSeconds(_options.TimeoutSeconds),
                cancellationToken);
            await PrintResultsAsync(results);

            var passed = results.All(result => result.Ok);
            await _writer.WriteLineAsync($"本轮通过 {results.Count(result => result.Ok)}/{results.Count}，{(passed ? "通过" : "失败")}。");
            if (!passed) return false;

            if (round == 1) await DelayWithCountdownAsync(_options.ConfirmIntervalSeconds, cancellationToken);
            else if (round == 2) await DelayWithCountdownAsync(_options.ThirdIntervalSeconds, cancellationToken);
        }

        return true;
    }

    private string DescribeModes() => _options.Modes switch
    {
        RunModes.Normal => "仅普通模式",
        RunModes.Mbps200 => "仅 200 Mbps 模式",
        RunModes.Both => "普通 + 200 Mbps 模式（并行测试）",
        _ => "无有效模式"
    };

    private async Task DelayWithCountdownAsync(int seconds, CancellationToken cancellationToken)
    {
        if (seconds <= 0) return;

        var previousLength = 0;
        for (var remaining = seconds; remaining > 0; remaining--)
        {
            var text = $"等待 {remaining} 秒...";
            var padding = new string(' ', Math.Max(0, previousLength - text.Length));
            await _writer.WriteAsync($"\r{text}{padding}");
            await _writer.FlushAsync(cancellationToken);
            previousLength = text.Length;
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }

        await _writer.WriteLineAsync();
    }

    private async Task WriteRasdialOutputAsync(RasdialResult result)
    {
        if (!string.IsNullOrWhiteSpace(result.Output)) await _writer.WriteLineAsync(result.Output);
    }

    private async Task WriteSuccessAsync(string message)
    {
        Console.ForegroundColor = ConsoleColor.Green;
        await _writer.WriteLineAsync(message);
        Console.ResetColor();
    }

    private async Task PrintResultsAsync(IReadOnlyList<ProbeResult> results)
    {
        foreach (var result in results)
        {
            var status = result.Ok ? "通过" : "失败";
            await _writer.WriteLineAsync($"  {result.Try}: {status}, {result.ElapsedMilliseconds} ms, {result.Uri}, {result.Note}");
        }
    }
}
