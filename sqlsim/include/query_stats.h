#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <regex>
#include <set>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <limits>
#include <cmath>
#include <memory>

/**
 * Per-execution stats parsed from SET STATISTICS TIME/IO messages
 */
struct QueryExecutionStats {
    double totalElapsedMs = 0.0;        // Total wall clock (std::chrono around SQLExecDirectW)
    double serverElapsedMs = 0.0;       // SET STATISTICS TIME: sum of all execution elapsed messages
    double serverCpuMs = 0.0;           // SET STATISTICS TIME: sum of all execution CPU messages
    double serverElapsedLastMs = 0.0;   // SET STATISTICS TIME: last execution elapsed (proc total or last statement)
    double serverCpuLastMs = 0.0;       // SET STATISTICS TIME: last execution CPU (proc total or last statement)
    double compileElapsedMs = 0.0;      // SET STATISTICS TIME: parse/compile elapsed
    double compileCpuMs = 0.0;          // SET STATISTICS TIME: parse/compile CPU
    int64_t logicalReads = 0;           // SET STATISTICS IO: sum across all tables
    int64_t physicalReads = 0;          // SET STATISTICS IO: sum across all tables
    int64_t readAheadReads = 0;         // SET STATISTICS IO: sum across all tables
    int64_t rowCount = -1;              // Row count (-1 = not available, e.g. quiet mode)
    int64_t spid = 0;                   // SQL Server session ID for this execution
    bool success = true;
};

/**
 * Aggregated stats for a unique query (across multiple executions via -n/-r)
 */
struct QueryStatsAggregate {
    std::string query;                   // The SQL text
    int executions = 0;                  // Successful executions
    int failures = 0;                    // Failed executions
    std::set<int64_t> spids;             // Distinct SQL Server sessions that executed this query

    // Total elapsed
    double totalElapsedAvg = 0.0;
    double totalElapsedMin = 0.0;
    double totalElapsedMax = 0.0;
    double totalElapsedTotal = 0.0;

    // Server elapsed (sum of all Execution Times messages — for batches)
    double serverElapsedAvg = 0.0;
    double serverElapsedMin = 0.0;
    double serverElapsedMax = 0.0;
    double serverElapsedTotal = 0.0;

    // Server CPU (sum of all Execution Times messages — for batches)
    double serverCpuAvg = 0.0;
    double serverCpuMin = 0.0;
    double serverCpuMax = 0.0;
    double serverCpuTotal = 0.0;

    // Server elapsed last (last Execution Times message — proc total for EXEC, last stmt for batch)
    double serverElapsedLastAvg = 0.0;
    double serverElapsedLastMin = 0.0;
    double serverElapsedLastMax = 0.0;
    double serverElapsedLastTotal = 0.0;

    // Server CPU last
    double serverCpuLastAvg = 0.0;
    double serverCpuLastMin = 0.0;
    double serverCpuLastMax = 0.0;
    double serverCpuLastTotal = 0.0;

    // Compile elapsed
    double compileElapsedAvg = 0.0;
    double compileElapsedMin = 0.0;
    double compileElapsedMax = 0.0;
    double compileElapsedTotal = 0.0;

    // Logical reads
    double logicalReadsAvg = 0.0;
    int64_t logicalReadsMin = 0;
    int64_t logicalReadsMax = 0;
    int64_t logicalReadsTotal = 0;

    // Physical reads
    double physicalReadsAvg = 0.0;
    int64_t physicalReadsMin = 0;
    int64_t physicalReadsMax = 0;
    int64_t physicalReadsTotal = 0;

    // Read-ahead reads
    double readAheadReadsAvg = 0.0;
    int64_t readAheadReadsMin = 0;
    int64_t readAheadReadsMax = 0;
    int64_t readAheadReadsTotal = 0;

    // Row count
    double rowCountAvg = 0.0;
    int64_t rowCountMin = 0;
    int64_t rowCountMax = 0;
    int64_t rowCountTotal = 0;
    bool hasRowCount = false;            // True if any execution had row_count >= 0
};

