using System.Collections.ObjectModel;
using System.Data;
using System.Security;
using Microsoft.Data.SqlClient;

namespace SqlsimStudio;

internal sealed class QueryStoreCollector : IAsyncDisposable
{
    private const string SnapshotSql = """
        /* sqlsim Studio Query Store snapshot */
        SELECT
            q.query_id,
            p.plan_id,
            rs.execution_type,
            CONVERT(nvarchar(4000), qt.query_sql_text) AS query_sql_text,
            SUM(CONVERT(bigint, rs.count_executions)) AS count_executions,
            SUM(CONVERT(float, rs.avg_duration) * rs.count_executions) AS total_duration_us,
            SUM(CONVERT(float, rs.avg_cpu_time) * rs.count_executions) AS total_cpu_us,
            SUM(CONVERT(float, rs.avg_logical_io_reads) * rs.count_executions) AS total_logical_reads,
            SUM(CONVERT(float, rs.avg_logical_io_writes) * rs.count_executions) AS total_logical_writes,
            SUM(CONVERT(float, rs.avg_physical_io_reads) * rs.count_executions) AS total_physical_reads,
            SUM(CONVERT(float, rs.avg_rowcount) * rs.count_executions) AS total_rows
        FROM sys.query_store_query_text AS qt
        INNER JOIN sys.query_store_query AS q ON q.query_text_id = qt.query_text_id
        INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
        INNER JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
        WHERE q.is_internal_query = 0
          AND qt.query_sql_text NOT LIKE '%sqlsim Studio Query Store snapshot%'
                    AND (@query_text IS NULL OR
                             LTRIM(RTRIM(CONVERT(nvarchar(max), qt.query_sql_text))) = @query_text)
        GROUP BY q.query_id, p.plan_id, rs.execution_type, CONVERT(nvarchar(4000), qt.query_sql_text);
        """;

    private readonly SqlConnection connection;
    private readonly SecureString? securePassword;
    private readonly IReadOnlyDictionary<QueryStoreKey, QueryStoreAggregate> before;
    private readonly string? queryText;

    private QueryStoreCollector(
        SqlConnection connection,
        SecureString? securePassword,
        IReadOnlyDictionary<QueryStoreKey, QueryStoreAggregate> before,
        string? queryText)
    {
        this.connection = connection;
        this.securePassword = securePassword;
        this.before = before;
        this.queryText = queryText;
    }

    public static async Task<QueryStoreCollector> StartAsync(
        QueryRunRequest request,
        string? secret,
        CancellationToken cancellationToken = default)
    {
        var (connection, securePassword) = CreateConnection(request, secret);

        try
        {
            await connection.OpenAsync(cancellationToken);
            await EnsureAvailableAsync(connection, cancellationToken);
            var queryText = request.Mode == "query" ? request.Query?.Trim() : null;
            var before = await CaptureAsync(connection, queryText, cancellationToken);
            return new QueryStoreCollector(connection, securePassword, before, queryText);
        }
        catch
        {
            await connection.DisposeAsync();
            securePassword?.Dispose();
            throw;
        }
    }

    public static async Task ValidateAsync(
        QueryRunRequest request,
        string? secret,
        CancellationToken cancellationToken = default)
    {
        var (connection, securePassword) = CreateConnection(request, secret);
        try
        {
            await connection.OpenAsync(cancellationToken);
            await EnsureAvailableAsync(connection, cancellationToken);
        }
        finally
        {
            await connection.DisposeAsync();
            securePassword?.Dispose();
        }
    }

    private static (SqlConnection Connection, SecureString? SecurePassword) CreateConnection(
        QueryRunRequest request,
        string? secret)
    {
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = request.Server,
            InitialCatalog = request.Database,
            Encrypt = true,
            TrustServerCertificate = request.TrustServerCertificate,
            ConnectTimeout = 15,
            ApplicationName = "sqlsim Studio Query Store"
        };

