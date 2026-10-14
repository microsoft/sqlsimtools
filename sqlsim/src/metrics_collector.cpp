#include "metrics_collector.h"
#include "timestamp_helper.h"
#include "json_output.h"
#include <algorithm>
#include <iostream>
#include <iomanip>
#include <numeric>

MetricsCollector::MetricsCollector() 
    : startTime_(std::chrono::steady_clock::now()),
      startTimeIso_(JsonOutput::getIsoTimestamp()) {
}

void MetricsCollector::reserveCapacity(size_t executionOps, size_t connectionOps) {
    // Phase 1 Optimization: Pre-allocate vectors to avoid repeated reallocations
    try {
        std::lock_guard<std::mutex> lockExec(executionMetrics_.mutex);
        executionMetrics_.durations.reserve(executionOps);
        
        std::lock_guard<std::mutex> lockConn(connectionMetrics_.mutex);
        connectionMetrics_.durations.reserve(connectionOps);
        // Fetch samples are recorded only when rows are displayed, so they
        // are not reserved; the vector grows when they are recorded.
    } catch (...) {
        // Ignore reservation failures - will just grow dynamically
    }
}

// Phase 1 Optimization: Get or create thread-local metrics (lock-free for common case)
MetricsCollector::ThreadLocalMetrics* MetricsCollector::getThreadLocalMetrics() const {
    thread_local ThreadLocalMetrics* localMetrics = nullptr;
    
    if (localMetrics == nullptr) {
        // First time this thread is recording metrics - allocate and register
        localMetrics = new ThreadLocalMetrics();
        std::lock_guard<std::mutex> lock(threadMetricsMutex_);
        threadMetrics_[std::this_thread::get_id()] = localMetrics;
    }
    
    return localMetrics;
}

void MetricsCollector::recordConnection(std::chrono::microseconds duration, bool success) {
    if (liveMetricsEnabled_) {
        (success ? liveConnectionSuccessCount_ : liveConnectionFailureCount_).fetch_add(1, std::memory_order_relaxed);
    }
    // Phase 1 Optimization: Lock-free thread-local recording
    try {
        ThreadLocalMetrics* local = getThreadLocalMetrics();
        local->connectionDurations.push_back(static_cast<double>(duration.count()));
        if (success) {
            local->connectionSuccessCount++;
        } else {
            local->connectionFailureCount++;
        }
    } catch (...) {
        // Silently ignore exceptions in metrics recording to avoid crashing the application
    }
}

void MetricsCollector::recordExecution(std::chrono::microseconds duration, bool success) {
    if (liveMetricsEnabled_) {
        (success ? liveExecutionSuccessCount_ : liveExecutionFailureCount_).fetch_add(1, std::memory_order_relaxed);
    }
    // Phase 1 Optimization: Lock-free thread-local recording
    try {
        ThreadLocalMetrics* local = getThreadLocalMetrics();
        local->executionDurations.push_back(static_cast<double>(duration.count()));
        if (success) {
            local->executionSuccessCount++;
        } else {
            local->executionFailureCount++;
        }
    } catch (...) {
        // Silently ignore exceptions in metrics recording to avoid crashing the application
    }
}

void MetricsCollector::recordFetch(std::chrono::microseconds duration, bool success) {
    // Phase 1 Optimization: Lock-free thread-local recording
    try {
        ThreadLocalMetrics* local = getThreadLocalMetrics();
        local->fetchDurations.push_back(static_cast<double>(duration.count()));
        if (success) {
            local->fetchSuccessCount++;
        } else {
            local->fetchFailureCount++;
        }
    } catch (...) {
        // Silently ignore exceptions in metrics recording to avoid crashing the application
    }
}

void MetricsCollector::recordError(const std::string& error, const std::string& errorType) {
    try {
        std::lock_guard<std::mutex> lock(errorMutex_);
        totalErrors_.fetch_add(1, std::memory_order_relaxed);
        recentErrors_.push_back(ErrorEntry(errorType, JsonOutput::getIsoTimestamp(), error));
        if (recentErrors_.size() > 100) {
            recentErrors_.erase(recentErrors_.begin());
        }
    } catch (...) {
        // Silently ignore exceptions in metrics recording to avoid crashing the application
    }
}

