#include "workload_simulator.h"
#include "file_open_error.h"
#include "platform_termination.h"
#include "timestamp_helper.h"
#include "version.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <thread>
#include <chrono>
#include <iomanip>
#include <algorithm>
#include <cctype>
#include <map>
#include <random>
#include <regex>
#include <set>

// Helper: create a short preview of a query for error messages
static std::string makeQueryPreview(const std::string& query, size_t maxLen = 80) {
    std::string preview = query;
    for (auto& c : preview) { if (c == '\n' || c == '\r') c = ' '; }
    if (preview.length() > maxLen) {
        preview.resize(maxLen);
        preview += "...";
    }
    return preview;
}

// SECURITY FIX (C-2): Comprehensive credential masking function
// Masks passwords, usernames, and access tokens in connection strings
std::string maskConnectionString(const std::string& connStr) {
    // ODBC braces values that contain ';', so mask through the closing brace.
    static const std::regex sensitivePattern(
        R"((PWD|Password|UID|Username|User ID|UserId|AccessToken|Access Token)=(?:\{(?:\}\}|[^}])*\}|[^;]*))",
        std::regex::icase);
    return std::regex_replace(connStr, sensitivePattern, "$1=********");
}

WorkloadSimulator::WorkloadSimulator(const WorkloadConfig& config)
    : config_(config), running_(false) {
    metrics_.setLiveMetricsEnabled(config_.streamJsonOutput);
    sqlsim::platform::installTerminationHandlers();
}

WorkloadSimulator::~WorkloadSimulator() {
    stop();
    
    // Join snapshot timer thread if active
    if (snapshotThread_.joinable()) {
        snapshotThread_.join();
    }
    if (streamJsonThread_.joinable()) {
        streamJsonThread_.join();
    }
    
    sqlsim::platform::uninstallTerminationHandlers();
}

bool WorkloadSimulator::run() {
    if (config_.verbose && !config_.jsonOutput) {
        TS_OUT << std::endl;
        TS_OUT << std::string(70, '=') << '\n';
        TS_OUT << "SQL Workload Simulator\n";
        TS_OUT << "ODBC Driver: ODBC Driver 18 for SQL Server\n";
        TS_OUT << std::string(70, '=') << std::endl;
        
        TS_OUT << "[PHASE 1] Configuration\n";
        TS_OUT << "Threads: " << config_.numThreads << '\n';
        
        if (!config_.workloadFile.empty()) {
            // Workload file mode
            TS_OUT << "Workload file: " << config_.workloadFile << '\n';
            bool isDurationMode = !config_.workloadEntries.empty() && config_.workloadEntries[0].duration_seconds > 0;
            if (isDurationMode) {
                TS_OUT << "Duration: " << config_.workloadEntries[0].duration_seconds << " seconds\n";
            } else {
                int totalBatches = 0;
                for (const auto& entry : config_.workloadEntries) {
                    totalBatches += entry.threads * entry.iterations * static_cast<int>(entry.queries.size());
                }
                TS_OUT << "Total batches to execute: " << totalBatches << '\n';
            }
            TS_OUT << "Workload groups: " << config_.workloadEntries.size() << '\n';
        } else {
            TS_OUT << "Iterations per thread: " << config_.iterationsPerThread << '\n';
            
            if (config_.queries.empty()) {
                TS_OUT << "Mode: Connection test only\n";
            } else {
                TS_OUT << "Total batches to execute: " << (config_.numThreads * config_.iterationsPerThread * config_.queries.size()) << '\n';
                TS_OUT << "Batches in workload: " << config_.queries.size() << '\n';
                TS_OUT << "Prepared Statements: " << (config_.usePreparedStatements ? "Yes" : "No") << '\n';
            }
        }
        
        // Display connection string (mask all credentials)
        std::string displayConnStr = maskConnectionString(config_.connectionString);
        TS_OUT << "Connection String: " << displayConnStr << '\n';
        
        if (!config_.queries.empty()) {
            // Display the batches to be executed
            TS_OUT << std::endl;
            TS_OUT << "Batches to execute:\n";
            for (size_t i = 0; i < config_.queries.size(); ++i) {
                TS_OUT << "[" << (i + 1) << "] " << config_.queries[i] << '\n';
            }
        }
        
        // Connection behavior options
        if (config_.reconnectPerIteration) {
            TS_OUT << "Reconnect per iteration: Yes" << '\n';
            if (config_.useConnectionPooling) {
                TS_OUT << "Connection pooling: Yes" << '\n';
            }
        }
    }
    
    // Determine if we're in replay mode
    bool isReplayMode = !config_.replayMode.empty();

    if (config_.streamJsonOutput) {
        metrics_.reset();
        workloadStartTime_ = std::chrono::steady_clock::now();
        writeStreamJsonEvent("started");
    }

    running_ = true;
    if (config_.streamJsonOutput) {
        streamJsonThread_ = std::thread(&WorkloadSimulator::streamJsonTimerThread, this);
    }
    
    if (config_.verbose && !config_.jsonOutput) {
        TS_OUT << std::endl;
        TS_OUT << "[PHASE 2] Initializing worker threads\n";
    }
    
    if (isReplayMode) {
        {
            std::lock_guard<std::mutex> lock(replayConnectionsMutex_);
            replayConnections_.clear();
        }

        // Replay mode: thread count depends on mode
        int threadCount;
        if (config_.replayMode == "fast") {
            // Fast mode: one thread per session
            threadCount = static_cast<int>(config_.replayData.sessions.size());
            if (threadCount == 0) {
                if (!config_.jsonOutput) {
                    TS_ERR << "sqlsim error: No replayable sessions found in replay file" << std::endl;
                }
                return false;
            }
        } else {
            // Stress mode: user-specified thread count
            threadCount = config_.numThreads;
        }
        
        // Launch replay worker threads
        connectionMessages_.reserve(threadCount);
        for (int i = 0; i < threadCount; ++i) {
            threads_.emplace_back(&WorkloadSimulator::replayWorkerThread, this, i);
        }
        if (config_.verbose && !config_.jsonOutput) {
            TS_OUT << "Launched " << threadCount << " replay worker thread(s) (" << config_.replayMode << " mode)\n";
        }
    } else {
        // Normal mode: launch worker threads
        connectionMessages_.reserve(config_.numThreads);
        if (config_.rampBatchSize > 0 && config_.rampBatchSize < config_.numThreads) {
            // Ramp-up mode: launch threads in batches to avoid connection storms
            for (int i = 0; i < config_.numThreads; ++i) {
                threads_.emplace_back(&WorkloadSimulator::workerThread, this, i);
                // After each batch (except the last), pause before launching the next
                if ((i + 1) % config_.rampBatchSize == 0 && (i + 1) < config_.numThreads) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(config_.rampDelayMs));
                }
            }
            if (config_.verbose && !config_.jsonOutput) {
                TS_OUT << "Launched " << config_.numThreads << " worker thread(s) (ramp: "
                       << config_.rampBatchSize << " per batch, " << config_.rampDelayMs << "ms delay)\n";
            }
        } else {
            for (int i = 0; i < config_.numThreads; ++i) {
                threads_.emplace_back(&WorkloadSimulator::workerThread, this, i);
            }
            if (config_.verbose && !config_.jsonOutput) {
                TS_OUT << "Launched " << config_.numThreads << " worker thread(s)\n";
            }
        }
    }
    
    if (config_.verbose && !config_.jsonOutput) {
        TS_OUT << std::endl;
        TS_OUT << "[PHASE 3] Connecting to database\n";
    }
    
    // Enable verbose JSON mode if both -v and -json are specified
    if (config_.verbose && config_.jsonOutput && !config_.streamJsonOutput) {
        metrics_.setVerboseJsonEnabled(true);
        metrics_.setMaskedConnectionString(maskConnectionString(config_.connectionString));
    }
    
    // Reset metrics timer to start from actual workload execution
    if (!config_.streamJsonOutput) {
        metrics_.reset();
    }
    
    // Phase 1 Optimization: Pre-allocate metrics vectors. Computed in size_t
    // and capped: the vectors still grow on demand, so a large -n x -r run
    // need not commit gigabytes before the first query executes.
    constexpr size_t maxReservedOps = 1000000;
    size_t estimatedExecutions;
    size_t estimatedConnections;
    if (isReplayMode) {
        estimatedExecutions = static_cast<size_t>(config_.replayData.replayableEvents) * static_cast<size_t>(config_.iterationsPerThread);
        estimatedConnections = isReplayMode && config_.replayMode == "fast" 
            ? config_.replayData.sessions.size() : static_cast<size_t>(config_.numThreads);
    } else {
        estimatedExecutions = static_cast<size_t>(config_.numThreads) * static_cast<size_t>(config_.iterationsPerThread) * config_.queries.size();
        estimatedConnections = static_cast<size_t>(config_.numThreads);
        if (config_.reconnectPerIteration) {
            estimatedConnections = static_cast<size_t>(config_.numThreads) * static_cast<size_t>(config_.iterationsPerThread);
        }
    }
    metrics_.reserveCapacity((std::min)(estimatedExecutions, maxReservedOps), (std::min)(estimatedConnections, maxReservedOps));
    
    // Record workload start time for snapshot elapsed calculation
    if (!config_.streamJsonOutput) {
        workloadStartTime_ = std::chrono::steady_clock::now();
    }
    hasFirstExecution_.store(false, std::memory_order_relaxed);
    firstExecutionNs_.store(0, std::memory_order_relaxed);
    lastExecutionNs_.store(0, std::memory_order_relaxed);
    peakThroughput_ = 0.0;
    
    // Start querystats snapshot timer thread if interval is configured
    if (config_.queryStatsIntervalSec > 0 && !config_.queryStatsFile.empty()) {
        snapshotThread_ = std::thread(&WorkloadSimulator::snapshotTimerThread, this);
    }
    
    // Wait for all threads to complete
    {
        std::lock_guard<std::mutex> lock(joinMutex_);
        for (auto& thread : threads_) {
            if (thread.joinable()) {
                thread.join();
            }
        }
    }
    
    running_ = false;
    streamJsonCV_.notify_all();

    if (streamJsonThread_.joinable()) {
        streamJsonThread_.join();
    }
    
    // Write final querystats snapshot and stop timer thread
    if (config_.queryStatsIntervalSec > 0 && !config_.queryStatsFile.empty()) {
        // Write the final "complete" snapshot
        writeQueryStatsSnapshot(true);
        
        // Join the timer thread
        if (snapshotThread_.joinable()) {
            snapshotThread_.join();
        }
    }
    
    threads_.clear();
    
    // Pass driver version to metrics for JSON output
    if (config_.jsonOutput) {
        std::lock_guard<std::mutex> lock(driverVersionMutex_);
        if (!driverVersion_.empty()) {
            metrics_.setDriverVersion(driverVersion_);
        }
    }
    
    // Pass server edition and version to metrics for JSON output
    if (config_.jsonOutput) {
        std::lock_guard<std::mutex> lock(editionMutex_);
        if (!serverEdition_.empty()) {
            metrics_.setServerEdition(serverEdition_);
        }
        if (!serverVersion_.empty()) {
            metrics_.setServerVersion(serverVersion_);
        }
    }
    
    // Print all buffered errors with proper timestamps
    if (!config_.jsonOutput && !bufferedErrors_.empty()) {
        std::lock_guard<std::mutex> lock(stderrMutex_);
        for (const auto& error : bufferedErrors_) {
            printMultiLineError(error);
        }
    }
    
    // Flush stderr to ensure errors appear before summary
    std::cerr << std::flush;
    std::cout << std::flush;
    
    if (config_.streamJsonOutput) {
        metrics_.consolidateThreadMetrics();
    }

    // Check if any errors occurred (used for return value)
    bool hasErrors = metrics_.getTotalErrors() > 0 || (isReplayMode
        ? (metrics_.getFailedExecutions() > 0 || metrics_.getSuccessfulExecutions() == 0)
        : (config_.queries.empty())
            ? (metrics_.getFailedConnections() > 0 || metrics_.getSuccessfulConnections() == 0)
            : (metrics_.getFailedExecutions() > 0 || metrics_.getSuccessfulExecutions() == 0));
    
    if (config_.streamJsonOutput) {
        writeStreamJsonEvent("completed", !hasErrors);
    } else if (config_.jsonOutput) {
        printJsonResult();
    } else if (config_.verbose) {
        TS_OUT << std::endl;
        TS_OUT << "[PHASE 5] Workload execution completed\n";
        TS_OUT << std::string(70, '=') << '\n';
        
        // Print query stats if enabled (before summary)
        if (config_.queryStats && !queryStats_.empty()) {
            printTextQueryStats();
        }
        
        // Print summary
        metrics_.printSummary();
        
        // Print replay summary if in replay mode
        if (metrics_.hasReplaySummary()) {
            metrics_.printReplaySummary();
        }
    } else {
        // Print query stats if enabled (before runtime)
        if (config_.queryStats && !queryStats_.empty()) {
            printTextQueryStats();
        }
        
        // Print just runtime in non-verbose mode
        metrics_.printRuntime();
        
        // Print replay summary if in replay mode
        if (metrics_.hasReplaySummary()) {
            metrics_.printReplaySummary();
        }
    }
    std::cout << std::flush; // Single flush at end
    
    // Determine success: return failure (exit code 1) if ANY errors occurred
    // This ensures scripts can detect SQL errors via exit code
    // Check totalErrors_ in addition to failed counters to catch errors
    // detected during result set processing (e.g., errors from non-first
    // statements in a multi-statement batch found via SQLMoreResults)
    if (config_.queries.empty()) {
        // Connection-only mode: success only if no connections failed
        return metrics_.getFailedConnections() == 0 && metrics_.getTotalErrors() == 0 && metrics_.getSuccessfulConnections() > 0;
    } else {
        // Query mode: success only if no executions failed and no errors recorded
        return metrics_.getFailedExecutions() == 0 && metrics_.getTotalErrors() == 0 && metrics_.getSuccessfulExecutions() > 0;
    }
}

