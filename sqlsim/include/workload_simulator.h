#pragma once

#include "odbc_connection.h"
#include "metrics_collector.h"
#include "query_stats.h"
#include "workload_config.h"
#include "xel_replay.h"
#include <vector>
#include <string>
#include <memory>
#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <sstream>

/**
 * Configuration for workload simulation
 */
struct WorkloadConfig {
    WorkloadConfig() = default;
    WorkloadConfig(const WorkloadConfig&) = default;
    WorkloadConfig& operator=(const WorkloadConfig&) = default;
    ~WorkloadConfig() {
        clearSensitiveValue(accessToken);
        clearSensitiveValue(connectionString);
    }

    static void clearSensitiveValue(std::string& value) {
        volatile char* data = value.empty() ? nullptr : &value[0];
        for (size_t index = 0; index < value.size(); ++index) {
            data[index] = '\0';
        }
        value.clear();
    }

    std::string connectionString;
    std::string accessToken;           // Optional: Entra access token for authentication
    std::string serverName;            // Server name for display (from -S or extracted from -c)
    std::string databaseName;          // Database name for display (from -d or extracted from -c)
    std::string authMethod;            // Authentication method for display
    int numThreads = 1;
    int iterationsPerThread = 1;
    bool usePreparedStatements = false;
    std::vector<std::string> queries;
    
    // Timeout options (in seconds, 0 = driver default)
    int loginTimeout = 0;              // Connection login timeout
    int queryTimeout = 0;              // Query execution timeout
    
    // Output options
    bool verbose = false;              // Show detailed phases and metrics
    bool quietMode = false;            // Suppress query results
    bool stopOnError = false;          // Stop execution on first error
    bool jsonOutput = false;           // Output in JSON format
    bool finalJsonOutput = false;      // Write canonical final JSON (-json)
    bool streamJsonOutput = false;     // Stream newline-delimited JSON progress events
    std::string outputFile;            // Optional: Write all output to file (like sqlcmd -o)
    
    // Connection behavior options
    bool reconnectPerIteration = false; // Disconnect/reconnect after each iteration
    bool useConnectionPooling = false;  // Enable ODBC connection pooling (requires reconnectPerIteration)
    
    // Additional options for display (show only when used)
    std::string inputFile;             // Input file path (-i)
    std::string appName;               // Application name (-app)
    int retryCount = 0;                // Connection retry count (-retry)
    int retryDelay = 10;               // Connection retry delay (-retrydelay)
    bool hasRetryCount = false;        // True if -retry was explicitly specified
    bool hasRetryDelay = false;        // True if -retrydelay was explicitly specified
    std::string encryptionLevel;       // Encryption level (-N)
    bool trustServerCertificate = false; // Trust server certificate (-C)
    std::string certificateHostname;   // Certificate hostname (-F)
    bool readOnlyIntent = false;       // Read-only intent (-R)
    bool multiSubnetFailover = false;  // Multi-subnet failover (-M)
    
    // Warnings to display after configuration (deferred from parsing)
    std::vector<std::string> warnings;
    
    // Replay mode options
    std::string replayMode;                // "fast" or "stress" (empty = not replay mode)
    std::string replayFile;                // Path to XML replay file
    ReplayData replayData;                 // Parsed replay data (populated by main.cpp)
    
    // Query stats options
    bool queryStats = false;               // Enable SET STATISTICS TIME/IO and per-query stats
    int queryStatsIntervalSec = 0;         // Interval for querystats JSON snapshot (0 = disabled)
    std::string queryStatsFile;            // Output file for querystats snapshot
    
    // Workload file mode
    std::string workloadFile;              // Path to workload JSON file (-workload)
    std::vector<WorkloadEntry> workloadEntries;  // Parsed workload entries
    std::vector<ThreadAssignment> threadAssignments; // Expanded per-thread assignments
    int rampBatchSize = 0;                 // Threads to launch per ramp batch (0 = all at once)
    int rampDelayMs = 500;                 // Delay (ms) between ramp batches
};

/**
 * SQL Workload Simulator - Generic SQL query execution tool
 */
class WorkloadSimulator {
public:
    explicit WorkloadSimulator(const WorkloadConfig& config);
    ~WorkloadSimulator();

    // Workload execution
    bool run();
    void stop();
    void printJsonResult() const;
    