/**
 * Thread-safe collector for query stats.
 *
 * Each worker thread owns a Slot holding running totals per distinct query, so
 * memory depends on the number of distinct queries, not on executions. A slot's
 * mutex is uncontended except while a snapshot merges it, which lets the
 * periodic -querystats-interval snapshot read live totals safely.
 */
class QueryStatsCollector {
public:
    struct Slot {
        std::mutex mutex;
        std::unordered_map<std::string, size_t> index;  // query text -> position in entries
        std::vector<QueryStatsAggregate> entries;        // first-seen order within this thread
    };

    /**
     * Register a worker thread and return its slot. The pointer stays valid for
     * the collector's lifetime, so recording never touches the shared slot list.
     */
    Slot* registerThread() {
        std::lock_guard<std::mutex> lock(registrationMutex_);
        slots_.push_back(std::make_unique<Slot>());
        return slots_.back().get();
    }

    /**
     * Record a single query execution's stats into the thread's running totals.
     */
    void record(Slot* slot, const std::string& query, const QueryExecutionStats& stats) {
        std::lock_guard<std::mutex> lock(slot->mutex);
        auto it = slot->index.find(query);
        size_t position;
        if (it == slot->index.end()) {
            position = slot->entries.size();
            slot->entries.push_back(newAggregate(query));
            slot->index.emplace(query, position);
        } else {
            position = it->second;
        }
        accumulate(slot->entries[position], stats);
    }

    /**
     * Record from a thread that did not register a slot.
     */
    void record(const std::string& query, const QueryExecutionStats& stats) {
        record(&overflowSlot_, query, stats);
    }

