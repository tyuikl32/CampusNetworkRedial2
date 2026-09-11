using System.Diagnostics;
using System.Net;

namespace CampusNetworkRedial;

internal sealed record ProbeResult(int Try, Uri Uri, bool Ok, long ElapsedMilliseconds, string Note);

internal interface IProbeClient
{
    Task<IReadOnlyList<ProbeResult>> ProbeAsync(int count, TimeSpan timeout, CancellationToken cancellationToken);
}

internal sealed class ProbeClient : IProbeClient
{
    private readonly HttpClient _httpClient;
    private readonly IReadOnlyList<Uri> _uris;

    public ProbeClient(HttpClient httpClient, IReadOnlyList<Uri> uris)
    {
        _httpClient = httpClient;
        _uris = uris.Count == 0 ? throw new ArgumentException("至少需要一个探针地址。", nameof(uris)) : uris;
    }

    public async Task<IReadOnlyList<ProbeResult>> ProbeAsync(int count, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var results = new List<ProbeResult>(count);
        for (var index = 0; index < count; index++)
        {
            var uri = _uris[index % _uris.Count];
            var stopwatch = Stopwatch.StartNew();
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, uri);
                using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutSource.CancelAfter(timeout);
                using var response = await _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    timeoutSource.Token);

                // A status code still proves that the endpoint was reached. The caller is
                // measuring path reachability, so 4xx/5xx responses are retained as passes.
                results.Add(new ProbeResult(
                    index + 1,
                    uri,
                    true,
                    stopwatch.ElapsedMilliseconds,
                    $"HTTP {(int)response.StatusCode} ({response.StatusCode})"));
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                results.Add(new ProbeResult(index + 1, uri, false, stopwatch.ElapsedMilliseconds, "超时"));
            }
            catch (HttpRequestException ex)
            {
                results.Add(new ProbeResult(index + 1, uri, false, stopwatch.ElapsedMilliseconds, ex.Message));
            }
            catch (Exception ex) when (ex is InvalidOperationException or WebException)
            {
                results.Add(new ProbeResult(index + 1, uri, false, stopwatch.ElapsedMilliseconds, ex.Message));
            }
            finally
            {
                stopwatch.Stop();
            }
        }

        return results;
    }
}

internal sealed record BandwidthResult(
    bool Succeeded,
    double MegabitsPerSecond,
    long BytesRead,
    double ElapsedSeconds,
    string Note);

internal interface IBandwidthProbeClient
{
    Task<BandwidthResult> MeasureDownloadAsync(TimeSpan duration, CancellationToken cancellationToken);
}

/// <summary>Measures downstream throughput from a LibreSpeed-compatible stream.</summary>
internal sealed class BandwidthProbeClient : IBandwidthProbeClient
{
    private readonly HttpClient _httpClient;
    private readonly Uri _downloadUri;

    public BandwidthProbeClient(HttpClient httpClient, Uri downloadUri)
    {
        _httpClient = httpClient;
        _downloadUri = downloadUri;
    }

    public async Task<BandwidthResult> MeasureDownloadAsync(TimeSpan duration, CancellationToken cancellationToken)
    {
        if (duration <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(duration));

        var stopwatch = Stopwatch.StartNew();
        long bytesRead = 0;
        try
        {
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(duration);
            var workers = Enumerable.Range(0, 6).Select(_ => Task.Run(async () =>
            {
                var buffer = new byte[128 * 1024];
                while (!timeoutSource.IsCancellationRequested)
                {
                    try
                    {
                        using var request = new HttpRequestMessage(HttpMethod.Get, BuildDownloadUri());
                        using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeoutSource.Token);
                        response.EnsureSuccessStatusCode();
                        await using var stream = await response.Content.ReadAsStreamAsync(timeoutSource.Token);
                        while (!timeoutSource.IsCancellationRequested)
                        {
                            var read = await stream.ReadAsync(buffer.AsMemory(), timeoutSource.Token);
                            if (read == 0) break;
                            Interlocked.Add(ref bytesRead, read);
                        }
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested)
                    {
                        break;
                    }
                    catch (Exception ex) when (ex is HttpRequestException or IOException)
                    {
                        // Retry another stream during this bounded measurement window.
                    }
                }
            }, timeoutSource.Token)).ToArray();
            await Task.WhenAll(workers);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // Expected: the bounded measurement window elapsed while the stream was active.
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException)
        {
            stopwatch.Stop();
            return new BandwidthResult(false, 0, bytesRead, stopwatch.Elapsed.TotalSeconds, ex.Message);
        }

        stopwatch.Stop();
        var seconds = Math.Max(stopwatch.Elapsed.TotalSeconds, 0.001);
        var megabitsPerSecond = bytesRead * 8d / seconds / 1_000_000d;
        return new BandwidthResult(bytesRead > 0, megabitsPerSecond, bytesRead, seconds, $"读取 {bytesRead:N0} 字节");
    }

    private Uri BuildDownloadUri()
    {
        var separator = _downloadUri.Query.Length == 0 ? "?" : "&";
        return new Uri($"{_downloadUri}{separator}r={Guid.NewGuid():N}&ckSize=100");
    }
}
