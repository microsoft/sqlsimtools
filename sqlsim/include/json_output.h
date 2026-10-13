#pragma once

#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <chrono>

/**
 * Structured error entry for JSON output
 * Each error has a type, timestamp, and message
 */
struct ErrorEntry {
    std::string type;       // "tool_error" or "sql_error"
    std::string timestamp;  // ISO 8601 format
    std::string message;    // Error message
    std::string query;      // Query text that caused the error (optional, empty for non-query errors)
    
    ErrorEntry() = default;
    ErrorEntry(const std::string& t, const std::string& ts, const std::string& msg)
        : type(t), timestamp(ts), message(msg) {}
    ErrorEntry(const std::string& t, const std::string& ts, const std::string& msg, const std::string& q)
        : type(t), timestamp(ts), message(msg), query(q) {}
};

/**
 * Simple JSON output helper for sqlsim
 * Provides basic JSON formatting without external dependencies
 */
class JsonOutput {
public:
    /**
     * Escape a string for JSON output
     */
    static std::string escapeJson(const std::string& str) {
        std::ostringstream oss;
        for (char c : str) {
            switch (c) {
                case '"':  oss << "\\\""; break;
                case '\\': oss << "\\\\"; break;
                case '\b': oss << "\\b"; break;
                case '\f': oss << "\\f"; break;
                case '\n': oss << "\\n"; break;
                case '\r': oss << "\\r"; break;
                case '\t': oss << "\\t"; break;
                default:
                    if (c < 32) {
                        oss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                    } else {
                        oss << c;
                    }
            }
        }
        return oss.str();
    }
    
    /**
     * Get current timestamp in ISO 8601 format with milliseconds
     */
    static std::string getIsoTimestamp() {
        auto now = std::chrono::system_clock::now();
        auto time_t_now = std::chrono::system_clock::to_time_t(now);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;
        
        std::tm tm_now;
        #ifdef _WIN32
        localtime_s(&tm_now, &time_t_now);
        #else
        localtime_r(&time_t_now, &tm_now);
        #endif
        
        std::ostringstream oss;
        oss << std::put_time(&tm_now, "%Y-%m-%dT%H:%M:%S");
        oss << '.' << std::setfill('0') << std::setw(3) << ms.count();
        return oss.str();
    }
    
    /**
     * Build JSON string for key-value pair
     */
    static std::string jsonPair(const std::string& key, const std::string& value, bool isLast = false) {
        std::ostringstream oss;
        oss << "  \"" << key << "\": \"" << escapeJson(value) << "\"";
        if (!isLast) oss << ",";
        oss << "\n";
        return oss.str();
    }
    
    static std::string jsonPair(const std::string& key, int value, bool isLast = false) {
        std::ostringstream oss;
        oss << "  \"" << key << "\": " << value;
        if (!isLast) oss << ",";
        oss << "\n";
        return oss.str();
    }
    
    static std::string jsonPair(const std::string& key, double value, bool isLast = false) {
        std::ostringstream oss;
        oss << "  \"" << key << "\": " << std::fixed << std::setprecision(3) << value;
        if (!isLast) oss << ",";
        oss << "\n";
        return oss.str();
    }
    
    static std::string jsonPair(const std::string& key, bool value, bool isLast = false) {
        std::ostringstream oss;
        oss << "  \"" << key << "\": " << (value ? "true" : "false");
        if (!isLast) oss << ",";
        oss << "\n";
        return oss.str();
    }
    
    /**
     * Build JSON string array (for batches list)
     */
    static std::string jsonStringArray(const std::string& key, const std::vector<std::string>& values, const std::string& indent = "    ") {
        std::ostringstream oss;
        oss << indent << "\"" << key << "\": [";
        if (values.empty()) {
            oss << "]";
        } else {
            oss << "\n";
            for (size_t i = 0; i < values.size(); ++i) {
                oss << indent << "  \"" << escapeJson(values[i]) << "\"";
                if (i < values.size() - 1) oss << ",";
                oss << "\n";
            }
            oss << indent << "]";
        }
        return oss.str();
    }
};
