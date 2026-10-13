#pragma once

#include <chrono>
#include <atomic>
#include <vector>
#include <mutex>
#include <string>
#include <unordered_map>
#include <thread>
#include "json_output.h"  // For ErrorEntry

/**
 * Verbose metrics structures for detailed JSON output when -v -json used together
 */
struct ThreadConnectionMetric {
    int threadId = 0;
    double connectTimeMs = 0.0;
    bool success = false;
    std::string errorMessage;  // Only set if !success
};

struct IterationMetric {
    int iteration = 0;
    double totalQueryMs = 0.0;
    int queriesExecuted = 0;
    int queriesFailed = 0;
};

struct ThreadIterationMetrics {
    int threadId = 0;
    std::vector<IterationMetric> iterations;
};

/**
 * Thread-safe metrics collection for performance analysis
 * Phase 1 Optimization: Uses thread-local storage for lock-free recording
 */
class MetricsCollector {
public:
    MetricsCollector();

    // Record operations
    void recordConnection(std::chrono::microseconds duration, bool success);
    void recordExecution(std::chrono::microseconds duration, bool success);
    void recordFetch(std::chrono::microseconds duration, bool success);
    void recordError(const std::string& error, const std::string& errorType = "sql_error");
    void recordError(const std::string& error, const std::string& query, const std::string& errorType);

    // Aggregate statistics
    struct Statistics {
        uint64_t count = 0;
        uint64_t successCount = 0;
        uint64_t failureCount = 0;
        double totalMicroseconds = 0.0;
        double avgMicroseconds = 0.0;
        double minMicroseconds = 0.0;
        double maxMicroseconds = 0.0;
        double p50Microseconds = 0.0;
        double p95Microseconds = 0.0;
        double p99Microseconds = 0.0;
    };

    Statistics getConnectionStats() const;
    Statistics getExecutionStats() const;
    Statistics getFetchStats() const;
    
    uint64_t getSuccessfulConnections() const;
    uint64_t getSuccessfulExecutions() const;
    uint64_t getFailedConnections() const;
    uint64_t getFailedExecutions() const;
    uint64_t getTotalErrors() const { return totalErrors_.load(); }
    void setLiveMetricsEnabled(bool enabled) { liveMetricsEnabled_ = enabled; }
    uint64_t getLiveSuccessfulConnections() const { return liveConnectionSuccessCount_.load(std::memory_order_relaxed); }
    uint64_t getLiveFailedConnections() const { return liveConnectionFailureCount_.load(std::memory_order_relaxed); }
    uint64_t getLiveSuccessfulExecutions() const { return liveExecutionSuccessCount_.load(std::memory_order_relaxed); }
    uint64_t getLiveFailedExecutions() const { return liveExecutionFailureCount_.load(std::memory_order_relaxed); }
    std::vector<ErrorEntry> getRecentErrors(size_t count = 10) const;
    
    // Warning tracking (real ODBC warnings — non-01000 states like 01004, 01001, 01003)
    void recordWarning(const std::string& warning);
    void recordWarningCount(int count) { totalWarnings_.fetch_add(count, std::memory_order_relaxed); }
    uint64_t getTotalWarnings() const { return totalWarnings_.load(std::memory_order_relaxed); }
    std::vector<ErrorEntry> getRecentWarnings(size_t count = 10) const;

    void reset();
    void printRuntime() const;
    void printSummary() const;
    void printJsonMetrics() const;  // Print metrics in JSON format
    void printJsonClose() const;     // Print success status and close JSON document
    
    // Replay summary
    void recordReplayResult(int originalResult, bool replaySuccess, bool replayAbort);
    void printReplaySummary() const;
    void printReplaySummaryJson() const;
    bool hasReplaySummary() const { return replayOriginalTotal_.load(std::memory_order_relaxed) > 0; }
    
    // Phase 1 Optimization: Pre-allocate vector capacity
    void reserveCapacity(size_t executionOps, size_t connectionOps);
    
