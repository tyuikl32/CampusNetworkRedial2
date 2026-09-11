namespace CampusNetworkRedial;

internal static class Program
{
    private const int Success = 0;
    private const int Failure = 1;
    private const int InvalidArguments = 2;

    public static async Task<int> Main(string[] args)
    {
        CliParseResult parsed;
        try
        {
            parsed = CliParser.Parse(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine($"参数错误：{ex.Message}");
            Console.Error.WriteLine(CliParser.Usage);
            return await FinishAsync(InvalidArguments, TrayNotificationKind.Failure, $"参数错误：{ex.Message}");
        }

        if (parsed.ShowHelp)
        {
            Console.WriteLine(CliParser.Usage);
            return await FinishAsync(Success, TrayNotificationKind.Success, "帮助信息已显示。");
        }

        if (!OperatingSystem.IsWindows() && !parsed.Options!.TestOnly)
        {
            Console.Error.WriteLine("此程序的 rasdial 连接管理功能仅支持 Windows。");
            return await FinishAsync(Failure, TrayNotificationKind.Failure, "当前系统不支持 Windows 拨号管理。");
        }

        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
            Console.WriteLine("正在停止……");
        };

        try
        {
            var options = parsed.Options!;
            Console.WriteLine("本软件仅供交流和学习，不作任何破解限制使用，请自觉在下载24小时以内删除！");

            using var http = new HttpClient(new SocketsHttpHandler
            {
                AllowAutoRedirect = true,
                AutomaticDecompression = System.Net.DecompressionMethods.All,
                UseProxy = true
            });
            http.DefaultRequestHeaders.UserAgent.ParseAdd("CampusNetworkRedial/1.0");

            var probe = new ProbeClient(http, options.ProbeUris);
            var bandwidthProbe = new BandwidthProbeClient(http, options.BandwidthTestUri);
            var coordinator = new RedialCoordinator(options, probe, bandwidthProbe, new RasdialClient(), Console.Out);

            if (options.TestOnly)
            {
                var passed = await coordinator.RunTestOnlyAsync(cancellation.Token);
                return await FinishAsync(
                    passed ? Success : Failure,
                    passed ? TrayNotificationKind.Success : TrayNotificationKind.Failure,
                    passed ? "当前连接测试通过。" : "当前连接测试失败。");
            }

            var dialName = DialNameResolver.Resolve(options.DialName);
            Console.WriteLine($"使用拨号连接：{dialName}");
            var succeeded = await coordinator.RunAsync(dialName, cancellation.Token);
            return await FinishAsync(
                succeeded ? Success : Failure,
                succeeded ? TrayNotificationKind.Success : TrayNotificationKind.Failure,
                succeeded
                    ? "已找到满足所选模式条件的校园网连接。"
                    : $"已尝试 {options.MaxAttempts} 次，仍未找到满足条件的连接。");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return await FinishAsync(Success, TrayNotificationKind.Stopped, "任务已由用户取消。");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"运行失败：{ex.Message}");
            return await FinishAsync(Failure, TrayNotificationKind.Failure, $"运行失败：{ex.Message}");
        }
    }

    private static async Task<int> FinishAsync(int exitCode, TrayNotificationKind kind, string message)
    {
        await TrayNotifier.TryShowAsync(kind, message, Console.Error);
        return exitCode;
    }
}

internal sealed record CliParseResult(AppOptions? Options, bool ShowHelp);

