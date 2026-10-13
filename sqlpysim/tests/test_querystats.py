import contextlib
import io
import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import sqlpysim


class FakeCursor:
    def __init__(self):
        self.messages = []
        self.description = None
        self.rowcount = -1
        self.executed = []

    def execute(self, sql):
        self.executed.append(sql)
        self.messages = []
        if sql.startswith("SET STATISTICS"):
            self.description = None
            return self
        if "@@SPID" in sql:
            self.description = [("spid",)]
            return self
        self.description = [("value",)]
        return self

    def fetchone(self):
        return (57,)

    def fetchall(self):
        self.messages = [
            ("01000", "SQL Server parse and compile time: CPU time = 1 ms, elapsed time = 2 ms."),
            ("01000", "[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]"
                      "Table '[sys].[t]'. Scan count 1, logical reads 7, physical reads 1, read-ahead reads 2."),
            ("01000", "SQL Server Execution Times: CPU time = 5 ms, elapsed time = 6 ms."),
        ]
        return [(1,), (2,)]

    def nextset(self):
        self.description = None
        return False

    def close(self):
        pass


class FakeConnection:
    def __init__(self):
        self.cursor_instance = FakeCursor()

    def cursor(self):
        return self.cursor_instance


class QueryStatsTests(unittest.TestCase):
    def test_parser_preserves_last_and_sum_semantics(self):
        stats = sqlpysim.QueryExecutionStats()
        messages = [
            "SQL Server parse and compile time: CPU time = 1 ms, elapsed time = 2 ms.",
            "SQL Server Execution Times: CPU time = 3 ms, elapsed time = 4 ms.",
            "SQL Server Execution Times: CPU time = 5 ms, elapsed time = 6 ms.",
            "Table 't'. Scan count 1, logical reads 1,234, physical reads 2, read-ahead reads 3.",
        ]

        self.assertTrue(all(
            sqlpysim.QueryStatsCollector.parse_message(message, stats)
            for message in messages
        ))
        self.assertEqual(stats.server_cpu_sum_ms, 8)
        self.assertEqual(stats.server_cpu_ms, 5)
        self.assertEqual(stats.server_elapsed_sum_ms, 10)
        self.assertEqual(stats.server_elapsed_ms, 6)
        self.assertEqual(stats.logical_reads, 1234)

    def test_collector_aggregates_successes_and_failures(self):
        collector = sqlpysim.QueryStatsCollector(["SELECT 1"])
        collector.record("SELECT 1", sqlpysim.QueryExecutionStats(
            total_elapsed_ms=8, logical_reads=4, row_count=1))
        collector.record("SELECT 1", sqlpysim.QueryExecutionStats(
            total_elapsed_ms=12, logical_reads=6, row_count=1))
        collector.record("SELECT 1", sqlpysim.QueryExecutionStats(success=False))

        payload = collector.to_dict()
        query = payload["queries"][0]
        self.assertEqual(
            query["total_elapsed_ms"],
            {"avg": 10.0, "min": 8, "max": 12}
        )
        self.assertEqual(query["executions"], 2)
        self.assertEqual(query["failures"], 1)
        self.assertEqual(payload["totals"]["logical_reads"], 10)
        self.assertEqual(payload["totals"]["total_rows"], 2)

    def test_executor_collects_statistics_time_and_io_messages(self):
        executor = sqlpysim.QueryExecutor(
            FakeConnection(), quiet=True, query_stats=True)
        executor.enable_query_stats()
        result = executor.execute_batch("SELECT value FROM t", 1)

        self.assertEqual(
            executor.connection.cursor_instance.executed[:2],
            ["SELECT CONVERT(bigint, @@SPID)",
             "SET STATISTICS TIME ON; SET STATISTICS IO ON"],
        )
        self.assertEqual(result.query_stats.spid, 57)
        self.assertTrue(result.success)
        self.assertEqual(result.rows_affected, 2)
        self.assertEqual(result.messages, [])
        self.assertEqual(result.query_stats.server_elapsed_ms, 6)
        self.assertEqual(result.query_stats.server_elapsed_sum_ms, 6)
        self.assertEqual(result.query_stats.server_cpu_ms, 5)
        self.assertEqual(result.query_stats.compile_elapsed_ms, 2)
        self.assertEqual(result.query_stats.logical_reads, 7)
        self.assertEqual(result.query_stats.row_count, 2)

    def test_json_output_contains_query_stats_object(self):
        collector = sqlpysim.QueryStatsCollector(["SELECT 1"])
        collector.record("SELECT 1", sqlpysim.QueryExecutionStats(
            total_elapsed_ms=2, logical_reads=7, row_count=1))
        metrics = sqlpysim.MetricsCollector()
        metrics.start_time = 1
        metrics.end_time = 2
        config = sqlpysim.WorkloadConfig(json_output=True, query_stats=True)

        previous_output = sqlpysim.output
        sqlpysim.output = sqlpysim.TimestampOutput(json_mode=True)
        stream = io.StringIO()
        try:
            with contextlib.redirect_stdout(stream):
                sqlpysim.print_json_output(
                    sqlpysim.ConnectionConfig(), config, ["SELECT 1"],
                    metrics, True, query_stats=collector)
        finally:
            sqlpysim.output = previous_output

        document = json.loads(stream.getvalue())
        self.assertEqual(document["query_stats"]["totals"]["logical_reads"], 7)
        self.assertNotIn("query_plan_hash", document["query_stats"]["queries"][0])

    def test_warning_messages_are_retained_in_final_and_snapshot_state(self):
        metrics = sqlpysim.MetricsCollector()
        for index in range(12):
            metrics.record_warning(f"warning {index}")

        state = metrics.get_snapshot_state()
        self.assertEqual(state["total_warnings"], 12)
        self.assertEqual(len(state["recent_warnings"]), 10)
        self.assertEqual(state["recent_warnings"][0].message, "warning 2")

        metrics.start_time = 1
        metrics.end_time = 2
        config = sqlpysim.WorkloadConfig(json_output=True)
        previous_output = sqlpysim.output
        sqlpysim.output = sqlpysim.TimestampOutput(json_mode=True)
        stream = io.StringIO()
        try:
            with contextlib.redirect_stdout(stream):
                sqlpysim.print_json_output(
                    sqlpysim.ConnectionConfig(), config, ["SELECT 1"],
                    metrics, True,
                )
        finally:
            sqlpysim.output = previous_output

        warnings = json.loads(stream.getvalue())["metrics"]["warnings"]
        self.assertEqual(warnings["total"], 12)
        self.assertEqual(len(warnings["list"]), 10)
        self.assertEqual(warnings["list"][0]["type"], "odbc_warning")
        self.assertEqual(warnings["list"][0]["message"], "warning 2")

    def test_driver_prefix_strip_keeps_server_brackets(self):
        strip = sqlpysim.QueryExecutor._strip_odbc_prefix
        cases = {
            "[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Table '[sys].[sysschobjs]'. Scan count 1":
                "Table '[sys].[sysschobjs]'. Scan count 1",
            "[Microsoft][ODBC Driver 18 for SQL Server][SQL Server][INFO] first [x] message":
                "[INFO] first [x] message",
            "[unixODBC][Driver Manager]Data source name not found":
                "Data source name not found",
            "[INFO] no driver prefix": "[INFO] no driver prefix",
            "plain message": "plain message",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(strip(raw), expected)

    def test_executor_retains_driver_warning_message(self):
        cursor = FakeCursor()
        cursor.messages = [
            ("01003", "Warning: Null value is eliminated by an aggregate operation.")
        ]
        result = sqlpysim.BatchResult(1, "SELECT SUM(value) FROM t")

        warning_count = sqlpysim.QueryExecutor._capture_messages(cursor, result)

        self.assertEqual(warning_count, 1)
        self.assertEqual(
            result.warnings,
            ["Warning: Null value is eliminated by an aggregate operation."],
        )


if __name__ == "__main__":
    unittest.main()