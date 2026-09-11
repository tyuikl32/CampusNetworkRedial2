using System.Diagnostics;
using System.Text.RegularExpressions;

namespace CampusNetworkRedial;

internal static partial class DialNameResolver
{
    private const string DefaultName = "宽带连接";

    public static string Resolve(string? requestedName)
    {
        if (!string.IsNullOrWhiteSpace(requestedName))
        {
            return requestedName.Trim();
        }

        var names = ReadPhoneBookNames().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (names.Length == 1)
        {
            return names[0];
        }

        if (names.Length > 1)
        {
            var active = TryReadActiveConnections();
            var match = names.FirstOrDefault(name => active.Contains(name, StringComparison.OrdinalIgnoreCase));
            if (match is not null)
            {
                return match;
            }

            throw new InvalidOperationException($"检测到多个拨号连接（{string.Join(", ", names)}），请使用 --dial-name 指定一个。");
        }

        return DefaultName;
    }

    private static IEnumerable<string> ReadPhoneBookNames()
    {
        var paths = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Microsoft", "Network", "Connections", "Pbk", "rasphone.pbk"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Network", "Connections", "Pbk", "rasphone.pbk")
        };

        foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(path)) continue;
            foreach (var line in File.ReadLines(path))
            {
                var match = SectionNameRegex().Match(line);
                if (match.Success) yield return match.Groups[1].Value.Trim();
            }
        }
    }

    private static string TryReadActiveConnections()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "rasdial.exe",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            });
            return process?.StandardOutput.ReadToEnd() ?? string.Empty;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return string.Empty;
        }
    }

    [GeneratedRegex(@"^\s*\[(.+?)\]\s*$", RegexOptions.CultureInvariant)]
    private static partial Regex SectionNameRegex();
}