    /**
     * Merge every thread's running totals into per-unique-query summaries,
     * ordered by first appearance (thread registration order, then the order
     * each thread first ran the query). Safe to call while workers are running.
     */
    std::vector<QueryStatsAggregate> aggregate() const {
        struct AccumulatorEntry {
            int index = 0;
            QueryStatsAggregate agg;
        };
        std::unordered_map<std::string, AccumulatorEntry> accum;
        int nextIndex = 0;

        forEachThreadAggregate([&](const QueryStatsAggregate& source) {
            auto it = accum.find(source.query);
            if (it == accum.end()) {
                AccumulatorEntry entry;
                entry.index = nextIndex++;
                entry.agg = newAggregate(source.query);
                it = accum.emplace(source.query, std::move(entry)).first;
            }
            merge(it->second.agg, source);
        });

        std::vector<std::pair<int, QueryStatsAggregate>> sorted;
        sorted.reserve(accum.size());
        for (auto& pair : accum) {
            auto& a = pair.second.agg;
            if (a.executions > 0) {
                a.totalElapsedAvg = a.totalElapsedTotal / a.executions;
                a.serverElapsedAvg = a.serverElapsedTotal / a.executions;
                a.serverCpuAvg = a.serverCpuTotal / a.executions;
                a.serverElapsedLastAvg = a.serverElapsedLastTotal / a.executions;
                a.serverCpuLastAvg = a.serverCpuLastTotal / a.executions;
                a.compileElapsedAvg = a.compileElapsedTotal / a.executions;
                a.logicalReadsAvg = static_cast<double>(a.logicalReadsTotal) / a.executions;
                a.physicalReadsAvg = static_cast<double>(a.physicalReadsTotal) / a.executions;
                a.readAheadReadsAvg = static_cast<double>(a.readAheadReadsTotal) / a.executions;
                if (a.hasRowCount) {
                    a.rowCountAvg = static_cast<double>(a.rowCountTotal) / a.executions;
                }
            }
            // Fix min/max values if no successful executions were recorded
            if (a.totalElapsedMin == (std::numeric_limits<double>::max)()) a.totalElapsedMin = 0.0;
            if (a.totalElapsedMax == (std::numeric_limits<double>::lowest)()) a.totalElapsedMax = 0.0;
            if (a.serverElapsedMin == (std::numeric_limits<double>::max)()) a.serverElapsedMin = 0.0;
            if (a.serverElapsedMax == (std::numeric_limits<double>::lowest)()) a.serverElapsedMax = 0.0;
            if (a.serverCpuMin == (std::numeric_limits<double>::max)()) a.serverCpuMin = 0.0;
            if (a.serverCpuMax == (std::numeric_limits<double>::lowest)()) a.serverCpuMax = 0.0;
            if (a.serverElapsedLastMin == (std::numeric_limits<double>::max)()) a.serverElapsedLastMin = 0.0;
            if (a.serverElapsedLastMax == (std::numeric_limits<double>::lowest)()) a.serverElapsedLastMax = 0.0;
            if (a.serverCpuLastMin == (std::numeric_limits<double>::max)()) a.serverCpuLastMin = 0.0;
            if (a.serverCpuLastMax == (std::numeric_limits<double>::lowest)()) a.serverCpuLastMax = 0.0;
            if (a.compileElapsedMin == (std::numeric_limits<double>::max)()) a.compileElapsedMin = 0.0;
            if (a.compileElapsedMax == (std::numeric_limits<double>::lowest)()) a.compileElapsedMax = 0.0;
            if (a.logicalReadsMin == (std::numeric_limits<int64_t>::max)()) a.logicalReadsMin = 0;
            if (a.logicalReadsMax == (std::numeric_limits<int64_t>::lowest)()) a.logicalReadsMax = 0;
            if (a.physicalReadsMin == (std::numeric_limits<int64_t>::max)()) a.physicalReadsMin = 0;
            if (a.physicalReadsMax == (std::numeric_limits<int64_t>::lowest)()) a.physicalReadsMax = 0;
            if (a.readAheadReadsMin == (std::numeric_limits<int64_t>::max)()) a.readAheadReadsMin = 0;
            if (a.readAheadReadsMax == (std::numeric_limits<int64_t>::lowest)()) a.readAheadReadsMax = 0;
            if (a.rowCountMin == (std::numeric_limits<int64_t>::max)()) a.rowCountMin = 0;
            if (a.rowCountMax == (std::numeric_limits<int64_t>::lowest)()) a.rowCountMax = 0;

            sorted.push_back({pair.second.index, std::move(a)});
        }
        std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) {
            return a.first < b.first;
        });

        std::vector<QueryStatsAggregate> result;
        result.reserve(sorted.size());
        for (auto& pair : sorted) {
            result.push_back(std::move(pair.second));
        }
        return result;
    }

    /**
     * Compute totals across all executions (for the summary footer).
     */
    struct Totals {
        int totalExecutions = 0;
        int totalFailures = 0;
        double totalTotalElapsedMs = 0.0;
        double totalServerElapsedMs = 0.0;      // sum of all Execution Times messages
        double totalServerCpuMs = 0.0;           // sum of all Execution Times messages
        double totalServerElapsedLastMs = 0.0;   // last Execution Times message per execution
        double totalServerCpuLastMs = 0.0;       // last Execution Times message per execution
        double totalCompileElapsedMs = 0.0;
        int64_t totalLogicalReads = 0;
        int64_t totalPhysicalReads = 0;
        int64_t totalReadAheadReads = 0;
        int64_t totalRows = 0;
        bool hasRowCount = false;
    };

    Totals getTotals() const {
        return totalsOf(aggregate());
    }

    // Totals from an existing aggregate() result, so a live snapshot's footer
    // always matches its per-query rows.
    static Totals totalsOf(const std::vector<QueryStatsAggregate>& aggregates) {
        Totals t;
        for (const auto& a : aggregates) {
            t.totalExecutions += a.executions;
            t.totalFailures += a.failures;
            t.totalTotalElapsedMs += a.totalElapsedTotal;
            t.totalServerElapsedMs += a.serverElapsedTotal;
            t.totalServerCpuMs += a.serverCpuTotal;
            t.totalServerElapsedLastMs += a.serverElapsedLastTotal;
            t.totalServerCpuLastMs += a.serverCpuLastTotal;
            t.totalCompileElapsedMs += a.compileElapsedTotal;
            t.totalLogicalReads += a.logicalReadsTotal;
            t.totalPhysicalReads += a.physicalReadsTotal;
            t.totalReadAheadReads += a.readAheadReadsTotal;
            if (a.hasRowCount) {
                t.hasRowCount = true;
                t.totalRows += a.rowCountTotal;
            }
        }
        return t;
    }

    bool empty() const {
        bool found = false;
        forEachThreadAggregate([&](const QueryStatsAggregate&) { found = true; });
        return !found;
    }

    /**
     * Parse SET STATISTICS TIME messages from info messages.
     * Returns the messages that are NOT statistics messages (for normal display).
     * Populates outStats with parsed values.
     * 
     * SET STATISTICS TIME format:
     *   "SQL Server parse and compile time: CPU time = 0 ms, elapsed time = 2 ms."
     *   " SQL Server Execution Times:    CPU time = 16 ms,  elapsed time = 123 ms."
     *
     * SET STATISTICS IO format:
     *   "Table 'LINEITEM'. Scan count 1, logical reads 100392, physical reads 5, ..."
     */
    static std::vector<std::string> parseAndFilterMessages(
        const std::vector<std::string>& messages,
        QueryExecutionStats& outStats) 
    {
        // Phase 1 Optimization: Avoid allocating nonStatsMessages vector in common case
        // where all messages are statistics messages (typical for querystats mode)
        std::vector<std::string> nonStatsMessages;
        bool hasNonStats = false;

        for (const auto& msg : messages) {
            bool isStatsMessage = false;

            // Phase 1 Optimization: Use c_str() pointer for fast prefix scanning
            // Most messages start with known prefixes, so check cheaply first
            const char* s = msg.c_str();
            
            // Skip leading whitespace including newlines (ODBC driver messages may have \n prefix)
            while (*s == ' ' || *s == '\n' || *s == '\r' || *s == '\t') s++;

            // Check for SET STATISTICS TIME: parse/compile
            // Format: "SQL Server parse and compile time: CPU time = X ms, elapsed time = Y ms."
            if (strncmp(s, "SQL Server parse and compile time", 33) == 0) {
                double cpu = 0, elapsed = 0;
                if (parseTimeMessage(msg.c_str(), msg.size(), cpu, elapsed)) {
                    outStats.compileCpuMs += cpu;
                    outStats.compileElapsedMs += elapsed;
                    isStatsMessage = true;
                }
            }
            // Check for SET STATISTICS TIME: execution
            // Format: " SQL Server Execution Times:    CPU time = X ms,  elapsed time = Y ms."
            else if (strncmp(s, "SQL Server Execution Times", 26) == 0) {
                double cpu = 0, elapsed = 0;
                if (parseTimeMessage(msg.c_str(), msg.size(), cpu, elapsed)) {
                    outStats.serverCpuMs += cpu;
                    outStats.serverElapsedMs += elapsed;
                    outStats.serverCpuLastMs = cpu;       // Overwrite: last Execution Times wins
                    outStats.serverElapsedLastMs = elapsed; // (proc total for EXEC, last stmt for batch)
                    isStatsMessage = true;
                }
            }
            // Check for SET STATISTICS IO
            // Format: "Table 'XXX'. Scan count N, logical reads N, physical reads N, ..."
            else if (strncmp(s, "Table '", 7) == 0) {
                int64_t logical = 0, physical = 0, readAhead = 0;
                if (parseIOMessage(msg.c_str(), msg.size(), logical, physical, readAhead)) {
                    outStats.logicalReads += logical;
                    outStats.physicalReads += physical;
                    outStats.readAheadReads += readAhead;
                    isStatsMessage = true;
                }
            }

            if (!isStatsMessage) {
                if (!hasNonStats) {
                    // First non-stats message: allocate vector now
                    nonStatsMessages.reserve(messages.size());
                    hasNonStats = true;
                }
                nonStatsMessages.push_back(msg);
            }
        }

        return nonStatsMessages;
    }