        SecureString? securePassword = null;
        var connection = new SqlConnection(builder.ConnectionString);
        switch (request.Authentication)
        {
            case "integrated":
                builder.IntegratedSecurity = true;
                connection.ConnectionString = builder.ConnectionString;
                break;
            case "sql":
                securePassword = ToSecureString(secret!);
                connection.Credential = new SqlCredential(request.Username!, securePassword);
                break;
            case "token":
                connection.AccessToken = secret!;
                break;
            default:
                connection.Dispose();
                throw new InvalidOperationException(
                    "Query Store collection currently supports integrated, SQL, and access-token authentication.");
        }
        return (connection, securePassword);
    }

    public async Task<QueryStoreDeltaResult> CompleteAsync(CancellationToken cancellationToken = default)
    {
        var after = await CaptureAsync(connection, queryText, cancellationToken);
        var deltas = new List<QueryStoreQueryDelta>();

        foreach (var (key, current) in after)
        {
            before.TryGetValue(key, out var previous);
            var executionCount = current.ExecutionCount - (previous?.ExecutionCount ?? 0);
            if (executionCount <= 0)
            {
                continue;
            }

            var duration = current.TotalDurationUs - (previous?.TotalDurationUs ?? 0);
            var cpu = current.TotalCpuUs - (previous?.TotalCpuUs ?? 0);
            var logicalReads = current.TotalLogicalReads - (previous?.TotalLogicalReads ?? 0);
            var logicalWrites = current.TotalLogicalWrites - (previous?.TotalLogicalWrites ?? 0);
            var physicalReads = current.TotalPhysicalReads - (previous?.TotalPhysicalReads ?? 0);
            var rows = current.TotalRows - (previous?.TotalRows ?? 0);

            deltas.Add(new QueryStoreQueryDelta(
                key.QueryId,
                key.PlanId,
                key.ExecutionType,
                current.QueryText,
                executionCount,
                duration / executionCount / 1000.0,
                cpu / executionCount / 1000.0,
                logicalReads / executionCount,
                logicalWrites / executionCount,
                physicalReads / executionCount,
                rows / executionCount));
        }

        var ordered = deltas
            .OrderByDescending(delta => delta.ExecutionCount)
            .ThenByDescending(delta => delta.AverageDurationMs)
            .Take(500)
            .ToArray();

        return new QueryStoreDeltaResult(
            "aggregate_delta",
            queryText is null
                ? "Query Store values are aggregated and can include other queries executed during the run."
                : "Query Store values are aggregated and can include the same query executed by other sessions during the run.",
            ordered.Sum(delta => delta.ExecutionCount),
            ordered);
    }

    public async ValueTask DisposeAsync()
    {
        await connection.DisposeAsync();
        securePassword?.Dispose();
    }

    private static async Task EnsureAvailableAsync(
        SqlConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT actual_state_desc
            FROM sys.database_query_store_options;
            """;
        command.CommandTimeout = 15;
        var state = Convert.ToString(await command.ExecuteScalarAsync(cancellationToken));
        if (!string.Equals(state, "READ_WRITE", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Query Store must be READ_WRITE for aggregate delta collection; current state is {state ?? "unavailable"}.");
        }
    }

    private static async Task<IReadOnlyDictionary<QueryStoreKey, QueryStoreAggregate>> CaptureAsync(
        SqlConnection connection,
        string? queryText,
        CancellationToken cancellationToken)
    {
        var values = new Dictionary<QueryStoreKey, QueryStoreAggregate>();
        await using var command = connection.CreateCommand();
        command.CommandText = SnapshotSql;
        command.CommandTimeout = 30;
        command.Parameters.Add("@query_text", SqlDbType.NVarChar, -1).Value =
            queryText is null ? DBNull.Value : queryText;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var key = new QueryStoreKey(reader.GetInt64(0), reader.GetInt64(1), reader.GetByte(2));
            values[key] = new QueryStoreAggregate(
                reader.GetString(3),
                reader.GetInt64(4),
                reader.GetDouble(5),
                reader.GetDouble(6),
                reader.GetDouble(7),
                reader.GetDouble(8),
                reader.GetDouble(9),
                reader.GetDouble(10));
        }
        return new ReadOnlyDictionary<QueryStoreKey, QueryStoreAggregate>(values);
    }

    private static SecureString ToSecureString(string value)
    {
        var secure = new SecureString();
        foreach (var character in value)
        {
            secure.AppendChar(character);
        }
        secure.MakeReadOnly();
        return secure;
    }
}

internal sealed record QueryStoreKey(long QueryId, long PlanId, byte ExecutionType);

internal sealed record QueryStoreAggregate(
    string QueryText,
    long ExecutionCount,
    double TotalDurationUs,
    double TotalCpuUs,
    double TotalLogicalReads,
    double TotalLogicalWrites,
    double TotalPhysicalReads,
    double TotalRows);

internal sealed record QueryStoreDeltaResult(
    string Source,
    string Warning,
    long ExecutionCount,
    IReadOnlyList<QueryStoreQueryDelta> Queries);

internal sealed record QueryStoreQueryDelta(
    long QueryId,
    long PlanId,
    byte ExecutionType,
    string QueryText,
    long ExecutionCount,
    double AverageDurationMs,
    double AverageCpuMs,
    double AverageLogicalReads,
    double AverageLogicalWrites,
    double AveragePhysicalReads,
    double AverageRows);
