#pragma once

#ifdef _WIN32
    #include <windows.h>
#endif

#include <sql.h>
#include <sqlext.h>
#include <string>
#include <memory>
#include <chrono>
#include <cstdint>
#include <unordered_map>
#include <vector>

// Forward declarations for replay types
enum class ReplayEventType;
enum class ReplayParamType;
struct ReplayParam;
struct ReplayEvent;

/**
 * RAII wrapper for ODBC connections with performance metrics
 */
class ODBCConnection {
public:
    ODBCConnection();
    ~ODBCConnection();

    // Disable copy, enable move
    ODBCConnection(const ODBCConnection&) = delete;
    ODBCConnection& operator=(const ODBCConnection&) = delete;
    ODBCConnection(ODBCConnection&&) noexcept;
    ODBCConnection& operator=(ODBCConnection&&) noexcept;

    // Connection management
    bool connect(const std::string& connectionString, int loginTimeout = 0);
    bool connectWithAccessToken(const std::string& connectionString, const std::string& accessToken, int loginTimeout = 0);
    void disconnect();
    bool isConnected() const { return connected_; }
    
    // Connection pooling management
    static bool enableConnectionPooling();
    
    // Timeout management
    bool setQueryTimeout(int seconds);
    
    // Driver verification
    static bool checkDriverAvailable(std::string& errorMessage);
    
    // Driver information (must be called after connect)
    std::string getDriverVersion();
    int64_t getServerProcessId();

    // Query execution
    bool execute(const std::string& query);
    bool executePrepared(const std::string& query);
    
    // Replay event execution (used by replay mode)
    bool executeReplayEvent(const ReplayEvent& event, 
                            std::unordered_map<int, SQLHSTMT>& handleMap);
    
    // Phase 2 Optimization: Clear prepared statement cache
    void clearPreparedStatementCache();
    
    // Fetch operations
    bool fetch();
    bool nextResultSet();  // Move to next result set (for multi-statement queries)
    SQLLEN getRowCount();
    
    // Result set metadata
    SQLSMALLINT getColumnCount();
    std::string getColumnName(SQLUSMALLINT columnNumber);
    std::string getColumnValue(SQLUSMALLINT columnNumber);

    // Performance metrics
    std::chrono::microseconds getLastExecutionTime() const { return lastExecutionTime_; }
    std::chrono::microseconds getLastFetchTime() const { return lastFetchTime_; }
    
    // Error handling
    // Phase 2 Optimization: Return by const reference to avoid string copy
    const std::string& getLastError() const { return lastError_; }
    
    // Check if last error was a timeout (SQLSTATE HYT00/HYT01 = query/connection timeout)
    bool isLastErrorTimeout() const {
        return lastError_.find("HYT00") != std::string::npos ||
               lastError_.find("HYT01") != std::string::npos;
    }
    
    // Informational messages (PRINT statements)
    const std::vector<std::string>& getInfoMessages() const { return infoMessages_; }
    void clearInfoMessages() { infoMessages_.clear(); }
    void captureCurrentInfoMessages();  // Capture messages from current statement (call after nextResultSet)
    
    // Real ODBC warnings (non-01000 states like 01004, 01001, 01003)
    const std::vector<std::string>& getWarnings() const { return warnings_; }
    int getWarningCount() const { return static_cast<int>(warnings_.size()); }
    void clearWarnings() { warnings_.clear(); }

private:
    void cleanup();
    void captureError(SQLSMALLINT handleType, SQLHANDLE handle);
    void captureInfoMessages(SQLHSTMT stmt);  // Capture PRINT statements
    SQLHSTMT getOrPrepareCachedStatement(const std::string& query);
    
    // Replay helpers
    bool drainAndReset(SQLHSTMT stmt);
    bool bindReplayParameters(SQLHSTMT stmt, const std::vector<ReplayParam>& params,
                              std::vector<std::vector<char>>& buffers,
                              std::vector<SQLLEN>& indicators);
    
    SQLHENV henv_;          // Environment handle
    SQLHDBC hdbc_;          // Connection handle
    SQLHSTMT hstmt_;        // Statement handle (for non-prepared queries)
    
    bool connected_;
    std::string lastError_;
    std::vector<std::string> infoMessages_;  // PRINT statements and other info messages
    std::vector<std::string> warnings_;       // Real ODBC warnings (non-01000 states: 01001, 01003, 01004, etc.)
    
    std::chrono::microseconds lastExecutionTime_;
    std::chrono::microseconds lastFetchTime_;
    
    // Phase 2 Optimization: Cache prepared statements to avoid re-preparing
    std::unordered_map<std::string, SQLHSTMT> preparedStatementCache_;
    
    // Replay: track current database for USE switching
    std::string currentDatabase_;
};