internal static class CliParser
{
    public const string Usage = """
用法：CampusNetworkRedial [选项]

  --dial-name <名称>                 Windows 拨号连接名；省略时从 rasphone.pbk 自动识别
  --test-only                        只测试当前连接，不执行重拨
  --normal-mode                      仅普通模式；不指定模式时默认两者兼具
  -200MbpsMode                      仅 200 Mbps 模式（也接受 --200MbpsMode）
  --timeout-seconds <1..60>          单次 HTTP 探针超时（默认 4）
  --probe-count <1..10>              每次普通连通性检查的探针次数（默认 3）
  --settle-seconds <0..300>          重连后等待时间（默认 3）
  --confirm-interval-seconds <0..300> 三轮测试第 1、2 轮之间的等待（默认 12）
  --third-interval-seconds <0..600>  三轮测试第 2、3 轮之间的等待（默认 30）
  --pause-seconds <1..600>           失败重试之间的等待（默认 2）
  --max-attempts <1..99>             最大重连次数（默认 99）
  --probe-uri <https://...>          普通模式探针地址，可重复传入
  --help                             显示帮助

未指定 --normal-mode 或 -200MbpsMode 时默认两者兼具并行测试；两个参数同时指定时也为两者兼具。
自动模式不读取控制台输入，成功后直接退出；Ctrl+C 可取消。

示例：
  CampusNetworkRedial --dial-name "校园网"                    # 默认两者兼具
  CampusNetworkRedial --normal-mode --dial-name "校园网"       # 仅普通模式
  CampusNetworkRedial -200MbpsMode --dial-name "校园网"        # 仅 200 Mbps 模式
  CampusNetworkRedial --test-only --normal-mode                # 当前连接三轮普通测试

请只对自己或明确获授权的网络和探针地址使用本工具。
""";

    public static CliParseResult Parse(IReadOnlyList<string> args)
    {
        var options = new AppOptions();
        var modeSpecified = false;
        for (var index = 0; index < args.Count; index++)
        {
            var argument = args[index];
            if (argument is "--help" or "-h" or "/?")
            {
                return new CliParseResult(null, true);
            }

            switch (argument)
            {
                case "--test-only":
                    options.TestOnly = true;
                    break;
                case "--normal-mode":
                    if (!modeSpecified)
                    {
                        options.Modes = RunModes.None;
                        modeSpecified = true;
                    }

                    options.Modes |= RunModes.Normal;
                    break;
                case "-200MbpsMode":
                case "--200MbpsMode":
                    if (!modeSpecified)
                    {
                        options.Modes = RunModes.None;
                        modeSpecified = true;
                    }

                    options.Modes |= RunModes.Mbps200;
                    break;
                case "--dial-name":
                    options.DialName = RequireValue(args, ref index, argument);
                    break;
                case "--timeout-seconds":
                    options.TimeoutSeconds = ReadInt(args, ref index, argument, 1, 60);
                    break;
                case "--probe-count":
                    options.ProbeCount = ReadInt(args, ref index, argument, 1, 10);
                    break;
                case "--settle-seconds":
                    options.SettleSeconds = ReadInt(args, ref index, argument, 0, 300);
                    break;
                case "--confirm-interval-seconds":
                    options.ConfirmIntervalSeconds = ReadInt(args, ref index, argument, 0, 300);
                    break;
                case "--third-interval-seconds":
                    options.ThirdIntervalSeconds = ReadInt(args, ref index, argument, 0, 600);
                    break;
                case "--pause-seconds":
                    options.PauseSeconds = ReadInt(args, ref index, argument, 1, 600);
                    break;
                case "--max-attempts":
                    options.MaxAttempts = ReadInt(args, ref index, argument, 1, 99);
                    break;
                case "--probe-uri":
                    var uriText = RequireValue(args, ref index, argument);
                    if (!Uri.TryCreate(uriText, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
                    {
                        throw new ArgumentException($"{argument} 必须是 http 或 https URL。");
                    }

                    if (!options.HasCustomProbeUris)
                    {
                        options.SetProbeUris(Array.Empty<Uri>());
                        options.HasCustomProbeUris = true;
                    }

                    options.ProbeUris.Add(uri);
                    break;
                default:
                    throw new ArgumentException($"不认识的选项：{argument}");
            }
        }

        return new CliParseResult(options, false);
    }

    private static string RequireValue(IReadOnlyList<string> args, ref int index, string option)
    {
        if (++index >= args.Count || string.IsNullOrWhiteSpace(args[index]))
        {
            throw new ArgumentException($"{option} 需要一个值。");
        }

        return args[index];
    }

    private static int ReadInt(IReadOnlyList<string> args, ref int index, string option, int minimum, int maximum)
    {
        var value = RequireValue(args, ref index, option);
        if (!int.TryParse(value, out var parsed) || parsed < minimum || parsed > maximum)
        {
            throw new ArgumentException($"{option} 必须是 {minimum} 到 {maximum} 之间的整数。");
        }

        return parsed;
    }
}
