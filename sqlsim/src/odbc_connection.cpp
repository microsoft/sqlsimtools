#include "odbc_connection.h"
#include "xel_replay.h"
#include <iostream>
#include <cstring>
#include <vector>
#include <thread>
#include <sstream>
#include <codecvt>
#include <locale>

// Helper function to convert UTF-16 (Windows wchar_t) to UTF-8
// This is needed for proper Unicode support in ODBC data retrieval
static std::string wcharToUtf8(const SQLWCHAR* wstr, SQLLEN length = -1) {
    if (!wstr) return "";
    
    // Calculate length if not provided
    size_t wlen = 0;
    if (length < 0) {
        while (wstr[wlen]) wlen++;
    } else {
        wlen = static_cast<size_t>(length);
    }
    
    if (wlen == 0) return "";
    
#ifdef _WIN32
    // Use Windows API for reliable conversion
    int utf8Len = WideCharToMultiByte(CP_UTF8, 0, reinterpret_cast<const wchar_t*>(wstr), 
                                       static_cast<int>(wlen), nullptr, 0, nullptr, nullptr);
    if (utf8Len <= 0) return "";
    
    std::string utf8(utf8Len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, reinterpret_cast<const wchar_t*>(wstr), 
                        static_cast<int>(wlen), &utf8[0], utf8Len, nullptr, nullptr);
    return utf8;
#else
    // POSIX fallback using codecvt (deprecated in C++17 but widely supported)
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    return converter.to_bytes(reinterpret_cast<const char16_t*>(wstr), 
                              reinterpret_cast<const char16_t*>(wstr + wlen));
#endif
}

// Helper function to convert UTF-8 to UTF-16 (SQLWCHAR) for ODBC W-APIs.
// Returns a string of SQLWCHAR, which is 16-bit on every platform. This must
// NOT use wchar_t: wchar_t is 16-bit on Windows but 32-bit on Linux, whereas
// SQLWCHAR is always 16-bit, so a wchar_t buffer would be the wrong width for
// SQLExecDirectW/SQLPrepareW on Linux and corrupt the query text.
static std::basic_string<SQLWCHAR> utf8ToSqlwchar(const std::string& utf8) {
    if (utf8.empty()) return {};

#ifdef _WIN32
    // Use Windows API for reliable conversion (wchar_t is 16-bit == SQLWCHAR)
    int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), 
                                   static_cast<int>(utf8.length()), nullptr, 0);
    if (wlen <= 0) return {};
    
    std::basic_string<SQLWCHAR> wstr(static_cast<size_t>(wlen), 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), 
                        static_cast<int>(utf8.length()),
                        reinterpret_cast<wchar_t*>(&wstr[0]), wlen);
    return wstr;
#else
    // POSIX: convert UTF-8 -> UTF-16 via char16_t (16-bit == SQLWCHAR),
    // mirroring the read path in wcharToUtf8. codecvt is deprecated in C++17
    // but remains widely available.
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    std::u16string u16 = converter.from_bytes(utf8);
    return std::basic_string<SQLWCHAR>(reinterpret_cast<const SQLWCHAR*>(u16.data()), u16.size());
#endif
}

// Uncomment to enable detailed debug logging for ODBC operations
// Or build with: .\build.ps1 -DebugODBC
// #define DEBUG_ODBC

#ifdef DEBUG_ODBC
#define DEBUG_LOG(msg) do { \
    std::ostringstream oss; \
    oss << "[DEBUG ODBC Thread " << std::this_thread::get_id() << "] " << msg << std::endl; \
    std::cout << oss.str(); \
} while(0)
#else
#define DEBUG_LOG(msg) do {} while(0)
#endif

// Secure memory zeroing utility (C-1 fix)
// Prevents compiler optimization from removing memory clearing operations
void secureZeroMemory(void* ptr, size_t size) {
#ifdef _WIN32
    SecureZeroMemory(ptr, size);
#else
    // POSIX alternative - use volatile to prevent optimization
    volatile unsigned char* p = static_cast<volatile unsigned char*>(ptr);
    while (size--) {
        *p++ = 0;
    }
#endif
}

// Removes the leading driver and driver-manager tags, such as
// "[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]". Server text can contain
// brackets of its own, such as Azure SQL's "Table '[sys].[sysschobjs]'" or a PRINT
// of "[INFO] ...", so stop at the first tag that is not a driver tag.
static std::string stripDriverPrefix(const std::string& message) {
    size_t pos = 0;
    while (pos < message.size() && message[pos] == '[') {
        size_t close = message.find(']', pos + 1);
        if (close == std::string::npos) break;
        std::string tag = message.substr(pos + 1, close - pos - 1);
        bool driverTag = tag == "Microsoft" || tag == "unixODBC" || tag == "Driver Manager" ||
                         tag == "SQL Server" || tag.rfind("ODBC ", 0) == 0;
        if (!driverTag) break;
        pos = close + 1;
    }
    return (pos > 0 && pos < message.size()) ? message.substr(pos) : message;
}

// SECURITY FIX (H-3): Sanitize error messages to prevent control character injection
// Removes terminal control sequences and limits message length
// Updated to support UTF-8 multi-byte sequences
std::string sanitizeErrorMessage(const std::string& message) {
    std::string sanitized;
    sanitized.reserve(message.length());
    
    for (size_t i = 0; i < message.length(); ++i) {
        unsigned char c = static_cast<unsigned char>(message[i]);
        
        // Allow printable ASCII
        if (c >= 32 && c < 127) {
            sanitized += c;
        } 
        // Allow common whitespace (convert to space)
        else if (c == '\n' || c == '\r' || c == '\t') {
            sanitized += ' ';
        }
        // Allow UTF-8 multi-byte sequences (0x80-0xFF are continuation/start bytes)
        // UTF-8 encoding: 0xC0-0xDF = 2-byte, 0xE0-0xEF = 3-byte, 0xF0-0xF7 = 4-byte
        else if (c >= 0x80) {
            // This is part of a UTF-8 multi-byte sequence, include it
            sanitized += c;
        }
        // Skip ASCII control characters (0x00-0x1F except whitespace, and 0x7F)
        // These include escape sequences that could be used for terminal injection
    }
    
    // Limit length to prevent excessively long error messages
    const size_t MAX_ERROR_LENGTH = 1000;
    if (sanitized.length() > MAX_ERROR_LENGTH) {
        sanitized.resize(MAX_ERROR_LENGTH - 3);
        sanitized += "...";
    }
    
    return sanitized;
}

// SQL_COPT_SS_ACCESS_TOKEN definition (in case it's not in the ODBC headers)
#ifndef SQL_COPT_SS_ACCESS_TOKEN
#define SQL_COPT_SS_ACCESS_TOKEN 1256
#endif

// Structure for access token
struct ACCESSTOKEN {
    DWORD dataSize;
    BYTE data[1];  // Variable length
};

ODBCConnection::ODBCConnection() 
    : henv_(SQL_NULL_HENV), hdbc_(SQL_NULL_HDBC), hstmt_(SQL_NULL_HSTMT), 
      connected_(false), lastExecutionTime_(0), lastFetchTime_(0) {
}

