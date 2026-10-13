#!/usr/bin/env python3
"""
SQL Workload Simulator (sqlpysim) - Python Edition

A Python-based SQL workload simulator using the mssql-python driver.
Shares sqlsim's core query and workload interface, with documented differences.

100% of the code, scripts, and documentation for sqlpysim was developed 
with GitHub Copilot in Visual Studio Code using various AI models, 
but 100% orchestrated by Bob Ward.
"""

import sys
import os
import argparse
import json
import time
import re
import threading
import statistics
import tempfile
from datetime import datetime
from dataclasses import dataclass, field
from typing import List, Optional, Any, Dict
from enum import Enum
from concurrent.futures import ThreadPoolExecutor, as_completed

# Version must match sqlsim
__version__ = "1.0.0"

# Try to import mssql-python driver
try:
    from mssql_python import connect as mssql_connect
    import mssql_python as _mssql_module
    _mssql_driver_version = getattr(_mssql_module, '__version__', 'unknown')
except ImportError:
    mssql_connect = None
    _mssql_driver_version = 'not installed'


SENSITIVE_CONNECTION_VALUE = re.compile(
    r'(PWD|Password|UID|Username|User ID|UserId|AccessToken|Access Token)='
    r'(?:\{(?:}}|[^}])*\}|[^;]*)',
    flags=re.IGNORECASE
)


def mask_connection_string(connection_string: str) -> str:
    """Mask credentials and tokens in an ODBC connection string."""
    return SENSITIVE_CONNECTION_VALUE.sub(r'\1=********', connection_string)


def quote_connection_value(value: str) -> str:
    """Brace an ODBC connection-string value and escape closing braces."""
    return "{" + value.replace("}", "}}") + "}"


def sanitize_error_message(message: str) -> str:
    """Mask credentials and remove terminal controls before reporting an error."""
    message = mask_connection_string(message)
    message = ''.join(character for character in message if character >= ' ' or character in '\n\r\t')
    return message[:1000]


def mask_command_line(arguments: List[str]) -> str:
    """Mask sensitive CLI values before displaying the command line."""
    masked = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]

        if argument in ('-U', '-P', '-T'):
            masked.append(argument)
            if index + 1 < len(arguments):
                masked.append('********')
                index += 2
                continue
        elif argument == '-c':
            masked.append(argument)
            if index + 1 < len(arguments):
                masked.append(mask_connection_string(arguments[index + 1]))
                index += 2
                continue
        elif len(argument) > 2 and argument.startswith(('-U', '-P', '-T')):
                masked.append(argument[:2] + '********')
                index += 1
                continue

        masked.append(argument)
        index += 1

    return ' '.join(masked)


# =============================================================================
# Data Classes
# =============================================================================

class AuthMethod(Enum):
    """Authentication methods supported by sqlpysim."""
    WINDOWS = "Windows"
    SQL_AUTH = "SQL"
    ENTRA_INTERACTIVE = "EntraInteractive"
    ENTRA_INTEGRATED = "EntraIntegrated"
    ENTRA_MSI = "EntraMSI"
    ENTRA_SERVICE_PRINCIPAL = "EntraServicePrincipal"
    TOKEN = "Token"


@dataclass
class ConnectionConfig:
    """Connection configuration."""
    server: str = "localhost"
    database: Optional[str] = None
    auth_method: AuthMethod = AuthMethod.WINDOWS
    username: Optional[str] = None
    password: Optional[str] = None
    access_token: Optional[str] = None
    # The driver reserves the application name and always reports
    # "MSSQL-Python" to the server, so this records what SQL Server will
    # actually see rather than a value the user asked for. -app is refused.
    app_name: str = "MSSQL-Python"
    login_timeout: int = 0  # 0 = driver default
    query_timeout: int = 0  # 0 = driver default
    encrypt: str = ""  # "", "yes", "no", "strict"
    trust_server_certificate: bool = False
    read_only_intent: bool = False
    multi_subnet_failover: bool = False
    retry_count: int = 0
    retry_delay: int = 10
    raw_connection_string: Optional[str] = None  # For -c option


@dataclass
class WorkloadEntry:
    """One group from a workload file.

    Mirrors sqlsim's WorkloadEntry. A group is a set of threads all running
    the same batches with the same iteration count and think time.
    """
    file: Optional[str] = None             # SQL script path, mutually exclusive with queries
    queries: List[str] = field(default_factory=list)  # Inline queries, mutually exclusive with file
    threads: int = 1                       # Threads for this group
    iterations: int = 1                    # Iterations per thread, ignored when duration_seconds > 0
    duration_seconds: int = 0              # Run for this long instead of counting iterations
    think_time_ms: int = 0                 # Delay between iterations, 0 for a tight loop
    ramp_batch_size: int = 0               # Threads to launch per batch, 0 for all at once
    ramp_delay_ms: int = 500               # Delay between ramp batches


@dataclass
class ThreadAssignment:
    """One thread's share of a workload, after groups are expanded.

    sqlsim expands each group into its thread count so every worker carries
    its own query list, iteration count and think time. Matching that keeps
    the two tools' concurrency behaviour identical.
    """
    queries: List[str] = field(default_factory=list)
    iterations: int = 1
    duration_seconds: int = 0
    workload_index: int = 0                # Which group this came from, for display
    think_time_ms: int = 0


@dataclass
class WorkloadConfig:
    """Workload configuration."""
    threads: int = 1
    iterations: int = 1
    prepared_statements: bool = False
    quiet_mode: bool = False
    verbose: bool = False
    stop_on_error: bool = False
    json_output: bool = False
    final_json_output: bool = False
    stream_json: bool = False
    output_file: Optional[str] = None
    reconnect_per_iteration: bool = False
    use_connection_pooling: bool = False
    input_file: Optional[str] = None
    query_stats: bool = False
    query_stats_interval: int = 0
    query_stats_file: Optional[str] = None
    # Workload file mode
    workload_file: Optional[str] = None
    workload_entries: List[WorkloadEntry] = field(default_factory=list)
    thread_assignments: List[ThreadAssignment] = field(default_factory=list)
    ramp_batch_size: int = 0
    ramp_delay_ms: int = 500
    warnings: List[str] = field(default_factory=list)


class WorkloadFileParser:
    """Parse a sqlsim workload JSON file.

    The format allows // line comments, which json.loads rejects, so they are
    stripped first. Comments inside string values must survive, which is why
    this walks the text rather than using a regular expression.

    Validation deliberately mirrors sqlsim's, including message wording, so a
    file rejected by one tool is rejected by the other for the same stated
    reason.
    """

    @staticmethod
    def strip_comments(content: str) -> str:
        out = []
        in_string = False
        escaped = False
        index = 0
        while index < len(content):
            char = content[index]
            if in_string:
                out.append(char)
                if escaped:
                    escaped = False
                elif char == '\\':
                    escaped = True
                elif char == '"':
                    in_string = False
                index += 1
                continue
            if char == '"':
                in_string = True
                out.append(char)
                index += 1
                continue
            if char == '/' and index + 1 < len(content) and content[index + 1] == '/':
                while index < len(content) and content[index] != '\n':
                    index += 1
                continue
            out.append(char)
            index += 1
        return ''.join(out)

    @classmethod
    def parse(cls, file_path: str) -> List[WorkloadEntry]:
        try:
            with open(file_path, 'r', encoding='utf-8-sig') as handle:
                content = handle.read()
        except OSError as error:
            raise ValueError(f"Cannot open workload file: {file_path}") from error
        return cls.parse_content(content, file_path)

    @classmethod
    def parse_content(cls, content: str, source_name: str = "<string>") -> List[WorkloadEntry]:
        try:
            document = json.loads(cls.strip_comments(content))
        except json.JSONDecodeError as error:
            raise ValueError(f"Workload file {source_name}: invalid JSON: {error}") from error

        if not isinstance(document, dict):
            raise ValueError(f"Workload file {source_name}: expected a JSON object")

        raw_entries = document.get("workloads")
        if not isinstance(raw_entries, list) or not raw_entries:
            raise ValueError(f"Workload file {source_name}: \"workloads\" key is required")

        global_duration = cls._optional_int(document, "duration_seconds", 0, source_name)
        global_ramp_batch = cls._optional_int(document, "ramp_batch_size", 0, source_name)
        global_ramp_delay = cls._optional_int(document, "ramp_delay_ms", 500, source_name)

        entries: List[WorkloadEntry] = []
        for position, raw in enumerate(raw_entries, start=1):
            if not isinstance(raw, dict):
                raise ValueError(
                    f"Workload file {source_name}: workload entry {position} must be an object")

            entry = WorkloadEntry(
                file=raw.get("file"),
                queries=[str(q) for q in raw.get("queries", [])],
                threads=cls._optional_int(raw, "threads", 1, source_name),
                iterations=cls._optional_int(raw, "iterations", 1, source_name),
                think_time_ms=cls._optional_int(raw, "think_time_ms", 0, source_name),
            )

            if not entry.file and not entry.queries:
                raise ValueError(
                    f"Workload file {source_name}: workload entry {position} "
                    "must have either \"file\" or \"queries\"")
            if entry.file and entry.queries:
                raise ValueError(
                    f"Workload file {source_name}: workload entry {position} "
                    "cannot have both \"file\" and \"queries\"")
            if entry.threads < 1:
                raise ValueError(
                    f"Workload file {source_name}: workload entry {position} threads must be >= 1")
            if global_duration == 0 and entry.iterations < 1:
                raise ValueError(
                    f"Workload file {source_name}: workload entry {position} "
                    "iterations must be >= 1 (or use top-level \"duration_seconds\")")

            entries.append(entry)

        # Global settings propagate to every entry, as they do in sqlsim, so
        # the rest of the pipeline reads them per group without special cases.
        if global_duration > 0:
            for entry in entries:
                entry.duration_seconds = global_duration
        if global_ramp_batch > 0:
            for entry in entries:
                entry.ramp_batch_size = global_ramp_batch
                entry.ramp_delay_ms = global_ramp_delay

        return entries

    @staticmethod
    def _optional_int(source: dict, key: str, default: int, source_name: str) -> int:
        if key not in source or source[key] is None:
            return default
        value = source[key]
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError(f"Workload file {source_name}: \"{key}\" must be an integer")
        return value


@dataclass
class BatchResult:
    """Result from executing a single batch."""
    batch_index: int
    sql: str
    success: bool = False
    rows_affected: int = 0
    execution_time_ms: float = 0.0
    error: Optional[str] = None
    # Multiple result sets support - each entry is (columns, rows)
    result_sets: List[tuple] = field(default_factory=list)  # [(columns, rows), ...]
    # Legacy single result set (for backward compatibility)
    columns: List[str] = field(default_factory=list)
    rows: List[tuple] = field(default_factory=list)
    messages: List[str] = field(default_factory=list)  # PRINT statements
    warning_count: int = 0  # Count of ODBC warnings (non-01000 SQLSTATE)
    warnings: List[str] = field(default_factory=list)
    query_stats: Optional['QueryExecutionStats'] = None


@dataclass
class QueryExecutionStats:
    """Per-execution server and client query statistics."""
    total_elapsed_ms: float = 0.0
    server_elapsed_sum_ms: float = 0.0
    server_cpu_sum_ms: float = 0.0
    server_elapsed_ms: float = 0.0
    server_cpu_ms: float = 0.0
    compile_elapsed_ms: float = 0.0
    compile_cpu_ms: float = 0.0
    logical_reads: int = 0
    physical_reads: int = 0
    read_ahead_reads: int = 0
    row_count: int = -1
    spid: int = 0
    success: bool = True