void MetricsCollector::recordError(const std::string& error, const std::string& query, const std::string& errorType) {
    try {
        std::lock_guard<std::mutex> lock(errorMutex_);
        totalErrors_.fetch_add(1, std::memory_order_relaxed);
        recentErrors_.push_back(ErrorEntry(errorType, JsonOutput::getIsoTimestamp(), error, query));
        if (recentErrors_.size() > 100) {
            recentErrors_.erase(recentErrors_.begin());
        }
    } catch (...) {
    }
}

// Phase 1 Optimization: Consolidate all thread-local metrics into main storage
void MetricsCollector::consolidateThreadMetrics() {
    std::lock_guard<std::mutex> lock(threadMetricsMutex_);
    
    for (const auto& pair : threadMetrics_) {
        ThreadLocalMetrics* local = pair.second;
        
        // Consolidate connection metrics
        {
            std::lock_guard<std::mutex> connLock(connectionMetrics_.mutex);
            connectionMetrics_.durations.insert(
                connectionMetrics_.durations.end(),
                local->connectionDurations.begin(),
                local->connectionDurations.end()
            );
            // Phase 3 Optimization: Use relaxed memory ordering for counter updates
            // Safe because mutex protects this consolidation and loads happen after thread joins
            connectionMetrics_.successCount.fetch_add(local->connectionSuccessCount, std::memory_order_relaxed);
            connectionMetrics_.failureCount.fetch_add(local->connectionFailureCount, std::memory_order_relaxed);
        }
        
        // Consolidate execution metrics
        {
            std::lock_guard<std::mutex> execLock(executionMetrics_.mutex);
            executionMetrics_.durations.insert(
                executionMetrics_.durations.end(),
                local->executionDurations.begin(),
                local->executionDurations.end()
            );
            // Phase 3 Optimization: Use relaxed memory ordering for counter updates
            executionMetrics_.successCount.fetch_add(local->executionSuccessCount, std::memory_order_relaxed);
            executionMetrics_.failureCount.fetch_add(local->executionFailureCount, std::memory_order_relaxed);
        }
        
        // Consolidate fetch metrics
        {
            std::lock_guard<std::mutex> fetchLock(fetchMetrics_.mutex);
            fetchMetrics_.durations.insert(
                fetchMetrics_.durations.end(),
                local->fetchDurations.begin(),
                local->fetchDurations.end()
            );
            // Phase 3 Optimization: Use relaxed memory ordering for counter updates
            fetchMetrics_.successCount.fetch_add(local->fetchSuccessCount, std::memory_order_relaxed);
            fetchMetrics_.failureCount.fetch_add(local->fetchFailureCount, std::memory_order_relaxed);
        }
        
        // Clean up thread-local metrics
        delete local;
    }
    
    threadMetrics_.clear();
}

MetricsCollector::Statistics MetricsCollector::calculateStats(const MetricData& data) const {
    Statistics stats;
    
    std::lock_guard<std::mutex> lock(data.mutex);
    
    stats.count = data.durations.size();
    // Phase 3 Optimization: Use relaxed memory ordering for final reads
    // Safe because thread join barrier ensures all updates are complete
    stats.successCount = data.successCount.load(std::memory_order_relaxed);
    stats.failureCount = data.failureCount.load(std::memory_order_relaxed);
    
    if (stats.count == 0) {
        return stats;
    }
    
    // Calculate total and average
    double sum = std::accumulate(data.durations.begin(), data.durations.end(), 0.0);
    stats.totalMicroseconds = sum;
    stats.avgMicroseconds = sum / stats.count;
    
    // Phase 2 Optimization: Sort once and calculate all percentiles + min/max from sorted vector
    std::vector<double> sorted = data.durations;
    std::sort(sorted.begin(), sorted.end());
    
    // Min and max are now just first and last elements (no extra scan needed)
    stats.minMicroseconds = sorted.front();
    stats.maxMicroseconds = sorted.back();
    
    // Calculate all percentiles from sorted vector (single pass)
    size_t p50_idx = sorted.size() * 50 / 100;
    size_t p95_idx = sorted.size() * 95 / 100;
    size_t p99_idx = sorted.size() * 99 / 100;
    
    stats.p50Microseconds = sorted[p50_idx];
    stats.p95Microseconds = sorted[p95_idx];
    stats.p99Microseconds = sorted[p99_idx];
    
    return stats;
}

