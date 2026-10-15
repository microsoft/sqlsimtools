#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <memory>
#include <cstdint>

/**
 * Replay event types parsed from XEvent trace XML
 */
enum class ReplayEventType {
    SqlBatchCompleted,       // sql_batch_completed - replay via SQLExecDirect
    RpcExecuteSql,           // rpc_completed with object_name=sp_executesql
    RpcPrepExec,             // rpc_completed with object_name=sp_prepexec
    RpcPrepare,              // rpc_completed with object_name=sp_prepare
    RpcExecute,              // rpc_completed with object_name=sp_execute
    RpcUnprepare,            // rpc_completed with object_name=sp_unprepare
    RpcUserProc,             // rpc_completed with user stored procedure
    RpcResetConnection,      // rpc_completed with sp_reset_connection (metadata only)
    Skipped                  // sp_cursor* or other unsupported events
};

/**
 * Parameter type for ODBC binding, inferred from SQL literal values
 */
enum class ReplayParamType {
    BigInt,      // Integer literal (42)       -> SQL_BIGINT
    Double,      // Decimal literal (3.14)     -> SQL_DOUBLE
    WVarChar,    // N'...' literal             -> SQL_WVARCHAR
    VarChar,     // '...' literal              -> SQL_VARCHAR
    Binary,      // 0x... literal              -> SQL_BINARY
    Datetime,    // 'YYYY-MM-DD ...' literal   -> SQL_TYPE_TIMESTAMP
    Null         // NULL keyword               -> SQL_WVARCHAR with null indicator
};

/**
 * A single parameter extracted from an RPC event
 */
struct ReplayParam {
    ReplayParamType type;
    std::string value;       // Raw value (unquoted for strings, hex digits for binary)
    bool isNull;
    
    ReplayParam() : type(ReplayParamType::Null), isNull(true) {}
    ReplayParam(ReplayParamType t, const std::string& v, bool n = false) 
        : type(t), value(v), isNull(n) {}
};

/**
 * A single event from the XEvent trace, ready for replay
 */
struct ReplayEvent {
    ReplayEventType eventType;
    
    // Core event data
    std::string statementText;      // SQL text (batch_text or statement)
    std::string objectName;         // RPC procedure name (sp_executesql, etc.)
    std::string databaseName;       // Database context for this event
    int64_t sessionId;              // Original session_id
    std::string timestamp;          // Original event timestamp (ISO 8601)
    
    // For sp_prepare/sp_execute lifecycle
    int prepareHandle;              // Handle number for prepare/execute correlation
    
    // Parameterized execution
    std::string parameterizedSql;   // SQL with ? markers (for sp_executesql, sp_prepexec, user procs)
    std::vector<ReplayParam> parameters;  // Bound parameter values
    
    // For user stored procedures  
    std::string procName;           // Fully qualified procedure name (e.g., dbo.MyProc)
    
    // Original event outcome from XEvent trace (0=OK, 1=Error, 2=Abort)
    int originalResult;
    double originalDurationMs;
    double originalCpuMs;
    int64_t originalLogicalReads;
    int64_t originalPhysicalReads;
    int64_t originalWrites;
    int64_t originalRowCount;

    ReplayEvent()
        : eventType(ReplayEventType::Skipped),
          sessionId(0),
          prepareHandle(0),
          originalResult(0),
          originalDurationMs(-1.0),
          originalCpuMs(-1.0),
          originalLogicalReads(-1),
          originalPhysicalReads(-1),
          originalWrites(-1),
          originalRowCount(-1) {}
};

/**
 * A sequence of events for a single session (fast mode)
 */
struct ReplaySession {
    int64_t sessionId;
    std::string databaseName;       // Initial database context
    std::vector<ReplayEvent> events; // Events in replay file order (event_sequence order from convert-xel.ps1)
    bool usesPooling;               // Whether sp_reset_connection was seen
    
    ReplaySession() : sessionId(0), usesPooling(false) {}
};

/**
 * Result of parsing a replay XML file
 */