class QueryStatsCollector:
    """Thread-safe per-query aggregation matching sqlsim's JSON contract."""

    _TIME_PATTERN = re.compile(
        r'CPU time\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*ms,\s*'
        r'elapsed time\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*ms',
        re.IGNORECASE
    )
    _IO_PATTERN = re.compile(
        r"Table\s+'[^']*'.*?logical reads\s+([0-9,]+),\s*"
        r'physical reads\s+([0-9,]+).*?read-ahead reads\s+([0-9,]+)',
        re.IGNORECASE | re.DOTALL
    )
    _METRIC_FIELDS = (
        'total_elapsed_ms', 'server_elapsed_ms', 'server_cpu_ms',
        'server_elapsed_sum_ms', 'server_cpu_sum_ms', 'compile_elapsed_ms',
        'logical_reads', 'physical_reads', 'read_ahead_reads'
    )

    def __init__(self, queries: List[str]):
        self._lock = threading.Lock()
        # Running totals per query: memory depends on distinct queries, not
        # executions, so long runs and periodic snapshots stay cheap.
        self._aggregates: Dict[str, Dict[str, Any]] = {}
        for query in queries:
            self._aggregates.setdefault(query, self._new_aggregate())

    @classmethod
    def _new_aggregate(cls) -> Dict[str, Any]:
        return {
            'executions': 0,
            'failures': 0,
            'spids': set(),
            'metrics': {name: [0, None, None] for name in cls._METRIC_FIELDS},
            'rows': [0, 0, None, None]
        }

    @classmethod
    def parse_message(cls, message: str, stats: QueryExecutionStats) -> bool:
        """Parse one SQL Server statistics diagnostic into an execution record."""
        normalized = message.lstrip()
        parsed = False

        if normalized.startswith('SQL Server parse and compile time'):
            for cpu_value, elapsed_value in cls._TIME_PATTERN.findall(message):
                stats.compile_cpu_ms += float(cpu_value)
                stats.compile_elapsed_ms += float(elapsed_value)
                parsed = True
        elif normalized.startswith('SQL Server Execution Times'):
            for cpu_value, elapsed_value in cls._TIME_PATTERN.findall(message):
                cpu_ms = float(cpu_value)
                elapsed_ms = float(elapsed_value)
                stats.server_cpu_sum_ms += cpu_ms
                stats.server_elapsed_sum_ms += elapsed_ms
                stats.server_cpu_ms = cpu_ms
                stats.server_elapsed_ms = elapsed_ms
                parsed = True
        elif normalized.startswith("Table '"):
            for logical_value, physical_value, read_ahead_value in cls._IO_PATTERN.findall(message):
                stats.logical_reads += int(logical_value.replace(',', ''))
                stats.physical_reads += int(physical_value.replace(',', ''))
                stats.read_ahead_reads += int(read_ahead_value.replace(',', ''))
                parsed = True

        return parsed

    def record(self, query: str, stats: QueryExecutionStats):
        """Record one completed or failed execution."""
        with self._lock:
            aggregate = self._aggregates.get(query)
            if aggregate is None:
                aggregate = self._aggregates[query] = self._new_aggregate()
            # Failed executions keep their SPID, as in sqlsim, so a session
            # that only ever failed is still visible.
            if stats.spid > 0:
                aggregate['spids'].add(stats.spid)
            if not stats.success:
                aggregate['failures'] += 1
                return
            aggregate['executions'] += 1
            for name, metric in aggregate['metrics'].items():
                value = getattr(stats, name)
                metric[0] += value
                metric[1] = value if metric[1] is None else min(metric[1], value)
                metric[2] = value if metric[2] is None else max(metric[2], value)
            if stats.row_count >= 0:
                rows = aggregate['rows']
                rows[0] += 1
                rows[1] += stats.row_count
                rows[2] = stats.row_count if rows[2] is None else min(rows[2], stats.row_count)
                rows[3] = stats.row_count if rows[3] is None else max(rows[3], stats.row_count)

    @staticmethod
    def _metric(count: int, total: Any, minimum: Any, maximum: Any) -> Dict[str, Any]:
        if not count:
            return {'avg': 0.0, 'min': 0, 'max': 0}
        return {'avg': total / count, 'min': minimum, 'max': maximum}

    def to_dict(self) -> Dict[str, Any]:
        """Return sqlsim-compatible per-query aggregates and totals."""
        queries = []
        total_fields = {
            'total_elapsed_ms': 0.0,
            'server_elapsed_ms': 0.0,
            'server_cpu_ms': 0.0,
            'server_elapsed_sum_ms': 0.0,
            'server_cpu_sum_ms': 0.0,
            'compile_elapsed_ms': 0.0,
            'logical_reads': 0,
            'physical_reads': 0,
            'read_ahead_reads': 0,
            'total_rows': 0,
            'executions': 0,
            'failures': 0
        }
        has_row_count = False

        with self._lock:
            for query, aggregate in self._aggregates.items():
                executions = aggregate['executions']
                failures = aggregate['failures']
                if executions == 0 and failures == 0:
                    continue
                spids = sorted(aggregate['spids'])
                entry = {'query': query, 'spids': spids[:10], 'spid_count': len(spids)}
                for name, (total, minimum, maximum) in aggregate['metrics'].items():
                    entry[name] = self._metric(executions, total, minimum, maximum)
                    total_fields[name] += total
                entry['executions'] = executions
                entry['failures'] = failures
                row_count, row_total, row_min, row_max = aggregate['rows']
                if row_count:
                    entry['row_count'] = self._metric(row_count, row_total, row_min, row_max)
                    total_fields['total_rows'] += row_total
                    has_row_count = True

                queries.append(entry)
                total_fields['executions'] += executions
                total_fields['failures'] += failures

        if not has_row_count:
            del total_fields['total_rows']
        return {'queries': queries, 'totals': total_fields}


@dataclass
class Statistics:
    """Aggregated statistics for operations."""
    total: int = 0
    successful: int = 0
    failed: int = 0
    total_time_ms: float = 0.0
    avg_ms: float = 0.0
    min_ms: float = 0.0
    max_ms: float = 0.0
    p50_ms: float = 0.0
    p95_ms: float = 0.0
    p99_ms: float = 0.0


@dataclass
class ErrorEntry:
    """Error entry for tracking."""
    error_type: str
    timestamp: str
    message: str


@dataclass
class ThreadConnectionResult:
    """Per-thread connection result for verbose JSON output."""
    thread_id: int
    latency_ms: float
    success: bool
    error: Optional[str] = None


@dataclass
class IterationResult:
    """Per-iteration result within a thread."""
    iteration: int
    total_query_ms: float
    queries_executed: int
    queries_failed: int


@dataclass
class ThreadIterationMetrics:
    """Per-thread iteration metrics for verbose JSON output."""
    thread_id: int
    iterations: List[IterationResult] = field(default_factory=list)


# =============================================================================
# Timestamp Output Helper
# =============================================================================

class TimestampOutput:
    """Handles timestamped output like sqlsim."""
    
    def __init__(self, output_file: Optional[str] = None, json_mode: bool = False):
        self.output_file = output_file
        self.json_mode = json_mode
        self._file_handle = None
        self._lock = threading.Lock()
    
    def open(self):
        """Open output file if specified."""
        if self.output_file:
            self._file_handle = open(self.output_file, 'w', encoding='utf-8')
    
    def close(self):
        """Close output file."""
        if self._file_handle:
            self._file_handle.close()
            self._file_handle = None
    
    def _get_timestamp(self) -> str:
        """Get timestamp in sqlsim format: YYYY-MM-DD HH:MM:SS.mmm"""
        now = datetime.now()
        return now.strftime("%Y-%m-%d %H:%M:%S.") + f"{now.microsecond // 1000:03d}"
    
    def write(self, message: str, newline: bool = True):
        """Write timestamped message (non-JSON mode only)."""
        if self.json_mode:
            return
        
        with self._lock:
            timestamp = self._get_timestamp()
            line = f"{timestamp} | {message}"
            if newline:
                line += "\n"
            
            if self._file_handle:
                self._file_handle.write(line)
                self._file_handle.flush()
            else:
                print(line, end="" if not newline else "")
                sys.stdout.flush()
    
    def write_block(self, messages: list, newline: bool = True):
        """Write several lines under one lock.

        Concurrent threads each print whole result sets. Taking the lock per
        line would let one thread's rows appear in the middle of another's,
        so a block that must stay together is written in one go.
        """
        if self.json_mode:
            return

        with self._lock:
            buffer = []
            for message in messages:
                timestamp = self._get_timestamp()
                line = f"{timestamp} | {message}"
                if newline:
                    line += "\n"
                buffer.append(line)
            payload = "".join(buffer)

            if self._file_handle:
                self._file_handle.write(payload)
                self._file_handle.flush()
            else:
                print(payload, end="")
                sys.stdout.flush()

    def write_raw(self, message: str):
        """Write raw message without timestamp (for JSON output)."""
        with self._lock:
            if self._file_handle:
                self._file_handle.write(message)
                self._file_handle.flush()
            else:
                print(message, end="")
                sys.stdout.flush()
    
    def write_error(self, message: str):
        """Write error message to stderr."""
        with self._lock:
            if not self.json_mode:
                timestamp = self._get_timestamp()
                line = f"{timestamp} | {message}\n"
                if self._file_handle:
                    self._file_handle.write(line)
                    self._file_handle.flush()
                else:
                    print(line, end="", file=sys.stderr)
                    sys.stderr.flush()


# Global output handler
output = TimestampOutput()


# =============================================================================
# Connection Manager
# =============================================================================

class ConnectionManager:
    """Manages database connections."""
    
    def __init__(self, config: ConnectionConfig):
        self.config = config
        self.connection: Any = None
        self.connect_time_ms: float = 0.0
        
        if mssql_connect is None:
            raise ImportError(
                "mssql-python driver not installed.\n"
                "Install with: pip install mssql-python"
            )
    
    def build_connection_string(self) -> str:
        """Build connection string based on config."""
        # If raw connection string provided via -c, use it directly
        if self.config.raw_connection_string:
            return self.config.raw_connection_string
        
        parts = [f"Server={self.config.server}"]
        
        if self.config.database:
            parts.append(f"Database={self.config.database}")
        
        # Authentication
        if self.config.auth_method == AuthMethod.WINDOWS:
            parts.append("Trusted_Connection=yes")
        elif self.config.auth_method == AuthMethod.SQL_AUTH:
            parts.append(f"UID={self.config.username}")
            parts.append(f"PWD={self.config.password}")
        elif self.config.auth_method == AuthMethod.ENTRA_INTERACTIVE:
            parts.append("Authentication=ActiveDirectoryInteractive")
        elif self.config.auth_method == AuthMethod.ENTRA_INTEGRATED:
            parts.append("Authentication=ActiveDirectoryIntegrated")
        elif self.config.auth_method == AuthMethod.ENTRA_MSI:
            parts.append("Authentication=ActiveDirectoryMsi")
            if self.config.username:
                parts.append(f"UID={self.config.username}")
        elif self.config.auth_method == AuthMethod.ENTRA_SERVICE_PRINCIPAL:
            parts.append("Authentication=ActiveDirectoryServicePrincipal")
            parts.append(f"UID={quote_connection_value(self.config.username)}")
            parts.append(f"PWD={quote_connection_value(self.config.password)}")
        # TOKEN auth handled separately
        
        # Encryption
        if self.config.encrypt == "strict":
            parts.append("Encrypt=strict")
        elif self.config.encrypt == "yes":
            parts.append("Encrypt=yes")
        elif self.config.encrypt == "no":
            parts.append("Encrypt=no")
        
        if self.config.trust_server_certificate:
            parts.append("TrustServerCertificate=yes")
        elif self.config.encrypt:
            parts.append("TrustServerCertificate=no")
        else:
            parts.append("TrustServerCertificate=yes")

        # Note: APP/Application Name is reserved by mssql-python driver and cannot be set
        
        # Read intent
        if self.config.read_only_intent:
            parts.append("ApplicationIntent=ReadOnly")
        
        # Multi-subnet failover
        if self.config.multi_subnet_failover:
            parts.append("MultiSubnetFailover=yes")
        
        return ";".join(parts)
    
    def get_masked_connection_string(self) -> str:
        """Get connection string with credentials masked."""
        if self.config.raw_connection_string:
            return mask_connection_string(self.config.raw_connection_string)

        parts = [f"Server={self.config.server}"]
        if self.config.database:
            parts.append(f"Database={self.config.database}")

        if self.config.auth_method == AuthMethod.WINDOWS:
            parts.append("Trusted_Connection=yes")
        elif self.config.auth_method == AuthMethod.SQL_AUTH:
            parts.extend(["UID=********", "PWD=********"])
        elif self.config.auth_method == AuthMethod.ENTRA_INTERACTIVE:
            parts.append("Authentication=ActiveDirectoryInteractive")
        elif self.config.auth_method == AuthMethod.ENTRA_INTEGRATED:
            parts.append("Authentication=ActiveDirectoryIntegrated")
        elif self.config.auth_method == AuthMethod.ENTRA_MSI:
            parts.append("Authentication=ActiveDirectoryMsi")
            if self.config.username:
                parts.append("UID=********")
        elif self.config.auth_method == AuthMethod.ENTRA_SERVICE_PRINCIPAL:
            parts.extend([
                "Authentication=ActiveDirectoryServicePrincipal",
                "UID=********",
                "PWD=********",
            ])

        if self.config.encrypt == "strict":
            parts.append("Encrypt=strict")
        elif self.config.encrypt == "yes":
            parts.append("Encrypt=yes")
        elif self.config.encrypt == "no":
            parts.append("Encrypt=no")

        if self.config.trust_server_certificate:
            parts.append("TrustServerCertificate=yes")
        elif self.config.encrypt:
            parts.append("TrustServerCertificate=no")
        else:
            parts.append("TrustServerCertificate=yes")

        if self.config.read_only_intent:
            parts.append("ApplicationIntent=ReadOnly")
        if self.config.multi_subnet_failover:
            parts.append("MultiSubnetFailover=yes")

        return ";".join(parts)
    
    def connect(self) -> 'ConnectionManager':
        """Establish connection with timing."""
        import struct
        
        start_time = time.perf_counter()
        
        conn_str = self.build_connection_string()
        
        # Retry logic
        last_error = None
        for attempt in range(self.config.retry_count + 1):
            try:
                # connect(timeout=) maps to SQL_ATTR_LOGIN_TIMEOUT; the per-statement
                # query timeout is the Connection.timeout property, set after connecting.
                connect_kwargs: Dict[str, Any] = {}
                if self.config.login_timeout > 0:
                    connect_kwargs["timeout"] = self.config.login_timeout

                if self.config.auth_method == AuthMethod.TOKEN:
                    # mssql-python uses attrs_before with SQL_COPT_SS_ACCESS_TOKEN
                    # Token must be encoded as UTF-16LE with length prefix
                    SQL_COPT_SS_ACCESS_TOKEN = 1256
                    token_bytes = self.config.access_token.encode("utf-16le")
                    token_struct = struct.pack(f'<I{len(token_bytes)}s', len(token_bytes), token_bytes)
                    connect_kwargs["attrs_before"] = {SQL_COPT_SS_ACCESS_TOKEN: token_struct}

                self.connection = mssql_connect(conn_str, **connect_kwargs)

                if self.config.query_timeout > 0:
                    self.connection.timeout = self.config.query_timeout

                self.connect_time_ms = (time.perf_counter() - start_time) * 1000
                return self
            except Exception as e:
                last_error = e
                if attempt < self.config.retry_count:
                    time.sleep(self.config.retry_delay)
        
        raise last_error
    
    def close(self):
        """Close connection."""
        if self.connection:
            self.connection.close()
            self.connection = None
    
    def query_server_edition(self) -> str:
        """Query SQL Server edition."""
        try:
            cursor = self.connection.cursor()
            cursor.execute("SELECT SERVERPROPERTY('Edition')")
            row = cursor.fetchone()
            cursor.close()
            return str(row[0]) if row else "Unknown"
        except:
            return "Unknown"

    def query_server_version(self) -> str:
        """Query the SQL Server product version."""
        try:
            cursor = self.connection.cursor()
            cursor.execute("SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))")
            row = cursor.fetchone()
            cursor.close()
            return str(row[0]) if row and row[0] is not None else ""
        except Exception:
            return ""
    
    def __enter__(self):
        return self.connect()
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False