MetricsCollector::Statistics MetricsCollector::getConnectionStats() const {
    return calculateStats(connectionMetrics_);
}

MetricsCollector::Statistics MetricsCollector::getExecutionStats() const {
    return calculateStats(executionMetrics_);
}

MetricsCollector::Statistics MetricsCollector::getFetchStats() const {
    return calculateStats(fetchMetrics_);
}

uint64_t MetricsCollector::getSuccessfulConnections() const {
    // Phase 3 Optimization: Use relaxed memory ordering for final reads
    return connectionMetrics_.successCount.load(std::memory_order_relaxed);
}

uint64_t MetricsCollector::getSuccessfulExecutions() const {
    // Phase 3 Optimization: Use relaxed memory ordering for final reads
    return executionMetrics_.successCount.load(std::memory_order_relaxed);
}

uint64_t MetricsCollector::getFailedConnections() const {
    // Phase 3 Optimization: Use relaxed memory ordering for final reads
    return connectionMetrics_.failureCount.load(std::memory_order_relaxed);
}

uint64_t MetricsCollector::getFailedExecutions() const {
    // Phase 3 Optimization: Use relaxed memory ordering for final reads
    return executionMetrics_.failureCount.load(std::memory_order_relaxed);
}

std::vector<ErrorEntry> MetricsCollector::getRecentErrors(size_t count) const {
    std::lock_guard<std::mutex> lock(errorMutex_);
    size_t start = recentErrors_.size() > count ? recentErrors_.size() - count : 0;
    return std::vector<ErrorEntry>(recentErrors_.begin() + start, recentErrors_.end());
}

void MetricsCollector::recordWarning(const std::string& warning) {
    try {
        std::lock_guard<std::mutex> lock(warningMutex_);
        recentWarnings_.push_back(ErrorEntry("odbc_warning", JsonOutput::getIsoTimestamp(), warning));
        if (recentWarnings_.size() > 100) {
            recentWarnings_.erase(recentWarnings_.begin());
        }
    } catch (...) {
        // Silently ignore exceptions in metrics recording
    }
}

std::vector<ErrorEntry> MetricsCollector::getRecentWarnings(size_t count) const {
    std::lock_guard<std::mutex> lock(warningMutex_);
    size_t start = recentWarnings_.size() > count ? recentWarnings_.size() - count : 0;
    return std::vector<ErrorEntry>(recentWarnings_.begin() + start, recentWarnings_.end());
}

void MetricsCollector::reset() {
    {
        std::lock_guard<std::mutex> lock(connectionMetrics_.mutex);
        connectionMetrics_.durations.clear();
        connectionMetrics_.successCount = 0;
        connectionMetrics_.failureCount = 0;
    }
    {
        std::lock_guard<std::mutex> lock(executionMetrics_.mutex);
        executionMetrics_.durations.clear();
        executionMetrics_.successCount = 0;
        executionMetrics_.failureCount = 0;
    }
    {
        std::lock_guard<std::mutex> lock(fetchMetrics_.mutex);
        fetchMetrics_.durations.clear();
        fetchMetrics_.successCount = 0;
        fetchMetrics_.failureCount = 0;
    }
    {
        std::lock_guard<std::mutex> lock(errorMutex_);
        recentErrors_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(warningMutex_);
        recentWarnings_.clear();
    }
    totalErrors_ = 0;
    totalWarnings_ = 0;
    liveConnectionSuccessCount_ = 0;
    liveConnectionFailureCount_ = 0;
    liveExecutionSuccessCount_ = 0;
    liveExecutionFailureCount_ = 0;
    startTime_ = std::chrono::steady_clock::now();
    startTimeIso_ = JsonOutput::getIsoTimestamp();
}

