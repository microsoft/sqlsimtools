#pragma once

#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <algorithm>
#include <cctype>

/**
 * A single workload entry from a workload JSON file.
 * Each entry defines a group of threads running the same queries.
 */
struct WorkloadEntry {
    std::string file;                      // SQL script file path (mutually exclusive with queries)
    std::vector<std::string> queries;      // Inline query list (mutually exclusive with file)
    int threads = 1;                       // Number of threads for this workload group
    int iterations = 1;                    // Iterations per thread (ignored when duration_seconds > 0)
    int duration_seconds = 0;              // Run duration in seconds (0 = use iterations instead)
    int think_time_ms = 0;                 // Delay (ms) between iterations (0 = tight loop)
    int ramp_batch_size = 0;               // Threads to launch per batch (0 = all at once)
    int ramp_delay_ms = 500;               // Delay (ms) between ramp batches
};

/**
 * Per-thread assignment derived from expanding WorkloadEntry groups.
 * Each thread gets its own query list and iteration count.
 */
struct ThreadAssignment {
    std::vector<std::string> queries;      // Queries this thread will execute
    int iterations = 1;                    // Iterations for this thread (ignored when duration_seconds > 0)
    int duration_seconds = 0;              // 0 = use iterations, >0 = run for this many seconds
    int workloadIndex = 0;                 // Which workload entry this came from (for display)
    int think_time_ms = 0;                 // Delay (ms) between iterations (0 = tight loop)
};

/**
 * Simple JSON parser for workload files.
 * Supports the specific structure needed for workload definitions:
 * {
 *   "workloads": [
 *     {"file": "script.sql", "threads": 2, "iterations": 10},
 *     {"queries": ["SELECT 1", "SELECT 2"], "threads": 1, "iterations": 100}
 *   ]
 * }
 */
class WorkloadFileParser {
public:
    /**
     * Parse a workload JSON file and return the list of workload entries.
     * Throws std::runtime_error on parse errors.
     */
    static std::vector<WorkloadEntry> parse(const std::string& filePath) {
        // Read file content
        std::ifstream file(filePath);
        if (!file.is_open()) {
            throw std::runtime_error("Cannot open workload file: " + filePath);
        }
        
        std::stringstream buffer;
        buffer << file.rdbuf();
        std::string content = buffer.str();
        
        return parseContent(content, filePath);
    }
    