# =============================================================================
# Query Executor
# =============================================================================

class QueryExecutor:
    """Executes SQL queries."""
    
    GO_PATTERN = re.compile(r'^\s*GO\s*$', re.MULTILINE | re.IGNORECASE)
    
    def __init__(self, connection: Any, quiet: bool = False,
                 query_stats: bool = False, verbose: bool = False):
        self.connection = connection
        self.quiet = quiet
        self.query_stats = query_stats
        self.verbose = verbose
        self.spid = 0  # SQL Server session ID, read once when query stats are enabled
        self._cursor = None  # Reusable cursor (like sqlsim's single hstmt_)
    
    @classmethod
    def split_batches(cls, sql: str) -> List[str]:
        """Split SQL into batches on GO statements."""
        batches = cls.GO_PATTERN.split(sql)
        return [b.strip() for b in batches if b.strip()]
    
    def _get_cursor(self):
        """Get or create reusable cursor (matches sqlsim behavior)."""
        if self._cursor is None:
            self._cursor = self.connection.cursor()
        return self._cursor
    
    def close(self):
        """Close the reusable cursor."""
        if self._cursor is not None:
            cursor = self._cursor
            self._cursor = None
            cursor.close()

    def enable_query_stats(self):
        """Enable the same server statistics diagnostics used by sqlsim."""
        cursor = self._get_cursor()
        # Read the session ID once per connection, before statistics are on, so
        # this query adds no diagnostics. Each reconnect creates a new executor.
        try:
            cursor.execute("SELECT CONVERT(bigint, @@SPID)")
            row = cursor.fetchone()
            self.spid = int(row[0]) if row and row[0] is not None else 0
            while cursor.nextset():
                pass
        except Exception:
            self.spid = 0
        cursor.execute("SET STATISTICS TIME ON; SET STATISTICS IO ON")
        while cursor.nextset():
            pass
    
    # Driver and driver-manager tags only. Server text can contain brackets of its own,
    # such as Azure SQL's "Table '[sys].[sysschobjs]'" or a PRINT of "[INFO] ...".
    _ODBC_PREFIX = re.compile(
        r"(?:\[(?:Microsoft|unixODBC|Driver Manager|SQL Server|ODBC [^\]]*)\])+")

    @staticmethod
    def _strip_odbc_prefix(msg_text: str) -> str:
        """Strip ODBC driver prefix from message text.
        e.g., '[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Hello world!' -> 'Hello world!'
        """
        match = QueryExecutor._ODBC_PREFIX.search(msg_text)
        if match and match.end() < len(msg_text):
            return msg_text[match.end():]
        return msg_text
    
    @staticmethod
    def _capture_messages(cursor, result: 'BatchResult',
                          stats: Optional[QueryExecutionStats] = None,
                          show_statistics: bool = False) -> int:
        """Capture PRINT messages from cursor, filtering routine server messages.
        
        Three-tier diagnostic classification (matches sqlsim):
        - Info messages: PRINT statements, RAISERROR sev<=10 (SQLSTATE 01000)
        - ODBC Warnings: 01001, 01003, 01004, etc. (tracked separately)
        - Filtered out: 'Changed database context' and 'Changed language setting'
        
        Returns count of ODBC warnings detected.
        """
        warning_count = 0
        if not hasattr(cursor, 'messages') or not cursor.messages:
            return warning_count
        for msg_tuple in cursor.messages:
            if len(msg_tuple) >= 2:
                msg_text = str(msg_tuple[1])
                msg_text = QueryExecutor._strip_odbc_prefix(msg_text)
                # Filter routine server messages (matches sqlsim)
                # Native error 5701 = "Changed database context to '...'"
                # Native error 5703 = "Changed language setting to '...'"
                if "Changed database context" in msg_text:
                    continue
                if "Changed language setting" in msg_text:
                    continue
                is_statistics = (
                    stats is not None and
                    QueryStatsCollector.parse_message(msg_text, stats)
                )
                # Three-tier classification: check first element for SQLSTATE
                sqlstate = str(msg_tuple[0]) if msg_tuple[0] else ""
                if sqlstate.startswith("01") and sqlstate != "01000":
                    # Non-01000 01xxx state = ODBC warning (01001, 01003, 01004, etc.)
                    warning_count += 1
                    result.warnings.append(msg_text)
                if not is_statistics or show_statistics:
                    result.messages.append(msg_text)
        return warning_count
    
    def execute_batch(self, sql: str, batch_index: int,
                      execution_sql: Optional[str] = None) -> BatchResult:
        """Execute a single batch using reusable cursor."""
        result = BatchResult(
            batch_index=batch_index,
            sql=sql[:100] + "..." if len(sql) > 100 else sql
        )
        if self.query_stats:
            result.query_stats = QueryExecutionStats(spid=self.spid)
        
        start_time = time.perf_counter()
        
        try:
            cursor = self._get_cursor()
            
            cursor.execute(execution_sql or sql)
            
            # Capture PRINT messages from initial execution
            total_warnings = self._capture_messages(
                cursor, result, result.query_stats, self.verbose)
            
            # Fetch all result sets (support multiple SELECT statements in one batch)
            total_rows = 0
            while True:
                if cursor.description:
                    columns = [col[0] for col in cursor.description]
                    if not self.quiet:
                        rows = cursor.fetchall()
                        total_rows += len(rows)
                        result.result_sets.append((columns, rows))
                        # Keep first result set in legacy fields for backward compatibility
                        if not result.columns:
                            result.columns = columns
                            result.rows = rows
                    else:
                        rows = cursor.fetchall()
                        total_rows += len(rows)
                    # mssql-python attaches STATISTICS TIME/IO diagnostics while
                    # fetching. Capture them before nextset() clears them.
                    total_warnings += self._capture_messages(
                        cursor, result, result.query_stats, self.verbose)
                else:
                    # Non-SELECT statement
                    if cursor.rowcount >= 0:
                        total_rows += cursor.rowcount
                
                # Try to move to next result set
                # Wrap in try/except to catch errors from non-first statements
                # in multi-statement batches (matches sqlsim fix from Feb 2026)
                try:
                    if not cursor.nextset():
                        break
                    # Capture messages between result sets
                    total_warnings += self._capture_messages(
                        cursor, result, result.query_stats, self.verbose)
                except Exception as next_err:
                    # Error from a later statement in a multi-statement batch
                    error_msg = self._strip_odbc_prefix(str(next_err))
                    if len(error_msg) > 1000:
                        error_msg = error_msg[:1000]
                    result.error = f"Batch error during result processing: {error_msg}"
                    result.success = False
                    # Close and recreate cursor for next batch
                    self.close()
                    break
            
            # Only set success if no error was encountered during result processing
            if result.error is None:
                result.rows_affected = total_rows
                result.success = True
            result.warning_count = total_warnings
            
        except Exception as e:
            error_msg = str(e)
            if len(error_msg) > 1000:
                error_msg = error_msg[:1000]
            result.error = error_msg
            result.success = False
            # On error, close and recreate cursor for next batch
            self.close()
        
        result.execution_time_ms = (time.perf_counter() - start_time) * 1000
        if result.query_stats is not None:
            result.query_stats.total_elapsed_ms = result.execution_time_ms
            result.query_stats.row_count = result.rows_affected if result.success else -1
            result.query_stats.success = result.success
        return result


# =============================================================================
# Metrics Collector
# =============================================================================