void MetricsCollector::printRuntime() const {
    // Phase 1 Optimization: Consolidate thread-local metrics before reading
    const_cast<MetricsCollector*>(this)->consolidateThreadMetrics();
    
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - startTime_);
    
    // Calculate total connection time
    double totalConnectionTime = 0.0;
    {
        std::lock_guard<std::mutex> lock(connectionMetrics_.mutex);
        if (!connectionMetrics_.durations.empty()) {
            for (const auto& duration : connectionMetrics_.durations) {
                totalConnectionTime += duration;
            }
        }
    }
    
    // Calculate total execution time
    double totalExecutionTime = 0.0;
    {
        std::lock_guard<std::mutex> lock(executionMetrics_.mutex);
        if (!executionMetrics_.durations.empty()) {
            for (const auto& duration : executionMetrics_.durations) {
                totalExecutionTime += duration;
            }
        }
    }
    
    double totalRuntimeSec = elapsed.count() / 1000.0;
    double totalConnTimeSec = totalConnectionTime / 1000000.0;
    double totalExecTimeSec = totalExecutionTime / 1000000.0;
    double totalWorkTimeSec = totalConnTimeSec + totalExecTimeSec;
    
    TS_OUT << std::endl;
    TS_OUT << std::string(70, '=') << '\n';
    TS_OUT << "Performance Metric Summary\n";
    TS_OUT << std::string(70, '=') << '\n';
    TS_OUT << "Total Runtime: " << std::fixed << std::setprecision(3) 
              << totalRuntimeSec << " seconds\n";
    TS_OUT << "Start Time: " << startTimeIso_ << '\n';
    TS_OUT << "End Time:   " << JsonOutput::getIsoTimestamp() << '\n';
    TS_OUT << '\n';

    // Connection and query execution averages
    auto connStats = getConnectionStats();
    auto execStats = getExecutionStats();
    if (connStats.count > 0) {
        TS_OUT << "Avg Connect Time: " << std::fixed << std::setprecision(2) << connStats.avgMicroseconds / 1000.0 << " ms"
                  << " (" << connStats.successCount << " successful, " << connStats.failureCount << " failed)\n";
    }
    if (execStats.count > 0) {
        TS_OUT << "Avg Elapsed: " << std::fixed << std::setprecision(2) << execStats.avgMicroseconds / 1000.0 << " ms"
                  << " (" << execStats.successCount << " successful, " << execStats.failureCount << " failed)\n";
    }
    TS_OUT << '\n';

    if (totalWorkTimeSec > 0) {
        TS_OUT << "Total Connection Time: " << std::fixed << std::setprecision(3)
                  << totalConnTimeSec << " seconds (" 
                  << std::fixed << std::setprecision(1) << (totalConnTimeSec / totalWorkTimeSec * 100.0) << "% of work)\n";
        TS_OUT << "Total Query Execution Time: " << std::fixed << std::setprecision(3)
                  << totalExecTimeSec << " seconds (" 
                  << std::fixed << std::setprecision(1) << (totalExecTimeSec / totalWorkTimeSec * 100.0) << "% of work)\n";
    } else {
        TS_OUT << "Total Connection Time: " << std::fixed << std::setprecision(3)
                  << totalConnTimeSec << " seconds\n";
        TS_OUT << "Total Query Execution Time: " << std::fixed << std::setprecision(3)
                  << totalExecTimeSec << " seconds\n";
    }
    
    // Always show error count (useful even in non-verbose mode)
    int64_t errorCount = totalErrors_.load(std::memory_order_relaxed);
    if (errorCount > 0) {
        TS_OUT << "Total Errors: " << errorCount << '\n';
    }
    int64_t warningCount = totalWarnings_.load(std::memory_order_relaxed);
    if (warningCount > 0) {
        TS_OUT << "Total Warnings: " << warningCount << '\n';
    }
    
    ConsoleOutput::flush();
}