    /**
     * Parse workload JSON content (for testing without file I/O).
     */
    static std::vector<WorkloadEntry> parseContent(const std::string& content, const std::string& sourceName = "<string>") {
        size_t pos = 0;
        skipWhitespace(content, pos);
        
        // Expect top-level object
        expectChar(content, pos, '{', sourceName);
        skipWhitespace(content, pos);
        
        // Parse top-level keys: "workloads" (required), "duration_seconds" (optional), ramp settings (optional)
        std::vector<WorkloadEntry> entries;
        int globalDurationSeconds = 0;
        int globalRampBatchSize = 0;
        int globalRampDelayMs = 500;
        
        while (pos < content.size() && content[pos] != '}') {
            std::string key = parseString(content, pos, sourceName);
            skipWhitespace(content, pos);
            expectChar(content, pos, ':', sourceName);
            skipWhitespace(content, pos);
            
            if (key == "workloads") {
                entries = parseWorkloadsArray(content, pos, sourceName);
            } else if (key == "duration_seconds") {
                globalDurationSeconds = parseInt(content, pos, sourceName);
            } else if (key == "ramp_batch_size") {
                globalRampBatchSize = parseInt(content, pos, sourceName);
            } else if (key == "ramp_delay_ms") {
                globalRampDelayMs = parseInt(content, pos, sourceName);
            } else {
                skipValue(content, pos, sourceName);
            }
            
            skipWhitespace(content, pos);
            if (pos < content.size() && content[pos] == ',') {
                pos++;
                skipWhitespace(content, pos);
            }
        }
        
        expectChar(content, pos, '}', sourceName);
        
        if (entries.empty()) {
            throw std::runtime_error("Workload file " + sourceName + ": \"workloads\" key is required");
        }
        
        // Validate entries
        for (size_t i = 0; i < entries.size(); ++i) {
            const auto& e = entries[i];
            if (e.file.empty() && e.queries.empty()) {
                throw std::runtime_error("Workload file " + sourceName + ": workload entry " + 
                    std::to_string(i + 1) + " must have either \"file\" or \"queries\"");
            }
            if (!e.file.empty() && !e.queries.empty()) {
                throw std::runtime_error("Workload file " + sourceName + ": workload entry " + 
                    std::to_string(i + 1) + " cannot have both \"file\" and \"queries\"");
            }
            if (e.threads < 1) {
                throw std::runtime_error("Workload file " + sourceName + ": workload entry " + 
                    std::to_string(i + 1) + " threads must be >= 1");
            }
            if (globalDurationSeconds == 0 && e.iterations < 1) {
                throw std::runtime_error("Workload file " + sourceName + ": workload entry " + 
                    std::to_string(i + 1) + " iterations must be >= 1 (or use top-level \"duration_seconds\")");
            }
        }
        
        // Store global duration on each entry so it propagates through the pipeline
        if (globalDurationSeconds > 0) {
            for (auto& e : entries) {
                e.duration_seconds = globalDurationSeconds;
            }
        }
        
        // Store ramp settings on each entry so they propagate through the pipeline
        if (globalRampBatchSize > 0) {
            for (auto& e : entries) {
                e.ramp_batch_size = globalRampBatchSize;
                e.ramp_delay_ms = globalRampDelayMs;
            }
        }
        
        return entries;
    }

private:
    static void skipWhitespace(const std::string& s, size_t& pos) {
        while (pos < s.size() && std::isspace(static_cast<unsigned char>(s[pos]))) {
            pos++;
        }
        // Skip line comments (// style)
        if (pos + 1 < s.size() && s[pos] == '/' && s[pos + 1] == '/') {
            while (pos < s.size() && s[pos] != '\n') pos++;
            skipWhitespace(s, pos); // recurse to skip more whitespace after comment
        }
    }
    
    static void expectChar(const std::string& s, size_t& pos, char expected, const std::string& source) {
        if (pos >= s.size() || s[pos] != expected) {
            std::string found = (pos < s.size()) ? std::string(1, s[pos]) : "EOF";
            throw std::runtime_error("Workload file " + source + ": expected '" + expected + 
                "' at position " + std::to_string(pos) + ", got '" + found + "'");
        }
        pos++;
    }
    
    static std::string parseString(const std::string& s, size_t& pos, const std::string& source) {
        expectChar(s, pos, '"', source);
        std::string result;
        while (pos < s.size() && s[pos] != '"') {
            if (s[pos] == '\\') {
                pos++;
                if (pos >= s.size()) throw std::runtime_error("Workload file " + source + ": unterminated string escape");
                switch (s[pos]) {
                    case '"':  result += '"'; break;
                    case '\\': result += '\\'; break;
                    case '/':  result += '/'; break;
                    case 'n':  result += '\n'; break;
                    case 'r':  result += '\r'; break;
                    case 't':  result += '\t'; break;
                    default:   result += s[pos]; break;
                }
            } else {
                result += s[pos];
            }
            pos++;
        }
        if (pos >= s.size()) throw std::runtime_error("Workload file " + source + ": unterminated string");
        pos++; // skip closing quote
        return result;
    }
    
    static int parseInt(const std::string& s, size_t& pos, const std::string& source) {
        size_t start = pos;
        // Allow negative numbers
        if (pos < s.size() && s[pos] == '-') pos++;
        while (pos < s.size() && std::isdigit(static_cast<unsigned char>(s[pos]))) {
            pos++;
        }
        if (pos == start) {
            throw std::runtime_error("Workload file " + source + ": expected integer at position " + std::to_string(pos));
        }
        return std::stoi(s.substr(start, pos - start));
    }
    