void WorkloadSimulator::printJsonResult() const {
    if (!config_.replayMode.empty()) {
        printJsonReplayCapture();
    }

    if (config_.queryStats && !queryStats_.empty()) {
        printJsonQueryStats();
    }

    if (hasFirstExecution_.load(std::memory_order_acquire)) {
        int64_t firstNs = firstExecutionNs_.load(std::memory_order_acquire);
        int64_t lastNs = lastExecutionNs_.load(std::memory_order_acquire);
        double execElapsedSec = (lastNs - firstNs) / 1e9;
        std::cout << std::fixed << std::setprecision(3);
        std::cout << JsonOutput::jsonPair("execution_elapsed_seconds", execElapsedSec);
        if (config_.queryStats && peakThroughput_ > 0.0) {
            std::cout << std::fixed << std::setprecision(1);
            std::cout << JsonOutput::jsonPair("peak_throughput", peakThroughput_);
        }
    }

    {
        std::lock_guard<std::mutex> lock(connTimesMutex_);
        if (!connTimesMs_.empty()) {
            double sum = 0, minVal = connTimesMs_[0], maxVal = connTimesMs_[0];
            for (double timeMs : connTimesMs_) {
                sum += timeMs;
                if (timeMs < minVal) minVal = timeMs;
                if (timeMs > maxVal) maxVal = timeMs;
            }
            std::cout << std::fixed << std::setprecision(3);
            std::cout << "  \"connection_stats\": {\n";
            std::cout << "    \"avg_ms\": " << (sum / connTimesMs_.size()) << ",\n";
            std::cout << "    \"min_ms\": " << minVal << ",\n";
            std::cout << "    \"max_ms\": " << maxVal << ",\n";
            std::cout << "    \"count\": " << connTimesMs_.size() << "\n";
            std::cout << "  },\n";
        }
    }

    metrics_.printJsonMetrics();
    metrics_.printJsonClose();
}

void WorkloadSimulator::stop() {
    running_ = false;
    streamJsonCV_.notify_all();
    
    // Use mutex to ensure only one code path joins threads
    std::lock_guard<std::mutex> lock(joinMutex_);
    
    // Join all threads if they haven't been joined yet
    for (auto& thread : threads_) {
        if (thread.joinable()) {
            thread.join();
        }
    }
    threads_.clear();
}

std::string WorkloadSimulator::queryServerEdition(ODBCConnection& conn) {
    // Query server edition - requires no special permissions
    if (conn.execute("SELECT CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))")) {
        if (conn.fetch()) {
            return conn.getColumnValue(1);
        }
    }
    return "";
}

std::string WorkloadSimulator::queryServerVersion(ODBCConnection& conn) {
    // Query server product version (e.g. "16.0.4175.1") - requires no special permissions
    if (conn.execute("SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))")) {
        if (conn.fetch()) {
            return conn.getColumnValue(1);
        }
    }
    return "";
}

