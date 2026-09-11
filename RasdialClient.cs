using System.Diagnostics;
using System.Text;

namespace CampusNetworkRedial;

internal sealed record RasdialResult(int ExitCode, string Output);

internal interface IRasdialClient
{
    Task<RasdialResult> DisconnectAsync(string dialName, CancellationToken cancellationToken);
    Task<RasdialResult> ConnectAsync(string dialName, CancellationToken cancellationToken);
}

internal sealed class RasdialClient : IRasdialClient
{
    public Task<RasdialResult> DisconnectAsync(string dialName, CancellationToken cancellationToken) =>
        RunAsync(new[] { dialName, "/disconnect" }, cancellationToken);

    public Task<RasdialResult> ConnectAsync(string dialName, CancellationToken cancellationToken) =>
        RunAsync(new[] { dialName }, cancellationToken);

    private static async Task<RasdialResult> RunAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "rasdial.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("无法启动 rasdial.exe。");
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            throw new InvalidOperationException("找不到 rasdial.exe，请确认运行环境是 Windows。", ex);
        }

        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
            }

            throw;
        }
        var output = await outputTask;
        var error = await errorTask;
        var combined = new StringBuilder(output);
        if (!string.IsNullOrWhiteSpace(error))
        {
            if (combined.Length > 0) combined.AppendLine();
            combined.Append(error);
        }

        return new RasdialResult(process.ExitCode, combined.ToString().Trim());
    }
}