void MetricsCollector::printSummary() const {
    // Phase 1 Optimization: Consolidate thread-local metrics before reading
    const_cast<MetricsCollector*>(this)->consolidateThreadMetrics();
    
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - startTime_);
    
    TS_OUT << std::string(70, '=') << '\n';
    TS_OUT << "Performance Metric Summary\n";
    TS_OUT << std::string(70, '=') << '\n';
    TS_OUT << "Total Runtime: " << std::fixed << std::setprecision(3) << elapsed.count() / 1000.0 << " seconds\n";
    TS_OUT << "Start Time: " << startTimeIso_ << '\n';
    TS_OUT << "End Time:   " << JsonOutput::getIsoTimestamp() << '\n';
    TS_OUT << "\n";
    
    auto printStats = [](const std::string& name, const Statistics& stats, int percentPrecision,
                         const std::string& timeLabel = "Latency") {
        TS_OUT << name << ":\n";
        TS_OUT << "Total Operations: " << stats.count << '\n';
        TS_OUT << "Successful: " << stats.successCount 
                  << " (" << std::fixed << std::setprecision(percentPrecision)
                  << (stats.count > 0 ? (100.0 * stats.successCount / stats.count) : 0.0) << "%)\n";
        TS_OUT << "Failed: " << stats.failureCount << '\n';
        
        if (stats.count > 0) {
            TS_OUT << "Avg " << timeLabel << ": " << std::fixed << std::setprecision(2) << stats.avgMicroseconds / 1000.0 << " ms\n";
        }
        TS_OUT << '\n';
    };
    
    printStats("Connection Operations", getConnectionStats(), 0, "Connect Time");
    printStats("Query Execution Operations", getExecutionStats(), 2, "Elapsed");
    printStats("Fetch Operations", getFetchStats(), 2);
    
    // Phase 3 Optimization: Use relaxed memory ordering for final reads
    TS_OUT << "Total Errors: " << totalErrors_.load(std::memory_order_relaxed) << '\n';
    int64_t totalWarnings = totalWarnings_.load(std::memory_order_relaxed);
    if (totalWarnings > 0) {
        TS_OUT << "Total Warnings: " << totalWarnings << '\n';
    }
    
    auto errors = getRecentErrors(5);
    if (!errors.empty()) {
        TS_OUT << std::endl;
        TS_OUT << "Recent Errors (last " << errors.size() << "):\n";
        for (size_t i = 0; i < errors.size(); ++i) {
            TS_OUT << "  " << (i + 1) << ". " << errors[i].message << '\n';
        }
    }
    
    // Add time breakdown summary (same as non-verbose mode)
    auto connStats = getConnectionStats();
    auto execStats = getExecutionStats();
    double totalRuntimeSec = elapsed.count() / 1000.0;
    double totalConnTimeSec = connStats.totalMicroseconds / 1000000.0;
    double totalExecTimeSec = execStats.totalMicroseconds / 1000000.0;
    double totalWorkTimeSec = totalConnTimeSec + totalExecTimeSec;
    
    TS_OUT << '\n';
    TS_OUT << "Time Breakdown:\n";
    TS_OUT << "Total Runtime: " << std::fixed << std::setprecision(3) 
              << totalRuntimeSec << " seconds\n";
    if (totalWorkTimeSec > 0) {
        TS_OUT << "Total Connection Time: " << std::fixed << std::setprecision(3)
                  << totalConnTimeSec << " seconds (" 
                  << std::fixed << std::setprecision(1) << (totalConnTimeSec / totalWorkTimeSec * 100.0) << "% of work)\n";
        TS_OUT << "Total Query Execution Time: " << std::fixed << std::setprecision(3)
                  << totalExecTimeSec << " seconds (" 
                  << std::fixed << std::setprecision(1) << (totalExecTimeSec / totalWorkTimeSec * 100.0) << "% of work)\n";
    } else {
        TS_OUT << "Total Connection Time: " << std::fixed << std::setprecision(3)
                  << totalConnTimeSec << " seconds\n";
        TS_OUT << "Total Query Execution Time: " << std::fixed << std::setprecision(3)
                  << totalExecTimeSec << " seconds\n";
    }
    
    TS_OUT << std::string(70, '=') << '\n';
    ConsoleOutput::flush();
}