void WorkloadSimulator::workerThread(int threadId) {
    try {
        // Create connection for this thread
        ODBCConnection conn;
    
        auto start = std::chrono::steady_clock::now();
        bool connected;
        
        // Use access token if provided, otherwise use connection string authentication
        if (!config_.accessToken.empty()) {
            connected = conn.connectWithAccessToken(config_.connectionString, config_.accessToken, config_.loginTimeout);
        } else {
            connected = conn.connect(config_.connectionString, config_.loginTimeout);
        }
        
        auto end = std::chrono::steady_clock::now();
        
        metrics_.recordConnection(
            std::chrono::duration_cast<std::chrono::microseconds>(end - start),
            connected
        );
        
        auto connTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        
        // Record connection time for querystats snapshot
        if (connected) {
            std::lock_guard<std::mutex> lock(connTimesMutex_);
            connTimesMs_.push_back(static_cast<double>(connTime));
        }
        
        // Record verbose JSON connection metric if enabled
        if (config_.verbose && config_.jsonOutput && !config_.streamJsonOutput) {
            if (!connected) {
                metrics_.recordThreadConnection(threadId, static_cast<double>(connTime), false, conn.getLastError());
            } else {
                metrics_.recordThreadConnection(threadId, static_cast<double>(connTime), true);
            }
        }
        
        // Buffer the connection message
        std::ostringstream msg;
        if (!connected) {
            // Phase 2 Optimization: Use const reference to avoid string copy
            const std::string& error = conn.getLastError();
            
            // Check if this is a login timeout error (SQLSTATE HYT00 or HYT01, or error message contains timeout-related text)
            bool isTimeout = (error.find("HYT00") != std::string::npos || 
                             error.find("HYT01") != std::string::npos ||
                             error.find("timeout") != std::string::npos ||
                             error.find("Timeout") != std::string::npos ||
                             error.find("timed out") != std::string::npos ||
                             error.find("TIMEOUT") != std::string::npos);
            
            if (isTimeout) {
                // Buffer error for display after thread completion (skip in JSON mode)
                if (!config_.jsonOutput) {
                    std::lock_guard<std::mutex> lock(stderrMutex_);
                    bufferedErrors_.push_back(error);
                }
                if (config_.loginTimeout > 0) {
                    msg << "Thread " << threadId << ": Connection TIMED OUT (" << config_.loginTimeout << "s) - " << error;
                } else {
                    msg << "Thread " << threadId << ": Connection TIMED OUT (driver default) - " << error;
                }
                metrics_.recordError("Login timeout: " + error);
            } else {
                // Buffer error for display after thread completion (skip in JSON mode)
                if (!config_.jsonOutput) {
                    std::lock_guard<std::mutex> lock(stderrMutex_);
                    bufferedErrors_.push_back(error);
                }
                msg << "Thread " << threadId << ": Connection FAILED - " << error;
                metrics_.recordError("Connection failed: " + error);
            }
            
            if (config_.verbose) {
                std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                connectionMessages_.push_back(msg.str());
            }
            
            // Check if all threads have completed connection attempts
            // Atomic increment is safe, but we need to protect vector operations
            if (++connectionsCompleted_ == config_.numThreads) {
                if (config_.verbose && !config_.jsonOutput) {
                    // SECURITY FIX (H-2): Protect vector access with mutex
                    std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                    for (const auto& message : connectionMessages_) {
                        TS_OUT << message << std::endl;
                    }
                }
            }
            return;
        }
        
        // Set query timeout if specified
        if (config_.queryTimeout > 0) {
            if (!conn.setQueryTimeout(config_.queryTimeout)) {
                msg << "Thread " << threadId << ": Failed to set query timeout - " << conn.getLastError();
                metrics_.recordError("Failed to set query timeout: " + conn.getLastError());
                
                if (config_.verbose) {
                    std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                    connectionMessages_.push_back(msg.str());
                }
                return;
            }
        }
        
        // Enable SET STATISTICS TIME/IO if querystats is enabled
        // Phase 1b: Register thread slot for lock-free querystats recording
        QueryStatsCollector::Slot* qsSlot = nullptr;
        int64_t querySpid = 0;
        if (config_.queryStats) {
            querySpid = conn.getServerProcessId();
            conn.execute("SET STATISTICS TIME ON; SET STATISTICS IO ON");
            conn.clearInfoMessages();
            qsSlot = queryStats_.registerThread();
        }
        
        msg << "Thread " << threadId << ": Connected successfully (" << connTime << " ms)";
        
        if (config_.verbose && !config_.jsonOutput) {
            std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
            connectionMessages_.push_back(msg.str());
        }
        
        // Query ODBC driver version (only first thread does this)
        if (!driverVersionQueried_.exchange(true)) {
            std::string version = conn.getDriverVersion();
            if (!version.empty() && version != "unknown") {
                std::lock_guard<std::mutex> lock(driverVersionMutex_);
                driverVersion_ = version;
            }
        }
        
        // Structured results record the server so live and saved runs can be compared.
        if ((config_.verbose || config_.jsonOutput || config_.streamJsonOutput) &&
            !editionQueried_.exchange(true)) {
            std::string edition = queryServerEdition(conn);
            std::string version = queryServerVersion(conn);
            if (config_.queryStats) {
                conn.clearInfoMessages();
            }
            if (!edition.empty() || !version.empty()) {
                std::lock_guard<std::mutex> lock(editionMutex_);
                serverEdition_ = edition;
                serverVersion_ = version;
            }
        }
        // Atomic increment is safe, but we need to protect vector operations
        if (++connectionsCompleted_ == config_.numThreads) {
            if (config_.verbose && !config_.jsonOutput) {
                // SECURITY FIX (H-2): Protect vector sort/access with mutex
                std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                std::sort(connectionMessages_.begin(), connectionMessages_.end());
                for (const auto& message : connectionMessages_) {
                    TS_OUT << message << '\n';
                }
                // Display ODBC driver version if retrieved
                {
                    std::lock_guard<std::mutex> dvLock(driverVersionMutex_);
                    if (!driverVersion_.empty()) {
                        TS_OUT << "ODBC Driver Version: " << driverVersion_ << '\n';
                    }
                }
                // Display server edition if retrieved
                {
                    std::lock_guard<std::mutex> edLock(editionMutex_);
                    if (!serverEdition_.empty()) {
                        std::string editionLine = "Server Edition: " + serverEdition_;
                        if (!serverVersion_.empty()) {
                            editionLine += " (v" + serverVersion_ + ")";
                        }
                        TS_OUT << editionLine << '\n';
                    }
                }
                TS_OUT << std::endl;
                TS_OUT << "[PHASE 4] Executing workload\n";
            } else if (!config_.jsonOutput) {
                // Non-verbose mode: show driver version and execution start message
                {
                    std::lock_guard<std::mutex> dvLock(driverVersionMutex_);
                    if (!driverVersion_.empty()) {
                        TS_OUT << "ODBC Driver Version: " << driverVersion_ << std::endl;
                    }
                }
                TS_OUT << "Starting execution (" << config_.numThreads << (config_.numThreads == 1 ? " thread)" : " threads)") << std::endl;
            }
            connectionCV_.notify_all(); // Wake all waiting threads
        } else {
            // Wait for the last thread to complete using condition variable
            std::unique_lock<std::mutex> lock(connectionMessagesMutex_);
            connectionCV_.wait(lock, [this]() { return connectionsCompleted_.load() >= config_.numThreads; });
        }
        
        // Check if stop was requested during connection phase
        if (!running_) {
            conn.disconnect();
            return;
        }
        
        // Execute workload (skip if no queries - connection test only)
        // In workload file mode, each thread has its own query list and iteration count
        const auto& threadQueries = (!config_.threadAssignments.empty() && threadId < static_cast<int>(config_.threadAssignments.size()))
            ? config_.threadAssignments[threadId].queries
            : config_.queries;
        int threadIterations = (!config_.threadAssignments.empty() && threadId < static_cast<int>(config_.threadAssignments.size()))
            ? config_.threadAssignments[threadId].iterations
            : config_.iterationsPerThread;
        int threadDurationSec = (!config_.threadAssignments.empty() && threadId < static_cast<int>(config_.threadAssignments.size()))
            ? config_.threadAssignments[threadId].duration_seconds
            : 0;
        int threadThinkTimeMs = (!config_.threadAssignments.empty() && threadId < static_cast<int>(config_.threadAssignments.size()))
            ? config_.threadAssignments[threadId].think_time_ms
            : 0;
        
        // Duration mode: run until deadline. Iteration mode: run for fixed count.
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(threadDurationSec);
        
        if (!threadQueries.empty()) {
            for (int iter = 0; (threadDurationSec > 0 ? std::chrono::steady_clock::now() < deadline : iter < threadIterations) && running_; ++iter) {
                // Track iteration metrics for verbose JSON (skip overhead when not needed)
                auto iterationStart = std::chrono::steady_clock::now();
                int queriesExecutedThisIteration = 0;
                int queriesFailedThisIteration = 0;
                
                // If reconnect is enabled, disconnect/reconnect for each iteration (except the first)
                if (config_.reconnectPerIteration && iter > 0) {
                    conn.disconnect();
                    
                    auto reconStart = std::chrono::steady_clock::now();
                    bool reconnected;
                    
                    // Use access token if provided, otherwise use connection string authentication
                    if (!config_.accessToken.empty()) {
                        reconnected = conn.connectWithAccessToken(config_.connectionString, config_.accessToken, config_.loginTimeout);
                    } else {
                        reconnected = conn.connect(config_.connectionString, config_.loginTimeout);
                    }
                    
                    auto reconEnd = std::chrono::steady_clock::now();
                    
                    metrics_.recordConnection(
                        std::chrono::duration_cast<std::chrono::microseconds>(reconEnd - reconStart),
                        reconnected
                    );
                    
                    if (!reconnected) {
                        // Phase 2 Optimization: Use const reference to avoid string copy
                        const std::string& error = conn.getLastError();
                        
                        // Buffer error for display after thread completion (skip in JSON mode)
                        if (!config_.jsonOutput) {
                            std::lock_guard<std::mutex> lock(stderrMutex_);
                            bufferedErrors_.push_back(error);
                        }
                        metrics_.recordError("Reconnection failed: " + error);
                        
                        if (config_.stopOnError) {
                            if (!config_.jsonOutput) TS_ERR << "STOP: Stopping execution due to reconnection error (-stoponerror flag is set)\n";
                            running_ = false;
                            return;
                        }
                        continue; // Skip this iteration if reconnection failed
                    }
                    
                    // Re-enable SET STATISTICS after reconnection
                    if (config_.queryStats) {
                        querySpid = conn.getServerProcessId();
                        conn.execute("SET STATISTICS TIME ON; SET STATISTICS IO ON");
                        conn.clearInfoMessages();
                    }
                }
                
                // Execute each query in the workload
                for (const auto& query : threadQueries) {
                    if (!running_) break;
                    
                    // Start timing for total elapsed (includes execute + fetch + result consumption)
                    auto queryStartTime = std::chrono::steady_clock::now();
                    
                    bool success;
                    if (config_.usePreparedStatements) {
                        success = conn.executePrepared(query);
                    } else {
                        success = conn.execute(query);
                    }
                    
                    // Initialize per-query stats for querystats mode
                    QueryExecutionStats queryExecStats;
                    queryExecStats.spid = querySpid;
                    
                    // Track per-iteration metrics for verbose JSON
                    queriesExecutedThisIteration++;
                    
                    if (!success) {
                        queriesFailedThisIteration++;
                        
                        // Phase 2 Optimization: Use const reference to avoid string copy
                        const std::string& error = conn.getLastError();
                        
                        // Check if this is a query timeout error - do single search for common case
                        size_t hytPos = error.find("HYT");
                        bool isTimeout = (hytPos != std::string::npos && 
                                         (error.substr(hytPos, 5) == "HYT00" || error.substr(hytPos, 5) == "HYT01")) ||
                                         error.find("timeout") != std::string::npos;
                        
                        // Buffer error for display after thread completion (skip in JSON mode - errors collected in recent_errors)
                        if (!config_.jsonOutput) {
                            std::lock_guard<std::mutex> lock(stderrMutex_);
                            bufferedErrors_.push_back(error);
                        }
                        
                        if (isTimeout) {
                            metrics_.recordError("Query timeout: " + error, query, "sql_error");
                        } else {
                            metrics_.recordError("Query execution failed: " + error, query, "sql_error");
                        }
                        
                        // Record failed execution in querystats so query gets a Q# in the detail table
                        if (config_.queryStats) {
                            QueryExecutionStats failedStats;
                            failedStats.spid = querySpid;
                            failedStats.success = false;
                            queryStats_.record(qsSlot, query, failedStats);
                        }
                        
                        // Record failed execution elapsed time
                        auto failEndTime = std::chrono::steady_clock::now();
                        metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(failEndTime - queryStartTime), false);
                        
                        // If stop on error is enabled, stop execution
                        if (config_.stopOnError) {
                            if (!config_.jsonOutput) TS_ERR << "STOP: Stopping execution due to error (-stoponerror flag is set)\n";
                            running_ = false;
                            return;
                        }
                        
                        continue;
                    }
                    
                    // Process all result sets from the query
                    int totalRowCount = 0;
                    // Display output is collected as plain text and timestamped and
                    // written after the timer stops, so formatting and console or -o
                    // file I/O are not counted as query time.
                    std::ostringstream displayBuffer;
                    auto flushDisplay = [&]() {
                        if (displayBuffer.tellp() > 0) {
                            const std::string text = TimestampHelper::prefixLines(displayBuffer.str());
                            std::lock_guard<std::mutex> outLock(resultOutputMutex_);
                            std::cout << text << std::flush;
                        }
                    };
                    
                    do {
                        // Display any accumulated PRINT messages before showing results
                        // This matches sqlcmd behavior where PRINT output appears before SELECT results
                        // Skip entirely in quiet non-querystats mode (no messages to display or parse)
                        const auto& pendingMessages = conn.getInfoMessages();
                        if (!pendingMessages.empty()) {
                            if (config_.queryStats) {
                                // Parse and filter SET STATISTICS messages for aggregation
                                auto nonStatsMessages = QueryStatsCollector::parseAndFilterMessages(pendingMessages, queryExecStats);
                                if (!config_.quietMode && !config_.jsonOutput) {
                                    if (config_.verbose) {
                                        // Verbose: show all messages including raw SET STATISTICS TIME/IO
                                        for (const auto& msg : pendingMessages) {
                                            displayBuffer << msg << '\n';
                                        }
                                    } else {
                                        // Normal: show only non-stats messages (PRINT, etc.)
                                        for (const auto& msg : nonStatsMessages) {
                                            displayBuffer << msg << '\n';
                                        }
                                    }
                                }
                            } else if (!config_.quietMode && !config_.jsonOutput) {
                                for (const auto& msg : pendingMessages) {
                                    displayBuffer << msg << '\n';
                                }
                            }
                            conn.clearInfoMessages();
                        }
                        
                        // Get column information for current result set
                        SQLSMALLINT columnCount = conn.getColumnCount();
                        std::vector<std::string> columnNames;
                        // Held until the rows are ready so header, rows, and the row
                        // count are emitted as one locked write.
                        std::string pendingHeader;
                        
                        // Don't display results if quiet mode OR json output mode (json should only contain metrics)
                        if (!config_.quietMode && !config_.jsonOutput && columnCount > 0) {
                            columnNames.reserve(columnCount);
                            for (SQLSMALLINT i = 1; i <= columnCount; i++) {
                                columnNames.push_back(conn.getColumnName(i));
                            }
                            
                            // Phase 1 Optimization: Buffer console output
                            std::ostringstream headerBuffer;
                            headerBuffer << '\n';
                            for (size_t i = 0; i < columnNames.size(); i++) {
                                headerBuffer << columnNames[i];
                                if (i < columnNames.size() - 1) {
                                    headerBuffer << " | ";
                                }
                            }
                            headerBuffer << '\n';
                            headerBuffer << std::string(80, '-') << '\n';
                            pendingHeader = headerBuffer.str();
                        }
                        
                        // Fetch all rows from current result set
                        int rowCount = 0;
                        // Don't display results if quiet mode OR json output mode
                        if (!config_.quietMode && !config_.jsonOutput) {
                            // Only fetch if there are columns (actual result set)
                            // PRINT statements and other T-SQL constructs may not produce a cursor
                            if (columnCount > 0) {
                                // Phase 1 Optimization: Buffer row output
                                std::ostringstream rowBuffer;
                                while (conn.fetch()) {
                                    rowCount++;
                                    totalRowCount++;
                                    metrics_.recordFetch(conn.getLastFetchTime(), true);
                                    
                                    // Display row data (buffered)
                                    for (SQLSMALLINT i = 1; i <= columnCount; i++) {
                                        rowBuffer << conn.getColumnValue(i);
                                        if (i < columnCount) {
                                            rowBuffer << " | ";
                                        }
                                    }
                                    rowBuffer << "\n";
                                }
                                
                                if (!pendingHeader.empty()) {
                                    displayBuffer << pendingHeader;
                                    pendingHeader.clear();
                                }
                                displayBuffer << rowBuffer.str();
                                displayBuffer << '\n';
                                displayBuffer << "(" << rowCount << " row(s) affected)\n";
                            } else {
                                // No result set columns (INSERT/UPDATE/DELETE or PRINT), get row count
                                rowCount = static_cast<int>(conn.getRowCount());
                                if (rowCount > 0) {
                                    totalRowCount += rowCount;
                                }
                            }
                        } else {
                            // In quiet mode, still need to consume result sets to avoid 
                            // statement handle issues, especially with prepared statements
                            if (columnCount > 0) {
                                while (conn.fetch()) {
                                    rowCount++;
                                    totalRowCount++;
                                }
                            } else {
                                // No result set (INSERT/UPDATE/DELETE), get row count
                                // SQLRowCount returns -1 for SELECT/no-row statements, so guard against negatives
                                rowCount = static_cast<int>(conn.getRowCount());
                                if (rowCount > 0) {
                                    totalRowCount += rowCount;
                                }
                            }
                        }
                        
                    } while (conn.nextResultSet()); // Move to next result set
                    
                    // Check if nextResultSet() exited due to an error (not just end of results)
                    // This catches errors from non-first statements in a multi-statement batch
                    // e.g., PRINT 'x'; RAISERROR('err', 16, 1); SELECT 1
                    const std::string& resultSetError = conn.getLastError();
                    if (!resultSetError.empty()) {
                        if (!config_.jsonOutput) {
                            std::lock_guard<std::mutex> lock(stderrMutex_);
                            bufferedErrors_.push_back(resultSetError);
                        }
                        metrics_.recordError("Batch error during result processing: " + resultSetError, query, "sql_error");
                        queriesFailedThisIteration++;
                        
                        // Record failed execution elapsed time
                        auto batchFailEndTime = std::chrono::steady_clock::now();
                        metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(batchFailEndTime - queryStartTime), false);
                        flushDisplay();
                        
                        // Record failed execution in querystats so query gets a Q# in the detail table
                        if (config_.queryStats) {
                            QueryExecutionStats failedStats;
                            failedStats.spid = querySpid;
                            failedStats.success = false;
                            queryStats_.record(qsSlot, query, failedStats);
                        }
                        
                        if (config_.stopOnError) {
                            if (!config_.jsonOutput) TS_ERR << "STOP: Stopping execution due to error (-stoponerror flag is set)\n";
                            running_ = false;
                            return;
                        }
                        continue;
                    }
                    
                    // Display any final PRINT messages that came after the last result set
                    // Skip in quiet non-querystats mode (no messages to display or parse)
                    const auto& finalMessages = conn.getInfoMessages();
                    if (!finalMessages.empty()) {
                        if (config_.queryStats) {
                            auto nonStatsMessages = QueryStatsCollector::parseAndFilterMessages(finalMessages, queryExecStats);
                            
                            if (!config_.quietMode && !config_.jsonOutput) {
                                if (config_.verbose) {
                                    // Verbose: show all messages including raw SET STATISTICS TIME/IO
                                    for (const auto& msg : finalMessages) {
                                        displayBuffer << msg << '\n';
                                    }
                                } else {
                                    // Normal: show only non-stats messages (PRINT, etc.)
                                    for (const auto& msg : nonStatsMessages) {
                                        displayBuffer << msg << '\n';
                                    }
                                }
                            }
                        } else if (!config_.quietMode && !config_.jsonOutput) {
                            for (const auto& msg : finalMessages) {
                                displayBuffer << msg << '\n';
                            }
                        }
                    }
                    
                    // Measure total elapsed from execute through all result consumption
                    auto queryEndTime = std::chrono::steady_clock::now();
                    metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(queryEndTime - queryStartTime), true);
                    flushDisplay();
                    
                    // Record query stats if enabled
                    if (config_.queryStats) {
                        queryExecStats.totalElapsedMs = std::chrono::duration_cast<std::chrono::microseconds>(queryEndTime - queryStartTime).count() / 1000.0;
                        queryExecStats.rowCount = totalRowCount;
                        queryExecStats.success = true;
                        queryStats_.record(qsSlot, query, queryExecStats);
                        recordExecutionTimestamp();
                    }
                    
                    // Count and record real ODBC warnings (non-01000 states like 01004, 01001, 01003)
                    int warnCount = conn.getWarningCount();
                    if (warnCount > 0) {
                        metrics_.recordWarningCount(warnCount);
                        for (const auto& w : conn.getWarnings()) {
                            metrics_.recordWarning(w);
                        }
                    }
                }
                
                // Record iteration metrics for verbose JSON output
                if (config_.verbose && config_.jsonOutput && !config_.streamJsonOutput) {
                    auto iterationEnd = std::chrono::steady_clock::now();
                    double iterationMs = std::chrono::duration_cast<std::chrono::microseconds>(iterationEnd - iterationStart).count() / 1000.0;
                    metrics_.recordIterationMetric(threadId, iter + 1, iterationMs, queriesExecutedThisIteration, queriesFailedThisIteration);
                }
                
                // Think time: simulate application-tier delay between iterations
                if (threadThinkTimeMs > 0 && running_) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(threadThinkTimeMs));
                }
            }
        } else {
            // Connection test only - perform multiple connection iterations
            for (int iter = 1; iter < config_.iterationsPerThread && running_; ++iter) {
                // Disconnect and reconnect for each iteration (except the first - already connected)
                conn.disconnect();
                
                auto iterStart = std::chrono::steady_clock::now();
                bool iterConnected;
                
                // Use access token if provided, otherwise use connection string authentication
                if (!config_.accessToken.empty()) {
                    iterConnected = conn.connectWithAccessToken(config_.connectionString, config_.accessToken, config_.loginTimeout);
                } else {
                    iterConnected = conn.connect(config_.connectionString, config_.loginTimeout);
                }
                
                auto iterEnd = std::chrono::steady_clock::now();
                
                metrics_.recordConnection(
                    std::chrono::duration_cast<std::chrono::microseconds>(iterEnd - iterStart),
                    iterConnected
                );
                
                if (!iterConnected) {
                    // Phase 2 Optimization: Use const reference to avoid string copy
                    const std::string& error = conn.getLastError();
                    
                    // Buffer error for display after thread completion (skip in JSON mode)
                    if (!config_.jsonOutput) {
                        std::lock_guard<std::mutex> lock(stderrMutex_);
                        bufferedErrors_.push_back("CONNECTION ERROR:\n" + error);
                    }
                    metrics_.recordError("Connection failed: " + error);
                    
                    // If stop on error is enabled, stop execution
                    if (config_.stopOnError) {
                        if (!config_.jsonOutput) TS_ERR << "STOP: Stopping execution due to connection error (-stoponerror flag is set)\n";
                        running_ = false;
                        return;
                    }
                }
            }
            
            if (config_.verbose && !config_.jsonOutput) {
                TS_OUT << "Connection test completed successfully\n";
            }
        }
        
        conn.disconnect();
    } catch (const std::exception& e) {
        // Catch standard exceptions (bad_alloc, runtime_error, etc.)
        std::string errorMsg = std::string("Thread ") + std::to_string(threadId) + 
                              " encountered exception: " + e.what();
        
        // Output error immediately with timestamp (skip in JSON mode)
        if (!config_.jsonOutput) {
            std::lock_guard<std::mutex> lock(stderrMutex_);
            TS_ERR << "ERROR: " << errorMsg << std::endl;
        }
        metrics_.recordError(errorMsg);
    } catch (...) {
        // Catch any other exceptions to prevent thread crash
        // Try to get more information about the error
        std::string errorMsg = std::string("Thread ") + std::to_string(threadId) + 
                              " encountered unknown exception";
        
        // Try to get current exception type info
        try {
            std::rethrow_exception(std::current_exception());
        } catch (const std::bad_alloc& ba) {
            errorMsg += " (bad_alloc: " + std::string(ba.what()) + ")";
        } catch (const std::runtime_error& re) {
            errorMsg += " (runtime_error: " + std::string(re.what()) + ")";
        } catch (const std::exception& e) {
            errorMsg += " (exception: " + std::string(e.what()) + ")";
        } catch (...) {
            errorMsg += " (non-standard exception - possibly SEH or access violation)";
        }
        
        // Output error immediately with timestamp (skip in JSON mode)
        if (!config_.jsonOutput) {
            std::lock_guard<std::mutex> lock(stderrMutex_);
            TS_ERR << "ERROR: " << errorMsg << std::endl;
        }
        metrics_.recordError(errorMsg);
    }
}