struct ReplayData {
    std::vector<ReplaySession> sessions;    // Grouped by session (for fast mode)
    std::vector<ReplayEvent> allEvents;     // Flat ordered list (for stress mode)
    size_t totalEvents;                     // Total events parsed (including skipped)
    size_t replayableEvents;                // Events that will be replayed
    size_t skippedEvents;                   // Events that were skipped (sp_cursor*, etc.)
    
    ReplayData() : totalEvents(0), replayableEvents(0), skippedEvents(0) {}
};

/**
 * XML parser for SQL Server Extended Events trace data.
 * 
 * Parses the XML produced by convert-xel.ps1 (which wraps event_data from
 * sys.fn_xe_file_target_read_file()) into ReplayEvent structures.
 * 
 * Expected XML format:
 *   <replay>
 *     <event name="sql_batch_completed" timestamp="...">
 *       <data name="batch_text"><value>SELECT 1</value></data>
 *       <action name="session_id"><value>52</value></action>
 *       <action name="database_name"><value>master</value></action>
 *     </event>
 *     <event name="rpc_completed" timestamp="...">
 *       <data name="object_name"><value>sp_executesql</value></data>
 *       <data name="statement"><value>SELECT @P1, @P2</value></data>
 *       <action name="session_id"><value>52</value></action>
 *       <action name="database_name"><value>master</value></action>
 *     </event>
 *     ...
 *   </replay>
 */
class XelReplayParser {
public:
    /**
     * Parse a replay XML file into ReplayData
     * @param filePath Path to the XML file
     * @param errorMsg Output: error message if parsing fails
     * @return true if parsing succeeded
     */
    bool parseFile(const std::string& filePath, std::string& errorMsg);
    
    /**
     * Get the parsed replay data (call after parseFile)
     */
    const ReplayData& getReplayData() const { return data_; }
    ReplayData& getReplayData() { return data_; }
    
    /**
     * Build stress-mode flat event list from session data.
     * Flattens all sessions, orders by timestamp, drops sp_prepare/sp_unprepare,
     * and promotes sp_execute to one-shot.
     */
    void buildStressSequence();

private:
    // XML element parsing
    struct XmlAttribute {
        std::string name;
        std::string value;
    };
    
    struct XmlElement {
        std::string tag;
        std::vector<XmlAttribute> attributes;
        std::string textContent;
        std::vector<XmlElement> children;
    };
    
    // Low-level XML parsing (focused on XEvent format)
    bool parseXml(const std::string& xml, std::string& errorMsg);
    bool parseElement(const std::string& xml, size_t& pos, XmlElement& element,
                      std::string& errorMsg, size_t depth);
    bool skipWhitespace(const std::string& xml, size_t& pos);
    bool parseAttributes(const std::string& xml, size_t& pos, std::vector<XmlAttribute>& attrs, bool& selfClosing);
    std::string parseQuotedValue(const std::string& xml, size_t& pos);
    std::string parseTextContent(const std::string& xml, size_t& pos, const std::string& endTag);
    std::string decodeXmlEntities(const std::string& text);
    
    // Event processing
    ReplayEvent processEventElement(const XmlElement& element);
    ReplayEventType classifyRpcEvent(const std::string& objectName);
    
    // Parameter parsing
    void parseExecuteSqlParams(ReplayEvent& event);
    void parseProcParams(ReplayEvent& event);
    ReplayParamType inferParamType(const std::string& value);
    std::string stripQuotes(const std::string& value, bool isNvarchar);
    
    // SQL parameterization
    std::string replaceParamMarkers(const std::string& sql);
    std::vector<std::string> splitParamValues(const std::string& paramList);
    std::vector<std::string> splitTopLevelArgs(const std::string& text, size_t startPos);
    
    // Session grouping
    void groupEventsBySessions();
    
    ReplayData data_;
};

/**
 * Utility: Infer ODBC parameter type from a SQL literal value string
 * Used by the replay engine when binding parameters
 */
ReplayParamType inferOdbcParamType(const std::string& value);
