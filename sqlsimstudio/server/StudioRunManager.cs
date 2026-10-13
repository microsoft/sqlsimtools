using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml;

namespace SqlsimStudio;

internal sealed class StudioRunManager
{
    private const string ProbeMarker = "STUDIOPROBE";
    private const string DriverVersionLabel = "ODBC Driver Version:";

    // CHAR(83) keeps the marker out of the batch text sqlsim echoes, so only the result row can match it.
    private const string ProbeQuery =
        "SELECT CHAR(83)+'TUDIOPROBE'" +
        "+'|'+CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion'))" +
        "+'|'+CONVERT(nvarchar(128),SERVERPROPERTY('Edition'))" +
        "+'|'+CONVERT(nvarchar(128),DB_NAME())";

    private static readonly Regex SensitiveConnectionValue = new(
        @"(PWD|Password|UID|Username|User ID|UserId|AccessToken|Access Token)=[^;]*",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private readonly object sync = new();
    private readonly List<RunHistoryEntry> history = [];
    private readonly SemaphoreSlim connectionTestGate = new(1, 1);
    private StudioRun? current;

    public StudioRunManager()
    {
        DeleteStaleWorkingDirectories();
    }

    public RunSnapshot GetSnapshot()
    {
        lock (sync)
        {
            return current?.Snapshot() ?? RunSnapshot.Empty;
        }
    }

    public IReadOnlyList<RunHistoryEntry> GetHistory()
    {
        lock (sync)
        {
            return history.AsEnumerable().Reverse().ToArray();
        }
    }

    public StartRunResult Start(QueryRunRequest request)
    {
        var validationError = Validate(request);
        if (validationError is not null)
        {
            return StartRunResult.Failed(validationError);
        }

        lock (sync)
        {
            if (current is { IsTerminal: false })
            {
                return StartRunResult.Failed("A workload is already running.");
            }

            if (current is not null && !DeleteWorkingDirectory(current.WorkingDirectory))
            {
                Console.Error.WriteLine("Warning: Studio could not delete the previous private run directory.");
            }

            var executable = RuntimeLocator.Find(request.Engine);
            if (executable is null)
            {
                return StartRunResult.Failed($"{request.Engine} is not installed where Studio can find it.");
            }

            var run = StudioRun.Create(request, executable);
            current = run;
            _ = ExecuteAsync(run);
            return StartRunResult.Started(run.Id);
        }
    }

    public async Task<ConnectionTestResult> TestConnectionAsync(QueryRunRequest request)
    {
        var probe = request with
        {
            Mode = "query",
            Query = ProbeQuery,
            InputFileName = null,
            InputContent = null,
            ReplayMode = null,
            WorkloadGroups = null,
            Threads = 1,
            Iterations = 1,
            Quiet = false,
            StopOnError = true,
            Telemetry = "console",
            StatisticsSource = "none",
            RetryCount = 0,
            RetryDelaySeconds = null,
            PreparedStatements = false,
            Reconnect = false,
            ConnectionPooling = false
        };

        if (Validate(probe) is { } validationError)
        {
            return ConnectionTestResult.Failed(validationError);
        }

        var executable = RuntimeLocator.Find(probe.Engine);
        if (executable is null)
        {
            return ConnectionTestResult.Failed($"{probe.Engine} is not installed where Studio can find it.");
        }

        lock (sync)
        {
            if (current is { IsTerminal: false })
            {
                return ConnectionTestResult.Failed("A workload is already running.");
            }
        }

        if (!await connectionTestGate.WaitAsync(0))
        {
            return ConnectionTestResult.Failed("A connection test is already running.");
        }

        var run = StudioRun.Create(probe, executable);
        var queryStoreSecret = run.Secret;
        var timeoutSeconds = Math.Clamp((probe.LoginTimeoutSeconds ?? 15) + 20, 20, 120);
        try
        {
            StudioPaths.CreatePrivateDirectory(StudioPaths.RunRoot);
            StudioPaths.CreatePrivateDirectory(run.WorkingDirectory);
            using var process = new Process { StartInfo = BuildStartInfo(run) };
            var elapsed = Stopwatch.StartNew();
            if (!process.Start())
            {
                return ConnectionTestResult.Failed("The connection test process did not start.");
            }

            if (run.Secret is not null)
            {
                await process.StandardInput.WriteLineAsync(run.Secret);
                run.Secret = null;
            }
            process.StandardInput.Close();

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException)
                {
                }
                return ConnectionTestResult.Failed($"No response within {timeoutSeconds} seconds.");
            }

            elapsed.Stop();
            var result = InterpretProbe(process.ExitCode, await stdoutTask, await stderrTask, elapsed.Elapsed.TotalMilliseconds);
            if (result.Success && request.StatisticsSource == "query-store")
            {
                try
                {
                    await QueryStoreCollector.ValidateAsync(run.Request, queryStoreSecret);
                }
                catch (Exception error)
                {
                    return ConnectionTestResult.Failed($"Query Store validation failed: {Sanitize(error.Message)}");
                }
            }
            return result;
        }
        catch (Exception error)
        {
            return ConnectionTestResult.Failed(Sanitize(error.Message));
        }
        finally
        {
            queryStoreSecret = null;
            run.Secret = null;
            DeleteWorkingDirectory(run.WorkingDirectory);
            connectionTestGate.Release();
        }
    }

    private static ConnectionTestResult InterpretProbe(int exitCode, string stdout, string stderr, double elapsedMs)
    {
        string? version = null;
        string? edition = null;
        string? database = null;
        string? driver = null;
        string? failure = null;

        foreach (var rawLine in stdout.Split('\n'))
        {
            var line = rawLine.Trim();
            var marker = line.IndexOf(ProbeMarker, StringComparison.Ordinal);
            if (marker >= 0)
            {
                var fields = line[(marker + ProbeMarker.Length)..].Split('|');
                if (fields.Length >= 4)
                {
                    version = Sanitize(fields[1].Trim());
                    edition = Sanitize(fields[2].Trim());
                    database = Sanitize(fields[3].Trim());
                }
            }
            else if (line.IndexOf(DriverVersionLabel, StringComparison.OrdinalIgnoreCase) is int label and >= 0)
            {
                // sqlsim prefixes output lines with a timestamp, so match anywhere in the line.
                driver = Sanitize(line[(label + DriverVersionLabel.Length)..].Trim());
            }
            else if (failure is null && line.Contains("error", StringComparison.OrdinalIgnoreCase))
            {
                failure = Sanitize(line);
            }
        }

        if (exitCode == 0 && version is not null)
        {
            return new ConnectionTestResult(true, null, version, edition, database, driver, Math.Round(elapsedMs));
        }

        var stderrLine = stderr
            .Split('\n')
            .Select(line => line.Trim())
            .FirstOrDefault(line => line.Length > 0);
        var message = stderrLine is not null ? Sanitize(stderrLine)
            : failure
            ?? (version is null && exitCode == 0
                ? "Connected, but the server did not return the expected probe row."
                : $"Connection failed (exit code {exitCode}).");
        return ConnectionTestResult.Failed(message);
    }

    public bool Stop()
    {
        lock (sync)
        {
            if (current is null || current.IsTerminal)
            {
                return false;
            }

            current.StopRequested = true;
            try
            {
                current.Process?.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            return true;
        }
    }

    public void Cleanup()
    {
        StudioRun? run;
        lock (sync)
        {
            run = current;
            current = null;
        }

        if (run is null)
        {
            return;
        }

        if (!run.IsTerminal && !run.StopRequested)
        {
            run.StopRequested = true;
            try
            {
                run.Process?.Kill(entireProcessTree: true);
                run.Process?.WaitForExit(5000);
            }
            catch (InvalidOperationException)
            {
            }
        }
        if (!DeleteWorkingDirectory(run.WorkingDirectory))
        {
            Console.Error.WriteLine("Warning: Studio could not delete the private run directory during shutdown.");
        }
    }

    private async Task ExecuteAsync(StudioRun run)
    {
        QueryStoreCollector? queryStoreCollector = null;
        try
        {
            StudioPaths.CreatePrivateDirectory(StudioPaths.RunRoot);
            StudioPaths.CreatePrivateDirectory(run.WorkingDirectory);
            await WriteInputFileAsync(run);
            if (run.Request.StatisticsSource == "query-store")
            {
                run.AddLog("Query Store", "info", "Validating Query Store and capturing the pre-run aggregate snapshot.");
                queryStoreCollector = await QueryStoreCollector.StartAsync(run.Request, run.Secret);
                run.AddLog("Query Store", "warning", "Aggregate deltas can include matching queries executed by other sessions.");
            }
            var startInfo = BuildStartInfo(run);
            run.AddLog("Studio", "info", $"Starting {run.Request.Engine} {run.Request.Mode} workload.");
            run.AddLog("Studio", "info",
                $"Target: {run.Request.Server}/{run.Request.Database}; " +
                $"connections={GetThreadCount(run.Request)}; mode={run.Request.Mode}.");

            using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            run.StartedAt = DateTimeOffset.UtcNow;
            run.State = "running";

            // Stop can arrive while the run is still starting, for example during the
            // Query Store pre-run snapshot. Honour it before launching anything, and
            // publish the process only once it exists so Stop never sees an unstarted
            // Process it cannot kill.
            lock (sync)
            {
                if (run.StopRequested)
                {
                    throw new OperationCanceledException("Stopped before the workload process started.");
                }
            }

            if (!process.Start())
            {
                throw new InvalidOperationException("The workload process did not start.");
            }

            lock (sync)
            {
                run.Process = process;
                run.ProcessId = process.Id;
                if (run.StopRequested)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            run.AddLog("Process", "info", $"Started process {process.Id}.");

            if (run.Secret is not null)
            {
                await process.StandardInput.WriteLineAsync(run.Secret);
                process.StandardInput.Close();
                run.Secret = null;
            }

            var stdoutTask = ReadStdoutAsync(run, process);
            var stderrTask = ReadStderrAsync(run, process);
            await process.WaitForExitAsync();
            await Task.WhenAll(stdoutTask, stderrTask);

            run.ExitCode = process.ExitCode;
            run.CompletedAt = DateTimeOffset.UtcNow;
            var terminalState = run.StopRequested ? "stopped" : process.ExitCode == 0 ? "completed" : "failed";

            // The final snapshot lands after the last tick, so re-read it for late errors.
            RefreshLiveQueryStats(run);

            var expectsFinalResult = run.Request.Telemetry is "final" or "live";
            if (expectsFinalResult)
            {
                if (!File.Exists(run.ResultPath))
                {
                    throw new InvalidOperationException("The workload completed without producing its canonical final JSON result.");
                }
                var resultText = await File.ReadAllTextAsync(run.ResultPath);
                run.FinalResult = JsonSerializer.Deserialize<JsonElement>(resultText);
                PromoteResultDiagnostics(run, run.FinalResult.Value);
            }

            if (queryStoreCollector is not null)
            {
                run.QueryStoreResult = await queryStoreCollector.CompleteAsync();
                run.AddLog("Query Store", "info",
                    $"Captured aggregate deltas for {run.QueryStoreResult.Queries.Count} query plan(s).");
            }

            run.AddLog("Process", process.ExitCode == 0 ? "info" : "error",
                $"Process exited with code {process.ExitCode}.");

            // A live run without runtime statistics has no channel carrying error text,
            // so say where the detail lives rather than leaving only the exit code.
            if (terminalState == "failed" && !run.HasDiagnostics())
            {
                run.AddLog("Studio", "error",
                    "The engine reported a failure but no error text. Live runs carry error "
                    + "counts only; set Studio server statistics to \"Runtime messages\" to "
                    + "capture the failing query and message, or use Final results only.");
            }

            ArchiveRun(run, terminalState);
            run.State = terminalState;
        }
        catch (Exception error)
        {
            run.Secret = null;
            run.CompletedAt = DateTimeOffset.UtcNow;
            run.State = run.StopRequested ? "stopped" : "failed";
            run.AddLog("Studio", run.StopRequested ? "info" : "error",
                run.StopRequested ? "Workload stopped by user." : Sanitize(error.Message));
        }
        finally
        {
            if (queryStoreCollector is not null)
            {
                await queryStoreCollector.DisposeAsync();
            }
            run.Process = null;
        }
    }

    private void ArchiveRun(StudioRun run, string terminalState)
    {
        if (terminalState != "completed" || run.FinalResult is null)
        {
            return;
        }

        var request = run.Request;
        object workloadDefinition = request.Mode switch
        {
            "query" => new { request.Query },
            "file" => new { request.InputContent },
            "replay" => new { request.InputContent, request.ReplayMode },
            _ => request.WorkloadGroups!.Select(group => new
            {
                group.Content,
                group.Threads,
                group.Iterations,
                group.ThinkTimeMs
            }).ToArray()
        };
        var workloadJson = JsonSerializer.Serialize(workloadDefinition);
        var workloadHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(workloadJson))).ToLowerInvariant();
        var comparisonJson = JsonSerializer.Serialize(new
        {
            request.Engine,
            request.Mode,
            Server = request.Server.ToUpperInvariant(),
            Database = request.Database?.ToUpperInvariant(),
            request.Authentication,
            Threads = GetThreadCount(request),
            request.Iterations,
            request.Quiet,
            request.TrustServerCertificate,
            request.StopOnError,
            request.StatisticsSource,
            request.Telemetry,
            WorkloadHash = workloadHash
        });
        var comparisonKey = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(comparisonJson))).ToLowerInvariant();
        var entry = new RunHistoryEntry(
            run.Id,
            run.CompletedAt ?? DateTimeOffset.UtcNow,
            request.Engine,
            request.Mode,
            request.Server,
            request.Database!,
            GetThreadCount(request),
            request.Iterations,
            request.StatisticsSource,
            request.Telemetry,
            workloadHash,
            comparisonKey,
            run.FinalResult.Value.Clone());

        lock (sync)
        {
            history.Add(entry);
            if (history.Count > 50)
            {
                history.RemoveAt(0);
            }
        }
    }

    private static ProcessStartInfo BuildStartInfo(StudioRun run)
    {
        var request = run.Request;
        var startInfo = new ProcessStartInfo
        {
            FileName = run.Executable.Command,
            WorkingDirectory = run.WorkingDirectory,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        foreach (var prefixArgument in run.Executable.PrefixArguments)
        {
            startInfo.ArgumentList.Add(prefixArgument);
        }

        AddArgument(startInfo, "-S", request.Server);
        if (!string.IsNullOrWhiteSpace(request.Database))
        {
            AddArgument(startInfo, "-d", request.Database);
        }

        switch (request.Authentication)
        {
            case "integrated":
                startInfo.ArgumentList.Add("-E");
                break;
            case "sql":
                AddArgument(startInfo, "-U", request.Username!);
                AddArgument(startInfo, "-P", "-");
                break;
            case "token":
                AddArgument(startInfo, "-T", "-");
                break;
            case "interactive":
                AddArgument(startInfo, "-A", "ActiveDirectoryInteractive");
                break;
            case "managed":
                AddArgument(startInfo, "-A", "ActiveDirectoryMsi");
                // A username here is a user-assigned managed identity client ID.
                if (!string.IsNullOrWhiteSpace(request.Username))
                {
                    AddArgument(startInfo, "-U", request.Username);
                }
                break;
            case "service-principal":
                AddArgument(startInfo, "-A", "ActiveDirectoryServicePrincipal");
                AddArgument(startInfo, "-U", request.Username!);
                AddArgument(startInfo, "-P", "-");
                break;
            default:
                throw new InvalidOperationException("Unsupported authentication mode.");
        }

        switch (request.Mode)
        {
            case "query":
                AddArgument(startInfo, "-Q", request.Query!);
                break;
            case "file":
                AddArgument(startInfo, "-i", run.InputPath!);
                break;
            case "replay":
                AddArgument(startInfo, "-replay", request.ReplayMode!);
                AddArgument(startInfo, "-replayfile", run.InputPath!);
                break;
            case "workload":
                AddArgument(startInfo, "-workload", run.InputPath!);
                break;
        }

        if (request.Mode != "workload" && (request.Mode != "replay" || request.ReplayMode == "stress"))
        {
            AddArgument(startInfo, "-n", request.Threads.ToString());
        }
        if (request.Mode != "workload")
        {
            AddArgument(startInfo, "-r", request.Iterations.ToString());
        }

        if (request.Quiet)
        {
            startInfo.ArgumentList.Add("-q");
        }
        if (request.LoginTimeoutSeconds is { } loginTimeout)
        {
            AddArgument(startInfo, "-l", loginTimeout.ToString());
        }
        // sqlpysim refuses -app: mssql-python reserves the application name
        // and always reports "MSSQL-Python", so passing one would fail the run
        // rather than quietly do nothing.
        if (!string.IsNullOrWhiteSpace(request.ApplicationName) && request.Engine != "sqlpysim")
        {
            AddArgument(startInfo, "-app", request.ApplicationName);
        }
        if (request.RetryCount is { } retryCount and > 0)
        {
            AddArgument(startInfo, "-retry", retryCount.ToString());
            if (request.RetryDelaySeconds is { } retryDelay)
            {
                AddArgument(startInfo, "-retrydelay", retryDelay.ToString());
            }
        }
        switch (request.Encryption)
        {
            case "optional":
                AddArgument(startInfo, "-N", "o");
                break;
            case "mandatory":
                AddArgument(startInfo, "-N", "m");
                break;
            case "strict":
                AddArgument(startInfo, "-N", "s");
                break;
        }
        if (request.TrustServerCertificate)
        {
            startInfo.ArgumentList.Add("-C");
        }
        if (!string.IsNullOrWhiteSpace(request.CertificateHostname))
        {
            AddArgument(startInfo, "-F", request.CertificateHostname);
        }
        if (request.ReadOnlyIntent)
        {
            startInfo.ArgumentList.Add("-R");
        }
        if (request.MultiSubnetFailover)
        {
            startInfo.ArgumentList.Add("-M");
        }
        if (request.QueryTimeoutSeconds is { } queryTimeout)
        {
            AddArgument(startInfo, "-t", queryTimeout.ToString());
        }
        if (request.PreparedStatements)
        {
            startInfo.ArgumentList.Add("-p");
        }
        if (request.Reconnect)
        {
            startInfo.ArgumentList.Add("-reconnect");
        }
        if (request.ConnectionPooling)
        {
            startInfo.ArgumentList.Add("-usepool");
        }
        if (request.StopOnError)
        {
            startInfo.ArgumentList.Add("-stoponerror");
        }
        if (request.StatisticsSource == "runtime")
        {
            startInfo.ArgumentList.Add("-querystats");
            // Snapshots go to their own file, so they never contend with the stdout stream.
            if (request.Telemetry == "live")
            {
                AddArgument(startInfo, "-querystats-interval", "1");
                AddArgument(startInfo, "-querystats-file", run.QueryStatsPath);
            }
        }

        if (request.Telemetry == "live")
        {
            startInfo.ArgumentList.Add("-stream-json");
            startInfo.ArgumentList.Add("-json");
            AddArgument(startInfo, "-o", run.ResultPath);
        }
        else if (request.Telemetry == "final")
        {
            // No -v: it adds a per-iteration record for every thread, which grows
            // with run length and nothing in Studio reads. Server version and
            // edition are recorded without it.
            startInfo.ArgumentList.Add("-json");
            AddArgument(startInfo, "-o", run.ResultPath);
        }

        return startInfo;
    }

    private static async Task ReadStdoutAsync(StudioRun run, Process process)
    {
        while (await process.StandardOutput.ReadLineAsync() is { } line)
        {
            if (run.Request.Telemetry == "live")
            {
                try
                {
                    var progress = JsonSerializer.Deserialize<JsonElement>(line);
                    run.LatestProgress = progress;
                    run.AddLog(run.Request.Engine, "info", SummarizeProgress(progress));
                    RefreshLiveQueryStats(run);
                }
                catch (JsonException)
                {
                    run.AddLog("Process", "warning", "Ignored non-JSON stdout from the workload process.");
                }
            }
            else if (run.Request.Telemetry == "console")
            {
                var sanitized = Sanitize(line);
                run.AppendConsoleLine(sanitized);
                if (!string.IsNullOrWhiteSpace(line))
                {
                    run.AddLog("Process", "info", sanitized);
                }
            }
            else if (!string.IsNullOrWhiteSpace(line))
            {
                run.AddLog("Process", "info", Sanitize(line));
            }
        }
    }

    // The engine rewrites the snapshot file on its own interval, so a read can land
    // mid-write; the previous snapshot stays until a complete one parses.
    private static void RefreshLiveQueryStats(StudioRun run)
    {
        if (!File.Exists(run.QueryStatsPath)) return;
        try
        {
            run.LiveQueryStats = JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(run.QueryStatsPath));
            PromoteLiveDiagnostics(run);
        }
        catch (Exception error) when (error is IOException or JsonException)
        {
        }
    }

    // A live run emits no error text on the stream or stderr, so the snapshot's
    // rolling error list is the only place a failure reason exists while it runs.
    private static void PromoteLiveDiagnostics(StudioRun run)
    {
        if (run.LiveQueryStats is not { } stats ||
            !stats.TryGetProperty("recent_errors", out var errors) ||
            errors.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var entry in errors.EnumerateArray())
        {
            var message = entry.TryGetProperty("message", out var text) ? text.GetString() : null;
            if (string.IsNullOrWhiteSpace(message))
            {
                continue;
            }

            var timestamp = entry.TryGetProperty("timestamp", out var stamp) ? stamp.GetString() : null;
            if (!run.TryMarkDiagnosticSeen($"{timestamp}|{message}"))
            {
                continue;
            }

            var query = entry.TryGetProperty("query", out var queryText) ? queryText.GetString() : null;
            run.AddLog(run.Request.Engine, "error", string.IsNullOrWhiteSpace(query)
                ? Sanitize(message)
                : $"{Sanitize(message)} (query: {Sanitize(Truncate(query, 120))})");
        }
    }

    // The engine reports SQL errors in the results file, not on stderr, so without this
    // a failed run would only ever log "Process exited with code 1".
    private static void PromoteResultDiagnostics(StudioRun run, JsonElement result)
    {
        if (!result.TryGetProperty("metrics", out var metrics))
        {
            return;
        }

        foreach (var (property, level) in new[] { ("errors", "error"), ("warnings", "warning") })
        {
            if (!metrics.TryGetProperty(property, out var section) ||
                !section.TryGetProperty("list", out var list) ||
                list.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            var reported = 0;
            foreach (var entry in list.EnumerateArray())
            {
                if (reported++ >= 20)
                {
                    run.AddLog("sqlsim", level, $"Additional {property} were reported; see the results JSON.");
                    break;
                }

                var message = entry.TryGetProperty("message", out var text) ? text.GetString() : null;
                if (string.IsNullOrWhiteSpace(message))
                {
                    continue;
                }

                var query = entry.TryGetProperty("query", out var queryText) ? queryText.GetString() : null;
                run.AddLog("sqlsim", level, string.IsNullOrWhiteSpace(query)
                    ? Sanitize(message)
                    : $"{Sanitize(message)} (query: {Sanitize(Truncate(query, 120))})");
            }
        }
    }

    private static string Truncate(string value, int maximum) =>
        value.Length <= maximum ? value : value[..maximum] + "...";

    private static async Task ReadStderrAsync(StudioRun run, Process process)
    {
        while (await process.StandardError.ReadLineAsync() is { } line)
        {
            if (!string.IsNullOrWhiteSpace(line))
            {
                run.AddLog("Process", "error", Sanitize(line));
            }
        }
    }

    private static string SummarizeProgress(JsonElement progress)
    {
        if (!progress.TryGetProperty("type", out var type))
        {
            return "Received a structured workload event.";
        }

        return type.GetString() switch
        {
            "started" => "Workload started.",
            "progress" when progress.TryGetProperty("successful_executions", out var completed) &&
                progress.TryGetProperty("throughput_per_second", out var throughput) =>
                $"{completed.GetInt64():N0} executions; {throughput.GetDouble():N1} exec/sec.",
            "completed" when progress.TryGetProperty("status", out var status) =>
                $"Workload completed with status {status.GetString()}.",
            _ => $"Received {type.GetString()} event."
        };
    }

    private static string? Validate(QueryRunRequest request)
    {
        if (request.Engine is not ("sqlsim" or "sqlpysim")) return "Engine must be sqlsim or sqlpysim.";
        if (request.Mode is not ("query" or "file" or "workload" or "replay")) return "Mode must be query, file, workload, or replay.";
        if (string.IsNullOrWhiteSpace(request.Server) || request.Server.Length > 253) return "Server is required and must be 253 characters or fewer.";
        if (request.Server.IndexOfAny([';', '{', '}']) >= 0) return "Server contains invalid connection-string characters.";
        if (string.IsNullOrWhiteSpace(request.Database) || request.Database.Length > 128) return "Database is required and must be 128 characters or fewer.";
        if (request.Database.IndexOfAny([';', '{', '}']) >= 0) return "Database contains invalid connection-string characters.";
        if (request.Mode == "query" && (string.IsNullOrWhiteSpace(request.Query) || Encoding.UTF8.GetByteCount(request.Query) > 1_000_000)) return "Query is required and must be 1 MB or smaller.";
        if (request.Mode == "file" && (string.IsNullOrWhiteSpace(request.InputContent) || Encoding.UTF8.GetByteCount(request.InputContent) > 1_000_000)) return "SQL file content is required and must be 1 MB or smaller.";
        if (request.Mode == "file" && !string.Equals(Path.GetExtension(request.InputFileName), ".sql", StringComparison.OrdinalIgnoreCase)) return "SQL file name must use the .sql extension.";
        if (request.Mode == "replay" && request.Engine != "sqlsim") return "Replay is supported only by sqlsim.";
        if (request.Mode == "replay" && request.ReplayMode is not ("fast" or "stress")) return "Replay mode must be fast or stress.";
        if (request.Mode == "replay" && (string.IsNullOrWhiteSpace(request.InputContent) || Encoding.UTF8.GetByteCount(request.InputContent) > 100_000_000)) return "Replay XML content is required and must be 100 MB or smaller.";
        if (request.Mode == "replay" && !string.Equals(Path.GetExtension(request.InputFileName), ".xml", StringComparison.OrdinalIgnoreCase)) return "Replay file name must use the .xml extension.";
        if (request.Mode == "replay" && ValidateReplayXml(request.InputContent!) is { } replayError) return replayError;
        if (request.Mode == "workload" && request.Engine != "sqlsim" && request.Engine != "sqlpysim") return "Mixed workloads are supported only by sqlsim and sqlpysim.";
        if (request.Mode == "workload" && (request.WorkloadGroups is null || request.WorkloadGroups.Count is < 1 or > 20)) return "Mixed workload requires between 1 and 20 groups.";
        if (request.Mode == "workload")
        {
            var totalBytes = 0;
            foreach (var group in request.WorkloadGroups!)
            {
                if (!string.Equals(Path.GetExtension(group.FileName), ".sql", StringComparison.OrdinalIgnoreCase)) return "Every workload group must use a .sql file.";
                if (string.IsNullOrWhiteSpace(group.Content)) return "Every workload group requires SQL content.";
                var contentBytes = Encoding.UTF8.GetByteCount(group.Content);
                if (contentBytes > 1_000_000) return "Each workload SQL file must be 1 MB or smaller.";
                totalBytes += contentBytes;
                if (totalBytes > 10_000_000) return "Combined workload SQL content must be 10 MB or smaller.";
                if (group.Threads is < 1 or > 10_000) return "Workload group connections must be between 1 and 10,000.";
                if (group.Iterations is < 1 or > 2_147_483_647) return "Workload group iterations must be at least 1.";
                if (group.ThinkTimeMs is < 0 or > 86_400_000) return "Workload group think time must be between 0 and 86,400,000 ms.";
            }
        }
        if (request.Mode != "workload" && (request.Threads is < 1 or > 10_000)) return "Connections must be between 1 and 10,000.";
        if (request.Mode != "workload" && (request.Iterations is < 1 or > 2_147_483_647)) return "Iterations must be at least 1.";
        if (request.Telemetry is not ("live" or "final" or "console")) return "Telemetry must be live, final, or console.";
        if (request.StatisticsSource is not ("none" or "runtime" or "query-store")) return "Unknown statistics source.";
        if (request.Authentication is not ("integrated" or "sql" or "token" or "interactive" or "managed" or "service-principal")) return "Unsupported authentication mode.";
        if (request.Authentication == "sql" && string.IsNullOrWhiteSpace(request.Username)) return "SQL authentication requires a username.";
        if (request.Authentication == "service-principal" && string.IsNullOrWhiteSpace(request.Username)) return "Service principal authentication requires a client ID.";
        if (request.Authentication is "sql" or "token" or "service-principal" && string.IsNullOrEmpty(request.Secret)) return "The selected authentication mode requires a secret.";
        // The engines reject -P for these modes, so refuse before launching a process.
        if (request.Authentication is "integrated" or "interactive" or "managed" && !string.IsNullOrEmpty(request.Secret)) return "The selected authentication mode does not accept a password or token.";
        if (request.Authentication is "integrated" or "interactive" && !string.IsNullOrWhiteSpace(request.Username)) return "The selected authentication mode does not accept a username.";
        if (request.Authentication == "interactive" && !OperatingSystem.IsWindows()) return "Microsoft Entra interactive requires Windows. Use an access token or managed identity.";
        // Wired in BuildStartInfo but not validated against a live target, so not offered yet.
        if (request.Username is { Length: > 1_024 }) return "Username must be 1,024 characters or fewer.";
        if (request.Secret?.Length > 10_000) return "Credential exceeds the maximum supported length.";
        if (request.LoginTimeoutSeconds is < 0 or > 86_400) return "Login timeout must be between 0 and 86,400 seconds.";
        if (request.QueryTimeoutSeconds is < 0 or > 86_400) return "Query timeout must be between 0 and 86,400 seconds.";
        if (request.RetryCount is < 0 or > 255) return "Retry count must be between 0 and 255.";
        if (request.RetryDelaySeconds is < 1 or > 60) return "Retry delay must be between 1 and 60 seconds.";
        if (request.Encryption is not (null or "default" or "optional" or "mandatory" or "strict")) return "Unknown encryption level.";
        if (request.ApplicationName is { Length: > 128 }) return "Application name must be 128 characters or fewer.";
        if (request.ApplicationName is not null && request.ApplicationName.AsSpan().IndexOfAny(";{}") >= 0) return "Application name cannot contain ';', '{', or '}'.";
        if (request.CertificateHostname is { Length: > 253 }) return "Certificate hostname must be 253 characters or fewer.";
        if (request.CertificateHostname is not null && request.CertificateHostname.AsSpan().IndexOfAny(";{}") >= 0) return "Certificate hostname cannot contain ';', '{', or '}'.";
        if (request.ConnectionPooling && !request.Reconnect) return "Connection pooling requires reconnect each iteration.";
        return null;
    }

    private static string? ValidateReplayXml(string content)
    {
        try
        {
            using var stringReader = new StringReader(content);
            using var reader = XmlReader.Create(stringReader, new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                MaxCharactersInDocument = 100_000_000
            });
            reader.MoveToContent();
            if (reader.NodeType != XmlNodeType.Element ||
                !string.Equals(reader.LocalName, "replay", StringComparison.Ordinal))
            {
                return "Replay XML must have a <replay> root element.";
            }

            var eventCount = 0;
            var rootDepth = reader.Depth;
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element &&
                    reader.Depth == rootDepth + 1 &&
                    string.Equals(reader.LocalName, "event", StringComparison.Ordinal))
                {
                    eventCount++;
                    if (eventCount > 100_000)
                    {
                        return "Replay XML exceeds the 100,000 event limit.";
                    }
                }
            }
            return eventCount > 0 ? null : "Replay XML must contain at least one <event> element.";
        }
        catch (XmlException)
        {
            return "Replay content must be well-formed XML.";
        }
    }

    private static async Task WriteInputFileAsync(StudioRun run)
    {
        if (run.Request.Mode == "workload")
        {
            var definitions = new List<object>();
            for (var index = 0; index < run.Request.WorkloadGroups!.Count; index++)
            {
                var group = run.Request.WorkloadGroups[index];
                var fileName = $"group-{index + 1:D2}.sql";
                await File.WriteAllTextAsync(
                    Path.Combine(run.WorkingDirectory, fileName), group.Content, new UTF8Encoding(false));
                definitions.Add(new
                {
                    file = fileName,
                    threads = group.Threads,
                    iterations = group.Iterations,
                    think_time_ms = group.ThinkTimeMs
                });
            }

            run.InputPath = Path.Combine(run.WorkingDirectory, "workload.json");
            await File.WriteAllTextAsync(run.InputPath,
                JsonSerializer.Serialize(new { workloads = definitions }, new JsonSerializerOptions { WriteIndented = true }),
                new UTF8Encoding(false));
            run.AddLog("Studio", "info", $"Generated private workload JSON for {definitions.Count} group(s).");
            return;
        }

        if (run.Request.Mode is not ("file" or "replay"))
        {
            return;
        }

        run.InputPath = Path.Combine(run.WorkingDirectory,
            run.Request.Mode == "file" ? "input.sql" : "replay.xml");
        await File.WriteAllTextAsync(run.InputPath, run.Request.InputContent!, new UTF8Encoding(false));
        run.AddLog("Studio", "info",
            $"Staged {run.Request.InputFileName} as a private {run.Request.Mode} input.");
    }

    private static void AddArgument(ProcessStartInfo startInfo, string name, string value)
    {
        startInfo.ArgumentList.Add(name);
        startInfo.ArgumentList.Add(value);
    }

    private static int GetThreadCount(QueryRunRequest request) =>
        request.Mode == "workload"
            ? request.WorkloadGroups!.Sum(group => group.Threads)
            : request.Threads;

    private static string Sanitize(string value) =>
        SensitiveConnectionValue.Replace(value, "$1=********")
            .Replace("\r", " ", StringComparison.Ordinal)
            .Replace("\n", " ", StringComparison.Ordinal);

    private static bool DeleteWorkingDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void DeleteStaleWorkingDirectories()
    {
        var root = StudioPaths.RunRoot;
        if (!Directory.Exists(root))
        {
            return;
        }

        foreach (var directory in Directory.EnumerateDirectories(root))
        {
            try
            {
                if (Directory.GetLastWriteTimeUtc(directory) < DateTime.UtcNow.AddDays(-1) &&
                    !DeleteWorkingDirectory(directory))
                {
                    Console.Error.WriteLine("Warning: Studio could not delete a stale private run directory.");
                }
            }
            catch (IOException)
            {
                Console.Error.WriteLine("Warning: Studio could not inspect a stale private run directory.");
            }
            catch (UnauthorizedAccessException)
            {
                Console.Error.WriteLine("Warning: Studio could not inspect a stale private run directory.");
            }
        }
    }
}