void MetricsCollector::printJsonMetrics() const {
    // Phase 1 Optimization: Consolidate thread-local metrics before reading
    const_cast<MetricsCollector*>(this)->consolidateThreadMetrics();
    
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - startTime_);
    
    auto connStats = getConnectionStats();
    auto execStats = getExecutionStats();
    auto fetchStats = getFetchStats();
    
    double totalRuntimeSec = elapsed.count() / 1000.0;
    double totalConnTimeSec = connStats.totalMicroseconds / 1000000.0;
    double totalExecTimeSec = execStats.totalMicroseconds / 1000000.0;
    
    std::ostringstream out;
    out << "  \"metrics\": {\n";
    
    // Output driver version if available (queried after connecting)
    if (!driverVersion_.empty()) {
        out << JsonOutput::jsonPair("odbc_driver_version", driverVersion_);
    }
    
    out << JsonOutput::jsonPair("total_runtime_seconds", totalRuntimeSec);
    out << JsonOutput::jsonPair("total_connection_time_seconds", totalConnTimeSec);
    out << JsonOutput::jsonPair("total_query_execution_time_seconds", totalExecTimeSec);
    
    out << JsonOutput::jsonPair("end_time", JsonOutput::getIsoTimestamp());
    
    // Verbose mode: show detailed operation metrics (matches text -v output)
    if (verboseJsonEnabled_) {
        // Connection operations
        out << "    \"connection_operations\": {\n";
        out << JsonOutput::jsonPair("total", static_cast<int>(connStats.count));
        out << JsonOutput::jsonPair("successful", static_cast<int>(connStats.successCount));
        out << JsonOutput::jsonPair("failed", static_cast<int>(connStats.failureCount));
        if (connStats.count > 0) {
            out << JsonOutput::jsonPair("avg_connect_time_ms", connStats.avgMicroseconds / 1000.0, true);
        } else {
            out << "      \"avg_connect_time_ms\": 0\n";
        }
        out << "    },\n";
        
        // Query execution operations
        out << "    \"query_execution_operations\": {\n";
        out << JsonOutput::jsonPair("total", static_cast<int>(execStats.count));
        out << JsonOutput::jsonPair("successful", static_cast<int>(execStats.successCount));
        out << JsonOutput::jsonPair("failed", static_cast<int>(execStats.failureCount));
        if (execStats.count > 0) {
            out << JsonOutput::jsonPair("avg_elapsed_ms", execStats.avgMicroseconds / 1000.0, true);
        } else {
            out << "      \"avg_elapsed_ms\": 0\n";
        }
        out << "    },\n";
        
        // Fetch operations
        out << "    \"fetch_operations\": {\n";
        out << JsonOutput::jsonPair("total", static_cast<int>(fetchStats.count));
        out << JsonOutput::jsonPair("successful", static_cast<int>(fetchStats.successCount));
        out << JsonOutput::jsonPair("failed", static_cast<int>(fetchStats.failureCount), true);
        out << "    },\n";
    }
    
    // Errors block with total count and list of structured error entries
    auto errors = getRecentErrors(10);
    out << "    \"errors\": {\n";
    out << "      \"total\": " << totalErrors_.load(std::memory_order_relaxed) << ",\n";
    out << "      \"list\": [";
    if (!errors.empty()) {
        out << "\n";
        for (size_t i = 0; i < errors.size(); ++i) {
            const auto& err = errors[i];
            out << "        {\n";
            out << "          \"type\": \"" << JsonOutput::escapeJson(err.type) << "\",\n";
            out << "          \"timestamp\": \"" << JsonOutput::escapeJson(err.timestamp) << "\",\n";
            if (!err.query.empty()) {
                out << "          \"query\": \"" << JsonOutput::escapeJson(err.query) << "\",\n";
            }
            out << "          \"message\": \"" << JsonOutput::escapeJson(err.message) << "\"\n";
            out << "        }";
            if (i < errors.size() - 1) out << ",";
            out << "\n";
        }
        out << "      ";
    }
    out << "]\n";
    out << "    },\n";
    
    // Warnings block with total count and list of structured warning entries
    auto warnings = getRecentWarnings(10);
    out << "    \"warnings\": {\n";
    out << "      \"total\": " << totalWarnings_.load(std::memory_order_relaxed) << ",\n";
    out << "      \"list\": [";
    if (!warnings.empty()) {
        out << "\n";
        for (size_t i = 0; i < warnings.size(); ++i) {
            const auto& warn = warnings[i];
            out << "        {\n";
            out << "          \"type\": \"" << JsonOutput::escapeJson(warn.type) << "\",\n";
            out << "          \"timestamp\": \"" << JsonOutput::escapeJson(warn.timestamp) << "\",\n";
            out << "          \"message\": \"" << JsonOutput::escapeJson(warn.message) << "\"\n";
            out << "        }";
            if (i < warnings.size() - 1) out << ",";
            out << "\n";
        }
        out << "      ";
    }
    out << "]\n";
    out << "    }\n";
    
    out << "  },\n";
    
    if (!serverEdition_.empty()) {
        out << "  \"server_edition\": \"" << JsonOutput::escapeJson(serverEdition_) << "\",\n";
    }
    if (!serverVersion_.empty()) {
        out << "  \"server_version\": \"" << JsonOutput::escapeJson(serverVersion_) << "\",\n";
    }
    ConsoleOutput::write(std::cout, out.str());

    // Output verbose metrics if enabled (-v -json combined)
    if (verboseJsonEnabled_) {
        printVerboseJsonMetrics();
    }
    
    // Output replay summary if in replay mode
    if (hasReplaySummary()) {
        printReplaySummaryJson();
    }
    
    ConsoleOutput::flush();
}