    static std::vector<std::string> parseStringArray(const std::string& s, size_t& pos, const std::string& source) {
        expectChar(s, pos, '[', source);
        skipWhitespace(s, pos);
        
        std::vector<std::string> result;
        if (pos < s.size() && s[pos] == ']') {
            pos++;
            return result;
        }
        
        while (true) {
            skipWhitespace(s, pos);
            result.push_back(parseString(s, pos, source));
            skipWhitespace(s, pos);
            if (pos < s.size() && s[pos] == ',') {
                pos++;
            } else {
                break;
            }
        }
        
        skipWhitespace(s, pos);
        expectChar(s, pos, ']', source);
        return result;
    }
    
    static WorkloadEntry parseWorkloadObject(const std::string& s, size_t& pos, const std::string& source) {
        expectChar(s, pos, '{', source);
        skipWhitespace(s, pos);
        
        WorkloadEntry entry;
        
        while (pos < s.size() && s[pos] != '}') {
            std::string key = parseString(s, pos, source);
            skipWhitespace(s, pos);
            expectChar(s, pos, ':', source);
            skipWhitespace(s, pos);
            
            if (key == "file") {
                entry.file = parseString(s, pos, source);
            } else if (key == "queries") {
                entry.queries = parseStringArray(s, pos, source);
            } else if (key == "threads") {
                entry.threads = parseInt(s, pos, source);
            } else if (key == "iterations") {
                entry.iterations = parseInt(s, pos, source);
            } else if (key == "think_time_ms") {
                entry.think_time_ms = parseInt(s, pos, source);
            } else {
                // Skip unknown values (string, number, array, or object)
                skipValue(s, pos, source);
            }
            
            skipWhitespace(s, pos);
            if (pos < s.size() && s[pos] == ',') {
                pos++;
                skipWhitespace(s, pos);
            }
        }
        
        expectChar(s, pos, '}', source);
        return entry;
    }
    
    static std::vector<WorkloadEntry> parseWorkloadsArray(const std::string& s, size_t& pos, const std::string& source) {
        expectChar(s, pos, '[', source);
        skipWhitespace(s, pos);
        
        std::vector<WorkloadEntry> result;
        if (pos < s.size() && s[pos] == ']') {
            pos++;
            return result;
        }
        
        while (true) {
            skipWhitespace(s, pos);
            result.push_back(parseWorkloadObject(s, pos, source));
            skipWhitespace(s, pos);
            if (pos < s.size() && s[pos] == ',') {
                pos++;
            } else {
                break;
            }
        }
        
        skipWhitespace(s, pos);
        expectChar(s, pos, ']', source);
        return result;
    }
    
    static void skipValue(const std::string& s, size_t& pos, const std::string& source) {
        if (pos >= s.size()) throw std::runtime_error("Workload file " + source + ": unexpected EOF");
        
        if (s[pos] == '"') {
            parseString(s, pos, source); // skip string
        } else if (s[pos] == '[') {
            // Skip array
            pos++;
            skipWhitespace(s, pos);
            while (pos < s.size() && s[pos] != ']') {
                skipValue(s, pos, source);
                skipWhitespace(s, pos);
                if (pos < s.size() && s[pos] == ',') { pos++; skipWhitespace(s, pos); }
            }
            if (pos < s.size()) pos++; // skip ]
        } else if (s[pos] == '{') {
            // Skip object
            pos++;
            skipWhitespace(s, pos);
            while (pos < s.size() && s[pos] != '}') {
                parseString(s, pos, source); // key
                skipWhitespace(s, pos);
                expectChar(s, pos, ':', source);
                skipWhitespace(s, pos);
                skipValue(s, pos, source);
                skipWhitespace(s, pos);
                if (pos < s.size() && s[pos] == ',') { pos++; skipWhitespace(s, pos); }
            }
            if (pos < s.size()) pos++; // skip }
        } else {
            // Skip number, true, false, null
            while (pos < s.size() && s[pos] != ',' && s[pos] != '}' && s[pos] != ']' && 
                   !std::isspace(static_cast<unsigned char>(s[pos]))) {
                pos++;
            }
        }
    }
};