ODBCConnection::~ODBCConnection() {
    cleanup();
}

ODBCConnection::ODBCConnection(ODBCConnection&& other) noexcept
    : henv_(other.henv_), hdbc_(other.hdbc_), hstmt_(other.hstmt_),
      connected_(other.connected_), lastError_(std::move(other.lastError_)),
            infoMessages_(std::move(other.infoMessages_)), warnings_(std::move(other.warnings_)),
            lastExecutionTime_(other.lastExecutionTime_), lastFetchTime_(other.lastFetchTime_),
            preparedStatementCache_(std::move(other.preparedStatementCache_)),
            currentDatabase_(std::move(other.currentDatabase_)) {
    other.henv_ = SQL_NULL_HENV;
    other.hdbc_ = SQL_NULL_HDBC;
    other.hstmt_ = SQL_NULL_HSTMT;
    other.connected_ = false;
        other.preparedStatementCache_.clear();
}

ODBCConnection& ODBCConnection::operator=(ODBCConnection&& other) noexcept {
    if (this != &other) {
        cleanup();
        henv_ = other.henv_;
        hdbc_ = other.hdbc_;
        hstmt_ = other.hstmt_;
        connected_ = other.connected_;
        lastError_ = std::move(other.lastError_);
        infoMessages_ = std::move(other.infoMessages_);
        warnings_ = std::move(other.warnings_);
        lastExecutionTime_ = other.lastExecutionTime_;
        lastFetchTime_ = other.lastFetchTime_;
        preparedStatementCache_ = std::move(other.preparedStatementCache_);
        currentDatabase_ = std::move(other.currentDatabase_);
        
        other.henv_ = SQL_NULL_HENV;
        other.hdbc_ = SQL_NULL_HDBC;
        other.hstmt_ = SQL_NULL_HSTMT;
        other.connected_ = false;
        other.preparedStatementCache_.clear();
    }
    return *this;
}

bool ODBCConnection::connectWithAccessToken(const std::string& connectionString, const std::string& accessToken, int loginTimeout) {
    auto start = std::chrono::steady_clock::now();
    
    // Allocate environment handle
    SQLRETURN ret = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &henv_);
    if (!SQL_SUCCEEDED(ret)) {
        lastError_ = "Failed to allocate environment handle";
        return false;
    }

    // Set ODBC version
    ret = SQLSetEnvAttr(henv_, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3, 0);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_ENV, henv_);
        cleanup();
        return false;
    }

    // Allocate connection handle
    ret = SQLAllocHandle(SQL_HANDLE_DBC, henv_, &hdbc_);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_ENV, henv_);
        cleanup();
        return false;
    }
    
    // Set login timeout if specified (0 = use driver default)
    if (loginTimeout > 0) {
        ret = SQLSetConnectAttr(hdbc_, SQL_ATTR_LOGIN_TIMEOUT, (SQLPOINTER)(SQLULEN)loginTimeout, 0);
        if (!SQL_SUCCEEDED(ret)) {
            captureError(SQL_HANDLE_DBC, hdbc_);
            cleanup();
            return false;
        }
    }

    // Prepare access token: expand each byte with a zero padding byte
    // SECURITY FIX (H-1): Platform-independent token size validation with proper overflow checking
    const size_t MAX_TOKEN_LENGTH = 10000; // Azure tokens typically < 10KB
    size_t tokenLength = accessToken.length();
    
    // Validate token length before any arithmetic operations
    if (tokenLength == 0) {
        lastError_ = "Access token is empty";
        cleanup();
        return false;
    }
    if (tokenLength > MAX_TOKEN_LENGTH) {
        lastError_ = "Access token exceeds maximum allowed size";
        cleanup();
        return false;
    }
    
    // Check for safe multiplication (prevent integer overflow)
    if (tokenLength > SIZE_MAX / 2) {
        lastError_ = "Access token too large for safe processing";
        cleanup();
        return false;
    }
    
    DWORD dataSize = 2 * static_cast<DWORD>(tokenLength);
    std::vector<BYTE> tokenData;
    try {
        tokenData.resize(sizeof(DWORD) + dataSize);
    } catch (const std::bad_alloc&) {
        lastError_ = "Failed to allocate memory for access token";
        cleanup();
        return false;
    }
    ACCESSTOKEN* pAccToken = reinterpret_cast<ACCESSTOKEN*>(tokenData.data());
    pAccToken->dataSize = dataSize;
    
    // Expand access token with padding bytes
    for (size_t i = 0, j = 0; i < dataSize; i += 2, j++) {
        pAccToken->data[i] = static_cast<BYTE>(accessToken[j]);
        pAccToken->data[i + 1] = 0;
    }

    // Set the access token attribute before connecting
    DEBUG_LOG("SQLSetConnectAttr: Setting access token");
    ret = SQLSetConnectAttr(hdbc_, SQL_COPT_SS_ACCESS_TOKEN, (SQLPOINTER)pAccToken, SQL_IS_POINTER);
    DEBUG_LOG("SQLSetConnectAttr result=" << ret);
    
    if (!SQL_SUCCEEDED(ret)) {
        // SECURITY: Zero token memory before returning on error
        secureZeroMemory(tokenData.data(), tokenData.size());
        captureError(SQL_HANDLE_DBC, hdbc_);
        cleanup();
        return false;
    }

    // Connect to database (without UID, PWD, Authentication, or Trusted_Connection in connection string)
    DEBUG_LOG("connectWithAccessToken: SQLDriverConnect with access token");
    ret = SQLDriverConnect(hdbc_, NULL,
                          reinterpret_cast<SQLCHAR*>(const_cast<char*>(connectionString.c_str())), SQL_NTS,
                          NULL, 0, NULL, SQL_DRIVER_NOPROMPT);
    DEBUG_LOG("connectWithAccessToken: SQLDriverConnect result=" << ret);
    
    // SECURITY FIX (C-1): Zero token memory after connection attempt completes
    // The ODBC driver holds a pointer to the token, so we must wait until
    // SQLDriverConnect() finishes before wiping the memory
    secureZeroMemory(tokenData.data(), tokenData.size());
    
    auto end = std::chrono::steady_clock::now();
    lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_DBC, hdbc_);
        
        // Check if error is due to missing driver
        if (lastError_.find("IM002") != std::string::npos) {
            lastError_ += "\n\nODBC Driver 18 for SQL Server is not installed.";
            lastError_ += "\nPlease install it from: https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server";
        }
        
        cleanup();
        return false;
    }

    // Allocate statement handle
    ret = SQLAllocHandle(SQL_HANDLE_STMT, hdbc_, &hstmt_);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_DBC, hdbc_);
        cleanup();
        return false;
    }

    connected_ = true;
    return true;
}