class MetricsCollector:
    """Collects and calculates metrics."""
    
    def __init__(self):
        self._lock = threading.Lock()
        self.connection_times: List[float] = []
        self.execution_times: List[float] = []
        self.connection_successes: int = 0
        self.connection_failures: int = 0
        self.execution_successes: int = 0
        self.execution_failures: int = 0
        self.errors: List[ErrorEntry] = []
        self.warnings: List[ErrorEntry] = []
        self.total_warnings: int = 0
        # The errors list is trimmed to the last ten entries, so it cannot be
        # used to report how many errors occurred. sqlsim keeps a separate
        # running total and so must this, both for the JSON summary and for
        # the live stream.
        self.total_errors: int = 0
        self.thread_connections: List[ThreadConnectionResult] = []
        self.thread_iteration_metrics: Dict[int, ThreadIterationMetrics] = {}
        self.start_time: float = 0.0
        self.end_time: float = 0.0
        self.start_time_iso: str = ""
        self.end_time_iso: str = ""
        self.server_edition: str = ""
        self.server_version: str = ""
        self.first_execution_time: Optional[float] = None
        self.last_execution_time: Optional[float] = None
    
    def record_connection(self, duration_ms: float, success: bool):
        """Record connection operation."""
        with self._lock:
            self.connection_times.append(duration_ms)
            if success:
                self.connection_successes += 1
            else:
                self.connection_failures += 1
    
    def record_execution(self, duration_ms: float, success: bool):
        """Record query execution."""
        now = time.perf_counter()
        with self._lock:
            self.execution_times.append(duration_ms)
            # Snapshots report throughput over the execution window rather than
            # the whole run, so the connection phase does not depress the rate.
            if self.first_execution_time is None:
                self.first_execution_time = now
            self.last_execution_time = now
            if success:
                self.execution_successes += 1
            else:
                self.execution_failures += 1
    
    def record_error(self, message: str, error_type: str = "sql_error"):
        """Record an error."""
        with self._lock:
            message = sanitize_error_message(message)
            timestamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.") + \
                       f"{datetime.now().microsecond // 1000:03d}"
            self.total_errors += 1
            self.errors.append(ErrorEntry(error_type, timestamp, message))
            # Keep only last 10 errors
            if len(self.errors) > 10:
                self.errors = self.errors[-10:]
    
    def get_live_counters(self) -> Dict[str, int]:
        """Read the counters a live stream reports, as one consistent set.

        Taken under the same lock the workers write through so a progress
        event cannot mix values from either side of an update.
        """
        with self._lock:
            return {
                'successful_connections': self.connection_successes,
                'failed_connections': self.connection_failures,
                'successful_executions': self.execution_successes,
                'failed_executions': self.execution_failures,
                'errors': self.total_errors,
            }

    def get_snapshot_state(self) -> Dict[str, Any]:
        """Read everything a periodic snapshot reports, as one consistent set.

        Connection timings, counters, and the recent error and warning lists
        are all taken under a single lock so a snapshot cannot describe two
        different moments in the run.
        """
        with self._lock:
            connection_stats: Dict[str, Any] = {'count': len(self.connection_times)}
            if self.connection_times:
                connection_stats['avg_ms'] = sum(self.connection_times) / len(self.connection_times)
                connection_stats['min_ms'] = min(self.connection_times)
                connection_stats['max_ms'] = max(self.connection_times)
            return {
                'connection_stats': connection_stats,
                'first_execution_time': self.first_execution_time,
                'last_execution_time': self.last_execution_time,
                'total_errors': self.total_errors,
                'total_warnings': self.total_warnings,
                'recent_errors': list(self.errors),
                'recent_warnings': list(self.warnings),
            }

    def record_warning(self, message: str):
        """Record an ODBC warning (non-01000 SQLSTATE, e.g., 01001, 01003, 01004)."""
        with self._lock:
            message = sanitize_error_message(message)
            self.total_warnings += 1
            timestamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S.") + \
                       f"{datetime.now().microsecond // 1000:03d}"
            self.warnings.append(ErrorEntry("odbc_warning", timestamp, message))
            if len(self.warnings) > 10:
                self.warnings = self.warnings[-10:]
    
    def record_thread_connection(self, thread_id: int, latency_ms: float,
                                  success: bool, error: str = None):
        """Record per-thread connection result for verbose JSON."""
        with self._lock:
            self.thread_connections.append(
                ThreadConnectionResult(thread_id, latency_ms, success, error))
    
    def record_thread_iteration(self, thread_id: int, iteration: int,
                                 total_query_ms: float, queries_executed: int,
                                 queries_failed: int):
        """Record per-thread iteration metrics for verbose JSON."""
        with self._lock:
            if thread_id not in self.thread_iteration_metrics:
                self.thread_iteration_metrics[thread_id] = ThreadIterationMetrics(thread_id)
            self.thread_iteration_metrics[thread_id].iterations.append(
                IterationResult(iteration, total_query_ms, queries_executed, queries_failed))
    
    @staticmethod
    def _calculate_stats_from_sorted(sorted_data: List[float]) -> tuple:
        """Calculate min, max, and percentiles from sorted data (matches sqlsim).
        
        Single sort optimization: sort once, extract all stats.
        Uses simple index calculation like sqlsim (no interpolation).
        """
        if not sorted_data:
            return 0.0, 0.0, 0.0, 0.0, 0.0
        
        n = len(sorted_data)
        # Min and max are first and last elements (no extra scan needed)
        min_val = sorted_data[0]
        max_val = sorted_data[-1]
        
        # Calculate percentiles using sqlsim's approach: size * percentile / 100
        p50_idx = n * 50 // 100
        p95_idx = n * 95 // 100
        p99_idx = n * 99 // 100
        
        # Clamp to valid range
        p50_idx = min(p50_idx, n - 1)
        p95_idx = min(p95_idx, n - 1)
        p99_idx = min(p99_idx, n - 1)
        
        return min_val, max_val, sorted_data[p50_idx], sorted_data[p95_idx], sorted_data[p99_idx]
    
    def get_connection_stats(self) -> Statistics:
        """Get connection statistics."""
        stats = Statistics()
        stats.total = len(self.connection_times)
        stats.successful = self.connection_successes
        stats.failed = self.connection_failures
        
        if self.connection_times:
            stats.total_time_ms = sum(self.connection_times)
            stats.avg_ms = stats.total_time_ms / stats.total
            
            # Sort once, extract all stats (matches sqlsim optimization)
            sorted_times = sorted(self.connection_times)
            stats.min_ms, stats.max_ms, stats.p50_ms, stats.p95_ms, stats.p99_ms = \
                self._calculate_stats_from_sorted(sorted_times)
        
        return stats
    
    def get_execution_stats(self) -> Statistics:
        """Get execution statistics."""
        stats = Statistics()
        stats.total = len(self.execution_times)
        stats.successful = self.execution_successes
        stats.failed = self.execution_failures
        
        if self.execution_times:
            stats.total_time_ms = sum(self.execution_times)
            stats.avg_ms = stats.total_time_ms / stats.total
            
            # Sort once, extract all stats (matches sqlsim optimization)
            sorted_times = sorted(self.execution_times)
            stats.min_ms, stats.max_ms, stats.p50_ms, stats.p95_ms, stats.p99_ms = \
                self._calculate_stats_from_sorted(sorted_times)
        
        return stats
    
    def get_total_runtime_seconds(self) -> float:
        """Get total runtime in seconds."""
        return self.end_time - self.start_time


# =============================================================================
# Workload Simulator
# =============================================================================

class WorkloadSimulator:
    """Multi-threaded workload simulator."""
    
    def __init__(self, conn_config: ConnectionConfig, workload_config: WorkloadConfig, 
                 batches: List[str]):
        self.conn_config = conn_config
        self.workload_config = workload_config
        self.batches = batches
        self.metrics = MetricsCollector()
        self._stop_flag = threading.Event()
        self._server_edition = ""
        self._edition_lock = threading.Lock()
        self._edition_queried = False
        self.query_stats = (
            QueryStatsCollector(batches) if workload_config.query_stats else None
        )
        self._stream_start = 0.0
        self._stream_stop = threading.Event()
        self._stream_thread: Optional[threading.Thread] = None
        self._stream_lock = threading.Lock()
        self._snapshot_start = 0.0
        self._snapshot_stop = threading.Event()
        self._snapshot_thread: Optional[threading.Thread] = None
        self._peak_throughput = 0.0
        self._snapshot_write_failed = False

    def _write_query_stats_snapshot(self, is_final: bool):
        """Replace the snapshot file with the run's current query statistics.

        Matching sqlsim, the file is written to a same-directory temporary
        name and then renamed over the target, so a reader never sees a
        half-written file. Failures are swallowed: a snapshot is a diagnostic
        side channel and must never interrupt the workload.
        """
        if self.query_stats is None or not self.workload_config.query_stats_file:
            return
        try:
            stats = self.query_stats.to_dict()
            state = self.metrics.get_snapshot_state()
            now = time.perf_counter()

            elapsed = now - self._snapshot_start
            execution_elapsed = 0.0
            throughput = 0.0
            first = state['first_execution_time']
            if first is not None:
                # A finished run measures to its last execution; a running one
                # measures to now, so the rate keeps moving between snapshots.
                end = state['last_execution_time'] if is_final else now
                execution_elapsed = (end or now) - first
                if execution_elapsed > 0:
                    throughput = stats['totals']['executions'] / execution_elapsed
                    if throughput > self._peak_throughput:
                        self._peak_throughput = throughput

            config: Dict[str, Any] = {
                'server': self.conn_config.server,
                'database': self.conn_config.database,
                'authentication': self.conn_config.auth_method.value,
                'threads': self.workload_config.threads,
                'iterations': self.workload_config.iterations,
            }
            if self.workload_config.workload_entries:
                config['total_batches'] = sum(
                    entry.threads * entry.iterations * len(entry.queries)
                    for entry in self.workload_config.workload_entries)
                config['workload_mode'] = True
            else:
                config['total_batches'] = (self.workload_config.threads *
                                           self.workload_config.iterations *
                                           len(self.batches))

            snapshot = {
                'timestamp': self._stream_timestamp(),
                'elapsed_seconds': round(elapsed, 3),
                'execution_elapsed_seconds': round(execution_elapsed, 3),
                'throughput': round(throughput, 1),
                'peak_throughput': round(self._peak_throughput, 1),
                'status': 'complete' if is_final else 'running',
                'config': config,
                'connection_stats': state['connection_stats'],
                'query_stats': stats,
                'total_errors': state['total_errors'],
                'total_warnings': state['total_warnings'],
                'recent_errors': [
                    {'type': entry.error_type, 'timestamp': entry.timestamp,
                     'message': entry.message}
                    for entry in state['recent_errors']
                ],
                'recent_warnings': [
                    {'type': entry.error_type, 'timestamp': entry.timestamp,
                     'message': entry.message}
                    for entry in state['recent_warnings']
                ],
            }

            target = self.workload_config.query_stats_file
            directory = os.path.dirname(os.path.abspath(target))
            handle, temp_path = tempfile.mkstemp(
                dir=directory, prefix=os.path.basename(target) + '.tmp.')
            try:
                with os.fdopen(handle, 'w', encoding='utf-8') as stream:
                    json.dump(snapshot, stream, indent=2)
                    stream.write('\n')
                os.replace(temp_path, target)
            except BaseException:
                self._discard_temp_snapshot(temp_path)
                raise
        except Exception as error:
            # A snapshot must never take the run down with it. sqlsim discards
            # the failure entirely, which leaves a mistyped path looking
            # exactly like a healthy run; report it once through the normal
            # error channel instead. That channel stays silent in JSON and
            # stream modes, so machine-readable output is never disturbed.
            if not self._snapshot_write_failed:
                self._snapshot_write_failed = True
                output.write_error(
                    "Warning: could not write the query statistics snapshot to "
                    f"'{self.workload_config.query_stats_file}': "
                    f"{sanitize_error_message(str(error))}. The workload continues.")

    @staticmethod
    def _discard_temp_snapshot(temp_path: str):
        """Remove a partial snapshot so a failed write leaves nothing behind."""
        try:
            os.unlink(temp_path)
        except OSError:
            # The temp file may never have been created, or may already be
            # gone; either way there is nothing left to clean up.
            return

    def _snapshot_timer_thread(self):
        """Write a snapshot immediately, then once per interval."""
        self._write_query_stats_snapshot(False)
        interval = float(self.workload_config.query_stats_interval)
        while not self._snapshot_stop.wait(interval):
            self._write_query_stats_snapshot(False)

    def _start_snapshots(self):
        self._snapshot_start = time.perf_counter()
        self._snapshot_thread = threading.Thread(
            target=self._snapshot_timer_thread, daemon=True)
        self._snapshot_thread.start()

    def _finish_snapshots(self):
        self._snapshot_stop.set()
        if self._snapshot_thread is not None:
            self._snapshot_thread.join(timeout=5.0)
            self._snapshot_thread = None
        self._write_query_stats_snapshot(True)

    @staticmethod
    def _stream_timestamp() -> str:
        now = datetime.now()
        return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}"

    def _write_stream_event(self, event_type: str, success: bool = True):
        """Emit one live telemetry event in sqlsim's -stream-json shape.

        Events go to stdout even when -o redirects the rest of the output,
        because the stream is a channel for a supervising process rather than
        part of the run's recorded output. Counters are cumulative and
        throughput is the running average, both matching sqlsim.
        """
        timestamp = self._stream_timestamp()
        if event_type == "started":
            payload = (
                f'{{"type":"started","timestamp":"{timestamp}"'
                f',"version":"{__version__}"'
                f',"threads":{self.workload_config.threads}}}'
            )
        else:
            elapsed = time.perf_counter() - self._stream_start
            counters = self.metrics.get_live_counters()
            completed = counters['successful_executions'] + counters['failed_executions']
            throughput = completed / elapsed if elapsed > 0 else 0.0
            with self._edition_lock:
                server_version = self.metrics.server_version
                server_edition = self.metrics.server_edition
            payload = (
                f'{{"type":"{event_type}","timestamp":"{timestamp}"'
                f',"elapsed_seconds":{elapsed:.3f}'
                f',"successful_connections":{counters["successful_connections"]}'
                f',"failed_connections":{counters["failed_connections"]}'
                f',"successful_executions":{counters["successful_executions"]}'
                f',"failed_executions":{counters["failed_executions"]}'
                f',"errors":{counters["errors"]}'
                f',"throughput_per_second":{throughput:.3f}'
            )
            if _mssql_driver_version not in ('unknown', 'not installed'):
                payload += f',"odbc_driver_version":{json.dumps(_mssql_driver_version)}'
            if server_version:
                payload += f',"server_version":{json.dumps(server_version)}'
            if server_edition:
                payload += f',"server_edition":{json.dumps(server_edition)}'
            if event_type == "completed":
                payload += f',"status":"{"success" if success else "error"}"'
            payload += '}'

        with self._stream_lock:
            sys.stdout.write(payload + "\n")
            sys.stdout.flush()

    def _stream_timer_thread(self):
        """Emit a progress event every second until the run ends."""
        while not self._stream_stop.wait(1.0):
            self._write_stream_event("progress")

    def _start_stream(self):
        self._stream_start = time.perf_counter()
        self._write_stream_event("started")
        self._stream_thread = threading.Thread(
            target=self._stream_timer_thread, daemon=True)
        self._stream_thread.start()

    def _finish_stream(self):
        self._stream_stop.set()
        if self._stream_thread is not None:
            self._stream_thread.join(timeout=2.0)
            self._stream_thread = None
        # sqlsim treats a run that executed nothing as a failure, so an empty
        # run does not report success here either.
        has_errors = (self.metrics.total_errors > 0
                      or self.metrics.execution_failures > 0
                      or self.metrics.execution_successes == 0)
        self._write_stream_event("completed", not has_errors)
    
    def _worker_thread(self, thread_id: int) -> List[str]:
        """Worker thread function."""
        messages = []
        connection = None

        # In workload file mode each thread has its own batches, iteration
        # count, duration and think time. Otherwise every thread shares the
        # run-level settings.
        assignment = None
        if self.workload_config.thread_assignments and thread_id < len(self.workload_config.thread_assignments):
            assignment = self.workload_config.thread_assignments[thread_id]
        thread_batches = assignment.queries if assignment else self.batches
        thread_iterations = assignment.iterations if assignment else self.workload_config.iterations
        thread_duration = assignment.duration_seconds if assignment else 0
        thread_think_ms = assignment.think_time_ms if assignment else 0
        # Per-thread connection and iteration records exist only for -v -json
        # output; recording them otherwise grows memory with every iteration.
        verbose_json = self.workload_config.verbose and self.workload_config.json_output

        try:
            # Connect
            conn_mgr = ConnectionManager(self.conn_config)
            conn_mgr.connect()
            connection = conn_mgr
            
            self.metrics.record_connection(conn_mgr.connect_time_ms, True)
            if verbose_json:
                self.metrics.record_thread_connection(thread_id, conn_mgr.connect_time_ms, True)
            messages.append(f"Thread {thread_id}: Connected successfully ({conn_mgr.connect_time_ms:.0f} ms)")
            
            # Query server edition and version (first thread only)
            with self._edition_lock:
                if not self._edition_queried:
                    self._server_edition = conn_mgr.query_server_edition()
                    self.metrics.server_edition = "" if self._server_edition == "Unknown" else self._server_edition
                    self.metrics.server_version = conn_mgr.query_server_version()
                    self._edition_queried = True
            
            # Print driver version and execution start (thread 0 only, non-verbose, non-JSON)
            if thread_id == 0 and not self.workload_config.verbose and not self.workload_config.json_output:
                output.write(f"Driver Version: {_mssql_driver_version}")
                threads_word = "thread" if self.workload_config.threads == 1 else "threads"
                output.write(f"Starting execution ({self.workload_config.threads} {threads_word})")
            
            # Create executor with reusable cursor (like sqlsim's single hstmt_)
            executor = QueryExecutor(
                connection.connection,
                quiet=self.workload_config.quiet_mode,
                query_stats=self.workload_config.query_stats,
                verbose=self.workload_config.verbose
            )
            if self.workload_config.query_stats:
                executor.enable_query_stats()
            
            # Execute iterations. Duration mode runs until a deadline instead
            # of counting, so the loop is driven by a generator either way.
            deadline = time.monotonic() + thread_duration if thread_duration > 0 else None

            def iteration_numbers():
                if deadline is None:
                    yield from range(1, thread_iterations + 1)
                    return
                counter = 1
                while time.monotonic() < deadline:
                    yield counter
                    counter += 1

            for iteration in iteration_numbers():
                if self._stop_flag.is_set():
                    break
                
                # Reconnect if configured
                if self.workload_config.reconnect_per_iteration and iteration > 1:
                    executor.close()  # Close cursor before disconnecting
                    connection.close()
                    conn_mgr = ConnectionManager(self.conn_config)
                    conn_mgr.connect()
                    connection = conn_mgr
                    self.metrics.record_connection(conn_mgr.connect_time_ms, True)
                    if verbose_json:
                        self.metrics.record_thread_connection(thread_id, conn_mgr.connect_time_ms, True)
                    # Create new executor for new connection
                    executor = QueryExecutor(
                        connection.connection,
                        quiet=self.workload_config.quiet_mode,
                        query_stats=self.workload_config.query_stats,
                        verbose=self.workload_config.verbose
                    )
                    if self.workload_config.query_stats:
                        executor.enable_query_stats()
                
                # Track per-iteration metrics for verbose JSON
                iter_start = time.perf_counter()
                iter_executed = 0
                iter_failed = 0
                
                for i, batch_sql in enumerate(thread_batches):
                    if self._stop_flag.is_set():
                        break
                    
                    result = executor.execute_batch(batch_sql, i + 1)
                    self.metrics.record_execution(result.execution_time_ms, result.success)
                    if self.query_stats is not None and result.query_stats is not None:
                        self.query_stats.record(batch_sql, result.query_stats)
                    iter_executed += 1
                    
                    # Track ODBC warnings
                    for warning in result.warnings:
                        self.metrics.record_warning(warning)
                    
                    if not result.success:
                        iter_failed += 1
                        self.metrics.record_error(result.error or "Unknown error")
                        # Every failing execution reports, as sqlsim does.
                        # Printing only the first thread's error left a run
                        # saying it had N errors while showing one message,
                        # and hid the case where threads fail differently.
                        output.write(result.error or "Unknown error")
                        if self.workload_config.stop_on_error:
                            self._stop_flag.set()
                            break
                    
                    # Output results for every execution, as sqlsim does.
                    if not self.workload_config.quiet_mode:
                        # Print PRINT messages (like sqlsim)
                        if result.messages:
                            for msg in result.messages:
                                output.write(msg)
                        if result.success and result.columns:
                            self._print_result_set(result)
                
                # Record per-iteration metrics for verbose JSON
                if verbose_json:
                    iter_total_ms = (time.perf_counter() - iter_start) * 1000
                    self.metrics.record_thread_iteration(
                        thread_id, iteration, iter_total_ms, iter_executed, iter_failed)

                # Think time: simulate application-tier delay between iterations
                if thread_think_ms > 0 and not self._stop_flag.is_set():
                    time.sleep(thread_think_ms / 1000.0)
            
            # Close executor when done
            executor.close()
        
        except Exception as e:
            safe_error = sanitize_error_message(str(e))
            self.metrics.record_connection(0, False)
            if verbose_json:
                self.metrics.record_thread_connection(thread_id, 0, False, safe_error)
            self.metrics.record_error(safe_error, "connection_error")
            # Reported immediately: the verbose-only message list would hide this entirely.
            output.write_error(f"Thread {thread_id}: Connection failed - {safe_error}")
            if self.workload_config.stop_on_error:
                self._stop_flag.set()
        
        finally:
            if connection:
                connection.close()
        
        return messages
    
    def _print_result_set(self, result: BatchResult):
        """Print result set(s) like sqlsim.

        Every execution prints its own result sets, as sqlsim does, so a run
        of N connections by M iterations produces N times M of them. Each set
        is written as one block so concurrent threads cannot interleave rows.
        """
        def format_set(columns, rows):
            lines = [""]
            # Column headers, using the " | " separator sqlsim uses.
            lines.append(" | ".join(columns))
            lines.append("-" * 80)
            for row in rows:
                lines.append(" | ".join(str(val) if val is not None else "NULL" for val in row))
            lines.append("")
            lines.append(f"({len(rows)} row(s) affected)")
            return lines

        # Use result_sets if available (multiple result sets), otherwise fall back to legacy
        if result.result_sets:
            for columns, rows in result.result_sets:
                # Skip only when the statement returned no columns, meaning it
                # was not a result-returning statement. A query that matched
                # nothing still has columns, and sqlsim prints its header and
                # "(0 row(s) affected)"; printing nothing would leave the user
                # unable to tell an empty result from a statement that never
                # ran.
                if not columns:
                    continue
                output.write_block(format_set(columns, rows))
        elif result.columns:
            # Legacy single result set
            output.write_block(format_set(result.columns, result.rows or []))
    
    def run(self) -> bool:
        """Run the workload simulation."""
        self.metrics.start_time = time.perf_counter()
        self.metrics.start_time_iso = datetime.now().strftime(
            "%Y-%m-%dT%H:%M:%S.%f")[:-3]
        
        output.write("Connecting...")
        
        if self.workload_config.verbose:
            self._print_verbose_header()
        
        if self.workload_config.stream_json:
            self._start_stream()

        if self.workload_config.query_stats_interval > 0:
            self._start_snapshots()

        # Run worker threads
        all_messages = []
        
        if self.workload_config.threads == 1:
            # Single thread - simpler execution
            messages = self._worker_thread(0)
            all_messages.extend(messages)
        else:
            # Multi-threaded
            with ThreadPoolExecutor(max_workers=self.workload_config.threads) as executor:
                ramp = self.workload_config.ramp_batch_size
                if 0 < ramp < self.workload_config.threads:
                    # Ramped start: submit in batches with a pause between, so
                    # the target sees connections arrive gradually rather than
                    # all at once.
                    futures = {}
                    for i in range(self.workload_config.threads):
                        futures[executor.submit(self._worker_thread, i)] = i
                        if (i + 1) % ramp == 0 and (i + 1) < self.workload_config.threads:
                            time.sleep(self.workload_config.ramp_delay_ms / 1000.0)
                else:
                    futures = {
                        executor.submit(self._worker_thread, i): i 
                        for i in range(self.workload_config.threads)
                    }
                
                for future in as_completed(futures):
                    messages = future.result()
                    all_messages.extend(messages)
        
        self.metrics.end_time = time.perf_counter()
        self.metrics.end_time_iso = datetime.now().strftime(
            "%Y-%m-%dT%H:%M:%S.%f")[:-3]

        # Print connection messages (verbose mode only - non-verbose prints in _worker_thread)
        if self.workload_config.verbose:
            for msg in sorted(all_messages):
                output.write(msg)
            output.write(f"Driver Version: {_mssql_driver_version}")
            if self._server_edition:
                output.write(f"Server Edition: {self._server_edition}")
            output.write("")
            output.write("[PHASE 4] Executing workload")
        
        if self.workload_config.query_stats_interval > 0:
            self._finish_snapshots()

        if self.workload_config.stream_json:
            self._finish_stream()

        return len(self.metrics.errors) == 0

    def _print_verbose_header(self):
        """Print verbose mode header."""
        output.write("")
        output.write("=" * 70)
        output.write("SQL Python Workload Simulator")
        output.write("Driver: mssql-python")
        output.write("=" * 70)
        output.write("[PHASE 1] Configuration")
        output.write(f"Threads: {self.workload_config.threads}")
        output.write(f"Iterations per thread: {self.workload_config.iterations}")
        output.write(f"Total batches to execute: {self.workload_config.threads * self.workload_config.iterations * len(self.batches)}")
        output.write(f"Batches in workload: {len(self.batches)}")
        output.write(f"Prepared Statements: {'Yes' if self.workload_config.prepared_statements else 'No'}")
        
        conn_mgr = ConnectionManager(self.conn_config)
        output.write(f"Connection String: {conn_mgr.get_masked_connection_string()}")
        output.write("")
        output.write("Batches to execute:")
        for i, batch in enumerate(self.batches, 1):
            output.write(f"[{i}] {batch}")
        output.write("")
        output.write("[PHASE 2] Initializing worker threads")
        output.write(f"Launched {self.workload_config.threads} worker thread(s)")
        output.write("")
        output.write("[PHASE 3] Connecting to database")


# =============================================================================
# Output Formatters
# =============================================================================

def print_text_summary(metrics: MetricsCollector, workload_config: WorkloadConfig):
    """Print text summary of metrics."""
    runtime = metrics.get_total_runtime_seconds()
    conn_stats = metrics.get_connection_stats()
    exec_stats = metrics.get_execution_stats()
    
    total_work_time = (conn_stats.total_time_ms + exec_stats.total_time_ms) / 1000
    
    if workload_config.verbose:
        output.write("")
        output.write("[PHASE 5] Workload execution completed")
        output.write("=" * 70)

    output.write("=" * 70)
    output.write("Performance Metric Summary")
    output.write("=" * 70)
    output.write(f"Total Runtime: {runtime:.3f} seconds")
    output.write(f"Start Time: {metrics.start_time_iso}")
    output.write(f"End Time:   {metrics.end_time_iso}")
    output.write("")

    if workload_config.verbose:
        # Connection Operations
        output.write("Connection Operations:")
        output.write(f"Total Operations: {conn_stats.total}")
        pct = (conn_stats.successful / conn_stats.total * 100) if conn_stats.total > 0 else 0
        output.write(f"Successful: {conn_stats.successful} ({pct:.0f}%)")
        output.write(f"Failed: {conn_stats.failed}")
        output.write(f"Avg Connect Time: {conn_stats.avg_ms:.2f} ms")
        output.write(f"Min Latency: {conn_stats.min_ms:.2f} ms")
        output.write(f"Max Latency: {conn_stats.max_ms:.2f} ms")
        output.write(f"P50 Latency: {conn_stats.p50_ms:.2f} ms")
        output.write(f"P95 Latency: {conn_stats.p95_ms:.2f} ms")
        output.write(f"P99 Latency: {conn_stats.p99_ms:.2f} ms")
        output.write("")
        
        # Query Execution Operations
        output.write("Query Execution Operations:")
        output.write(f"Total Operations: {exec_stats.total}")
        pct = (exec_stats.successful / exec_stats.total * 100) if exec_stats.total > 0 else 0
        output.write(f"Successful: {exec_stats.successful} ({pct:.2f}%)")
        output.write(f"Failed: {exec_stats.failed}")
        output.write(f"Avg Elapsed: {exec_stats.avg_ms:.2f} ms")
        output.write(f"Min Latency: {exec_stats.min_ms:.2f} ms")
        output.write(f"Max Latency: {exec_stats.max_ms:.2f} ms")
        output.write(f"P50 Latency: {exec_stats.p50_ms:.2f} ms")
        output.write(f"P95 Latency: {exec_stats.p95_ms:.2f} ms")
        output.write(f"P99 Latency: {exec_stats.p99_ms:.2f} ms")
        output.write("")
        
        # Fetch Operations (not tracked separately in Python)
        output.write("Fetch Operations:")
        output.write("Total Operations: 0")
        output.write("Successful: 0 (0.00%)")
        output.write("Failed: 0")
        output.write("")
        
        output.write(f"Total Errors: {len(metrics.errors)}")
        if metrics.total_warnings > 0:
            output.write(f"Total Warnings: {metrics.total_warnings}")
        output.write("")
        
        output.write("Time Breakdown:")
        output.write(f"Total Runtime: {runtime:.3f} seconds")
    else:
        if conn_stats.total > 0:
            output.write(
                f"Avg Connect Time: {conn_stats.avg_ms:.2f} ms "
                f"({conn_stats.successful} successful, {conn_stats.failed} failed)")
        if exec_stats.total > 0:
            output.write(
                f"Avg Elapsed: {exec_stats.avg_ms:.2f} ms "
                f"({exec_stats.successful} successful, {exec_stats.failed} failed)")
        output.write("")
    
    if total_work_time > 0:
        conn_pct = (conn_stats.total_time_ms / 1000) / total_work_time * 100
        exec_pct = (exec_stats.total_time_ms / 1000) / total_work_time * 100
        output.write(f"Total Connection Time: {conn_stats.total_time_ms / 1000:.3f} seconds ({conn_pct:.1f}% of work)")
        output.write(f"Total Query Execution Time: {exec_stats.total_time_ms / 1000:.3f} seconds ({exec_pct:.1f}% of work)")
    
    # Show total warnings count when > 0 (matches sqlsim)
    if not workload_config.verbose and metrics.total_warnings > 0:
        output.write(f"Total Warnings: {metrics.total_warnings}")
    
    if workload_config.verbose:
        output.write("=" * 70)


def print_text_query_stats(query_stats: QueryStatsCollector):
    """Print sqlsim-compatible per-query statistics."""
    payload = query_stats.to_dict()
    if not payload['queries']:
        return

    output.write("Query Stats:")
    output.write("-" * 70)
    for index, query in enumerate(payload['queries'], 1):
        output.write(f"Query {index}: {query['query']}")
        for label, field_name, precision in (
            ('Total elapsed (ms)', 'total_elapsed_ms', 3),
            ('Server elapsed (ms)', 'server_elapsed_ms', 3),
            ('Server CPU (ms)', 'server_cpu_ms', 3),
            ('Server elapsed sum', 'server_elapsed_sum_ms', 3),
            ('Server CPU sum', 'server_cpu_sum_ms', 3),
            ('Compile elapsed (ms)', 'compile_elapsed_ms', 3),
            ('Logical reads', 'logical_reads', 1),
            ('Physical reads', 'physical_reads', 1),
            ('Read-ahead reads', 'read_ahead_reads', 1),
        ):
            metric = query[field_name]
            output.write(
                f"  {label + ':':22} avg={metric['avg']:.{precision}f}  "
                f"min={metric['min']:.{precision}f}  max={metric['max']:.{precision}f}"
            )
        if 'row_count' in query:
            metric = query['row_count']
            output.write(
                f"  {'Row count:':22} avg={metric['avg']:.1f}  "
                f"min={metric['min']:.0f}  max={metric['max']:.0f}"
            )
        output.write(f"  Executions: {query['executions']}")
        if query['failures']:
            output.write(f"  Failures: {query['failures']}")
        if query['spids']:
            # As in sqlsim, the text report lists the first ten and the JSON
            # spid_count carries the full number.
            more = query['spid_count'] - len(query['spids'])
            output.write(f"  SPIDs: {', '.join(str(spid) for spid in query['spids'])}"
                         + (f" (+{more} more)" if more > 0 else ""))
        output.write("")

    totals = payload['totals']
    output.write("-" * 70)
    output.write("Totals:")
    output.write(f"  Total elapsed: {totals['total_elapsed_ms']:.3f} ms")
    output.write(f"  Server elapsed: {totals['server_elapsed_ms']:.3f} ms")
    output.write(f"  Server CPU: {totals['server_cpu_ms']:.3f} ms")
    output.write(f"  Server el. sum: {totals['server_elapsed_sum_ms']:.3f} ms")
    output.write(f"  Server CPU sum: {totals['server_cpu_sum_ms']:.3f} ms")
    output.write(f"  Compile: {totals['compile_elapsed_ms']:.3f} ms")
    output.write(f"  Logical reads: {totals['logical_reads']}")
    output.write(f"  Physical reads: {totals['physical_reads']}")
    output.write(f"  Read-ahead reads: {totals['read_ahead_reads']}")
    if 'total_rows' in totals:
        output.write(f"  Total rows: {totals['total_rows']}")
    output.write(f"  Executions: {totals['executions']}")
    output.write(f"  Failures: {totals['failures']}")
    output.write("")


def print_json_output(conn_config: ConnectionConfig, workload_config: WorkloadConfig,
                     batches: List[str], metrics: MetricsCollector, success: bool,
                     command_line: str = "",
                     query_stats: Optional[QueryStatsCollector] = None,
                     output_target: Optional[TimestampOutput] = None):
    """Print JSON output matching sqlsim format."""
    runtime = metrics.get_total_runtime_seconds()
    conn_stats = metrics.get_connection_stats()
    exec_stats = metrics.get_execution_stats()
    
    start_time = metrics.start_time_iso or (
        datetime.now().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3])
    
    # Build JSON manually to match sqlsim format exactly
    json_lines = []
    json_lines.append("{")
    json_lines.append(f'  "version": "{__version__}",')
    json_lines.append(f'  "start_time": "{start_time}",')

    def escape_json(value: str) -> str:
        return value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

    configuration = {
        "odbc_driver": "mssql-python",
        "server": conn_config.server,
        "database": conn_config.database or "(default)",
        "authentication": conn_config.auth_method.value,
        "threads": workload_config.threads,
    }

    if workload_config.workload_file:
        configuration["workload_file"] = workload_config.workload_file
        entries = workload_config.workload_entries
        if entries and entries[0].duration_seconds > 0:
            configuration["duration_seconds"] = entries[0].duration_seconds
        else:
            configuration["total_batches"] = sum(
                e.threads * e.iterations * len(e.queries) for e in entries
            )
        configuration["workload_groups"] = len(entries)
        workloads = []
        for entry in entries:
            workload = {}
            if entry.file:
                workload["file"] = entry.file
            workload["threads"] = entry.threads
            if entry.duration_seconds > 0:
                workload["duration_seconds"] = entry.duration_seconds
            else:
                workload["iterations"] = entry.iterations
            if entry.think_time_ms > 0:
                workload["think_time_ms"] = entry.think_time_ms
            workload["batch_count"] = len(entry.queries)
            workload["batches"] = entry.queries
            workloads.append(workload)
        configuration["workloads"] = workloads
    elif batches:
        configuration["iterations_per_thread"] = workload_config.iterations
        configuration["total_batches"] = (
            workload_config.threads * workload_config.iterations * len(batches)
        )
        configuration["batch_count"] = len(batches)
        configuration["batches"] = batches
    else:
        configuration["iterations_per_thread"] = workload_config.iterations
        configuration["connection_test_only"] = True

    if workload_config.input_file:
        configuration["input_file"] = workload_config.input_file
    if conn_config.login_timeout > 0:
        configuration["login_timeout"] = conn_config.login_timeout
    if conn_config.query_timeout > 0:
        configuration["query_timeout"] = conn_config.query_timeout
    if workload_config.reconnect_per_iteration:
        configuration["reconnect_per_iteration"] = True
    if workload_config.use_connection_pooling:
        configuration["connection_pooling"] = True
    if workload_config.ramp_batch_size > 0:
        configuration["ramp_batch_size"] = workload_config.ramp_batch_size
        configuration["ramp_delay_ms"] = workload_config.ramp_delay_ms
    if workload_config.stop_on_error:
        configuration["stop_on_error"] = True
    configuration["application_name"] = conn_config.app_name
    if conn_config.retry_count != 1:
        configuration["retry_count"] = conn_config.retry_count
    if conn_config.retry_delay != 10:
        configuration["retry_delay"] = conn_config.retry_delay
    if conn_config.encrypt:
        configuration["encryption"] = {
            "no": "Optional", "yes": "Mandatory", "strict": "Strict"
        }[conn_config.encrypt]
    if conn_config.trust_server_certificate:
        configuration["trust_server_certificate"] = True
    if conn_config.read_only_intent:
        configuration["read_only_intent"] = True
    if conn_config.multi_subnet_failover:
        configuration["multi_subnet_failover"] = True
    if workload_config.output_file:
        configuration["output_file"] = workload_config.output_file
    if workload_config.quiet_mode:
        configuration["quiet_mode"] = True
    if workload_config.verbose:
        configuration["verbose_mode"] = True
    if workload_config.stream_json:
        configuration["stream_json"] = True
    if workload_config.query_stats:
        configuration["query_stats"] = True
        if workload_config.query_stats_interval > 0:
            configuration["query_stats_interval_sec"] = workload_config.query_stats_interval
            configuration["query_stats_file"] = workload_config.query_stats_file
    if workload_config.warnings:
        configuration["warnings"] = workload_config.warnings

    serialized_config = json.dumps(configuration, indent=2).splitlines()
    json_lines.append('  "configuration": ' + serialized_config[0])
    json_lines.extend('  ' + line for line in serialized_config[1:-1])
    json_lines.append('  ' + serialized_config[-1] + ',')

    if query_stats is not None:
        serialized_stats = json.dumps(query_stats.to_dict(), indent=2).splitlines()
        json_lines.append('  "query_stats": ' + serialized_stats[0])
        json_lines.extend('  ' + line for line in serialized_stats[1:-1])
        json_lines.append('  ' + serialized_stats[-1] + ',')
    
    # Metrics
    json_lines.append('  "metrics": {')
    json_lines.append(f'  "odbc_driver_version": "{_mssql_driver_version}",')
    json_lines.append(f'  "total_runtime_seconds": {runtime:.3f},')
    json_lines.append(f'  "total_connection_time_seconds": {conn_stats.total_time_ms / 1000:.3f},')
    json_lines.append(f'  "total_query_execution_time_seconds": {exec_stats.total_time_ms / 1000:.3f},')
    
    end_time = metrics.end_time_iso or (
        datetime.now().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3])
    json_lines.append(f'  "end_time": "{end_time}",')
    
    if workload_config.verbose:
        json_lines.append('    "connection_operations": {')
        json_lines.append(f'      "total": {conn_stats.total},')
        json_lines.append(f'      "successful": {conn_stats.successful},')
        json_lines.append(f'      "failed": {conn_stats.failed},')
        json_lines.append(f'      "avg_connect_time_ms": {conn_stats.avg_ms:.3f}')
        json_lines.append('    },')
        json_lines.append('    "query_execution_operations": {')
        json_lines.append(f'      "total": {exec_stats.total},')
        json_lines.append(f'      "successful": {exec_stats.successful},')
        json_lines.append(f'      "failed": {exec_stats.failed},')
        json_lines.append(f'      "avg_elapsed_ms": {exec_stats.avg_ms:.3f}')
        json_lines.append('    },')
        json_lines.append('    "fetch_operations": {')
        json_lines.append('      "total": 0,')
        json_lines.append('      "successful": 0,')
        json_lines.append('      "failed": 0')
        json_lines.append('    },')

    # Errors
    json_lines.append('    "errors": {')
    json_lines.append(f'      "total": {metrics.total_errors},')
    if metrics.errors:
        json_lines.append('      "list": [')
        for i, err in enumerate(metrics.errors):
            escaped_type = err.error_type.replace('\\', '\\\\').replace('"', '\\"')
            escaped_msg = err.message.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            comma = "," if i < len(metrics.errors) - 1 else ""
            json_lines.append('        {')
            json_lines.append(f'          "type": "{escaped_type}",')
            json_lines.append(f'          "timestamp": "{err.timestamp}",')
            json_lines.append(f'          "message": "{escaped_msg}"')
            json_lines.append(f'        }}{comma}')
        json_lines.append('      ]')
    else:
        json_lines.append('      "list": []')
    json_lines.append('    },')
    json_lines.append('    "warnings": {')
    json_lines.append(f'      "total": {metrics.total_warnings},')
    if metrics.warnings:
        json_lines.append('      "list": [')
        for i, warning in enumerate(metrics.warnings):
            comma = "," if i < len(metrics.warnings) - 1 else ""
            json_lines.append('        {')
            json_lines.append(f'          "type": "{escape_json(warning.error_type)}",')
            json_lines.append(f'          "timestamp": "{escape_json(warning.timestamp)}",')
            json_lines.append(f'          "message": "{escape_json(warning.message)}"')
            json_lines.append(f'        }}{comma}')
        json_lines.append('      ]')
    else:
        json_lines.append('      "list": []')
    json_lines.append('    }')
    json_lines.append('  },')
    if metrics.server_edition:
        json_lines.append(f'  "server_edition": "{escape_json(metrics.server_edition)}",')
    if metrics.server_version:
        json_lines.append(f'  "server_version": "{escape_json(metrics.server_version)}",')
    
    # Verbose JSON: thread-level connection and iteration details
    if workload_config.verbose:
        json_lines.append(f'  "success": {"true" if success else "false"},')
        
        # Thread connections
        json_lines.append('  "thread_connections": [')
        sorted_conns = sorted(metrics.thread_connections, key=lambda c: c.thread_id)
        for i, conn in enumerate(sorted_conns):
            comma = "," if i < len(sorted_conns) - 1 else ""
            error_part = ""
            if not conn.success and conn.error:
                escaped_err = conn.error.replace('\\', '\\\\').replace('"', '\\"')
                error_part = f', "error": "{escaped_err}"'
            status = "success" if conn.success else "failed"
            json_lines.append(f'    {{"thread_id": {conn.thread_id}, "connect_time_ms": {conn.latency_ms:.3f}, "status": "{status}"{error_part}}}{comma}')
        json_lines.append('  ],')
        
        # Thread iterations
        json_lines.append('  "thread_iterations": [')
        sorted_thread_ids = sorted(metrics.thread_iteration_metrics.keys())
        for ti, thread_id in enumerate(sorted_thread_ids):
            thread_metrics = metrics.thread_iteration_metrics[thread_id]
            t_comma = "," if ti < len(sorted_thread_ids) - 1 else ""
            json_lines.append('    {')
            json_lines.append(f'      "thread_id": {thread_metrics.thread_id},')
            json_lines.append('      "iterations": [')
            for ii, iter_result in enumerate(thread_metrics.iterations):
                i_comma = "," if ii < len(thread_metrics.iterations) - 1 else ""
                json_lines.append(f'        {{"iteration": {iter_result.iteration}, "total_query_ms": {iter_result.total_query_ms:.3f}, "queries_executed": {iter_result.queries_executed}, "queries_failed": {iter_result.queries_failed}}}{i_comma}')
            json_lines.append('      ]')
            json_lines.append(f'    }}{t_comma}')
        json_lines.append('  ]')
    else:
        json_lines.append(f'  "success": {"true" if success else "false"}')
    json_lines.append("}")
    
    (output_target or output).write_raw("\n".join(json_lines) + "\n")