// ============================================================================
// Replay Mode: Worker Thread
// ============================================================================

void WorkloadSimulator::replayFastSession(int threadId, const ReplaySession& session, ODBCConnection& conn, QueryStatsCollector::Slot* qsSlot, int64_t replaySpid) {
    // Per-session handle map for sp_prepare/sp_execute lifecycle
    std::unordered_map<int, SQLHSTMT> handleMap;
    
    int eventIndex = 0;
    for (const auto& event : session.events) {
        if (!running_) break;
        eventIndex++;
        
        // Verbose: log each event being replayed
        if (config_.verbose && !config_.jsonOutput) {
            std::string eventTypeStr;
            switch (event.eventType) {
                case ReplayEventType::SqlBatchCompleted: eventTypeStr = "sql_batch"; break;
                case ReplayEventType::RpcExecuteSql:     eventTypeStr = "sp_executesql"; break;
                case ReplayEventType::RpcPrepExec:       eventTypeStr = "sp_prepexec"; break;
                case ReplayEventType::RpcPrepare:        eventTypeStr = "sp_prepare"; break;
                case ReplayEventType::RpcExecute:        eventTypeStr = "sp_execute"; break;
                case ReplayEventType::RpcUnprepare:      eventTypeStr = "sp_unprepare"; break;
                case ReplayEventType::RpcUserProc:       eventTypeStr = "user_proc"; break;
                case ReplayEventType::RpcResetConnection: eventTypeStr = "reset_conn"; break;
                default: eventTypeStr = "skipped"; break;
            }
            std::string sqlPreview = event.statementText;
            if (sqlPreview.length() > 120) {
                sqlPreview.resize(120);
                sqlPreview += "...";
            }
            // Replace newlines with spaces for single-line display
            for (auto& c : sqlPreview) { if (c == '\n' || c == '\r') c = ' '; }
            std::lock_guard<std::mutex> lock(stderrMutex_);
            TS_OUT << "  T" << threadId << " [" << eventIndex << "/" << session.events.size() << "] " 
                   << eventTypeStr << ": " << sqlPreview << std::endl;
        }
        
        // Start timing for total elapsed (includes execute + fetch + result consumption)
        auto queryStartTime = std::chrono::steady_clock::now();
        
        bool success = conn.executeReplayEvent(event, handleMap);
        
        // Initialize per-query stats for querystats mode
        QueryExecutionStats queryExecStats;
        queryExecStats.spid = replaySpid;
        
        // Track replay outcome for replay summary
        bool isAbort = !success && conn.isLastErrorTimeout();
        metrics_.recordReplayResult(event.originalResult, success, isAbort);
        
        if (!success) {
            const std::string& error = conn.getLastError();
            if (!config_.jsonOutput) {
                std::lock_guard<std::mutex> lock(stderrMutex_);
                bufferedErrors_.push_back(error);
            }
            metrics_.recordError("Replay event failed: " + error);
            
            // Record failed execution elapsed time
            auto failEndTime = std::chrono::steady_clock::now();
            metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(failEndTime - queryStartTime), false);
            
            // Record failed execution in querystats so query gets a Q# in the detail table
            if (config_.queryStats) {
                QueryExecutionStats failedStats;
                failedStats.spid = queryExecStats.spid;
                failedStats.success = false;
                queryStats_.record(qsSlot, event.statementText, failedStats);
            }
            
            if (config_.stopOnError) {
                if (!config_.jsonOutput) TS_ERR << "STOP: Stopping execution due to replay error (-stoponerror flag is set)\n";
                running_ = false;
                break;
            }
            continue;
        }
        
        // Consume all result sets (replay doesn't display results by default)
        int totalRowCount = 0;
        if (event.eventType != ReplayEventType::RpcPrepare &&
            event.eventType != ReplayEventType::RpcUnprepare &&
            event.eventType != ReplayEventType::RpcResetConnection &&
            event.eventType != ReplayEventType::Skipped) {
            
            // Drain result sets
            do {
                // Parse and filter SET STATISTICS messages if querystats is enabled
                if (config_.queryStats) {
                    const auto& msgs = conn.getInfoMessages();
                    if (!msgs.empty()) {
                        QueryStatsCollector::parseAndFilterMessages(msgs, queryExecStats);
                        conn.clearInfoMessages();
                    }
                }
                
                const SQLSMALLINT columnCount = conn.getColumnCount();
                if (columnCount > 0) {
                    while (conn.fetch()) {
                        totalRowCount++;
                        metrics_.recordFetch(conn.getLastFetchTime(), true);
                    }
                } else {
                    const SQLLEN rowCount = conn.getRowCount();
                    if (rowCount > 0) {
                        totalRowCount += static_cast<int>(rowCount);
                    }
                }
            } while (conn.nextResultSet());
            
            // Parse any final messages
            if (config_.queryStats) {
                const auto& finalMsgs = conn.getInfoMessages();
                if (!finalMsgs.empty()) {
                    QueryStatsCollector::parseAndFilterMessages(finalMsgs, queryExecStats);
                }
            }
            
            // Check if nextResultSet() exited due to an error
            const std::string& resultSetError = conn.getLastError();
            if (!resultSetError.empty()) {
                if (!config_.jsonOutput) {
                    std::lock_guard<std::mutex> lock(stderrMutex_);
                    bufferedErrors_.push_back(resultSetError);
                }
                metrics_.recordError("Replay batch error during result processing: " + resultSetError);
                
                // Record failed execution in querystats so query gets a Q# in the detail table
                if (config_.queryStats) {
                    QueryExecutionStats failedStats;
                    failedStats.spid = queryExecStats.spid;
                    failedStats.success = false;
                    queryStats_.record(qsSlot, event.statementText, failedStats);
                }
                
                if (config_.stopOnError) {
                    if (!config_.jsonOutput) TS_ERR << "STOP: Stopping execution due to replay error (-stoponerror flag is set)\n";
                    running_ = false;
                    break;
                }
            }
        }
        
        // Measure total elapsed from execute through all result consumption
        auto queryEndTime = std::chrono::steady_clock::now();
        if (success) {
            metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(queryEndTime - queryStartTime), true);
        }
        
        // Record query stats if enabled
        if (config_.queryStats && success) {
            queryExecStats.totalElapsedMs = std::chrono::duration_cast<std::chrono::microseconds>(queryEndTime - queryStartTime).count() / 1000.0;
            queryExecStats.rowCount = totalRowCount;
            queryExecStats.success = true;
            queryStats_.record(qsSlot, event.statementText, queryExecStats);
            recordExecutionTimestamp();
        }
        
        // Count and record real ODBC warnings (non-01000 states like 01004, 01001, 01003)
        int warnCount = conn.getWarningCount();
        if (warnCount > 0) {
            metrics_.recordWarningCount(warnCount);
            for (const auto& w : conn.getWarnings()) {
                metrics_.recordWarning(w);
            }
        }
    }
    
    // Cleanup any remaining prepared statement handles
    for (auto& pair : handleMap) {
        SQLFreeHandle(SQL_HANDLE_STMT, pair.second);
    }
    handleMap.clear();
}