void MetricsCollector::printJsonClose() const {
    std::ostringstream out;
    out << "  \"success\": " << (totalErrors_.load() == 0 ? "true" : "false") << "\n";
    out << "}\n";
    ConsoleOutput::write(std::cout, out.str(), true);
}

void MetricsCollector::recordThreadConnection(int threadId, double connectTimeMs, bool success, const std::string& errorMsg) {
    if (!verboseJsonEnabled_) return;
    
    std::lock_guard<std::mutex> lock(verboseMetricsMutex_);
    ThreadConnectionMetric metric;
    metric.threadId = threadId;
    metric.connectTimeMs = connectTimeMs;
    metric.success = success;
    metric.errorMessage = errorMsg;
    threadConnections_.push_back(metric);
}

void MetricsCollector::recordIterationMetric(int threadId, int iteration, double totalQueryMs, int queriesExecuted, int queriesFailed) {
    if (!verboseJsonEnabled_) return;
    
    std::lock_guard<std::mutex> lock(verboseMetricsMutex_);
    
    // Get or create thread iteration metrics
    auto& threadMetrics = threadIterationMetrics_[threadId];
    threadMetrics.threadId = threadId;
    
    IterationMetric iterMetric;
    iterMetric.iteration = iteration;
    iterMetric.totalQueryMs = totalQueryMs;
    iterMetric.queriesExecuted = queriesExecuted;
    iterMetric.queriesFailed = queriesFailed;
    threadMetrics.iterations.push_back(iterMetric);
}

void MetricsCollector::printVerboseJsonMetrics() const {
    std::lock_guard<std::mutex> lock(verboseMetricsMutex_);
    
    std::ostringstream out;
    // Connection string (masked)
    out << "  \"connection_string\": \"" << JsonOutput::escapeJson(maskedConnectionString_) << "\",\n";
    
    // Thread connections array
    out << "  \"thread_connections\": [";
    if (!threadConnections_.empty()) {
        out << "\n";
        for (size_t i = 0; i < threadConnections_.size(); ++i) {
            const auto& conn = threadConnections_[i];
            out << "    {";
            out << "\"thread_id\": " << conn.threadId << ", ";
            out << "\"connect_time_ms\": " << std::fixed << std::setprecision(3) << conn.connectTimeMs << ", ";
            out << "\"status\": \"" << (conn.success ? "success" : "failed") << "\"";
            if (!conn.success && !conn.errorMessage.empty()) {
                out << ", \"error\": \"" << JsonOutput::escapeJson(conn.errorMessage) << "\"";
            }
            out << "}";
            if (i < threadConnections_.size() - 1) out << ",";
            out << "\n";
        }
        out << "  ";
    }
    out << "],\n";
    
    // Thread iteration metrics array
    out << "  \"thread_iterations\": [";
    if (!threadIterationMetrics_.empty()) {
        out << "\n";
        
        // Sort thread IDs for consistent output
        std::vector<int> sortedThreadIds;
        for (const auto& pair : threadIterationMetrics_) {
            sortedThreadIds.push_back(pair.first);
        }
        std::sort(sortedThreadIds.begin(), sortedThreadIds.end());
        
        for (size_t ti = 0; ti < sortedThreadIds.size(); ++ti) {
            int threadId = sortedThreadIds[ti];
            const auto& threadMetrics = threadIterationMetrics_.at(threadId);
            
            out << "    {\n";
            out << "      \"thread_id\": " << threadMetrics.threadId << ",\n";
            out << "      \"iterations\": [";
            
            if (!threadMetrics.iterations.empty()) {
                out << "\n";
                for (size_t i = 0; i < threadMetrics.iterations.size(); ++i) {
                    const auto& iter = threadMetrics.iterations[i];
                    out << "        {";
                    out << "\"iteration\": " << iter.iteration << ", ";
                    out << "\"total_query_ms\": " << std::fixed << std::setprecision(3) << iter.totalQueryMs << ", ";
                    out << "\"queries_executed\": " << iter.queriesExecuted << ", ";
                    out << "\"queries_failed\": " << iter.queriesFailed;
                    out << "}";
                    if (i < threadMetrics.iterations.size() - 1) out << ",";
                    out << "\n";
                }
                out << "      ";
            }
            out << "]\n";
            out << "    }";
            if (ti < sortedThreadIds.size() - 1) out << ",";
            out << "\n";
        }
        out << "  ";
    }
    out << "],\n";
    ConsoleOutput::write(std::cout, out.str());
}

