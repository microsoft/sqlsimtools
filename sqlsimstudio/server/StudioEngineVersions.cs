using System.Diagnostics;
using System.Text.RegularExpressions;

namespace SqlsimStudio;

internal sealed record EngineVersionInfo(bool Available, string? Version, string? Problem = null);

// Engine versions come from each packaged engine's --version output. Successful
// probes are cached; failures are retried so installing Python packages takes
// effect after the page is refreshed.
internal static partial class StudioEngineVersions
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly Dictionary<string, EngineVersionInfo> Cache = new(StringComparer.Ordinal);

    public static async Task<IReadOnlyDictionary<string, EngineVersionInfo>> GetAsync()
    {
        await Gate.WaitAsync();
        try
        {
            foreach (var engine in new[] { "sqlsim", "sqlpysim" })
            {
                if (!Cache.TryGetValue(engine, out var cached) || cached.Problem is not null || cached.Version is null)
                {
                    Cache[engine] = await ReadAsync(engine);
                }
            }
            return new Dictionary<string, EngineVersionInfo>(Cache, StringComparer.Ordinal);
        }
        finally
        {
            Gate.Release();
        }
    }

    private static async Task<EngineVersionInfo> ReadAsync(string engine)
    {
        var executable = RuntimeLocator.Find(engine);
        if (executable is null)
        {
            return new EngineVersionInfo(false, null, "not found");
        }

        var version = await RunAsync(executable.Command, [.. executable.PrefixArguments, "--version"]);
        if (version.StartFailed)
        {
            return new EngineVersionInfo(true, null, engine == "sqlpysim" ? "Python not found" : "could not start");
        }

        var match = VersionPattern().Match(version.Output);
        var reported = version.ExitCode == 0 && match.Success ? match.Groups["version"].Value : null;
        if (engine == "sqlpysim" && reported is not null)
        {
            var driver = await RunAsync(executable.Command,
                ["-c", "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('mssql_python') else 1)"]);
            if (driver.ExitCode != 0)
            {
                return new EngineVersionInfo(true, reported, "mssql-python not installed");
            }
        }

        return new EngineVersionInfo(true, reported);
    }

    private sealed record ProbeResult(bool StartFailed, int ExitCode, string Output);

    private static async Task<ProbeResult> RunAsync(string command, IEnumerable<string> arguments)
    {
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = command,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            foreach (var argument in arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return new ProbeResult(true, -1, string.Empty);
            }
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
            _ = process.StandardError.ReadToEndAsync(timeout.Token);
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return new ProbeResult(false, -1, string.Empty);
            }
            return new ProbeResult(false, process.ExitCode, await output);
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            return new ProbeResult(true, -1, string.Empty);
        }
    }

    [GeneratedRegex(@"^\s*(?:sqlsim|sqlpysim)\s+(?<version>[0-9A-Za-z.+-]{1,32})\s*$", RegexOptions.Multiline)]
    private static partial Regex VersionPattern();
}