void WorkloadSimulator::replayWorkerThread(int threadId) {
    try {
        ODBCConnection conn;
        const int64_t capturedSpid =
            config_.replayMode == "fast" &&
            threadId < static_cast<int>(config_.replayData.sessions.size())
                ? config_.replayData.sessions[threadId].sessionId
                : 0;
        
        auto start = std::chrono::steady_clock::now();
        bool connected;
        
        if (!config_.accessToken.empty()) {
            connected = conn.connectWithAccessToken(config_.connectionString, config_.accessToken, config_.loginTimeout);
        } else {
            connected = conn.connect(config_.connectionString, config_.loginTimeout);
        }
        
        auto end = std::chrono::steady_clock::now();
        
        metrics_.recordConnection(
            std::chrono::duration_cast<std::chrono::microseconds>(end - start),
            connected
        );
        
        auto connTime = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        
        // Record connection time for querystats snapshot
        if (connected) {
            std::lock_guard<std::mutex> lock(connTimesMutex_);
            connTimesMs_.push_back(static_cast<double>(connTime));
        }
        
        if (config_.verbose && config_.jsonOutput && !config_.streamJsonOutput) {
            if (!connected) {
                metrics_.recordThreadConnection(threadId, static_cast<double>(connTime), false, conn.getLastError());
            } else {
                metrics_.recordThreadConnection(threadId, static_cast<double>(connTime), true);
            }
        }
        
        std::ostringstream msg;
        if (!connected) {
            const std::string& error = conn.getLastError();
            if (!config_.jsonOutput) {
                std::lock_guard<std::mutex> lock(stderrMutex_);
                bufferedErrors_.push_back(error);
            }
            msg << "Thread " << threadId << ": Connection FAILED - " << error;
            metrics_.recordError("Connection failed: " + error);
            
            if (config_.verbose) {
                std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                connectionMessages_.push_back(msg.str());
            }
            
            int expectedThreads = (config_.replayMode == "fast") 
                ? static_cast<int>(config_.replayData.sessions.size()) 
                : config_.numThreads;
            
            if (++connectionsCompleted_ == expectedThreads) {
                if (config_.verbose && !config_.jsonOutput) {
                    std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                    for (const auto& message : connectionMessages_) {
                        TS_OUT << message << std::endl;
                    }
                }
                connectionCV_.notify_all();
            }
            {
                std::lock_guard<std::mutex> lock(replayConnectionsMutex_);
                replayConnections_.push_back({threadId + 1, capturedSpid, 0});
            }
            return;
        }
        
        // Set query timeout if specified
        if (config_.queryTimeout > 0) {
            conn.setQueryTimeout(config_.queryTimeout);
        }

        const int64_t replaySpid = conn.getServerProcessId();
        if (replaySpid <= 0) {
            const std::string warning = "Replay connection SPID is unavailable: " + conn.getLastError();
            metrics_.recordWarningCount(1);
            metrics_.recordWarning(warning);
        }
        {
            std::lock_guard<std::mutex> lock(replayConnectionsMutex_);
            replayConnections_.push_back({threadId + 1, capturedSpid, replaySpid});
        }
        
        // Enable SET STATISTICS TIME/IO if querystats is enabled
        // Phase 1b: Register thread slot for lock-free querystats recording
        QueryStatsCollector::Slot* qsSlot = nullptr;
        if (config_.queryStats) {
            conn.execute("SET STATISTICS TIME ON; SET STATISTICS IO ON");
            conn.clearInfoMessages();
            qsSlot = queryStats_.registerThread();
        }
        
        msg << "Thread " << threadId << ": Connected successfully (" << connTime << " ms)";
        if (config_.verbose && !config_.jsonOutput) {
            std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
            connectionMessages_.push_back(msg.str());
        }
        
        // Query driver version (first thread only)
        if (!driverVersionQueried_.exchange(true)) {
            std::string version = conn.getDriverVersion();
            if (!version.empty() && version != "unknown") {
                std::lock_guard<std::mutex> lock(driverVersionMutex_);
                driverVersion_ = version;
            }
        }
        
        // JSON results record the server so saved runs can be compared later.
        if ((config_.verbose || config_.jsonOutput) && !editionQueried_.exchange(true)) {
            std::string edition = queryServerEdition(conn);
            std::string version = queryServerVersion(conn);
            if (config_.queryStats) {
                conn.clearInfoMessages();
            }
            if (!edition.empty() || !version.empty()) {
                std::lock_guard<std::mutex> lock(editionMutex_);
                serverEdition_ = edition;
                serverVersion_ = version;
            }
        }
        
        // Synchronize connection completion
        int expectedThreads = (config_.replayMode == "fast") 
            ? static_cast<int>(config_.replayData.sessions.size()) 
            : config_.numThreads;
        
        if (++connectionsCompleted_ == expectedThreads) {
            if (config_.verbose && !config_.jsonOutput) {
                std::lock_guard<std::mutex> lock(connectionMessagesMutex_);
                std::sort(connectionMessages_.begin(), connectionMessages_.end());
                for (const auto& message : connectionMessages_) {
                    TS_OUT << message << '\n';
                }
                {
                    std::lock_guard<std::mutex> dvLock(driverVersionMutex_);
                    if (!driverVersion_.empty()) {
                        TS_OUT << "ODBC Driver Version: " << driverVersion_ << '\n';
                    }
                }
                {
                    std::lock_guard<std::mutex> edLock(editionMutex_);
                    if (!serverEdition_.empty()) {
                        std::string editionLine = "Server Edition: " + serverEdition_;
                        if (!serverVersion_.empty()) {
                            editionLine += " (v" + serverVersion_ + ")";
                        }
                        TS_OUT << editionLine << '\n';
                    }
                }
                TS_OUT << std::endl;
                TS_OUT << "[PHASE 4] Replaying workload (" << config_.replayMode << " mode)\n";
            } else if (!config_.jsonOutput) {
                {
                    std::lock_guard<std::mutex> dvLock(driverVersionMutex_);
                    if (!driverVersion_.empty()) {
                        TS_OUT << "ODBC Driver Version: " << driverVersion_ << std::endl;
                    }
                }
                TS_OUT << "Starting replay (" << expectedThreads << (expectedThreads == 1 ? " thread, " : " threads, ")
                       << config_.replayMode << " mode)" << std::endl;
            }
            connectionCV_.notify_all();
        } else {
            std::unique_lock<std::mutex> lock(connectionMessagesMutex_);
            connectionCV_.wait(lock, [this, expectedThreads]() { 
                return connectionsCompleted_.load() >= expectedThreads; 
            });
        }
        
        if (!running_) {
            conn.disconnect();
            return;
        }
        
        // Execute replay based on mode
        if (config_.replayMode == "fast") {
            // Fast mode: this thread replays the session at index threadId
            if (threadId < static_cast<int>(config_.replayData.sessions.size())) {
                const auto& session = config_.replayData.sessions[threadId];
                
                for (int iter = 0; iter < config_.iterationsPerThread && running_; ++iter) {
                    replayFastSession(threadId, session, conn, qsSlot, replaySpid);
                }
            }
        } else {
            // Stress mode: each thread runs through the full flat event list
            std::unordered_map<int, SQLHSTMT> handleMap; // Not used in stress (no prepare lifecycle)
            
            for (int iter = 0; iter < config_.iterationsPerThread && running_; ++iter) {
                int stressEventIndex = 0;
                for (const auto& event : config_.replayData.allEvents) {
                    if (!running_) break;
                    stressEventIndex++;
                    
                    // Verbose: log each event being replayed
                    if (config_.verbose && !config_.jsonOutput) {
                        std::string eventTypeStr;
                        switch (event.eventType) {
                            case ReplayEventType::SqlBatchCompleted: eventTypeStr = "sql_batch"; break;
                            case ReplayEventType::RpcExecuteSql:     eventTypeStr = "sp_executesql"; break;
                            case ReplayEventType::RpcPrepExec:       eventTypeStr = "sp_prepexec"; break;
                            case ReplayEventType::RpcUserProc:       eventTypeStr = "user_proc"; break;
                            default: eventTypeStr = "rpc"; break;
                        }
                        std::string sqlPreview = event.statementText;
                        if (sqlPreview.length() > 120) {
                            sqlPreview.resize(120);
                            sqlPreview += "...";
                        }
                        for (auto& c : sqlPreview) { if (c == '\n' || c == '\r') c = ' '; }
                        std::lock_guard<std::mutex> lock(stderrMutex_);
                        TS_OUT << "  T" << threadId << " [" << stressEventIndex << "/" << config_.replayData.allEvents.size() << "] " 
                               << eventTypeStr << ": " << sqlPreview << std::endl;
                    }
                    
                    // Start timing for total elapsed (includes execute + fetch + result consumption)
                    auto stressQueryStartTime = std::chrono::steady_clock::now();
                    
                    bool success = conn.executeReplayEvent(event, handleMap);
                    
                    // Initialize per-query stats for querystats mode
                    QueryExecutionStats stressQueryStats;
                    stressQueryStats.spid = replaySpid;
                    
                    // Track replay outcome for replay summary
                    bool isAbort = !success && conn.isLastErrorTimeout();
                    metrics_.recordReplayResult(event.originalResult, success, isAbort);
                    
                    if (!success) {
                        const std::string& error = conn.getLastError();
                        if (!config_.jsonOutput) {
                            std::lock_guard<std::mutex> lock(stderrMutex_);
                            bufferedErrors_.push_back(error);
                        }
                        metrics_.recordError("Replay event failed: " + error);
                        
                        // Record failed execution elapsed time
                        auto stressFailEndTime = std::chrono::steady_clock::now();
                        metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(stressFailEndTime - stressQueryStartTime), false);
                        
                        // Record failed execution in querystats so query gets a Q# in the detail table
                        if (config_.queryStats) {
                            QueryExecutionStats failedStats;
                            failedStats.spid = replaySpid;
                            failedStats.success = false;
                            queryStats_.record(qsSlot, event.statementText, failedStats);
                        }
                        
                        if (config_.stopOnError) {
                            if (!config_.jsonOutput) TS_ERR << "STOP: Stopping due to replay error (-stoponerror)\n";
                            running_ = false;
                            break;
                        }
                        continue;
                    }
                    
                    // Drain result sets
                    int stressTotalRowCount = 0;
                    if (event.eventType != ReplayEventType::RpcPrepare &&
                        event.eventType != ReplayEventType::RpcUnprepare &&
                        event.eventType != ReplayEventType::RpcResetConnection &&
                        event.eventType != ReplayEventType::Skipped) {
                        do {
                            // Parse and filter SET STATISTICS messages if querystats is enabled
                            if (config_.queryStats) {
                                const auto& msgs = conn.getInfoMessages();
                                if (!msgs.empty()) {
                                    QueryStatsCollector::parseAndFilterMessages(msgs, stressQueryStats);
                                    conn.clearInfoMessages();
                                }
                            }
                            
                            const SQLSMALLINT columnCount = conn.getColumnCount();
                            if (columnCount > 0) {
                                while (conn.fetch()) {
                                    stressTotalRowCount++;
                                    metrics_.recordFetch(conn.getLastFetchTime(), true);
                                }
                            } else {
                                const SQLLEN rowCount = conn.getRowCount();
                                if (rowCount > 0) {
                                    stressTotalRowCount += static_cast<int>(rowCount);
                                }
                            }
                        } while (conn.nextResultSet());
                        
                        // Parse any final messages
                        if (config_.queryStats) {
                            const auto& finalMsgs = conn.getInfoMessages();
                            if (!finalMsgs.empty()) {
                                QueryStatsCollector::parseAndFilterMessages(finalMsgs, stressQueryStats);
                            }
                        }
                        
                        // Check if nextResultSet() exited due to an error
                        const std::string& resultSetError = conn.getLastError();
                        if (!resultSetError.empty()) {
                            if (!config_.jsonOutput) {
                                std::lock_guard<std::mutex> lock(stderrMutex_);
                                bufferedErrors_.push_back(resultSetError);
                            }
                            metrics_.recordError("Replay batch error during result processing: " + resultSetError);
                            
                            // Record failed execution in querystats so query gets a Q# in the detail table
                            if (config_.queryStats) {
                                QueryExecutionStats failedStats;
                                failedStats.spid = replaySpid;
                                failedStats.success = false;
                                queryStats_.record(qsSlot, event.statementText, failedStats);
                            }
                            
                            if (config_.stopOnError) {
                                if (!config_.jsonOutput) TS_ERR << "STOP: Stopping due to replay error (-stoponerror)\n";
                                running_ = false;
                                break;
                            }
                        }
                    }
                    
                    // Measure total elapsed from execute through all result consumption
                    auto stressQueryEndTime = std::chrono::steady_clock::now();
                    if (success) {
                        metrics_.recordExecution(std::chrono::duration_cast<std::chrono::microseconds>(stressQueryEndTime - stressQueryStartTime), true);
                    }
                    
                    // Record query stats if enabled
                    if (config_.queryStats && success) {
                        stressQueryStats.totalElapsedMs = std::chrono::duration_cast<std::chrono::microseconds>(stressQueryEndTime - stressQueryStartTime).count() / 1000.0;
                        stressQueryStats.rowCount = stressTotalRowCount;
                        stressQueryStats.success = true;
                        queryStats_.record(qsSlot, event.statementText, stressQueryStats);
                        recordExecutionTimestamp();
                    }
                    
                    // Count and record real ODBC warnings (non-01000 states like 01004, 01001, 01003)
                    int warnCount = conn.getWarningCount();
                    if (warnCount > 0) {
                        metrics_.recordWarningCount(warnCount);
                        for (const auto& w : conn.getWarnings()) {
                            metrics_.recordWarning(w);
                        }
                    }
                }
            }
        }
        
        conn.disconnect();
    } catch (const std::exception& e) {
        std::string errorMsg = std::string("Replay thread ") + std::to_string(threadId) + 
                              " encountered exception: " + e.what();
        if (!config_.jsonOutput) {
            std::lock_guard<std::mutex> lock(stderrMutex_);
            TS_ERR << "ERROR: " << errorMsg << std::endl;
        }
        metrics_.recordError(errorMsg);
    } catch (...) {
        std::string errorMsg = std::string("Replay thread ") + std::to_string(threadId) + 
                              " encountered unknown exception";
        if (!config_.jsonOutput) {
            std::lock_guard<std::mutex> lock(stderrMutex_);
            TS_ERR << "ERROR: " << errorMsg << std::endl;
        }
        metrics_.recordError(errorMsg);
    }
}