bool ODBCConnection::connect(const std::string& connectionString, int loginTimeout) {
    auto start = std::chrono::steady_clock::now();
    
    DEBUG_LOG("Connect: Starting connection");

    // Allocate environment handle
    SQLRETURN ret = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &henv_);
    DEBUG_LOG("SQLAllocHandle(ENV) result=" << ret);
    if (!SQL_SUCCEEDED(ret)) {
        lastError_ = "Failed to allocate environment handle";
        return false;
    }

    // Set ODBC version
    ret = SQLSetEnvAttr(henv_, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3, 0);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_ENV, henv_);
        cleanup();
        return false;
    }

    // Allocate connection handle
    ret = SQLAllocHandle(SQL_HANDLE_DBC, henv_, &hdbc_);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_ENV, henv_);
        cleanup();
        return false;
    }
    
    // Set login timeout if specified (0 = use driver default)
    if (loginTimeout > 0) {
        ret = SQLSetConnectAttr(hdbc_, SQL_ATTR_LOGIN_TIMEOUT, (SQLPOINTER)(SQLULEN)loginTimeout, 0);
        if (!SQL_SUCCEEDED(ret)) {
            captureError(SQL_HANDLE_DBC, hdbc_);
            cleanup();
            return false;
        }
    }

    // Connect to database
    DEBUG_LOG("SQLDriverConnect: Connecting to database");
    ret = SQLDriverConnect(hdbc_, NULL,
                          reinterpret_cast<SQLCHAR*>(const_cast<char*>(connectionString.c_str())), SQL_NTS,
                          NULL, 0, NULL, SQL_DRIVER_NOPROMPT);
    DEBUG_LOG("SQLDriverConnect result=" << ret);

    auto end = std::chrono::steady_clock::now();
    lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_DBC, hdbc_);
        
        // Check if error is due to missing driver
        if (lastError_.find("Data source name not found") != std::string::npos ||
            lastError_.find("IM002") != std::string::npos) {
            lastError_ += "\n\nMicrosoft ODBC Driver for SQL Server is not installed.\n"
                         "Please install ODBC Driver 17 or 18:\n"
                         "  Windows: https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server\n"
                         "  Linux: Install msodbcsql17 or msodbcsql18 package";
        }
        
        cleanup();
        return false;
    }

    // Allocate statement handle
    ret = SQLAllocHandle(SQL_HANDLE_STMT, hdbc_, &hstmt_);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_DBC, hdbc_);
        cleanup();
        return false;
    }

    connected_ = true;
    return true;
}

void ODBCConnection::disconnect() {
    cleanup();
}

int64_t ODBCConnection::getServerProcessId() {
    if (!execute("SELECT CONVERT(bigint, @@SPID)")) {
        return 0;
    }

    if (getColumnCount() < 1 || !fetch()) {
        lastError_ = "Unable to read the SQL Server session ID for this connection";
        return 0;
    }

    try {
        const int64_t spid = std::stoll(getColumnValue(1));
        while (nextResultSet()) {
        }
        return spid;
    } catch (const std::exception&) {
        lastError_ = "SQL Server returned an invalid session ID for this connection";
        return 0;
    }
}

bool ODBCConnection::execute(const std::string& query) {
    try {
        if (!connected_) {
            lastError_ = "Not connected";
            return false;
        }

        // Clear any previous messages and errors
        lastError_.clear();
        infoMessages_.clear();
        warnings_.clear();
        
        // Drain any remaining results from previous execution
        SQLRETURN drainRet;
        do {
            drainRet = SQLMoreResults(hstmt_);
        } while (drainRet == SQL_SUCCESS || drainRet == SQL_SUCCESS_WITH_INFO);
        
        // Close any existing cursor
        SQLCloseCursor(hstmt_);

        // Convert UTF-8 query to UTF-16 for proper Unicode support
        std::basic_string<SQLWCHAR> wquery = utf8ToSqlwchar(query);
        
        DEBUG_LOG("SQLExecDirectW: " << query.substr(0, 80) << (query.length() > 80 ? "..." : ""));
        auto execStart = std::chrono::steady_clock::now();
        SQLRETURN ret = SQLExecDirectW(hstmt_, (SQLWCHAR*)wquery.c_str(), SQL_NTS);
        DEBUG_LOG("SQLExecDirectW result=" << ret);
        
        auto execEnd = std::chrono::steady_clock::now();
        lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(execEnd - execStart);
        
        // Capture informational messages (PRINT statements) - do this before error check
        if (ret == SQL_SUCCESS_WITH_INFO || ret == SQL_SUCCESS) {
            captureInfoMessages(hstmt_);
        }
        
        // SQL_NO_DATA (100) is a success code for UPDATE/DELETE with 0 rows affected
        if (!SQL_SUCCEEDED(ret) && ret != SQL_NO_DATA) {
            captureError(SQL_HANDLE_STMT, hstmt_);
            return false;
        }
        
        return true;
    } catch (const std::exception& e) {
        lastError_ = std::string("Exception in execute: ") + e.what();
        return false;
    } catch (...) {
        lastError_ = "Unknown exception in execute";
        return false;
    }
}

// Phase 2 Optimization: Get or create cached prepared statement
SQLHSTMT ODBCConnection::getOrPrepareCachedStatement(const std::string& query) {
    // Check if we already have this statement prepared
    auto it = preparedStatementCache_.find(query);
    if (it != preparedStatementCache_.end()) {
        DEBUG_LOG("getOrPrepareCachedStatement: Cache HIT for query: " << query.substr(0, 50));
        return it->second;  // Return cached statement
    }

    constexpr size_t MAX_PREPARED_STATEMENTS = 1024;
    if (preparedStatementCache_.size() >= MAX_PREPARED_STATEMENTS) {
        DEBUG_LOG("getOrPrepareCachedStatement: Cache limit reached; clearing cached handles");
        clearPreparedStatementCache();
    }
    
    // Cache miss - allocate and prepare new statement
    DEBUG_LOG("getOrPrepareCachedStatement: Cache MISS - preparing query: " << query.substr(0, 50));
    SQLHSTMT stmt = SQL_NULL_HSTMT;
    SQLRETURN ret = SQLAllocHandle(SQL_HANDLE_STMT, hdbc_, &stmt);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_DBC, hdbc_);
        return SQL_NULL_HSTMT;
    }
    
    // Convert UTF-8 query to UTF-16 for proper Unicode support
    std::basic_string<SQLWCHAR> wquery = utf8ToSqlwchar(query);
    ret = SQLPrepareW(stmt, (SQLWCHAR*)wquery.c_str(), SQL_NTS);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_STMT, stmt);
        SQLFreeHandle(SQL_HANDLE_STMT, stmt);
        return SQL_NULL_HSTMT;
    }
    
    // Cache the prepared statement
    preparedStatementCache_[query] = stmt;
    DEBUG_LOG("getOrPrepareCachedStatement: Cached statement. Cache size now: " << preparedStatementCache_.size());
    return stmt;
}

