#pragma once

#include <string>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <iostream>

/**
 * Timestamp utility for adding timestamps to output
 */
class TimestampHelper {
public:
    /**
     * Get current timestamp formatted as "YYYY-MM-DD HH:MM:SS.mmm | "
     */
    static std::string getCurrentTimestamp() {
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
        oss << std::put_time(&tm_now, "%Y-%m-%d %H:%M:%S");
        oss << '.' << std::setfill('0') << std::setw(3) << ms.count() << " | ";
        return oss.str();
    }
    
    /**
     * Prefix every line in a string with a timestamp
     */
    static std::string prefixLines(const std::string& text) {
        if (text.empty()) return text;
        
        // One timestamp per call: the lines are written together, and
        // formatting a timestamp per line is costly under many threads.
        const std::string timestamp = getCurrentTimestamp();
        std::string result;
        result.reserve(text.size() + timestamp.size() * 16);
        size_t start = 0;
        while (start < text.size()) {
            size_t end = text.find('\n', start);
            if (end == std::string::npos) end = text.size();
            if (start > 0) result += '\n';
            result += timestamp;
            result.append(text, start, end - start);
            start = end + 1;
        }
        
        // If original text ended with newline, preserve it
        if (text.back() == '\n') {
            result += '\n';
        }
        
        return result;
    }
};

// Helper macro to print with timestamp
#define TS_OUT std::cout << TimestampHelper::getCurrentTimestamp()
#define TS_ERR std::cerr << TimestampHelper::getCurrentTimestamp()

// Helper function to print multi-line error messages with timestamps on each line
inline void printMultiLineError(const std::string& message) {
    std::istringstream stream(message);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty()) {
            TS_ERR << line << std::endl;
        }
    }
    std::cerr << std::flush;  // Ensure errors are flushed immediately
}