internal sealed class StudioRun
{
    private const int MaximumConsoleOutputCharacters = 262_144;
    private readonly object sync = new();
    private readonly List<RunLogEntry> logs = [];
    private readonly HashSet<string> seenDiagnostics = [];
    private readonly StringBuilder consoleOutput = new();
    private bool consoleOutputTruncated;

    public required string Id { get; init; }
    public required QueryRunRequest Request { get; init; }
    public required RuntimeExecutable Executable { get; init; }
    public required string WorkingDirectory { get; init; }
    public required string ResultPath { get; init; }
    public required string QueryStatsPath { get; init; }
    public string? InputPath { get; set; }
    public string? Secret { get; set; }
    public Process? Process { get; set; }
    public int? ProcessId { get; set; }
    public int? ExitCode { get; set; }
    public string State { get; set; } = "starting";
    public bool StopRequested { get; set; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
    public JsonElement? LatestProgress { get; set; }
    public JsonElement? FinalResult { get; set; }
    public JsonElement? LiveQueryStats { get; set; }
    public QueryStoreDeltaResult? QueryStoreResult { get; set; }
    public bool IsTerminal => State is "completed" or "failed" or "stopped";

    // The snapshot keeps a rolling error list, so the same entry reappears every tick.
    public bool TryMarkDiagnosticSeen(string key)
    {
        lock (sync)
        {
            return seenDiagnostics.Add(key);
        }
    }

    // True once a real failure reason has been logged, as opposed to the exit code alone.
    public bool HasDiagnostics()
    {
        lock (sync)
        {
            return logs.Any(entry => entry.Level == "error" && entry.Source != "Process");
        }
    }

    public static StudioRun Create(QueryRunRequest request, RuntimeExecutable executable)
    {
        var id = Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant();
        var workingDirectory = Path.Combine(StudioPaths.RunRoot, id);
        return new StudioRun
        {
            Id = id,
            Request = request with { Secret = null },
            Secret = request.Secret,
            Executable = executable,
            WorkingDirectory = workingDirectory,
            ResultPath = Path.Combine(workingDirectory, "result.json"),
            QueryStatsPath = Path.Combine(workingDirectory, "querystats-live.json")
        };
    }

    public void AddLog(string source, string level, string message)
    {
        lock (sync)
        {
            logs.Add(new RunLogEntry(DateTimeOffset.UtcNow, source, level, message));
            if (logs.Count > 500)
            {
                logs.RemoveAt(0);
            }
        }
    }

    public void AppendConsoleLine(string line)
    {
        lock (sync)
        {
            if (consoleOutputTruncated)
            {
                return;
            }

            var remaining = MaximumConsoleOutputCharacters - consoleOutput.Length;
            if (line.Length + Environment.NewLine.Length > remaining)
            {
                if (remaining > 0)
                {
                    consoleOutput.Append(line.AsSpan(0, Math.Min(line.Length, remaining)));
                }
                consoleOutputTruncated = true;
                return;
            }

            consoleOutput.AppendLine(line);
        }
    }

    public RunSnapshot Snapshot()
    {
        lock (sync)
        {
            return new RunSnapshot(
                Id, State, Request.Engine, Request.Telemetry, ProcessId, ExitCode,
                StartedAt, CompletedAt, LatestProgress, FinalResult, LiveQueryStats, QueryStoreResult,
                consoleOutput.ToString(), consoleOutputTruncated, [.. logs]);
        }
    }
}

internal sealed record QueryRunRequest(
    string Engine,
    string Mode,
    string Server,
    string? Database,
    string Authentication,
    string? Username,
    string? Secret,
    string? Query,
    string? InputFileName,
    string? InputContent,
    string? ReplayMode,
    IReadOnlyList<WorkloadGroupRequest>? WorkloadGroups,
    int Threads,
    int Iterations,
    bool Quiet,
    bool TrustServerCertificate,
    bool StopOnError,
    string Telemetry,
    string StatisticsSource,
    int? LoginTimeoutSeconds = null,
    string? ApplicationName = null,
    int? RetryCount = null,
    int? RetryDelaySeconds = null,
    string? Encryption = null,
    string? CertificateHostname = null,
    bool ReadOnlyIntent = false,
    bool MultiSubnetFailover = false,
    int? QueryTimeoutSeconds = null,
    bool PreparedStatements = false,
    bool Reconnect = false,
    bool ConnectionPooling = false);

internal sealed record WorkloadGroupRequest(
    string FileName,
    string Content,
    int Threads,
    int Iterations,
    int ThinkTimeMs);

internal sealed record ConnectionTestResult(
    bool Success,
    string? Error,
    string? ServerVersion,
    string? Edition,
    string? Database,
    string? Driver,
    double? ElapsedMs)
{
    public static ConnectionTestResult Failed(string error) =>
        new(false, error, null, null, null, null, null);
}

internal sealed record RunLogEntry(DateTimeOffset Timestamp, string Source, string Level, string Message);

internal sealed record RunHistoryEntry(
    string Id,
    DateTimeOffset CompletedAt,
    string Engine,
    string Mode,
    string Server,
    string Database,
    int Threads,
    int Iterations,
    string StatisticsSource,
    string Telemetry,
    string WorkloadHash,
    string ComparisonKey,
    JsonElement Result);

internal sealed record RunSnapshot(
    string? Id,
    string State,
    string? Engine,
    string? Telemetry,
    int? ProcessId,
    int? ExitCode,
    DateTimeOffset? StartedAt,
    DateTimeOffset? CompletedAt,
    JsonElement? Progress,
    JsonElement? Result,
    JsonElement? LiveQueryStats,
    QueryStoreDeltaResult? QueryStore,
    string ConsoleOutput,
    bool ConsoleOutputTruncated,
    IReadOnlyList<RunLogEntry> Logs)
{
    public static RunSnapshot Empty { get; } = new(
        null, "idle", null, null, null, null, null, null, null, null, null, null, "", false, []);
}

internal sealed record StartRunResult(bool Success, string? RunId, string? Error)
{
    public static StartRunResult Started(string runId) => new(true, runId, null);
    public static StartRunResult Failed(string error) => new(false, null, error);
}

internal sealed record RuntimeExecutable(string Command, IReadOnlyList<string> PrefixArguments);

internal static class RuntimeLocator
{
    public static RuntimeExecutable? Find(string engine)
    {
        var environmentName = engine == "sqlsim" ? "SQLSIM_STUDIO_SQLSIM_PATH" : "SQLSIM_STUDIO_SQLPYSIM_PATH";
        var configured = Environment.GetEnvironmentVariable(environmentName);
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured))
        {
            return Create(engine, configured);
        }