bool ODBCConnection::executePrepared(const std::string& query) {
    try {
        if (!connected_) {
            lastError_ = "Not connected";
            return false;
        }

        // Clear any previous messages and errors
        lastError_.clear();
        infoMessages_.clear();
        warnings_.clear();
        
        // Phase 2 Optimization: Get or prepare cached statement (only prepares once per query)
        SQLHSTMT stmt = getOrPrepareCachedStatement(query);
        if (stmt == SQL_NULL_HSTMT) {
            // Error already captured in getOrPrepareCachedStatement
            return false;
        }

        // Drain any remaining results from previous execution
        // This is critical for stored procedures with OUTPUT parameters
        // which may leave the statement in a pending state
        SQLRETURN drainRet;
        do {
            drainRet = SQLMoreResults(stmt);
        } while (drainRet == SQL_SUCCESS || drainRet == SQL_SUCCESS_WITH_INFO);

        // Close any existing cursor and reset parameters
        // Note: SQLCloseCursor returns SQL_ERROR if no cursor is open, which is expected on first execution
        SQLRETURN closeCursorRet = SQLCloseCursor(stmt);
        if (!SQL_SUCCEEDED(closeCursorRet) && closeCursorRet != SQL_ERROR) {
            // Only fail if it's not the expected "no cursor" error
            captureError(SQL_HANDLE_STMT, stmt);
            return false;
        }
        
        SQLRETURN freeStmtRet = SQLFreeStmt(stmt, SQL_RESET_PARAMS);
        if (!SQL_SUCCEEDED(freeStmtRet)) {
            captureError(SQL_HANDLE_STMT, stmt);
            return false;
        }

        auto start = std::chrono::steady_clock::now();
        
        // Execute the prepared statement
        DEBUG_LOG("executePrepared: Executing cached statement");
        SQLRETURN ret = SQLExecute(stmt);
        
        auto end = std::chrono::steady_clock::now();
        lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
        
        // Capture informational messages (PRINT statements) - do this before error check
        if (ret == SQL_SUCCESS_WITH_INFO || ret == SQL_SUCCESS) {
            captureInfoMessages(stmt);
        }
        
        if (!SQL_SUCCEEDED(ret) && ret != SQL_NO_DATA) {
            captureError(SQL_HANDLE_STMT, stmt);
            return false;
        }
        
        // Update hstmt_ so fetch operations use the correct statement
        hstmt_ = stmt;
        
        return true;
    } catch (const std::exception& e) {
        lastError_ = std::string("Exception in executePrepared: ") + e.what();
        return false;
    } catch (...) {
        lastError_ = "Unknown exception in executePrepared";
        return false;
    }
}

void ODBCConnection::clearPreparedStatementCache() {
    DEBUG_LOG("clearPreparedStatementCache: Clearing " << preparedStatementCache_.size() << " cached statements");
    for (auto& pair : preparedStatementCache_) {
        if (pair.second == hstmt_) {
            hstmt_ = SQL_NULL_HSTMT;
        }
        SQLFreeHandle(SQL_HANDLE_STMT, pair.second);
    }
    preparedStatementCache_.clear();
}

bool ODBCConnection::fetch() {
    if (!connected_) {
        lastError_ = "Not connected";
        return false;
    }

    auto start = std::chrono::steady_clock::now();
    
    DEBUG_LOG("SQLFetch: Fetching row");
    SQLRETURN ret = SQLFetch(hstmt_);
    DEBUG_LOG("SQLFetch result=" << ret);
    
    auto end = std::chrono::steady_clock::now();
    lastFetchTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    
    if (ret == SQL_NO_DATA) {
        return false;
    }
    
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_STMT, hstmt_);
        return false;
    }
    
    return true;
}

bool ODBCConnection::nextResultSet() {
    if (!connected_) {
        lastError_ = "Not connected";
        return false;
    }

    SQLRETURN ret = SQLMoreResults(hstmt_);
    
    // Capture any PRINT statements that came with this result set
    if (ret == SQL_SUCCESS_WITH_INFO || ret == SQL_SUCCESS) {
        captureInfoMessages(hstmt_);
    }
    
    if (ret == SQL_NO_DATA) {
        return false; // No more result sets
    }
    
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_STMT, hstmt_);
        return false;
    }
    
    return true;
}

SQLLEN ODBCConnection::getRowCount() {
    if (!connected_) {
        return -1;
    }
    
    SQLLEN rowCount = 0;
    SQLRETURN ret = SQLRowCount(hstmt_, &rowCount);
    
    if (!SQL_SUCCEEDED(ret)) {
        // SQLRowCount failed - this is an actual error
        captureError(SQL_HANDLE_STMT, hstmt_);
        return -1;
    }
    
    // rowCount is valid: >= 0 for UPDATE/INSERT/DELETE, -1 for SELECT/no rows
    return rowCount;
}

SQLSMALLINT ODBCConnection::getColumnCount() {
    if (!connected_ || hstmt_ == SQL_NULL_HSTMT) {
        return 0;
    }
    
    SQLSMALLINT columnCount = 0;
    SQLRETURN ret = SQLNumResultCols(hstmt_, &columnCount);
    
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_STMT, hstmt_);
        return 0;
    }
    
    return columnCount;
}

std::string ODBCConnection::getColumnName(SQLUSMALLINT columnNumber) {
    if (!connected_ || hstmt_ == SQL_NULL_HSTMT) {
        return "";
    }
    
    // Use wide character buffer for proper Unicode support
    SQLWCHAR columnName[256];
    SQLSMALLINT nameLength = 0;
    SQLSMALLINT dataType = 0;
    SQLULEN columnSize = 0;
    SQLSMALLINT decimalDigits = 0;
    SQLSMALLINT nullable = 0;
    
    SQLRETURN ret = SQLDescribeColW(hstmt_, columnNumber, columnName, 
                                    sizeof(columnName) / sizeof(SQLWCHAR),
                                    &nameLength, &dataType, &columnSize, &decimalDigits, &nullable);
    
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_STMT, hstmt_);
        return "";
    }
    
    // Convert UTF-16 to UTF-8
    return wcharToUtf8(columnName, nameLength);
}

std::string ODBCConnection::getColumnValue(SQLUSMALLINT columnNumber) {
    if (!connected_ || hstmt_ == SQL_NULL_HSTMT) {
        return "";
    }
    
    SQLLEN indicator = 0;
    // Use wide character buffer for proper Unicode support
    // 4096 wide chars = 8192 bytes
    SQLWCHAR buffer[4096];
    std::wstring fullData;
    
    // For very large columns, we'll limit to a reasonable maximum to prevent memory issues
    const size_t MAX_COLUMN_SIZE = 1024 * 1024; // 1MB limit (in wide characters)
    
    // SQLGetData retrieves data in chunks if the column is larger than the buffer
    // Each call returns the next portion of data
    while (true) {
        SQLRETURN ret = SQLGetData(hstmt_, columnNumber, SQL_C_WCHAR, buffer, 
                                   sizeof(buffer), &indicator);
        
        if (indicator == SQL_NULL_DATA) {
            return "NULL";
        }
        
        if (ret == SQL_NO_DATA) {
            // No more data to retrieve
            break;
        }
        
        if (!SQL_SUCCEEDED(ret)) {
            captureError(SQL_HANDLE_STMT, hstmt_);
            if (fullData.empty()) {
                return "";
            }
            break;  // Return what we have so far
        }
        
        // Calculate how many characters were returned
        // indicator is in bytes, so divide by sizeof(SQLWCHAR)
        size_t charsReturned;
        if (indicator == SQL_NO_TOTAL) {
            // Driver doesn't know total length, use buffer size minus null terminator
            charsReturned = (sizeof(buffer) / sizeof(SQLWCHAR)) - 1;
        } else if (ret == SQL_SUCCESS_WITH_INFO) {
            // Data was truncated - buffer is full (minus null terminator)
            charsReturned = (sizeof(buffer) / sizeof(SQLWCHAR)) - 1;
        } else {
            // All remaining data fit in buffer
            charsReturned = static_cast<size_t>(indicator) / sizeof(SQLWCHAR);
        }
        
        // Append to full data
        fullData.append(reinterpret_cast<wchar_t*>(buffer), charsReturned);
        
        // Check size limit
        if (fullData.size() > MAX_COLUMN_SIZE) {
            std::string result = wcharToUtf8(reinterpret_cast<const SQLWCHAR*>(fullData.c_str()), 
                                             static_cast<SQLLEN>(fullData.size()));
            result += "... [DATA TRUNCATED - Column size exceeds 1MB limit]";
            return result;
        }
        
        // If SQL_SUCCESS (not SQL_SUCCESS_WITH_INFO), we got all the data
        if (ret == SQL_SUCCESS) {
            break;
        }
    }
    
    // Convert UTF-16 to UTF-8
    return wcharToUtf8(reinterpret_cast<const SQLWCHAR*>(fullData.c_str()), 
                       static_cast<SQLLEN>(fullData.size()));
}