// ============================================================================
// Querystats Snapshot Timer & Writer
// ============================================================================

void WorkloadSimulator::snapshotTimerThread() {
    // Write an immediate first snapshot so the dashboard gets data ASAP
    writeQueryStatsSnapshot(false);
    
    while (running_) {
        // Sleep in 100ms increments to check running_ frequently
        for (int i = 0; i < config_.queryStatsIntervalSec * 10 && running_; ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        // Write snapshot if still running (final snapshot is written by run() after workers complete)
        if (running_) {
            writeQueryStatsSnapshot(false);
        }
    }
}

void WorkloadSimulator::streamJsonTimerThread() {
    std::unique_lock<std::mutex> lock(streamJsonMutex_);
    while (!streamJsonCV_.wait_for(lock, std::chrono::seconds(1), [this]() { return !running_; })) {
        lock.unlock();
        writeStreamJsonEvent("progress");
        lock.lock();
    }
}

void WorkloadSimulator::writeStreamJsonEvent(const std::string& type, bool success) const {
    const auto now = std::chrono::steady_clock::now();
    const double elapsedSeconds =
        std::chrono::duration_cast<std::chrono::milliseconds>(now - workloadStartTime_).count() / 1000.0;
    const uint64_t successfulExecutions = metrics_.getLiveSuccessfulExecutions();
    const uint64_t failedExecutions = metrics_.getLiveFailedExecutions();
    const uint64_t completedExecutions = successfulExecutions + failedExecutions;
    const double throughput = elapsedSeconds > 0.0 ? completedExecutions / elapsedSeconds : 0.0;

    std::ostringstream event;
    event << "{\"type\":\"" << type << "\""
          << ",\"timestamp\":\"" << JsonOutput::getIsoTimestamp() << "\"";
    if (type == "started") {
        event << ",\"version\":\"" << SQLSIM_VERSION << "\""
              << ",\"threads\":" << config_.numThreads;
    } else {
        event << std::fixed << std::setprecision(3)
              << ",\"elapsed_seconds\":" << elapsedSeconds
              << ",\"successful_connections\":" << metrics_.getLiveSuccessfulConnections()
              << ",\"failed_connections\":" << metrics_.getLiveFailedConnections()
              << ",\"successful_executions\":" << successfulExecutions
              << ",\"failed_executions\":" << failedExecutions
              << ",\"errors\":" << metrics_.getTotalErrors()
              << ",\"throughput_per_second\":" << throughput;
        {
            std::lock_guard<std::mutex> lock(driverVersionMutex_);
            if (!driverVersion_.empty()) {
                event << ",\"odbc_driver_version\":\""
                      << JsonOutput::escapeJson(driverVersion_) << "\"";
            }
        }
        {
            std::lock_guard<std::mutex> lock(editionMutex_);
            if (!serverVersion_.empty()) {
                event << ",\"server_version\":\""
                      << JsonOutput::escapeJson(serverVersion_) << "\"";
            }
            if (!serverEdition_.empty()) {
                event << ",\"server_edition\":\""
                      << JsonOutput::escapeJson(serverEdition_) << "\"";
            }
        }
        if (type == "completed") {
            event << ",\"status\":\"" << (success ? "success" : "error") << "\"";
        }
    }
    event << '}';
    std::cout << event.str() << std::endl;
}

void WorkloadSimulator::recordExecutionTimestamp() {
    // Phase 1 Optimization: Lock-free using atomics instead of mutex
    auto now = std::chrono::steady_clock::now();
    int64_t nowNs = std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
    
    // Set first execution time with compare-and-swap (only first thread wins)
    if (!hasFirstExecution_.load(std::memory_order_acquire)) {
        int64_t expected = 0;
        if (firstExecutionNs_.compare_exchange_strong(expected, nowNs, std::memory_order_release)) {
            hasFirstExecution_.store(true, std::memory_order_release);
        }
    }
    
    // Update last execution time — always store (latest wins)
    lastExecutionNs_.store(nowNs, std::memory_order_release);
}

void WorkloadSimulator::writeQueryStatsSnapshot(bool isFinal) const {
    try {
        auto aggregates = queryStats_.aggregate();
        auto totals = QueryStatsCollector::totalsOf(aggregates);
        
        auto now = std::chrono::steady_clock::now();
        double elapsedSec = std::chrono::duration_cast<std::chrono::milliseconds>(now - workloadStartTime_).count() / 1000.0;
        
        // Calculate execution-only elapsed time (excludes connection phase)
        double execElapsedSec = 0.0;
        double currentThroughput = 0.0;
        {
            // Phase 1 Optimization: Read atomics directly, no mutex needed
            if (hasFirstExecution_.load(std::memory_order_acquire)) {
                int64_t firstNs = firstExecutionNs_.load(std::memory_order_acquire);
                int64_t lastNs = lastExecutionNs_.load(std::memory_order_acquire);
                if (isFinal) {
                    execElapsedSec = (lastNs - firstNs) / 1e9;
                } else {
                    int64_t nowNs = std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
                    execElapsedSec = (nowNs - firstNs) / 1e9;
                }
                if (execElapsedSec > 0.0) {
                    currentThroughput = static_cast<double>(totals.totalExecutions) / execElapsedSec;
                    if (currentThroughput > peakThroughput_) {
                        peakThroughput_ = currentThroughput;
                    }
                }
            }
        }
        
        std::ostringstream json;
        json << std::fixed;
        
        json << "{\n";
        json << "  \"timestamp\": \"" << JsonOutput::getIsoTimestamp() << "\",\n";
        json << std::setprecision(3);
        json << "  \"elapsed_seconds\": " << elapsedSec << ",\n";
        json << "  \"execution_elapsed_seconds\": " << execElapsedSec << ",\n";
        json << std::setprecision(1);
        json << "  \"throughput\": " << currentThroughput << ",\n";
        json << "  \"peak_throughput\": " << peakThroughput_ << ",\n";
        json << std::setprecision(3);
        json << "  \"status\": \"" << (isFinal ? "complete" : "running") << "\",\n";
        
        // Config info
        json << "  \"config\": {\n";
        json << "    \"server\": \"" << JsonOutput::escapeJson(config_.serverName) << "\",\n";
        json << "    \"database\": \"" << JsonOutput::escapeJson(config_.databaseName) << "\",\n";
        json << "    \"authentication\": \"" << JsonOutput::escapeJson(config_.authMethod) << "\",\n";
        json << "    \"threads\": " << config_.numThreads << ",\n";
        json << "    \"iterations\": " << config_.iterationsPerThread << ",\n";
        // Calculate total_batches correctly for both workload and non-workload modes
        int totalBatches = 0;
        if (!config_.workloadEntries.empty()) {
            for (const auto& entry : config_.workloadEntries) {
                totalBatches += entry.threads * entry.iterations * static_cast<int>(entry.queries.size());
            }
            json << "    \"total_batches\": " << totalBatches << ",\n";
            json << "    \"workload_mode\": true\n";
        } else {
            totalBatches = config_.numThreads * config_.iterationsPerThread * static_cast<int>(config_.queries.size());
            json << "    \"total_batches\": " << totalBatches << "\n";
        }
        json << "  },\n";
        
        // Connection stats
        {
            std::lock_guard<std::mutex> lock(connTimesMutex_);
            json << "  \"connection_stats\": {\n";
            if (!connTimesMs_.empty()) {
                double sum = 0, minVal = connTimesMs_[0], maxVal = connTimesMs_[0];
                for (double t : connTimesMs_) {
                    sum += t;
                    if (t < minVal) minVal = t;
                    if (t > maxVal) maxVal = t;
                }
                json << std::setprecision(3);
                json << "    \"avg_ms\": " << (sum / connTimesMs_.size()) << ",\n";
                json << "    \"min_ms\": " << minVal << ",\n";
                json << "    \"max_ms\": " << maxVal << ",\n";
                json << "    \"count\": " << connTimesMs_.size() << "\n";
            } else {
                json << "    \"count\": 0\n";
            }
            json << "  },\n";
        }
        
        // Query stats
        json << "  \"query_stats\": {\n";
        json << "    \"queries\": [\n";
        
        for (size_t i = 0; i < aggregates.size(); ++i) {
            const auto& a = aggregates[i];
            json << "      {\n";
            json << "        \"query\": \"" << JsonOutput::escapeJson(a.query) << "\",\n";
            json << "        \"spids\": [";
            size_t spidIndex = 0;
            for (const auto spid : a.spids) {
                if (spidIndex >= 10) break;
                if (spidIndex++ > 0) json << ", ";
                json << spid;
            }
            json << "],\n";
            json << "        \"spid_count\": " << a.spids.size() << ",\n";
            
            json << std::setprecision(3);
            json << "        \"total_elapsed_ms\": {\"avg\": " << a.totalElapsedAvg 
                 << ", \"min\": " << a.totalElapsedMin 
                 << ", \"max\": " << a.totalElapsedMax << "},\n";
            json << "        \"server_elapsed_ms\": {\"avg\": " << a.serverElapsedLastAvg 
                 << ", \"min\": " << a.serverElapsedLastMin 
                 << ", \"max\": " << a.serverElapsedLastMax << "},\n";
            json << "        \"server_cpu_ms\": {\"avg\": " << a.serverCpuLastAvg 
                 << ", \"min\": " << a.serverCpuLastMin 
                 << ", \"max\": " << a.serverCpuLastMax << "},\n";
            json << "        \"server_elapsed_sum_ms\": {\"avg\": " << a.serverElapsedAvg 
                 << ", \"min\": " << a.serverElapsedMin 
                 << ", \"max\": " << a.serverElapsedMax << "},\n";
            json << "        \"server_cpu_sum_ms\": {\"avg\": " << a.serverCpuAvg 
                 << ", \"min\": " << a.serverCpuMin 
                 << ", \"max\": " << a.serverCpuMax << "},\n";
            json << "        \"compile_elapsed_ms\": {\"avg\": " << a.compileElapsedAvg 
                 << ", \"min\": " << a.compileElapsedMin 
                 << ", \"max\": " << a.compileElapsedMax << "},\n";
            json << std::setprecision(1);
            json << "        \"logical_reads\": {\"avg\": " << a.logicalReadsAvg 
                 << ", \"min\": " << a.logicalReadsMin 
                 << ", \"max\": " << a.logicalReadsMax << "},\n";
            json << "        \"physical_reads\": {\"avg\": " << a.physicalReadsAvg 
                 << ", \"min\": " << a.physicalReadsMin 
                 << ", \"max\": " << a.physicalReadsMax << "},\n";
            json << "        \"read_ahead_reads\": {\"avg\": " << a.readAheadReadsAvg 
                 << ", \"min\": " << a.readAheadReadsMin 
                 << ", \"max\": " << a.readAheadReadsMax << "},\n";
            if (a.hasRowCount) {
                json << "        \"row_count\": {\"avg\": " << a.rowCountAvg 
                     << ", \"min\": " << a.rowCountMin 
                     << ", \"max\": " << a.rowCountMax << "},\n";
            }
            json << "        \"executions\": " << a.executions << ",\n";
            json << "        \"failures\": " << a.failures << "\n";
            json << "      }";
            if (i < aggregates.size() - 1) json << ",";
            json << "\n";
        }
        
        json << "    ],\n";
        
        // Totals
        json << std::setprecision(3);
        json << "    \"totals\": {\n";
        json << "      \"total_elapsed_ms\": " << totals.totalTotalElapsedMs << ",\n";
        json << "      \"server_elapsed_ms\": " << totals.totalServerElapsedLastMs << ",\n";
        json << "      \"server_cpu_ms\": " << totals.totalServerCpuLastMs << ",\n";
        json << "      \"server_elapsed_sum_ms\": " << totals.totalServerElapsedMs << ",\n";
        json << "      \"server_cpu_sum_ms\": " << totals.totalServerCpuMs << ",\n";
        json << "      \"compile_elapsed_ms\": " << totals.totalCompileElapsedMs << ",\n";
        json << "      \"logical_reads\": " << totals.totalLogicalReads << ",\n";
        json << "      \"physical_reads\": " << totals.totalPhysicalReads << ",\n";
        json << "      \"read_ahead_reads\": " << totals.totalReadAheadReads << ",\n";
        if (totals.hasRowCount) {
            json << "      \"total_rows\": " << totals.totalRows << ",\n";
        }
        json << "      \"executions\": " << totals.totalExecutions << ",\n";
        json << "      \"failures\": " << totals.totalFailures << "\n";
        json << "    }\n";
        json << "  },\n";
        
        // Error and warning counts for dashboard display
        auto totalErrors = metrics_.getTotalErrors();
        auto totalWarnings = metrics_.getTotalWarnings();
        json << "  \"total_errors\": " << totalErrors << ",\n";
        json << "  \"total_warnings\": " << totalWarnings << ",\n";
        
        // Recent error messages (up to 10)
        auto errors = metrics_.getRecentErrors(10);
        json << "  \"recent_errors\": [";
        if (!errors.empty()) {
            json << "\n";
            for (size_t i = 0; i < errors.size(); ++i) {
                const auto& err = errors[i];
                json << "    {\"type\": \"" << JsonOutput::escapeJson(err.type)
                     << "\", \"timestamp\": \"" << JsonOutput::escapeJson(err.timestamp) << "\"";
                if (!err.query.empty()) {
                    json << ", \"query\": \"" << JsonOutput::escapeJson(err.query) << "\"";
                }
                json << ", \"message\": \"" << JsonOutput::escapeJson(err.message) << "\"}";
                if (i < errors.size() - 1) json << ",";
                json << "\n";
            }
            json << "  ";
        }
        json << "],\n";
        
        // Recent warning messages (up to 10)
        auto warnings = metrics_.getRecentWarnings(10);
        json << "  \"recent_warnings\": [";
        if (!warnings.empty()) {
            json << "\n";
            for (size_t i = 0; i < warnings.size(); ++i) {
                const auto& warn = warnings[i];
                json << "    {\"type\": \"" << JsonOutput::escapeJson(warn.type)
                     << "\", \"timestamp\": \"" << JsonOutput::escapeJson(warn.timestamp)
                     << "\", \"message\": \"" << JsonOutput::escapeJson(warn.message) << "\"}";
                if (i < warnings.size() - 1) json << ",";
                json << "\n";
            }
            json << "  ";
        }
        json << "]\n";
        json << "}\n";
        
        // Use an unpredictable same-directory temp file, then atomically replace.
        std::random_device randomDevice;
        const uint64_t nonce = (static_cast<uint64_t>(randomDevice()) << 32) ^ randomDevice();
        std::ostringstream tempName;
        tempName << config_.queryStatsFile << ".tmp." << std::hex << nonce;
        const std::string tempFile = tempName.str();
        {
            errno = 0;
            std::ofstream ofs(tempFile, std::ios::binary | std::ios::trunc);
            if (!ofs.is_open()) {
                const int openError = errno;
                reportSnapshotFailure("the file could not be opened for writing (" +
                                      describeFileOpenFailure(tempFile, openError) + ")");
                return;
            }
            ofs << json.str();
            ofs.flush();
            if (!ofs.good()) {
                ofs.close();
                std::remove(tempFile.c_str());
                reportSnapshotFailure("writing the snapshot failed");
                return;
            }
        }
        // Atomic replace on Windows using MoveFileEx (no gap where file doesn't exist)
#ifdef _WIN32
        if (!MoveFileExA(tempFile.c_str(), config_.queryStatsFile.c_str(), MOVEFILE_REPLACE_EXISTING)) {
            std::remove(tempFile.c_str());
            reportSnapshotFailure("the snapshot could not replace the existing file");
        }
#else
        // POSIX rename replaces an existing destination atomically.
        if (std::rename(tempFile.c_str(), config_.queryStatsFile.c_str()) != 0) {
            std::remove(tempFile.c_str());
            reportSnapshotFailure("the snapshot could not replace the existing file");
        }
#endif
        
    } catch (const std::exception& error) {
        // A snapshot must never take the run down with it, but discarding the
        // failure entirely leaves a mistyped path looking exactly like a
        // healthy run, so it is reported once instead.
        reportSnapshotFailure(error.what());
    } catch (...) {
        reportSnapshotFailure("an unknown error occurred");
    }
}

void WorkloadSimulator::reportSnapshotFailure(const std::string& reason) const {
    // JSON and streaming output are machine read, so a warning there would
    // corrupt the very channel a supervisor is parsing. Those modes stay
    // silent; the absence of the file is the signal.
    if (config_.jsonOutput) {
        return;
    }
    bool alreadyReported = false;
    if (snapshotWriteReported_.compare_exchange_strong(alreadyReported, true)) {
        TS_ERR << "Warning: could not write the query statistics snapshot to '"
               << config_.queryStatsFile << "': " << reason
               << ". The workload continues." << std::endl;
    }
}

// ============================================================================
// Query Stats Output
// ============================================================================

void WorkloadSimulator::printTextQueryStats() const {
    auto aggregates = queryStats_.aggregate();
    auto totals = QueryStatsCollector::totalsOf(aggregates);
    
    if (aggregates.empty()) return;
    
    TS_OUT << std::endl;
    TS_OUT << "Query Stats (SET STATISTICS TIME/IO):\n";
    TS_OUT << std::string(70, '-') << '\n';
    
    for (size_t i = 0; i < aggregates.size(); ++i) {
        const auto& a = aggregates[i];
        
        // Show query text (truncated to 120 chars for display)
        std::string queryPreview = a.query;
        // Replace newlines with spaces for compact display
        for (auto& c : queryPreview) { if (c == '\n' || c == '\r') c = ' '; }
        if (queryPreview.length() > 120) {
            queryPreview.resize(120);
            queryPreview += "...";
        }
        
        TS_OUT << "Query " << (i + 1) << ": " << queryPreview << '\n';
        TS_OUT << "  Total elapsed (ms):   avg=" << std::fixed << std::setprecision(3) << a.totalElapsedAvg 
               << "  min=" << a.totalElapsedMin 
               << "  max=" << a.totalElapsedMax << '\n';
        TS_OUT << "  Server elapsed (ms):  avg=" << std::fixed << std::setprecision(3) << a.serverElapsedLastAvg 
               << "  min=" << a.serverElapsedLastMin 
               << "  max=" << a.serverElapsedLastMax << '\n';
        TS_OUT << "  Server CPU (ms):      avg=" << std::fixed << std::setprecision(3) << a.serverCpuLastAvg 
               << "  min=" << a.serverCpuLastMin 
               << "  max=" << a.serverCpuLastMax << '\n';
        TS_OUT << "  Server elapsed sum:   avg=" << std::fixed << std::setprecision(3) << a.serverElapsedAvg 
               << "  min=" << a.serverElapsedMin 
               << "  max=" << a.serverElapsedMax << '\n';
        TS_OUT << "  Server CPU sum:       avg=" << std::fixed << std::setprecision(3) << a.serverCpuAvg 
               << "  min=" << a.serverCpuMin 
               << "  max=" << a.serverCpuMax << '\n';
        TS_OUT << "  Compile elapsed (ms): avg=" << std::fixed << std::setprecision(3) << a.compileElapsedAvg 
               << "  min=" << a.compileElapsedMin 
               << "  max=" << a.compileElapsedMax << '\n';
        TS_OUT << "  Logical reads:        avg=" << std::fixed << std::setprecision(1) << a.logicalReadsAvg 
               << "  min=" << a.logicalReadsMin 
               << "  max=" << a.logicalReadsMax << '\n';
        TS_OUT << "  Physical reads:       avg=" << std::fixed << std::setprecision(1) << a.physicalReadsAvg 
               << "  min=" << a.physicalReadsMin 
               << "  max=" << a.physicalReadsMax << '\n';
        TS_OUT << "  Read-ahead reads:     avg=" << std::fixed << std::setprecision(1) << a.readAheadReadsAvg 
               << "  min=" << a.readAheadReadsMin 
               << "  max=" << a.readAheadReadsMax << '\n';
        if (a.hasRowCount) {
            TS_OUT << "  Row count:            avg=" << std::fixed << std::setprecision(1) << a.rowCountAvg 
                   << "  min=" << a.rowCountMin 
                   << "  max=" << a.rowCountMax << '\n';
        }
        TS_OUT << "  Executions: " << a.executions << '\n';
        if (!a.spids.empty()) {
            TS_OUT << "  SPIDs: ";
            size_t spidIndex = 0;
            for (const auto spid : a.spids) {
                if (spidIndex++ > 0) TS_OUT << ", ";
                TS_OUT << spid;
            }
            TS_OUT << '\n';
        }
        TS_OUT << '\n';
    }
    
    // Totals
    TS_OUT << std::string(70, '-') << '\n';
    TS_OUT << "Totals:\n";
    TS_OUT << "  Total elapsed:  " << std::fixed << std::setprecision(3) << totals.totalTotalElapsedMs << " ms\n";
    TS_OUT << "  Server elapsed: " << std::fixed << std::setprecision(3) << totals.totalServerElapsedLastMs << " ms\n";
    TS_OUT << "  Server CPU:     " << std::fixed << std::setprecision(3) << totals.totalServerCpuLastMs << " ms\n";
    TS_OUT << "  Server el. sum: " << std::fixed << std::setprecision(3) << totals.totalServerElapsedMs << " ms\n";
    TS_OUT << "  Server CPU sum: " << std::fixed << std::setprecision(3) << totals.totalServerCpuMs << " ms\n";
    TS_OUT << "  Compile:        " << std::fixed << std::setprecision(3) << totals.totalCompileElapsedMs << " ms\n";
    TS_OUT << "  Logical reads:  " << totals.totalLogicalReads << '\n';
    TS_OUT << "  Physical reads: " << totals.totalPhysicalReads << '\n';
    TS_OUT << "  Read-ahead:     " << totals.totalReadAheadReads << '\n';
    if (totals.hasRowCount) {
        TS_OUT << "  Total rows:     " << totals.totalRows << '\n';
    }
    TS_OUT << "  Executions:     " << totals.totalExecutions << '\n';
}

void WorkloadSimulator::printJsonQueryStats() const {
    auto aggregates = queryStats_.aggregate();
    auto totals = QueryStatsCollector::totalsOf(aggregates);
    
    if (aggregates.empty()) return;
    
    std::cout << "  \"query_stats\": {\n";
    std::cout << "    \"queries\": [\n";
    
    for (size_t i = 0; i < aggregates.size(); ++i) {
        const auto& a = aggregates[i];
        std::cout << "      {\n";
        std::cout << "        \"query\": \"" << JsonOutput::escapeJson(a.query) << "\",\n";
        std::cout << "        \"spids\": [";
        size_t spidIndex = 0;
        for (const auto spid : a.spids) {
            if (spidIndex >= 10) break;
            if (spidIndex++ > 0) std::cout << ", ";
            std::cout << spid;
        }
        std::cout << "],\n";
        std::cout << "        \"spid_count\": " << a.spids.size() << ",\n";
        
        std::cout << std::fixed << std::setprecision(3);
        std::cout << "        \"total_elapsed_ms\": {\"avg\": " << a.totalElapsedAvg 
                  << ", \"min\": " << a.totalElapsedMin 
                  << ", \"max\": " << a.totalElapsedMax << "},\n";
        std::cout << "        \"server_elapsed_ms\": {\"avg\": " << a.serverElapsedLastAvg 
                  << ", \"min\": " << a.serverElapsedLastMin 
                  << ", \"max\": " << a.serverElapsedLastMax << "},\n";
        std::cout << "        \"server_cpu_ms\": {\"avg\": " << a.serverCpuLastAvg 
                  << ", \"min\": " << a.serverCpuLastMin 
                  << ", \"max\": " << a.serverCpuLastMax << "},\n";
        std::cout << "        \"server_elapsed_sum_ms\": {\"avg\": " << a.serverElapsedAvg 
                  << ", \"min\": " << a.serverElapsedMin 
                  << ", \"max\": " << a.serverElapsedMax << "},\n";
        std::cout << "        \"server_cpu_sum_ms\": {\"avg\": " << a.serverCpuAvg 
                  << ", \"min\": " << a.serverCpuMin 
                  << ", \"max\": " << a.serverCpuMax << "},\n";
        std::cout << "        \"compile_elapsed_ms\": {\"avg\": " << a.compileElapsedAvg 
                  << ", \"min\": " << a.compileElapsedMin 
                  << ", \"max\": " << a.compileElapsedMax << "},\n";
        std::cout << "        \"logical_reads\": {\"avg\": " << std::setprecision(1) << a.logicalReadsAvg 
                  << ", \"min\": " << a.logicalReadsMin 
                  << ", \"max\": " << a.logicalReadsMax << "},\n";
        std::cout << "        \"physical_reads\": {\"avg\": " << a.physicalReadsAvg 
                  << ", \"min\": " << a.physicalReadsMin 
                  << ", \"max\": " << a.physicalReadsMax << "},\n";
        std::cout << "        \"read_ahead_reads\": {\"avg\": " << a.readAheadReadsAvg 
                  << ", \"min\": " << a.readAheadReadsMin 
                  << ", \"max\": " << a.readAheadReadsMax << "},\n";
        if (a.hasRowCount) {
            std::cout << "        \"row_count\": {\"avg\": " << a.rowCountAvg 
                      << ", \"min\": " << a.rowCountMin 
                      << ", \"max\": " << a.rowCountMax << "},\n";
        }

        std::cout << "        \"executions\": " << a.executions << ",\n";
        std::cout << "        \"failures\": " << a.failures << "\n";
        std::cout << "      }";
        if (i < aggregates.size() - 1) std::cout << ",";
        std::cout << "\n";
    }
    
    std::cout << "    ],\n";
    
    // Totals
    std::cout << std::fixed << std::setprecision(3);
    std::cout << "    \"totals\": {\n";
    std::cout << "      \"total_elapsed_ms\": " << totals.totalTotalElapsedMs << ",\n";
    std::cout << "      \"server_elapsed_ms\": " << totals.totalServerElapsedLastMs << ",\n";
    std::cout << "      \"server_cpu_ms\": " << totals.totalServerCpuLastMs << ",\n";
    std::cout << "      \"server_elapsed_sum_ms\": " << totals.totalServerElapsedMs << ",\n";
    std::cout << "      \"server_cpu_sum_ms\": " << totals.totalServerCpuMs << ",\n";
    std::cout << "      \"compile_elapsed_ms\": " << totals.totalCompileElapsedMs << ",\n";
    std::cout << "      \"logical_reads\": " << totals.totalLogicalReads << ",\n";
    std::cout << "      \"physical_reads\": " << totals.totalPhysicalReads << ",\n";
    std::cout << "      \"read_ahead_reads\": " << totals.totalReadAheadReads << ",\n";
    if (totals.hasRowCount) {
        std::cout << "      \"total_rows\": " << totals.totalRows << ",\n";
    }
    std::cout << "      \"executions\": " << totals.totalExecutions << ",\n";
    std::cout << "      \"failures\": " << totals.totalFailures << "\n";
    std::cout << "    }\n";
    std::cout << "  },\n";
}

void WorkloadSimulator::printJsonReplayCapture() const {
    struct OriginalAggregate {
        std::string eventType;
        uint64_t executions = 0;
        uint64_t ok = 0;
        uint64_t errors = 0;
        uint64_t aborts = 0;
        double durationTotalMs = 0.0;
        uint64_t durationSamples = 0;
        double cpuTotalMs = 0.0;
        uint64_t cpuSamples = 0;
        int64_t logicalReadsTotal = 0;
        uint64_t logicalReadsSamples = 0;
        int64_t physicalReadsTotal = 0;
        uint64_t physicalReadsSamples = 0;
        int64_t writesTotal = 0;
        uint64_t writesSamples = 0;
        int64_t rowCountTotal = 0;
        uint64_t rowCountSamples = 0;
        std::set<int64_t> sessions;
        std::set<std::string> databases;
    };

    std::map<std::string, OriginalAggregate> aggregates;
    for (const auto& event : config_.replayData.allEvents) {
        if (event.eventType == ReplayEventType::Skipped || event.statementText.empty()) continue;
        auto& aggregate = aggregates[event.statementText];
        aggregate.eventType = event.objectName;
        aggregate.executions++;
        aggregate.sessions.insert(event.sessionId);
        if (!event.databaseName.empty()) aggregate.databases.insert(event.databaseName);
        if (event.originalResult == 1) aggregate.errors++;
        else if (event.originalResult == 2) aggregate.aborts++;
        else aggregate.ok++;
        if (event.originalDurationMs >= 0.0) {
            aggregate.durationTotalMs += event.originalDurationMs;
            aggregate.durationSamples++;
        }
        if (event.originalCpuMs >= 0.0) {
            aggregate.cpuTotalMs += event.originalCpuMs;
            aggregate.cpuSamples++;
        }
        if (event.originalLogicalReads >= 0) {
            aggregate.logicalReadsTotal += event.originalLogicalReads;
            aggregate.logicalReadsSamples++;
        }
        if (event.originalPhysicalReads >= 0) {
            aggregate.physicalReadsTotal += event.originalPhysicalReads;
            aggregate.physicalReadsSamples++;
        }
        if (event.originalWrites >= 0) {
            aggregate.writesTotal += event.originalWrites;
            aggregate.writesSamples++;
        }
        if (event.originalRowCount >= 0) {
            aggregate.rowCountTotal += event.originalRowCount;
            aggregate.rowCountSamples++;
        }
    }

    auto printOptionalAverage = [](const char* name, double total, uint64_t samples) {
        std::cout << "        \"" << name << "\": ";
        if (samples == 0) std::cout << "null";
        else std::cout << std::fixed << std::setprecision(3) << total / static_cast<double>(samples);
        std::cout << ",\n";
    };

    std::cout << "  \"replay_capture\": {\n";
    std::cout << "    \"total_events\": " << config_.replayData.totalEvents << ",\n";
    std::cout << "    \"replayable_events\": " << config_.replayData.replayableEvents << ",\n";
    std::cout << "    \"skipped_events\": " << config_.replayData.skippedEvents << ",\n";
    std::cout << "    \"sessions\": " << config_.replayData.sessions.size() << ",\n";
    std::cout << "    \"captured_spids\": [";
    for (size_t sessionIndex = 0; sessionIndex < config_.replayData.sessions.size(); ++sessionIndex) {
        if (sessionIndex > 0) std::cout << ", ";
        std::cout << config_.replayData.sessions[sessionIndex].sessionId;
    }
    std::cout << "],\n";
    std::cout << "    \"queries\": [";
    if (!aggregates.empty()) std::cout << "\n";

    size_t index = 0;
    for (const auto& [query, aggregate] : aggregates) {
        std::cout << "      {\n";
        std::cout << "        \"query\": \"" << JsonOutput::escapeJson(query) << "\",\n";
        std::cout << "        \"event_type\": \"" << JsonOutput::escapeJson(aggregate.eventType) << "\",\n";
        std::cout << "        \"executions\": " << aggregate.executions << ",\n";
        std::cout << "        \"sessions\": " << aggregate.sessions.size() << ",\n";
        std::cout << "        \"captured_spids\": [";
        constexpr size_t maxQuerySpids = 10;
        size_t sessionIndex = 0;
        for (const auto sessionId : aggregate.sessions) {
            if (sessionIndex >= maxQuerySpids) break;
            if (sessionIndex++ > 0) std::cout << ", ";
            std::cout << sessionId;
        }
        std::cout << "],\n";
        std::cout << "        \"databases\": [";
        size_t databaseIndex = 0;
        for (const auto& database : aggregate.databases) {
            if (databaseIndex++ > 0) std::cout << ", ";
            std::cout << "\"" << JsonOutput::escapeJson(database) << "\"";
        }
        std::cout << "],\n";
        std::cout << "        \"outcomes\": {\"ok\": " << aggregate.ok
                  << ", \"error\": " << aggregate.errors
                  << ", \"abort\": " << aggregate.aborts << "},\n";
        printOptionalAverage("avg_duration_ms", aggregate.durationTotalMs, aggregate.durationSamples);
        printOptionalAverage("avg_cpu_ms", aggregate.cpuTotalMs, aggregate.cpuSamples);
        printOptionalAverage("avg_logical_reads", static_cast<double>(aggregate.logicalReadsTotal), aggregate.logicalReadsSamples);
        printOptionalAverage("avg_physical_reads", static_cast<double>(aggregate.physicalReadsTotal), aggregate.physicalReadsSamples);
        printOptionalAverage("avg_writes", static_cast<double>(aggregate.writesTotal), aggregate.writesSamples);
        std::cout << "        \"avg_row_count\": ";
        if (aggregate.rowCountSamples == 0) std::cout << "null\n";
        else std::cout << std::fixed << std::setprecision(3)
                       << static_cast<double>(aggregate.rowCountTotal) /
                          static_cast<double>(aggregate.rowCountSamples) << "\n";
        std::cout << "      }";
        if (++index < aggregates.size()) std::cout << ",";
        std::cout << "\n";
    }
    if (!aggregates.empty()) std::cout << "    ";
    std::cout << "],\n";
    std::cout << "    \"connection_map\": [";
    std::vector<ReplayConnectionInfo> connections;
    {
        std::lock_guard<std::mutex> lock(replayConnectionsMutex_);
        connections = replayConnections_;
    }
    std::sort(connections.begin(), connections.end(),
              [](const ReplayConnectionInfo& left, const ReplayConnectionInfo& right) {
                  return left.worker < right.worker;
              });
    if (!connections.empty()) std::cout << "\n";
    for (size_t connectionIndex = 0; connectionIndex < connections.size(); ++connectionIndex) {
        const auto& connection = connections[connectionIndex];
        std::cout << "      {\"worker\": " << connection.worker << ", \"captured_spid\": ";
        if (connection.capturedSpid > 0) std::cout << connection.capturedSpid;
        else std::cout << "null";
        std::cout << ", \"replay_spid\": ";
        if (connection.replaySpid > 0) std::cout << connection.replaySpid;
        else std::cout << "null";
        std::cout << "}";
        if (connectionIndex + 1 < connections.size()) std::cout << ",";
        std::cout << "\n";
    }
    if (!connections.empty()) std::cout << "    ";
    std::cout << "]\n";
    std::cout << "  },\n";
}
