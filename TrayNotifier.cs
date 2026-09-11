using System.Drawing;
using System.Windows.Forms;

namespace CampusNetworkRedial;

internal enum TrayNotificationKind
{
    Success,
    Failure,
    Stopped
}

internal static class TrayNotifier
{
    private const int BalloonDurationMilliseconds = 5_000;
    private const int IconLifetimeMilliseconds = 6_000;

    public static async Task TryShowAsync(
        TrayNotificationKind kind,
        string message,
        TextWriter errorWriter)
    {
        if (!OperatingSystem.IsWindows()) return;

        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() => ShowOnStaThread(kind, message, completion))
        {
            IsBackground = true,
            Name = "CampusNetworkRedial.TrayNotification"
        };
        thread.SetApartmentState(ApartmentState.STA);

        try
        {
            thread.Start();
            await completion.Task;
        }
        catch (Exception ex)
        {
            // Notification failures must never replace the program's real exit result.
            await errorWriter.WriteLineAsync($"托盘通知失败：{ex.Message}");
        }
    }

    private static void ShowOnStaThread(
        TrayNotificationKind kind,
        string message,
        TaskCompletionSource completion)
    {
        try
        {
            var (title, balloonIcon, trayIcon) = kind switch
            {
                TrayNotificationKind.Success => ("校园网拨号成功", ToolTipIcon.Info, SystemIcons.Information),
                TrayNotificationKind.Failure => ("校园网拨号失败", ToolTipIcon.Error, SystemIcons.Error),
                _ => ("校园网拨号已停止", ToolTipIcon.Warning, SystemIcons.Warning)
            };

            using var notifyIcon = new NotifyIcon
            {
                Icon = trayIcon,
                Text = "校园网自动拨号",
                Visible = true
            };
            using var timer = new System.Windows.Forms.Timer
            {
                Interval = IconLifetimeMilliseconds
            };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                Application.ExitThread();
            };

            notifyIcon.ShowBalloonTip(BalloonDurationMilliseconds, title, message, balloonIcon);
            timer.Start();
            Application.Run();
            notifyIcon.Visible = false;
            completion.TrySetResult();
        }
        catch (Exception ex)
        {
            completion.TrySetException(ex);
        }
    }
}