void ODBCConnection::cleanup() {
    DEBUG_LOG("cleanup: Starting cleanup");
    
    // Phase 2 Optimization: Check if hstmt_ is in the prepared statement cache
    // If so, it will be freed by clearPreparedStatementCache() and we shouldn't free it again
    bool hstmtInCache = false;
    if (hstmt_ != SQL_NULL_HSTMT) {
        for (const auto& pair : preparedStatementCache_) {
            if (pair.second == hstmt_) {
                hstmtInCache = true;
                break;
            }
        }
    }
    
    // Clear prepared statement cache
    clearPreparedStatementCache();
    
    // Only free hstmt_ if it wasn't in the prepared statement cache
    if (hstmt_ != SQL_NULL_HSTMT && !hstmtInCache) {
        DEBUG_LOG("cleanup: Freeing statement handle (not in cache)");
        SQLFreeHandle(SQL_HANDLE_STMT, hstmt_);
        hstmt_ = SQL_NULL_HSTMT;
    } else if (hstmt_ != SQL_NULL_HSTMT) {
        DEBUG_LOG("cleanup: Skipping statement handle free (already freed in cache clear)");
        hstmt_ = SQL_NULL_HSTMT;
    }
    
    if (hdbc_ != SQL_NULL_HDBC) {
        if (connected_) {
            DEBUG_LOG("cleanup: Disconnecting");
            SQLDisconnect(hdbc_);
        }
        DEBUG_LOG("cleanup: Freeing connection handle");
        SQLFreeHandle(SQL_HANDLE_DBC, hdbc_);
        hdbc_ = SQL_NULL_HDBC;
    }
    
    if (henv_ != SQL_NULL_HENV) {
        DEBUG_LOG("cleanup: Freeing environment handle");
        SQLFreeHandle(SQL_HANDLE_ENV, henv_);
        henv_ = SQL_NULL_HENV;
    }
    
    connected_ = false;
}

bool ODBCConnection::setQueryTimeout(int seconds) {
    if (!connected_) {
        lastError_ = "Not connected";
        return false;
    }
    
    // Set query timeout on statement handle (0 = no timeout/driver default)
    SQLRETURN ret = SQLSetStmtAttr(hstmt_, SQL_ATTR_QUERY_TIMEOUT, (SQLPOINTER)(SQLULEN)seconds, 0);
    if (!SQL_SUCCEEDED(ret)) {
        captureError(SQL_HANDLE_STMT, hstmt_);
        return false;
    }
    
    return true;
}

std::string ODBCConnection::getDriverVersion() {
    if (!connected_) {
        return "unknown";
    }
    
    SQLCHAR driverVersion[256];
    SQLSMALLINT versionLength;
    
    SQLRETURN ret = SQLGetInfo(hdbc_, SQL_DRIVER_VER, driverVersion, sizeof(driverVersion), &versionLength);
    if (SQL_SUCCEEDED(ret)) {
        return std::string(reinterpret_cast<char*>(driverVersion), versionLength);
    }
    
    return "unknown";
}

void ODBCConnection::captureError(SQLSMALLINT handleType, SQLHANDLE handle) {
    SQLWCHAR sqlState[6];
    SQLWCHAR message[SQL_MAX_MESSAGE_LENGTH];
    SQLINTEGER nativeError;
    SQLSMALLINT textLength;
    SQLSMALLINT recNumber = 1;
    std::string combinedError;

    // Loop through all diagnostic records to capture complete error chain
    while (true) {
        SQLRETURN diagRet = SQLGetDiagRecW(handleType, handle, recNumber, sqlState, &nativeError,
                                           message, sizeof(message) / sizeof(SQLWCHAR), &textLength);
        
        if (diagRet == SQL_NO_DATA) {
            break;  // No more diagnostic records
        }
        
        if (diagRet == SQL_SUCCESS || diagRet == SQL_SUCCESS_WITH_INFO) {
            // SECURITY FIX (H-3): Sanitize error messages to prevent control character injection
            // Note: SQL_SUCCESS_WITH_INFO means message was truncated but we still have valid data
            std::string stateStr = wcharToUtf8(sqlState);
            std::string msgStr = wcharToUtf8(message, textLength);
            std::string rawError = stateStr + ": " + msgStr;
            if (!combinedError.empty()) {
                combinedError += "\n";  // Each error on its own line for readability
            }
            combinedError += sanitizeErrorMessage(rawError);
        } else if (diagRet == SQL_ERROR) {
            if (combinedError.empty()) {
                combinedError = "Error retrieving diagnostic information (SQL_ERROR)";
            }
            break;
        } else if (diagRet == SQL_INVALID_HANDLE) {
            if (combinedError.empty()) {
                combinedError = "Invalid handle passed to SQLGetDiagRecW";
            }
            break;
        } else {
            if (combinedError.empty()) {
                combinedError = "Unknown ODBC error (SQLGetDiagRecW returned " + std::to_string(diagRet) + ")";
            }
            break;
        }
        
        recNumber++;
    }
    
    if (combinedError.empty()) {
        lastError_ = "No diagnostic information available";
    } else {
        lastError_ = combinedError;
    }
}