private:
    mutable std::mutex registrationMutex_;       // Guards slots_ during registration and merging
    std::vector<std::unique_ptr<Slot>> slots_;   // One per registered worker thread
    mutable Slot overflowSlot_;                  // For threads that did not register

    static QueryStatsAggregate newAggregate(const std::string& query) {
        QueryStatsAggregate a;
        a.query = query;
        a.totalElapsedMin = (std::numeric_limits<double>::max)();
        a.totalElapsedMax = (std::numeric_limits<double>::lowest)();
        a.serverElapsedMin = (std::numeric_limits<double>::max)();
        a.serverElapsedMax = (std::numeric_limits<double>::lowest)();
        a.serverCpuMin = (std::numeric_limits<double>::max)();
        a.serverCpuMax = (std::numeric_limits<double>::lowest)();
        a.serverElapsedLastMin = (std::numeric_limits<double>::max)();
        a.serverElapsedLastMax = (std::numeric_limits<double>::lowest)();
        a.serverCpuLastMin = (std::numeric_limits<double>::max)();
        a.serverCpuLastMax = (std::numeric_limits<double>::lowest)();
        a.compileElapsedMin = (std::numeric_limits<double>::max)();
        a.compileElapsedMax = (std::numeric_limits<double>::lowest)();
        a.logicalReadsMin = (std::numeric_limits<int64_t>::max)();
        a.logicalReadsMax = (std::numeric_limits<int64_t>::lowest)();
        a.physicalReadsMin = (std::numeric_limits<int64_t>::max)();
        a.physicalReadsMax = (std::numeric_limits<int64_t>::lowest)();
        a.readAheadReadsMin = (std::numeric_limits<int64_t>::max)();
        a.readAheadReadsMax = (std::numeric_limits<int64_t>::lowest)();
        a.rowCountMin = (std::numeric_limits<int64_t>::max)();
        a.rowCountMax = (std::numeric_limits<int64_t>::lowest)();
        return a;
    }

    static void accumulate(QueryStatsAggregate& a, const QueryExecutionStats& s) {
        if (s.spid > 0) {
            a.spids.insert(s.spid);
        }

        // Count failures separately; only accumulate stats from successful executions
        if (!s.success) {
            a.failures++;
            return;
        }
        a.executions++;

        a.totalElapsedTotal += s.totalElapsedMs;
        a.totalElapsedMin = (std::min)(a.totalElapsedMin, s.totalElapsedMs);
        a.totalElapsedMax = (std::max)(a.totalElapsedMax, s.totalElapsedMs);

        a.serverElapsedTotal += s.serverElapsedMs;
        a.serverElapsedMin = (std::min)(a.serverElapsedMin, s.serverElapsedMs);
        a.serverElapsedMax = (std::max)(a.serverElapsedMax, s.serverElapsedMs);

        a.serverCpuTotal += s.serverCpuMs;
        a.serverCpuMin = (std::min)(a.serverCpuMin, s.serverCpuMs);
        a.serverCpuMax = (std::max)(a.serverCpuMax, s.serverCpuMs);

        a.serverElapsedLastTotal += s.serverElapsedLastMs;
        a.serverElapsedLastMin = (std::min)(a.serverElapsedLastMin, s.serverElapsedLastMs);
        a.serverElapsedLastMax = (std::max)(a.serverElapsedLastMax, s.serverElapsedLastMs);

        a.serverCpuLastTotal += s.serverCpuLastMs;
        a.serverCpuLastMin = (std::min)(a.serverCpuLastMin, s.serverCpuLastMs);
        a.serverCpuLastMax = (std::max)(a.serverCpuLastMax, s.serverCpuLastMs);

        a.compileElapsedTotal += s.compileElapsedMs;
        a.compileElapsedMin = (std::min)(a.compileElapsedMin, s.compileElapsedMs);
        a.compileElapsedMax = (std::max)(a.compileElapsedMax, s.compileElapsedMs);

        a.logicalReadsTotal += s.logicalReads;
        a.logicalReadsMin = (std::min)(a.logicalReadsMin, s.logicalReads);
        a.logicalReadsMax = (std::max)(a.logicalReadsMax, s.logicalReads);

        a.physicalReadsTotal += s.physicalReads;
        a.physicalReadsMin = (std::min)(a.physicalReadsMin, s.physicalReads);
        a.physicalReadsMax = (std::max)(a.physicalReadsMax, s.physicalReads);

        a.readAheadReadsTotal += s.readAheadReads;
        a.readAheadReadsMin = (std::min)(a.readAheadReadsMin, s.readAheadReads);
        a.readAheadReadsMax = (std::max)(a.readAheadReadsMax, s.readAheadReads);

        if (s.rowCount >= 0) {
            a.hasRowCount = true;
            a.rowCountTotal += s.rowCount;
            a.rowCountMin = (std::min)(a.rowCountMin, s.rowCount);
            a.rowCountMax = (std::max)(a.rowCountMax, s.rowCount);
        }
    }

    static void merge(QueryStatsAggregate& into, const QueryStatsAggregate& from) {
        into.spids.insert(from.spids.begin(), from.spids.end());
        into.failures += from.failures;
        into.executions += from.executions;

        into.totalElapsedTotal += from.totalElapsedTotal;
        into.totalElapsedMin = (std::min)(into.totalElapsedMin, from.totalElapsedMin);
        into.totalElapsedMax = (std::max)(into.totalElapsedMax, from.totalElapsedMax);

        into.serverElapsedTotal += from.serverElapsedTotal;
        into.serverElapsedMin = (std::min)(into.serverElapsedMin, from.serverElapsedMin);
        into.serverElapsedMax = (std::max)(into.serverElapsedMax, from.serverElapsedMax);

        into.serverCpuTotal += from.serverCpuTotal;
        into.serverCpuMin = (std::min)(into.serverCpuMin, from.serverCpuMin);
        into.serverCpuMax = (std::max)(into.serverCpuMax, from.serverCpuMax);

        into.serverElapsedLastTotal += from.serverElapsedLastTotal;
        into.serverElapsedLastMin = (std::min)(into.serverElapsedLastMin, from.serverElapsedLastMin);
        into.serverElapsedLastMax = (std::max)(into.serverElapsedLastMax, from.serverElapsedLastMax);

        into.serverCpuLastTotal += from.serverCpuLastTotal;
        into.serverCpuLastMin = (std::min)(into.serverCpuLastMin, from.serverCpuLastMin);
        into.serverCpuLastMax = (std::max)(into.serverCpuLastMax, from.serverCpuLastMax);

        into.compileElapsedTotal += from.compileElapsedTotal;
        into.compileElapsedMin = (std::min)(into.compileElapsedMin, from.compileElapsedMin);
        into.compileElapsedMax = (std::max)(into.compileElapsedMax, from.compileElapsedMax);

        into.logicalReadsTotal += from.logicalReadsTotal;
        into.logicalReadsMin = (std::min)(into.logicalReadsMin, from.logicalReadsMin);
        into.logicalReadsMax = (std::max)(into.logicalReadsMax, from.logicalReadsMax);

        into.physicalReadsTotal += from.physicalReadsTotal;
        into.physicalReadsMin = (std::min)(into.physicalReadsMin, from.physicalReadsMin);
        into.physicalReadsMax = (std::max)(into.physicalReadsMax, from.physicalReadsMax);

        into.readAheadReadsTotal += from.readAheadReadsTotal;
        into.readAheadReadsMin = (std::min)(into.readAheadReadsMin, from.readAheadReadsMin);
        into.readAheadReadsMax = (std::max)(into.readAheadReadsMax, from.readAheadReadsMax);

        if (from.hasRowCount) {
            into.hasRowCount = true;
            into.rowCountTotal += from.rowCountTotal;
            into.rowCountMin = (std::min)(into.rowCountMin, from.rowCountMin);
            into.rowCountMax = (std::max)(into.rowCountMax, from.rowCountMax);
        }
    }

    // Visit each thread's per-query totals in registration order, then the
    // overflow slot, holding each slot's lock only while it is read.
    template <typename Visitor>
    void forEachThreadAggregate(Visitor visit) const {
        std::lock_guard<std::mutex> registration(registrationMutex_);
        auto visitSlot = [&](Slot& slot) {
            std::lock_guard<std::mutex> lock(slot.mutex);
            for (const auto& aggregate : slot.entries) {
                visit(aggregate);
            }
        };
        for (const auto& slot : slots_) {
            visitSlot(*slot);
        }
        visitSlot(overflowSlot_);
    }

    /**
     * Parse "CPU time = X ms, elapsed time = Y ms" from a SET STATISTICS TIME message.
     * Phase 1 Optimization: Uses direct pointer arithmetic with strtod() instead of
     * building intermediate std::string objects. Eliminates per-char string concatenation.
     */
    static bool parseTimeMessage(const char* msg, size_t len, double& cpuMs, double& elapsedMs) {
        // Look for "CPU time = X ms" using strstr for fast C-level search
        const char* cpuPtr = strstr(msg, "CPU time = ");
        if (!cpuPtr) return false;
        cpuPtr += 11; // length of "CPU time = "

        // Extract CPU value directly with strtod (handles leading minus, digits)
        char* endPtr = nullptr;
        cpuMs = std::strtod(cpuPtr, &endPtr);
        if (endPtr == cpuPtr) return false; // no digits consumed

        // Look for "elapsed time = Y ms"
        const char* elapsedPtr = strstr(msg, "elapsed time = ");
        if (!elapsedPtr) return false;
        elapsedPtr += 15; // length of "elapsed time = "

        // Extract elapsed value directly with strtod
        elapsedMs = std::strtod(elapsedPtr, &endPtr);
        if (endPtr == elapsedPtr) return false; // no digits consumed

        return true;
    }

    /**
     * Parse "logical reads N, physical reads N, ... read-ahead reads N" from a SET STATISTICS IO message.
     * Phase 1 Optimization: Uses direct pointer arithmetic with strtoll() instead of
     * building intermediate std::string objects. Eliminates per-char string concatenation.
     */
    static bool parseIOMessage(const char* msg, size_t len, int64_t& logicalReads, int64_t& physicalReads, int64_t& readAheadReads) {
        // Look for "logical reads X" using strstr for fast C-level search
        const char* logicalPtr = strstr(msg, "logical reads ");
        if (!logicalPtr) return false;
        logicalPtr += 14; // length of "logical reads "

        // Extract logical reads directly with strtoll
        char* endPtr = nullptr;
        logicalReads = std::strtoll(logicalPtr, &endPtr, 10);
        if (endPtr == logicalPtr) return false; // no digits consumed

        // Look for "physical reads X"
        const char* physicalPtr = strstr(msg, "physical reads ");
        if (!physicalPtr) return false;
        physicalPtr += 15; // length of "physical reads "

        // Extract physical reads directly with strtoll
        physicalReads = std::strtoll(physicalPtr, &endPtr, 10);
        if (endPtr == physicalPtr) return false; // no digits consumed

        // Look for "read-ahead reads X"
        // Note: must find the standalone "read-ahead reads" not "page server read-ahead reads" or "lob read-ahead reads"
        // Search from after physical reads to find the first "read-ahead reads" which is the standard one
        readAheadReads = 0;
        const char* raPtr = strstr(endPtr, "read-ahead reads ");
        if (raPtr) {
            // Make sure this is not "page server read-ahead reads" by checking preceding text
            bool isPageServer = (raPtr >= msg + 12 && strncmp(raPtr - 12, "page server ", 12) == 0);
            if (!isPageServer) {
                const char* valPtr = raPtr + 17; // length of "read-ahead reads "
                readAheadReads = std::strtoll(valPtr, &endPtr, 10);
                if (endPtr == valPtr) readAheadReads = 0; // no digits consumed
            }
        }

        return true;
    }
};