# =============================================================================
# Command Line Parsing
# =============================================================================

def parse_args() -> argparse.Namespace:
    """Parse command line arguments matching sqlsim exactly."""
    parser = argparse.ArgumentParser(
        prog='sqlpysim',
        description='Python SQL Workload Simulator using mssql-python driver',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        add_help=False,
        epilog='''
Examples:

  # Connection test (defaults to localhost):
  python sqlpysim.py -E

  # Basic query execution:
  python sqlpysim.py -S localhost -d testdb -E -Q "SELECT @@VERSION"

  # Load test (10 threads, 100 iterations each, quiet mode):
  python sqlpysim.py -S localhost -d testdb -E -i queries.sql -n 10 -r 100 -q

  # SQL Authentication (password on stdin, so it stays out of process lists):
  echo "$password" | python sqlpysim.py -S localhost -d testdb -U myuser -P - -Q "SELECT 1"

  # Azure SQL with Entra Interactive:
  python sqlpysim.py -S myserver.database.windows.net -d mydb -A -Q "SELECT 1"

  # Azure SQL with Access Token ($token = az account get-access-token ...):
  echo "$token" | python sqlpysim.py -S myserver.database.windows.net -d mydb -T - -Q "SELECT 1"
'''
    )
    
    # Connection Options
    conn_group = parser.add_argument_group('Connection Options')
    conn_group.add_argument('-c', dest='connection_string', metavar='<connection_string>',
                           help='Complete connection string (overrides other connection options)')
    conn_group.add_argument('-S', dest='server',
                           metavar='<server>',
                           help='SQL Server name (default: localhost)')
    conn_group.add_argument('-d', dest='database', metavar='<database>',
                           help='Database name')
    
    # Authentication
    auth_group = parser.add_argument_group('Authentication')
    auth_group.add_argument('-E', dest='windows_auth', action='store_true',
                           help='Windows Authentication')
    auth_group.add_argument('-A', dest='entra_auth', nargs='?', const='ActiveDirectoryInteractive',
                           metavar='[mode]',
                           help='Microsoft Entra auth (default: ActiveDirectoryInteractive)')
    auth_group.add_argument('-T', dest='access_token', metavar='<token>',
                           help='Access token authentication (use - to read redirected stdin)')
    auth_group.add_argument('-U', dest='username', metavar='<username>',
                           help='SQL username or client ID for MI')
    auth_group.add_argument('-P', dest='password', metavar='<password>',
                           help='SQL password/client secret (use - to read redirected stdin)')
    
    # Connection Settings
    conn_settings = parser.add_argument_group('Connection Settings')
    conn_settings.add_argument('-l', dest='login_timeout', type=int, default=0,
                              metavar='<seconds>', help='Login timeout')
    conn_settings.add_argument('-app', dest='app_name', default=None,
                              metavar='<name>',
                              help='Not supported: the mssql-python driver reserves the application name')
    conn_settings.add_argument('-retry', dest='retry_count', type=int, default=0,
                              metavar='<count>', help='Connection retry attempts')
    conn_settings.add_argument('-retrydelay', dest='retry_delay', type=int, default=10,
                              metavar='<seconds>', help='Seconds between retries')
    
    # Query Options
    query_group = parser.add_argument_group('Query Options')
    query_group.add_argument('-Q', dest='query', metavar='<query>',
                            help='Query to execute')
    query_group.add_argument('-i', dest='input_file', metavar='<file>',
                            help='Input file containing SQL queries')
    query_group.add_argument('-t', dest='query_timeout', type=int, default=0,
                            metavar='<seconds>', help='Query timeout')
    
    # Workload Options
    workload_group = parser.add_argument_group('Workload Options')
    workload_group.add_argument('-workload', dest='workload_file', metavar='<jsonfile>',
                               help='Workload definition file (mixed workloads, per-group threads)')
    workload_group.add_argument('-n', dest='threads', type=int, default=1,
                               metavar='<threads>', help='Concurrent threads (default: 1)')
    workload_group.add_argument('-r', dest='iterations', type=int, default=1,
                               metavar='<iterations>', help='Iterations per thread (default: 1)')
    workload_group.add_argument('-p', dest='prepared', action='store_true',
                               help='Use prepared statements')
    workload_group.add_argument('-reconnect', dest='reconnect', action='store_true',
                               help='Disconnect/reconnect after each iteration')
    workload_group.add_argument('-usepool', dest='use_pool', action='store_true',
                               help='Enable connection pooling (requires -reconnect)')
    workload_group.add_argument('-querystats', dest='query_stats', action='store_true',
                               help='Show sqlsim-compatible per-query server statistics')
    workload_group.add_argument('-querystats-interval', dest='query_stats_interval',
                               type=str, default=None, metavar='SECONDS',
                               help='Write a query-statistics snapshot every N seconds (implies -querystats)')
    workload_group.add_argument('-querystats-file', dest='query_stats_file',
                               type=str, default=None, metavar='FILE',
                               help='Snapshot file path (default querystats-live.json)')
    
    # Security & Encryption
    security_group = parser.add_argument_group('Security & Encryption')
    security_group.add_argument('-N', dest='encrypt', nargs='?', const='m',
                               metavar='[level]',
                               help='TDS 8.0 encryption: o (optional), m (mandatory), s (strict)')
    security_group.add_argument('-C', dest='trust_cert', action='store_true',
                               help='Trust server certificate')
    security_group.add_argument('-R', dest='read_only', action='store_true',
                               help='Read-only intent (route to AG secondary)')
    security_group.add_argument('-M', dest='multi_subnet', action='store_true',
                               help='Multi-subnet failover')
    
    # Output Options
    output_group = parser.add_argument_group('Output Options')
    output_group.add_argument('-o', dest='output_file', metavar='<file>',
                             help='Output file')
    output_group.add_argument('-q', dest='quiet', action='store_true',
                             help='Quiet mode (suppress query results)')
    output_group.add_argument('-v', dest='verbose', action='store_true',
                             help='Verbose mode')
    output_group.add_argument('-stoponerror', dest='stop_on_error', action='store_true',
                             help='Stop on first error')
    output_group.add_argument('-json', dest='json_output', action='store_true',
                             help='JSON output format')
    output_group.add_argument('-stream-json', dest='stream_json', action='store_true',
                             help='Stream progress events as JSON lines while running')
    
    # Help
    parser.add_argument('-h', '-?', '--help', action='help',
                       help='Show this help message')
    parser.add_argument('--version', action='version',
                       version=f'sqlpysim {__version__}')
    
    return parser.parse_args()