        foreach (var candidate in Candidates(engine))
        {
            if (File.Exists(candidate))
            {
                return Create(engine, candidate);
            }
        }

        return null;
    }

    private static RuntimeExecutable Create(string engine, string path)
    {
        if (engine == "sqlpysim")
        {
            return new RuntimeExecutable(FindPython(), [Path.GetFullPath(path)]);
        }
        return new RuntimeExecutable(Path.GetFullPath(path), []);
    }

    // Double-clicking Studio does not activate a virtual environment, so look for
    // one beside the executable, then at the sqlsimtools bundle root, before
    // falling back to the platform command.
    public static string FindPython()
    {
        var configured = Environment.GetEnvironmentVariable("SQLSIM_STUDIO_PYTHON_PATH");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return configured;
        }

        foreach (var root in new[] { AppContext.BaseDirectory, Path.Combine(AppContext.BaseDirectory, "..") })
        {
            var venvPython = OperatingSystem.IsWindows()
                ? Path.Combine(root, ".venv", "Scripts", "python.exe")
                : Path.Combine(root, ".venv", "bin", "python");
            if (File.Exists(venvPython))
            {
                return Path.GetFullPath(venvPython);
            }
        }

        return OperatingSystem.IsWindows() ? "python" : "python3";
    }

    // Engines sit beside Studio in the standalone package, and in sibling
    // sqlsim/<arch> and sqlpysim folders in the sqlsimtools bundle.
    private static IEnumerable<string> Candidates(string engine)
    {
        var executableName = OperatingSystem.IsWindows() ? "sqlsim.exe" : "sqlsim";
        if (engine == "sqlsim")
        {
            var architecture = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "ARM64" : "x64";
            yield return Path.Combine(AppContext.BaseDirectory, "sqlsim", executableName);
            yield return Path.Combine(AppContext.BaseDirectory, executableName);
            yield return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "sqlsim", architecture, executableName));
            yield return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
                "..", "..", "..", "..", "..", "sqlsim", "build",
                OperatingSystem.IsWindows() ? "x64" : "linux-x64",
                OperatingSystem.IsWindows() ? Path.Combine("Release", executableName) : executableName));
        }
        else
        {
            yield return Path.Combine(AppContext.BaseDirectory, "sqlpysim", "sqlpysim.py");
            yield return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "sqlpysim", "sqlpysim.py"));
            yield return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
                "..", "..", "..", "..", "..", "sqlpysim", "sqlpysim.py"));
        }
    }
}