void ODBCConnection::captureInfoMessages(SQLHSTMT stmt) {
    // Capture informational messages from SQL_SUCCESS_WITH_INFO
    // 01000 = PRINT statements, RAISERROR sev<=10, routine server messages → infoMessages_
    // Other 01xxx (01001, 01003, 01004, etc.) = real ODBC warnings → both infoMessages_ and warnings_
    //
    // Routine server messages are FILTERED OUT (not added to infoMessages_):
    //   Native error 5701 = "Changed database context to '...'"
    //   Native error 5703 = "Changed language setting to ..."
    // These are routine connection housekeeping and not useful to display.
    SQLWCHAR sqlState[6];
    SQLWCHAR message[SQL_MAX_MESSAGE_LENGTH];
    SQLINTEGER nativeError;
    SQLSMALLINT textLength;
    SQLSMALLINT recNumber = 1;
    
    while (true) {
        SQLRETURN diagRet = SQLGetDiagRecW(SQL_HANDLE_STMT, stmt, recNumber, sqlState, &nativeError,
                                           message, sizeof(message) / sizeof(SQLWCHAR), &textLength);
        
        if (diagRet == SQL_NO_DATA) {
            break;  // No more diagnostic records
        }
        
        if (diagRet == SQL_SUCCESS || diagRet == SQL_SUCCESS_WITH_INFO) {
            // Phase 1 Optimization: Compare SQLWCHAR state directly to avoid wcharToUtf8 call
            // SQLSTATE is always 5 ASCII chars + null terminator
            bool is01state = (sqlState[0] == L'0' && sqlState[1] == L'1');
            
            // Only process 01xxx states (informational/warning)
            if (is01state) {
                // Phase 1 Optimization: Check for 01000 using direct wchar comparison
                bool is01000 = (sqlState[2] == L'0' && sqlState[3] == L'0' && sqlState[4] == L'0');
                
                // Filter out routine server housekeeping messages (01000 only)
                // 5701 = "Changed database context to '...'" (USE database, connection default)
                // 5703 = "Changed language setting to ..." (SET LANGUAGE, connection default)
                if (is01000 && (nativeError == 5701 || nativeError == 5703)) {
                    recNumber++;
                    continue;  // Skip routine messages - not useful to display
                }
                
                std::string msg = stripDriverPrefix(wcharToUtf8(message, textLength));
                
                std::string sanitized = sanitizeErrorMessage(msg);
                if (is01000) {
                    infoMessages_.push_back(std::move(sanitized));
                } else {
                    infoMessages_.push_back(sanitized);
                    // Real ODBC warnings have specific states (not the 01000 catch-all)
                    std::string state = wcharToUtf8(sqlState);
                    warnings_.push_back(state + ": " + sanitized);
                }
            }
        } else {
            break;  // Error retrieving diagnostics, stop
        }
        
        recNumber++;
    }
}

void ODBCConnection::captureCurrentInfoMessages() {
    // Public method to capture info messages from current statement
    // Call this after nextResultSet() to get PRINT messages
    if (hstmt_ != SQL_NULL_HSTMT) {
        captureInfoMessages(hstmt_);
    }
}

bool ODBCConnection::enableConnectionPooling() {
    // Enable ODBC connection pooling at the environment level
    SQLRETURN ret = SQLSetEnvAttr(SQL_NULL_HENV, SQL_ATTR_CONNECTION_POOLING, 
                                 (SQLPOINTER)SQL_CP_ONE_PER_DRIVER, 0);
    if (!SQL_SUCCEEDED(ret)) {
        return false;
    }
    
    // Set pooling match criteria (relaxed matching for better pooling)
    ret = SQLSetEnvAttr(SQL_NULL_HENV, SQL_ATTR_CP_MATCH, 
                       (SQLPOINTER)SQL_CP_RELAXED_MATCH, 0);
    return SQL_SUCCEEDED(ret);
}

// ============================================================================
// Replay Mode: Event Execution with Parameter Binding
// ============================================================================

bool ODBCConnection::drainAndReset(SQLHSTMT stmt) {
    // Drain any remaining results from previous execution
    SQLRETURN drainRet;
    do {
        drainRet = SQLMoreResults(stmt);
    } while (drainRet == SQL_SUCCESS || drainRet == SQL_SUCCESS_WITH_INFO);
    
    // Close any existing cursor
    SQLCloseCursor(stmt);
    
    // Reset parameters
    SQLFreeStmt(stmt, SQL_RESET_PARAMS);
    
    return true;
}