def read_secret_from_stdin(option: str, maximum_bytes: int) -> str:
    """Read one bounded UTF-8 credential line from redirected stdin."""
    if sys.stdin.isatty():
        raise ValueError(
            f"{option} - requires redirected stdin; pipe the credential to sqlpysim"
        )

    raw_value = bytearray(sys.stdin.buffer.readline(maximum_bytes + 2))
    try:
        if raw_value.endswith(b"\n"):
            del raw_value[-1:]
        if raw_value.endswith(b"\r"):
            del raw_value[-1:]
        if not raw_value:
            raise ValueError(f"Credential from stdin cannot be empty for {option}")
        if len(raw_value) > maximum_bytes:
            raise ValueError(f"Credential from stdin exceeds maximum length for {option}")
        try:
            return raw_value.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError(f"Credential from stdin must be valid UTF-8 for {option}") from error
    finally:
        for index in range(len(raw_value)):
            raw_value[index] = 0


def resolve_stdin_credentials(args: argparse.Namespace) -> Optional[str]:
    """Resolve -P - or -T - before normal argument validation."""
    if args.password == "-" and args.access_token == "-":
        return "Cannot read both -P and -T from the same stdin stream"

    try:
        if args.password == "-":
            args.password = read_secret_from_stdin("-P", 128)
        if args.access_token == "-":
            args.access_token = read_secret_from_stdin("-T", 10000)
    except ValueError as error:
        return str(error)

    if args.password is not None:
        if not args.password:
            return "Password cannot be empty (-P requires a value)"
        if len(args.password.encode("utf-8")) > 128:
            return "Password exceeds maximum length"
    if args.access_token is not None:
        token_length = len(args.access_token.encode("utf-8"))
        if token_length < 10 or token_length > 10000:
            return "Invalid access token format"
    return None