// ============================================================================
// Replay Summary
// ============================================================================

void MetricsCollector::recordReplayResult(int originalResult, bool replaySuccess, bool replayAbort) {
    replayOriginalTotal_.fetch_add(1, std::memory_order_relaxed);
    
    // Classify original trace outcome
    switch (originalResult) {
        case 0: replayOriginalOk_.fetch_add(1, std::memory_order_relaxed); break;
        case 1: replayOriginalError_.fetch_add(1, std::memory_order_relaxed); break;
        case 2: replayOriginalAbort_.fetch_add(1, std::memory_order_relaxed); break;
        default: replayOriginalOk_.fetch_add(1, std::memory_order_relaxed); break;  // Unknown = OK
    }
    
    // Classify replay outcome
    if (replaySuccess) {
        replayResultOk_.fetch_add(1, std::memory_order_relaxed);
    } else if (replayAbort) {
        replayResultAbort_.fetch_add(1, std::memory_order_relaxed);
    } else {
        replayResultError_.fetch_add(1, std::memory_order_relaxed);
    }
}

void MetricsCollector::printReplaySummary() const {
    uint64_t origTotal = replayOriginalTotal_.load(std::memory_order_relaxed);
    if (origTotal == 0) return;
    
    uint64_t origOk = replayOriginalOk_.load(std::memory_order_relaxed);
    uint64_t origError = replayOriginalError_.load(std::memory_order_relaxed);
    uint64_t origAbort = replayOriginalAbort_.load(std::memory_order_relaxed);
    
    uint64_t resultOk = replayResultOk_.load(std::memory_order_relaxed);
    uint64_t resultError = replayResultError_.load(std::memory_order_relaxed);
    uint64_t resultAbort = replayResultAbort_.load(std::memory_order_relaxed);
    uint64_t resultTotal = resultOk + resultError + resultAbort;
    
    TS_OUT << std::endl;
    TS_OUT << "Replay Summary:\n";
    TS_OUT << "  Original trace: " << origTotal << " events ("
           << origOk << " ok, " << origError << " error, " << origAbort << " abort)\n";
    TS_OUT << "  Replay result:  " << resultTotal << " events ("
           << resultOk << " ok, " << resultError << " error, " << resultAbort << " abort)\n";
}

void MetricsCollector::printReplaySummaryJson() const {
    uint64_t origTotal = replayOriginalTotal_.load(std::memory_order_relaxed);
    if (origTotal == 0) return;
    
    uint64_t origOk = replayOriginalOk_.load(std::memory_order_relaxed);
    uint64_t origError = replayOriginalError_.load(std::memory_order_relaxed);
    uint64_t origAbort = replayOriginalAbort_.load(std::memory_order_relaxed);
    
    uint64_t resultOk = replayResultOk_.load(std::memory_order_relaxed);
    uint64_t resultError = replayResultError_.load(std::memory_order_relaxed);
    uint64_t resultAbort = replayResultAbort_.load(std::memory_order_relaxed);
    uint64_t resultTotal = resultOk + resultError + resultAbort;
    
    std::ostringstream out;
    out << "  \"replay_summary\": {\n";
    out << "    \"original\": {\n";
    out << "      \"events\": " << origTotal << ",\n";
    out << "      \"ok\": " << origOk << ",\n";
    out << "      \"error\": " << origError << ",\n";
    out << "      \"abort\": " << origAbort << "\n";
    out << "    },\n";
    out << "    \"result\": {\n";
    out << "      \"events\": " << resultTotal << ",\n";
    out << "      \"ok\": " << resultOk << ",\n";
    out << "      \"error\": " << resultError << ",\n";
    out << "      \"abort\": " << resultAbort << "\n";
    out << "    }\n";
    out << "  },\n";
    ConsoleOutput::write(std::cout, out.str());
}