bool ODBCConnection::bindReplayParameters(SQLHSTMT stmt, 
                                           const std::vector<ReplayParam>& params,
                                           std::vector<std::vector<char>>& buffers,
                                           std::vector<SQLLEN>& indicators) {
    buffers.resize(params.size());
    indicators.resize(params.size());
    
    for (size_t i = 0; i < params.size(); ++i) {
        SQLUSMALLINT paramNum = static_cast<SQLUSMALLINT>(i + 1);
        const auto& param = params[i];
        SQLRETURN ret;
        
        if (param.isNull || param.type == ReplayParamType::Null) {
            // NULL parameter
            indicators[i] = SQL_NULL_DATA;
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_WCHAR, SQL_WVARCHAR, 1, 0,
                                   nullptr, 0, &indicators[i]);
        }
        else if (param.type == ReplayParamType::BigInt) {
            int64_t val = 0;
            try { val = std::stoll(param.value); } catch (...) {}
            buffers[i].resize(sizeof(int64_t));
            memcpy(buffers[i].data(), &val, sizeof(int64_t));
            indicators[i] = 0;
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_SBIGINT, SQL_BIGINT, 0, 0,
                                   buffers[i].data(), sizeof(int64_t), &indicators[i]);
        }
        else if (param.type == ReplayParamType::Double) {
            double val = 0.0;
            try { val = std::stod(param.value); } catch (...) {}
            buffers[i].resize(sizeof(double));
            memcpy(buffers[i].data(), &val, sizeof(double));
            indicators[i] = 0;
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_DOUBLE, SQL_DOUBLE, 0, 0,
                                   buffers[i].data(), sizeof(double), &indicators[i]);
        }
        else if (param.type == ReplayParamType::WVarChar) {
            // SQL_C_WCHAR requires 16-bit SQLWCHAR on every platform. Do not
            // use wchar_t here because it is 32-bit on Linux and macOS.
            const std::basic_string<SQLWCHAR> wval = utf8ToSqlwchar(param.value);
            size_t byteLen = (wval.size() + 1) * sizeof(SQLWCHAR);
            buffers[i].resize(byteLen);
            memcpy(buffers[i].data(), wval.c_str(), byteLen);
            indicators[i] = static_cast<SQLLEN>(wval.size() * sizeof(SQLWCHAR));
            
            SQLULEN columnSize = wval.empty() ? 1 : static_cast<SQLULEN>(wval.size());
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_WCHAR, SQL_WVARCHAR, columnSize, 0,
                                   buffers[i].data(), static_cast<SQLLEN>(byteLen), &indicators[i]);
        }
        else if (param.type == ReplayParamType::VarChar) {
            size_t len = param.value.size() + 1;
            buffers[i].resize(len);
            memcpy(buffers[i].data(), param.value.c_str(), len);
            indicators[i] = static_cast<SQLLEN>(param.value.size());
            
            SQLULEN columnSize = param.value.empty() ? 1 : static_cast<SQLULEN>(param.value.size());
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_CHAR, SQL_VARCHAR, columnSize, 0,
                                   buffers[i].data(), static_cast<SQLLEN>(len), &indicators[i]);
        }
        else if (param.type == ReplayParamType::Datetime) {
            // Parse datetime string into SQL_TIMESTAMP_STRUCT
            // Expected formats: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DD HH:MM:SS.fff..."
            SQL_TIMESTAMP_STRUCT ts = {};
            const std::string& dtVal = param.value;
            // Parse date portion: YYYY-MM-DD
            if (dtVal.size() >= 10) {
                try { ts.year = static_cast<SQLSMALLINT>(std::stoi(dtVal.substr(0, 4))); } catch (...) {}
                try { ts.month = static_cast<SQLUSMALLINT>(std::stoi(dtVal.substr(5, 2))); } catch (...) {}
                try { ts.day = static_cast<SQLUSMALLINT>(std::stoi(dtVal.substr(8, 2))); } catch (...) {}
            }
            // Parse time portion: HH:MM:SS
            if (dtVal.size() >= 19) {
                try { ts.hour = static_cast<SQLUSMALLINT>(std::stoi(dtVal.substr(11, 2))); } catch (...) {}
                try { ts.minute = static_cast<SQLUSMALLINT>(std::stoi(dtVal.substr(14, 2))); } catch (...) {}
                try { ts.second = static_cast<SQLUSMALLINT>(std::stoi(dtVal.substr(17, 2))); } catch (...) {}
            }
            // Parse fractional seconds - truncate to 7 digits (datetime2(7) precision)
            // then convert to nanoseconds for SQL_TIMESTAMP_STRUCT.fraction
            if (dtVal.size() > 20 && dtVal[19] == '.') {
                std::string frac = dtVal.substr(20);
                // Truncate to 7 digits (datetime2(7) max precision)
                if (frac.size() > 7) frac.resize(7);
                // Pad to 7 digits if shorter
                while (frac.size() < 7) frac += '0';
                // Convert 7-digit fractional seconds to nanoseconds (* 100)
                try { ts.fraction = static_cast<SQLUINTEGER>(std::stoul(frac)) * 100; } catch (...) {}
            }
            buffers[i].resize(sizeof(SQL_TIMESTAMP_STRUCT));
            memcpy(buffers[i].data(), &ts, sizeof(SQL_TIMESTAMP_STRUCT));
            indicators[i] = sizeof(SQL_TIMESTAMP_STRUCT);
            // Use precision 7 (datetime2(7)) for maximum compatibility
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP, 27, 7,
                                   buffers[i].data(), sizeof(SQL_TIMESTAMP_STRUCT), &indicators[i]);
        }
        else if (param.type == ReplayParamType::Binary) {
            // Convert hex string to binary
            const std::string& hex = param.value;
            size_t binLen = hex.size() / 2;
            buffers[i].resize(binLen > 0 ? binLen : 1);
            for (size_t j = 0; j < binLen; ++j) {
                unsigned int byte = 0;
                std::string hexByte = hex.substr(j * 2, 2);
                try {
                    byte = static_cast<unsigned int>(std::stoul(hexByte, nullptr, 16));
                } catch (...) {}
                buffers[i][j] = static_cast<char>(byte);
            }
            indicators[i] = static_cast<SQLLEN>(binLen);
            
            SQLULEN columnSize = binLen > 0 ? static_cast<SQLULEN>(binLen) : 1;
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_BINARY, SQL_BINARY, columnSize, 0,
                                   buffers[i].data(), static_cast<SQLLEN>(binLen), &indicators[i]);
        }
        else {
            // Fallback: bind as WVARCHAR
            indicators[i] = SQL_NULL_DATA;
            ret = SQLBindParameter(stmt, paramNum, SQL_PARAM_INPUT,
                                   SQL_C_WCHAR, SQL_WVARCHAR, 1, 0,
                                   nullptr, 0, &indicators[i]);
        }
        
        if (!SQL_SUCCEEDED(ret)) {
            captureError(SQL_HANDLE_STMT, stmt);
            return false;
        }
    }
    return true;
}