    // Results
    const MetricsCollector& getMetrics() const { return metrics_; }
    const QueryStatsCollector& getQueryStats() const { return queryStats_; }
    
    // Driver information (available after run() completes)
    std::string getDriverVersion() const { 
        std::lock_guard<std::mutex> lock(driverVersionMutex_);
        return driverVersion_; 
    }
    
    // Delete copy constructor and assignment operator
    WorkloadSimulator(const WorkloadSimulator&) = delete;
    WorkloadSimulator& operator=(const WorkloadSimulator&) = delete;

private:
    struct ReplayConnectionInfo {
        int worker;
        int64_t capturedSpid;
        int64_t replaySpid;
    };

    void workerThread(int threadId);
    void replayWorkerThread(int threadId);          // Replay mode worker
    void replayFastSession(int threadId, const ReplaySession& session, ODBCConnection& conn, QueryStatsCollector::Slot* qsSlot, int64_t replaySpid);
    std::string queryServerEdition(ODBCConnection& conn);
    std::string queryServerVersion(ODBCConnection& conn);
    void printTextQueryStats() const;               // Print query stats in text format
    void printJsonQueryStats() const;               // Print query stats in JSON format
    void printJsonReplayCapture() const;             // Print original XEvent performance aggregates
    void snapshotTimerThread();                      // Timer thread for periodic querystats snapshots
    void writeQueryStatsSnapshot(bool isFinal) const; // Write querystats JSON snapshot to file
    // Report the first snapshot write failure, so a mistyped path does not
    // leave the run looking healthy. Silent in JSON modes.
    void reportSnapshotFailure(const std::string& reason) const;
    void recordExecutionTimestamp();                   // Track first/last execution times for throughput
    void streamJsonTimerThread();                       // Emit periodic NDJSON progress events
    void writeStreamJsonEvent(const std::string& type, bool success = false) const;
    
    WorkloadConfig config_;
    MetricsCollector metrics_;
    QueryStatsCollector queryStats_;
    std::atomic<bool> running_;
    std::vector<std::thread> threads_;
    std::mutex joinMutex_;  // Protects thread joining to prevent double-join
    
    // For buffering connection messages to prevent garbled output
    std::vector<std::string> connectionMessages_;
    std::condition_variable connectionCV_;
    std::mutex connectionMessagesMutex_;
    std::atomic<int> connectionsCompleted_{0};
    
    // Server identity captured from the first successful connection.
    std::string serverEdition_;
    std::string serverVersion_;
    std::atomic<bool> editionQueried_{false};
    mutable std::mutex editionMutex_;
    
    // For ODBC driver version (captured from first connection)
    std::string driverVersion_;
    std::atomic<bool> driverVersionQueried_{false};
    mutable std::mutex driverVersionMutex_;
    
    // Mutex for thread-safe stderr output and buffered errors
    std::mutex stderrMutex_;
    std::vector<std::string> bufferedErrors_;

    // Serializes result-set writes to stdout. Separate from stderrMutex_ so
    // error reporting never contends with the result path.
    std::mutex resultOutputMutex_;
    
    // Querystats snapshot timer
    std::thread snapshotThread_;
    std::thread streamJsonThread_;
    std::condition_variable streamJsonCV_;
    std::mutex streamJsonMutex_;
    std::chrono::steady_clock::time_point workloadStartTime_;
    
    // Execution time tracking for accurate throughput (excludes connection phase)
    // Phase 1 Optimization: Uses atomics instead of mutex for lock-free recording
    std::atomic<int64_t> firstExecutionNs_{0};   // nanoseconds since steady_clock epoch
    std::atomic<int64_t> lastExecutionNs_{0};     // nanoseconds since steady_clock epoch
    std::atomic<bool> hasFirstExecution_{false};
    mutable double peakThroughput_{0.0};  // Max executions/sec observed across snapshots
    // A snapshot write failure is reported once, so a per-interval timer cannot
    // flood the output with the same message.
    mutable std::atomic<bool> snapshotWriteReported_{false};
    
    // Thread-safe connection time tracking for snapshots
    mutable std::mutex connTimesMutex_;
    std::vector<double> connTimesMs_;

    mutable std::mutex replayConnectionsMutex_;
    std::vector<ReplayConnectionInfo> replayConnections_;
};