    // Phase 1 Optimization: Consolidate thread-local metrics (call before reading stats)
    void consolidateThreadMetrics();
    
    // Verbose JSON metrics (-v -json combined)
    void setVerboseJsonEnabled(bool enabled) { verboseJsonEnabled_ = enabled; }
    void setMaskedConnectionString(const std::string& connStr) { maskedConnectionString_ = connStr; }
    void setServerEdition(const std::string& edition) { serverEdition_ = edition; }
    void setServerVersion(const std::string& version) { serverVersion_ = version; }
    void setDriverVersion(const std::string& version) { driverVersion_ = version; }
    void recordThreadConnection(int threadId, double connectTimeMs, bool success, const std::string& errorMsg = "");
    void recordIterationMetric(int threadId, int iteration, double totalQueryMs, int queriesExecuted, int queriesFailed);
    void printVerboseJsonMetrics() const;  // Print verbose metrics directly in JSON output

private:
    // Phase 1 Optimization: Thread-local metrics for lock-free recording
    struct ThreadLocalMetrics {
        std::vector<double> connectionDurations;
        std::vector<double> executionDurations;
        std::vector<double> fetchDurations;
        uint64_t connectionSuccessCount = 0;
        uint64_t connectionFailureCount = 0;
        uint64_t executionSuccessCount = 0;
        uint64_t executionFailureCount = 0;
        uint64_t fetchSuccessCount = 0;
        uint64_t fetchFailureCount = 0;
    };
    
    struct MetricData {
        std::vector<double> durations;
        std::atomic<uint64_t> successCount{0};
        std::atomic<uint64_t> failureCount{0};
        mutable std::mutex mutex;
    };

    Statistics calculateStats(const MetricData& data) const;

    MetricData connectionMetrics_;
    MetricData executionMetrics_;
    MetricData fetchMetrics_;
    
    // Phase 1 Optimization: Thread-local storage for lock-free metrics
    mutable std::mutex threadMetricsMutex_;
    mutable std::unordered_map<std::thread::id, ThreadLocalMetrics*> threadMetrics_;
    
    std::atomic<uint64_t> totalErrors_{0};
    std::atomic<uint64_t> totalWarnings_{0};
    bool liveMetricsEnabled_ = false;
    std::atomic<uint64_t> liveConnectionSuccessCount_{0};
    std::atomic<uint64_t> liveConnectionFailureCount_{0};
    std::atomic<uint64_t> liveExecutionSuccessCount_{0};
    std::atomic<uint64_t> liveExecutionFailureCount_{0};
    mutable std::mutex errorMutex_;
    std::vector<ErrorEntry> recentErrors_;
    mutable std::mutex warningMutex_;
    std::vector<ErrorEntry> recentWarnings_;
    
    std::chrono::steady_clock::time_point startTime_;
    std::string startTimeIso_;  // Wall clock ISO timestamp for text output
    
    // Phase 1 Optimization: Get or create thread-local metrics
    ThreadLocalMetrics* getThreadLocalMetrics() const;
    
    // Verbose JSON metrics storage
    bool verboseJsonEnabled_ = false;
    std::string maskedConnectionString_;
    std::string serverEdition_;
    std::string serverVersion_;
    std::string driverVersion_;
    mutable std::mutex verboseMetricsMutex_;
    std::vector<ThreadConnectionMetric> threadConnections_;
    std::unordered_map<int, ThreadIterationMetrics> threadIterationMetrics_;
    
    // Replay summary counters (atomic for thread-safe recording)
    std::atomic<uint64_t> replayOriginalTotal_{0};
    std::atomic<uint64_t> replayOriginalOk_{0};
    std::atomic<uint64_t> replayOriginalError_{0};
    std::atomic<uint64_t> replayOriginalAbort_{0};
    std::atomic<uint64_t> replayResultOk_{0};
    std::atomic<uint64_t> replayResultError_{0};
    std::atomic<uint64_t> replayResultAbort_{0};
};