bool ODBCConnection::executeReplayEvent(const ReplayEvent& event,
                                         std::unordered_map<int, SQLHSTMT>& handleMap) {
    try {
        if (!connected_) {
            lastError_ = "Not connected";
            return false;
        }
        
        infoMessages_.clear();
        warnings_.clear();
        
        // Switch database context if the event specifies a different database
        if (!event.databaseName.empty() && event.databaseName != currentDatabase_) {
            std::string escapedDatabaseName = event.databaseName;
            size_t closingBracket = 0;
            while ((closingBracket = escapedDatabaseName.find(']', closingBracket)) != std::string::npos) {
                escapedDatabaseName.insert(closingBracket, 1, ']');
                closingBracket += 2;
            }
            if (!execute("USE [" + escapedDatabaseName + "]")) {
                return false;
            }
            currentDatabase_ = event.databaseName;
        }
        
        switch (event.eventType) {
            case ReplayEventType::SqlBatchCompleted: {
                // SQLExecDirect for batch text
                return execute(event.statementText);
            }
            
            case ReplayEventType::RpcExecuteSql:
            case ReplayEventType::RpcPrepExec: {
                // sp_executesql / sp_prepexec: SQLPrepare + SQLBindParameter + SQLExecute
                const std::string& sql = event.parameterizedSql.empty() 
                    ? event.statementText : event.parameterizedSql;
                if (sql.empty()) {
                    lastError_ = "Empty SQL text for sp_executesql replay";
                    return false;
                }
                
                if (event.parameters.empty()) {
                    // No parameters extracted — fall back to SQLExecDirect
                    return execute(sql);
                }
                
                // Drain previous results and reset hstmt_ for reuse
                drainAndReset(hstmt_);
                
                // Convert SQL to wide string and prepare
                std::basic_string<SQLWCHAR> wsql = utf8ToSqlwchar(sql);
                
                SQLRETURN ret = SQLPrepareW(hstmt_, (SQLWCHAR*)wsql.c_str(), SQL_NTS);
                if (!SQL_SUCCEEDED(ret)) {
                    captureError(SQL_HANDLE_STMT, hstmt_);
                    return false;
                }
                
                // Bind parameters
                std::vector<std::vector<char>> buffers;
                std::vector<SQLLEN> indicators;
                if (!bindReplayParameters(hstmt_, event.parameters, buffers, indicators)) {
                    return false;
                }
                
                // Execute
                auto start = std::chrono::steady_clock::now();
                ret = SQLExecute(hstmt_);
                auto end = std::chrono::steady_clock::now();
                lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
                
                if (ret == SQL_SUCCESS_WITH_INFO || ret == SQL_SUCCESS) {
                    captureInfoMessages(hstmt_);
                }
                
                if (!SQL_SUCCEEDED(ret) && ret != SQL_NO_DATA) {
                    captureError(SQL_HANDLE_STMT, hstmt_);
                    return false;
                }
                
                return true;
            }
            
            case ReplayEventType::RpcPrepare: {
                // SQLAllocHandle + SQLPrepare, store in handle map
                const std::string& sql = event.parameterizedSql.empty()
                    ? event.statementText : event.parameterizedSql;
                if (sql.empty()) {
                    lastError_ = "Empty SQL text for sp_prepare replay";
                    return false;
                }
                
                SQLHSTMT stmt = SQL_NULL_HSTMT;
                SQLRETURN ret = SQLAllocHandle(SQL_HANDLE_STMT, hdbc_, &stmt);
                if (!SQL_SUCCEEDED(ret)) {
                    captureError(SQL_HANDLE_DBC, hdbc_);
                    return false;
                }
                
                std::basic_string<SQLWCHAR> wsql = utf8ToSqlwchar(sql);
                
                ret = SQLPrepareW(stmt, (SQLWCHAR*)wsql.c_str(), SQL_NTS);
                
                if (!SQL_SUCCEEDED(ret)) {
                    captureError(SQL_HANDLE_STMT, stmt);
                    SQLFreeHandle(SQL_HANDLE_STMT, stmt);
                    return false;
                }
                
                // Store in handle map
                handleMap[event.prepareHandle] = stmt;
                return true;
            }
            
            case ReplayEventType::RpcExecute: {
                // Look up handle map and execute
                auto it = handleMap.find(event.prepareHandle);
                if (it == handleMap.end()) {
                    // Handle not found - fall back to direct execution
                    if (!event.statementText.empty()) {
                        return execute(event.statementText);
                    }
                    lastError_ = "Prepare handle " + std::to_string(event.prepareHandle) + " not found";
                    return false;
                }
                
                SQLHSTMT stmt = it->second;
                drainAndReset(stmt);
                
                // Bind parameters if any
                std::vector<std::vector<char>> buffers;
                std::vector<SQLLEN> indicators;
                if (!event.parameters.empty()) {
                    if (!bindReplayParameters(stmt, event.parameters, buffers, indicators)) {
                        return false;
                    }
                }
                
                auto start = std::chrono::steady_clock::now();
                SQLRETURN ret = SQLExecute(stmt);
                auto end = std::chrono::steady_clock::now();
                lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
                
                if (ret == SQL_SUCCESS_WITH_INFO || ret == SQL_SUCCESS) {
                    captureInfoMessages(stmt);
                }
                
                if (!SQL_SUCCEEDED(ret) && ret != SQL_NO_DATA) {
                    captureError(SQL_HANDLE_STMT, stmt);
                    return false;
                }
                
                hstmt_ = stmt;
                return true;
            }
            
            case ReplayEventType::RpcUnprepare: {
                // Free the prepared statement and remove from map
                auto it = handleMap.find(event.prepareHandle);
                if (it != handleMap.end()) {
                    SQLFreeHandle(SQL_HANDLE_STMT, it->second);
                    handleMap.erase(it);
                }
                return true;
            }
            
            case ReplayEventType::RpcUserProc: {
                // User stored procedure: SQLPrepare("{CALL proc(?,?)}") + SQLBindParameter + SQLExecute
                const std::string& sql = event.parameterizedSql.empty()
                    ? event.statementText : event.parameterizedSql;
                if (sql.empty()) {
                    lastError_ = "Empty SQL text for user proc replay";
                    return false;
                }
                
                if (event.parameters.empty()) {
                    // No parameters extracted — fall back to SQLExecDirect
                    return execute(sql);
                }
                
                // Drain previous results and reset hstmt_ for reuse
                drainAndReset(hstmt_);
                
                // Convert SQL to wide string and prepare
                std::basic_string<SQLWCHAR> wsql = utf8ToSqlwchar(sql);
                
                SQLRETURN ret = SQLPrepareW(hstmt_, (SQLWCHAR*)wsql.c_str(), SQL_NTS);
                if (!SQL_SUCCEEDED(ret)) {
                    captureError(SQL_HANDLE_STMT, hstmt_);
                    return false;
                }
                
                // Bind parameters
                std::vector<std::vector<char>> buffers;
                std::vector<SQLLEN> indicators;
                if (!bindReplayParameters(hstmt_, event.parameters, buffers, indicators)) {
                    return false;
                }
                
                // Execute
                auto start = std::chrono::steady_clock::now();
                ret = SQLExecute(hstmt_);
                auto end = std::chrono::steady_clock::now();
                lastExecutionTime_ = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
                
                if (ret == SQL_SUCCESS_WITH_INFO || ret == SQL_SUCCESS) {
                    captureInfoMessages(hstmt_);
                }
                
                if (!SQL_SUCCEEDED(ret) && ret != SQL_NO_DATA) {
                    captureError(SQL_HANDLE_STMT, hstmt_);
                    return false;
                }
                
                return true;
            }
            
            case ReplayEventType::RpcResetConnection:
                // Metadata only - nothing to execute
                return true;
                
            case ReplayEventType::Skipped:
                // Nothing to do
                return true;
                
            default:
                lastError_ = "Unknown replay event type";
                return false;
        }
    } catch (const std::exception& e) {
        lastError_ = std::string("Exception in executeReplayEvent: ") + e.what();
        return false;
    } catch (...) {
        lastError_ = "Unknown exception in executeReplayEvent";
        return false;
    }
}

// ============================================================================
// Driver Verification
// ============================================================================

bool ODBCConnection::checkDriverAvailable(std::string& errorMessage) {
    SQLHENV henv = SQL_NULL_HENV;
    SQLRETURN ret;
    
    // Allocate environment handle
    ret = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &henv);
    if (!SQL_SUCCEEDED(ret)) {
        errorMessage = "Failed to initialize ODBC environment";
        return false;
    }
    
    ret = SQLSetEnvAttr(henv, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3, 0);
    if (!SQL_SUCCEEDED(ret)) {
        SQLFreeHandle(SQL_HANDLE_ENV, henv);
        errorMessage = "Failed to set ODBC version";
        return false;
    }
    
    // Check for SQL Server drivers
    SQLCHAR driverDesc[256];
    SQLCHAR driverAttrs[256];
    SQLSMALLINT descLen, attrsLen;
    bool foundSqlServerDriver = false;
    
    ret = SQLDrivers(henv, SQL_FETCH_FIRST, driverDesc, sizeof(driverDesc), &descLen,
                     driverAttrs, sizeof(driverAttrs), &attrsLen);
    
    while (SQL_SUCCEEDED(ret)) {
        std::string driver(reinterpret_cast<const char*>(driverDesc));
        if (driver.find("SQL Server") != std::string::npos) {
            foundSqlServerDriver = true;
            break;
        }
        ret = SQLDrivers(henv, SQL_FETCH_NEXT, driverDesc, sizeof(driverDesc), &descLen,
                        driverAttrs, sizeof(driverAttrs), &attrsLen);
    }
    
    SQLFreeHandle(SQL_HANDLE_ENV, henv);
    
    if (!foundSqlServerDriver) {
        errorMessage = "sqlsim error: Microsoft ODBC Driver for SQL Server is not installed.\n\n"
                      "Please install ODBC Driver 17 or 18 for SQL Server:\n\n"
                      "Windows:\n"
                      "  Download from: https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server\n"
                      "  Or use: winget install Microsoft.ODBCDriver.18\n\n"
                      "Linux (Ubuntu/Debian):\n"
                      "  sudo apt-get install msodbcsql18\n\n"
                      "Linux (RHEL/CentOS):\n"
                      "  sudo yum install msodbcsql18\n";
        return false;
    }
    
    return true;
}