def validate_args(args: argparse.Namespace) -> tuple:
    """Validate arguments and return (conn_config, workload_config, error_message)."""
    errors = []
    warnings = []

    entra_modes = {
        "activedirectoryinteractive": AuthMethod.ENTRA_INTERACTIVE,
        "activedirectoryintegrated": AuthMethod.ENTRA_INTEGRATED,
        "activedirectorymsi": AuthMethod.ENTRA_MSI,
        "activedirectoryserviceprincipal": AuthMethod.ENTRA_SERVICE_PRINCIPAL,
    }
    entra_mode = None
    if args.entra_auth is not None:
        entra_mode = entra_modes.get(args.entra_auth.lower())
        if entra_mode is None:
            errors.append(
                f"Unknown authentication type '{args.entra_auth}'. Valid options: "
                "ActiveDirectoryInteractive, ActiveDirectoryIntegrated, "
                "ActiveDirectoryMsi, ActiveDirectoryServicePrincipal")
    
    # If -c (connection string) provided, skip auth validation
    if args.connection_string:
        if (args.server is not None or args.database is not None or
                args.windows_auth or args.entra_auth is not None or
                args.access_token is not None or args.username is not None or
                args.password is not None):
            errors.append("Cannot use both -c and -S/-d/-E/-A/-T/-U/-P options")
    else:
        if args.entra_auth is not None:
            if args.windows_auth or args.access_token:
                errors.append("Cannot mix authentication methods (-E, -A, -T, -U/-P)")
            if entra_mode == AuthMethod.ENTRA_SERVICE_PRINCIPAL:
                if not args.username or not args.password:
                    errors.append(
                        "ActiveDirectoryServicePrincipal requires "
                        "-U <client_id> and -P <client_secret>")
            elif entra_mode == AuthMethod.ENTRA_MSI:
                if args.password:
                    errors.append("ActiveDirectoryMsi does not accept -P")
            elif entra_mode in (AuthMethod.ENTRA_INTERACTIVE, AuthMethod.ENTRA_INTEGRATED):
                if args.username or args.password:
                    errors.append(f"{args.entra_auth} does not accept -U or -P")
        else:
            auth_count = sum([
                args.windows_auth,
                args.access_token is not None,
                args.username is not None or args.password is not None,
            ])
            if auth_count == 0:
                errors.append(
                    "Must specify authentication: -E (Windows), -A (Entra), "
                    "-T (Token), or -U/-P (SQL)")
            elif auth_count > 1:
                errors.append("Cannot mix authentication methods (-E, -A, -T, -U/-P)")
            if (args.username is None) != (args.password is None):
                errors.append("SQL authentication requires -U <username> and -P <password>")
    
    # Check thread count
    if args.threads < 1:
        errors.append("Thread count (-n) must be at least 1")
    
    # Check iteration count
    if args.iterations < 1:
        errors.append("Iteration count (-r) must be at least 1")

    if args.use_pool and not args.reconnect:
        errors.append("-usepool requires -reconnect (connection pooling only applies when reconnecting)")

    if args.encrypt is not None and args.encrypt not in ("o", "m", "s"):
        errors.append(
            f"Invalid encryption level '{args.encrypt}'. "
            "Valid options: o (optional), m (mandatory), s (strict)"
        )
    
    # Check -Q and -i
    if args.query and args.input_file:
        errors.append("Cannot use -Q with -i (choose one query source)")

    # sqlsim rejects -workload combined with another query source rather than
    # picking a winner, because a workload file defines the whole run.
    if args.workload_file and args.query:
        errors.append("Cannot use -Q with -workload (choose one query source)")
    if args.workload_file and args.input_file:
        errors.append("Cannot use -i with -workload (choose one query source)")
    
    # Metacharacter validation for connection parameters (matches sqlsim)
    _metachar_set = set(';{}')
    if not args.connection_string:
        if args.server and any(c in _metachar_set for c in args.server):
            errors.append("Server name contains invalid characters (connection string metacharacters not allowed)")
        if args.database and any(c in _metachar_set for c in args.database):
            errors.append("Database name contains invalid characters (connection string metacharacters not allowed)")

    # mssql-python reserves APP and sets the application name itself, so a
    # requested name can never reach the server. Accepting the option and
    # printing it back was worse than refusing it: the output and the JSON
    # both claimed the requested name while APP_NAME() returned
    # "MSSQL-Python", so a session could not be found by the name the user
    # was shown. See the reserved keyword list in the driver documentation:
    # https://learn.microsoft.com/sql/connect/python/mssql-python/connection-strings
    if args.app_name is not None:
        errors.append(
            "Application name (-app) cannot be set: the mssql-python driver reserves this "
            "connection keyword and reports the application as 'MSSQL-Python'. Remove -app, "
            "or use sqlsim if the application name matters.")
    
    if args.json_output and args.stream_json and not args.output_file:
        errors.append("Combining -stream-json with -json requires -o <final-result-file>")
    
    # -querystats-interval implies -querystats and defaults its own file, both
    # matching sqlsim. The value is validated here rather than by argparse so
    # the wording matches too.
    query_stats_interval = 0
    if args.query_stats_interval is not None:
        try:
            query_stats_interval = int(args.query_stats_interval)
        except ValueError:
            errors.append(f"Invalid value for -querystats-interval: {args.query_stats_interval}")
        else:
            if query_stats_interval < 1:
                errors.append("-querystats-interval must be >= 1")
                query_stats_interval = 0
    
    # Range validation (matches sqlsim)
    if args.login_timeout < 0 or args.login_timeout > 86400:
        errors.append("Login timeout (-l) must be between 0 and 86400 seconds")
    if args.query_timeout < 0 or args.query_timeout > 86400:
        errors.append("Query timeout (-t) must be between 0 and 86400 seconds")
    if args.retry_count < 0 or args.retry_count > 255:
        errors.append("Retry count (-retry) must be between 0 and 255")
    if args.retry_delay < 1 or args.retry_delay > 60:
        errors.append("Retry delay (-retrydelay) must be between 1 and 60 seconds")

    # ODBC Driver 18 has no ActiveDirectoryInteractive implementation off Windows. sqlsim
    # rejects it there; without this, mssql-python falls back to InteractiveBrowserCredential
    # and blocks forever on a headless host.
    if sys.platform != "win32":
        wants_interactive = entra_mode == AuthMethod.ENTRA_INTERACTIVE
        if args.connection_string and re.search(
                r'Authentication\s*=\s*ActiveDirectoryInteractive',
                args.connection_string, re.IGNORECASE):
            wants_interactive = True
        if wants_interactive:
            platform_name = "macOS" if sys.platform == "darwin" else "Linux"
            errors.append(
                f"ActiveDirectoryInteractive is not supported by ODBC Driver 18 on {platform_name}. "
                "Use -T (access token) or -A ActiveDirectoryMsi")

    # mssql-python prepares only executions with bound parameters. sqlpysim
    # workloads contain complete SQL text and have no parameter-binding source.
    if args.prepared:
        warnings.append(
            "Prepared statements (-p) are not supported for raw SQL workloads by "
            "mssql-python; flag ignored")
    
    # Print any warnings to stderr
    for w in warnings:
        print(f"Warning: {w}", file=sys.stderr)
    
    if errors:
        return None, None, "\n".join(errors)
    
    # Build connection config
    conn_config = ConnectionConfig()
    
    # Check for raw connection string (-c option)
    if args.connection_string:
        conn_config.raw_connection_string = args.connection_string
        # Try to extract server/database from connection string for display
        server_match = re.search(r'Server=([^;]+)', args.connection_string, re.IGNORECASE)
        db_match = re.search(r'Database=([^;]+)', args.connection_string, re.IGNORECASE)
        if server_match:
            conn_config.server = server_match.group(1)
        if db_match:
            conn_config.database = db_match.group(1)
        conn_config.auth_method = AuthMethod.WINDOWS  # Default display
    else:
        conn_config.server = args.server or "localhost"
        conn_config.database = args.database
        
        # Authentication method
        if args.windows_auth:
            conn_config.auth_method = AuthMethod.WINDOWS
        elif args.access_token:
            conn_config.auth_method = AuthMethod.TOKEN
            conn_config.access_token = args.access_token
        elif args.entra_auth:
            conn_config.auth_method = entra_mode
            if entra_mode == AuthMethod.ENTRA_MSI:
                conn_config.username = args.username  # Client ID for user-assigned MI
            elif entra_mode == AuthMethod.ENTRA_SERVICE_PRINCIPAL:
                conn_config.username = args.username
                conn_config.password = args.password
        elif args.username and args.password:
            conn_config.auth_method = AuthMethod.SQL_AUTH
            conn_config.username = args.username
            conn_config.password = args.password
    
    # app_name is deliberately not taken from args: -app is refused during
    # validation, and the field holds what the driver actually reports.
    conn_config.login_timeout = args.login_timeout
    conn_config.query_timeout = args.query_timeout
    conn_config.retry_count = args.retry_count
    conn_config.retry_delay = args.retry_delay
    conn_config.trust_server_certificate = args.trust_cert
    conn_config.read_only_intent = args.read_only
    conn_config.multi_subnet_failover = args.multi_subnet
    
    # Encryption
    if args.encrypt:
        encrypt_map = {'o': 'no', 'm': 'yes', 's': 'strict'}
        conn_config.encrypt = encrypt_map.get(args.encrypt, "")
    
    # Build workload config
    workload_config = WorkloadConfig()
    workload_config.threads = args.threads
    workload_config.iterations = args.iterations
    workload_config.prepared_statements = False
    workload_config.quiet_mode = args.quiet
    workload_config.verbose = args.verbose
    workload_config.stop_on_error = args.stop_on_error
    workload_config.json_output = args.json_output
    workload_config.final_json_output = args.json_output
    # Matching sqlsim, -stream-json also turns on JSON mode: the timestamped
    # text output would otherwise interleave with the event lines.
    workload_config.stream_json = args.stream_json
    if args.stream_json:
        workload_config.json_output = True
    workload_config.output_file = args.output_file
    workload_config.reconnect_per_iteration = args.reconnect
    workload_config.use_connection_pooling = args.use_pool
    workload_config.input_file = args.input_file
    workload_config.query_stats = args.query_stats
    workload_config.query_stats_interval = query_stats_interval
    workload_config.warnings = warnings
    if query_stats_interval > 0:
        workload_config.query_stats = True
        workload_config.query_stats_file = args.query_stats_file or "querystats-live.json"
    workload_config.workload_file = args.workload_file

    # Workload file mode: load the groups and expand them into per-thread
    # assignments, the way sqlsim does, so each worker carries its own query
    # list, iteration count and think time.
    if args.workload_file:
        try:
            entries = WorkloadFileParser.parse(args.workload_file)
        except ValueError as error:
            return None, None, str(error)

        total_threads = 0
        for index, entry in enumerate(entries):
            if entry.file:
                try:
                    with open(entry.file, 'r', encoding='utf-8-sig') as handle:
                        script = handle.read()
                except OSError:
                    return None, None, f"Cannot open workload script file: {entry.file}"
                entry.queries = [b for b in QueryExecutor.split_batches(script) if b.strip()]
                if not entry.queries:
                    return None, None, f"No batches found in workload script: {entry.file}"

            for _ in range(entry.threads):
                workload_config.thread_assignments.append(ThreadAssignment(
                    queries=list(entry.queries),
                    iterations=entry.iterations,
                    duration_seconds=entry.duration_seconds,
                    workload_index=index,
                    think_time_ms=entry.think_time_ms,
                ))
            total_threads += entry.threads

        workload_config.workload_entries = entries
        # The run's thread count is the sum of the groups, not -n.
        workload_config.threads = total_threads
        if entries and entries[0].ramp_batch_size > 0:
            workload_config.ramp_batch_size = entries[0].ramp_batch_size
            workload_config.ramp_delay_ms = entries[0].ramp_delay_ms

    return conn_config, workload_config, None


# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    """Main entry point."""
    global output
    
    # Parse arguments first so -h and --version work without the driver.
    args = parse_args()

    if mssql_connect is None:
        print("Error: mssql-python driver not installed.", file=sys.stderr)
        print("Install with: pip install mssql-python", file=sys.stderr)
        return 1

    stdin_error = resolve_stdin_credentials(args)
    if stdin_error:
        print(f"Error: {stdin_error}", file=sys.stderr)
        return 1
    
    # Validate arguments
    conn_config, workload_config, error = validate_args(args)
    if error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    
    # Match sqlsim: pooling is off unless -usepool is requested.
    pooling = getattr(_mssql_module, 'pooling', None)
    if not callable(pooling):
        print("Error: installed mssql-python driver does not expose connection pooling control",
              file=sys.stderr)
        return 1
    pooling(enabled=workload_config.use_connection_pooling)
    
    # In combined mode stdout remains the NDJSON channel and -o receives only
    # the canonical final document.
    dual_json_output = workload_config.stream_json and workload_config.final_json_output
    output = TimestampOutput(
        None if dual_json_output else workload_config.output_file,
        workload_config.json_output)
    final_output = (
        TimestampOutput(workload_config.output_file, json_mode=True)
        if dual_json_output else None)
    
    # Print console messages before redirecting to file (like sqlsim)
    using_output_file = workload_config.output_file is not None
    if using_output_file and not workload_config.json_output:
        console_output = TimestampOutput()  # Console only
        console_output.write(f"=== SQL Python Workload Simulator v{__version__} ===")
        console_output.write("Driver: mssql-python")
        console_output.write(f"Output redirected to: {workload_config.output_file}")
        connect_target = conn_config.server
        if conn_config.database:
            connect_target += f"/{conn_config.database}"
        console_output.write(f"Connecting to {connect_target}...")
    
    output.open()
    
    try:
        if final_output is not None:
            final_output.open()
        # Get batches
        batches = []
        if args.query:
            batches = QueryExecutor.split_batches(args.query)
        elif args.input_file:
            try:
                with open(args.input_file, 'r', encoding='utf-8') as f:
                    sql_content = f.read()
                batches = QueryExecutor.split_batches(sql_content)
            except Exception as e:
                output.write_error(f"Error reading input file: {e}")
                return 1
        elif workload_config.workload_file:
            # Workload mode runs from per-thread assignments, so this list is
            # only for display and for query statistics. sqlsim builds the same
            # de-duplicated union of every group's batches.
            for entry in workload_config.workload_entries:
                for query in entry.queries:
                    if query not in batches:
                        batches.append(query)
        
        # Print header (non-JSON mode)
        if not workload_config.json_output:
            output.write(f"=== SQL Python Workload Simulator v{__version__} ===")
            output.write("Driver: mssql-python")
            
            if workload_config.verbose:
                cmd_line = mask_command_line(sys.argv)
                output.write(f"Command: {cmd_line}")
            
            output.write("Configuration:")
            output.write(f"Server: {conn_config.server}")
            output.write(f"Database: {conn_config.database or '(default)'}")
            output.write(f"Authentication: {conn_config.auth_method.value}")
            output.write(f"Threads: {workload_config.threads}")

            if workload_config.workload_file:
                # Workload file mode reports its groups rather than a single
                # iteration count, matching sqlsim's layout.
                output.write(f"Workload file: {workload_config.workload_file}")
                entries = workload_config.workload_entries
                is_duration_mode = bool(entries) and entries[0].duration_seconds > 0
                if is_duration_mode:
                    output.write(f"Duration: {entries[0].duration_seconds} seconds")
                else:
                    total_batches = sum(e.threads * e.iterations * len(e.queries) for e in entries)
                    output.write(f"Total batches to execute: {total_batches}")
                output.write(f"Workload groups: {len(entries)}")
                for position, entry in enumerate(entries, start=1):
                    shape = "duration mode" if is_duration_mode else f"{entry.iterations} iteration(s)"
                    line = f"  Group {position}: {entry.threads} thread(s), {shape}, {len(entry.queries)} batch(es)"
                    if entry.think_time_ms > 0:
                        line += f", think={entry.think_time_ms}ms"
                    if entry.file:
                        line += f" [{entry.file}]"
                    output.write(line)
            else:
                output.write(f"Iterations per thread: {workload_config.iterations}")

                if batches:
                    total_batches = workload_config.threads * workload_config.iterations * len(batches)
                    output.write(f"Total batches to execute: {total_batches}")
                    output.write(f"Batches in workload: {len(batches)}")
                else:
                    output.write("Mode: Connection test only")
            
            if workload_config.input_file:
                output.write(f"Input file: {workload_config.input_file}")
            if conn_config.login_timeout > 0:
                output.write(f"Login timeout: {conn_config.login_timeout} seconds")
            if conn_config.query_timeout > 0:
                output.write(f"Query timeout: {conn_config.query_timeout} seconds")
            if workload_config.reconnect_per_iteration:
                output.write("Reconnect per iteration: Yes")
            if workload_config.stop_on_error:
                output.write("Stop on error: Yes")
            
            output.write(f"Application name: {conn_config.app_name}")
            
            if conn_config.trust_server_certificate:
                output.write("Trust server certificate: Yes")
            if workload_config.output_file:
                output.write(f"Output file: {workload_config.output_file}")
            if workload_config.quiet_mode:
                output.write("Quiet mode: Yes")
            if workload_config.verbose:
                output.write("Verbose mode: Yes")
            if workload_config.query_stats:
                output.write("Query stats: Yes")
            if workload_config.query_stats_interval > 0:
                output.write(f"Query stats interval: {workload_config.query_stats_interval}s")
                output.write(f"Query stats file: {workload_config.query_stats_file}")
            
            output.write("")
            
            if batches and not workload_config.verbose:
                output.write("Batches to execute:")
                for i, batch in enumerate(batches, 1):
                    output.write(f"[{i}] {batch}")
                output.write("")
        
        # Run workload
        simulator = WorkloadSimulator(conn_config, workload_config, batches)
        success = simulator.run()
        
        # Print summary
        if workload_config.stream_json:
            if final_output is not None:
                print_json_output(
                    conn_config, workload_config, batches, simulator.metrics,
                    success, query_stats=simulator.query_stats,
                    output_target=final_output)
        elif workload_config.json_output:
            print_json_output(conn_config, workload_config, batches, 
                            simulator.metrics, success,
                            query_stats=simulator.query_stats)
        else:
            output.write("")
            if simulator.query_stats is not None:
                print_text_query_stats(simulator.query_stats)
            print_text_summary(simulator.metrics, workload_config)
        
        # Print console message when using output file (like sqlsim)
        if using_output_file and not workload_config.json_output:
            console_output.write(f"Execution complete. See {workload_config.output_file} for results.")
        
        return 0 if success else 1
    
    except KeyboardInterrupt:
        output.write_error("Interrupted by user")
        return 1
    except Exception as e:
        if workload_config.json_output:
            output.write_raw(json.dumps({"error": sanitize_error_message(str(e)), "success": False}) + "\n")
        else:
            output.write_error(f"Error: {sanitize_error_message(str(e))}")
        return 1
    finally:
        if final_output is not None:
            final_output.close()
        output.close()


if __name__ == "__main__":
    sys.exit(main())
