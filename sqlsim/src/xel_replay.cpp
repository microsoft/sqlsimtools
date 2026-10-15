#include "xel_replay.h"
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <iostream>

// ============================================================================
// XML Entity Decoding
// ============================================================================

std::string XelReplayParser::decodeXmlEntities(const std::string& text) {
    std::string result;
    result.reserve(text.size());
    
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '&') {
            // Find the semicolon
            size_t semi = text.find(';', i);
            if (semi != std::string::npos && semi - i < 10) {
                std::string entity = text.substr(i + 1, semi - i - 1);
                if (entity == "amp") { result += '&'; }
                else if (entity == "lt") { result += '<'; }
                else if (entity == "gt") { result += '>'; }
                else if (entity == "quot") { result += '"'; }
                else if (entity == "apos") { result += '\''; }
                else if (entity.size() > 1 && entity[0] == '#') {
                    // Numeric character reference
                    try {
                        const unsigned long codepoint = (entity[1] == 'x' || entity[1] == 'X')
                            ? std::stoul(entity.substr(2), nullptr, 16)
                            : std::stoul(entity.substr(1));
                        if (codepoint < 0x80) {
                            result += static_cast<char>(codepoint);
                        } else if (codepoint < 0x800) {
                            result += static_cast<char>(0xC0 | (codepoint >> 6));
                            result += static_cast<char>(0x80 | (codepoint & 0x3F));
                        } else if (codepoint < 0x10000 && !(codepoint >= 0xD800 && codepoint <= 0xDFFF)) {
                            result += static_cast<char>(0xE0 | (codepoint >> 12));
                            result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
                            result += static_cast<char>(0x80 | (codepoint & 0x3F));
                        } else if (codepoint <= 0x10FFFF) {
                            result += static_cast<char>(0xF0 | (codepoint >> 18));
                            result += static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F));
                            result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F));
                            result += static_cast<char>(0x80 | (codepoint & 0x3F));
                        } else {
                            result += '&';
                            result += entity;
                            result += ';';
                        }
                    } catch (const std::exception&) {
                        result += '&';
                        result += entity;
                        result += ';';
                    }
                } else {
                    // Unknown entity, keep as-is
                    result += '&';
                    result += entity;
                    result += ';';
                }
                i = semi;
            } else {
                result += '&';
            }
        } else {
            result += text[i];
        }
    }
    return result;
}

// ============================================================================
// Low-level XML Parsing (focused on XEvent format)
// ============================================================================

bool XelReplayParser::skipWhitespace(const std::string& xml, size_t& pos) {
    while (pos < xml.size() && std::isspace(static_cast<unsigned char>(xml[pos]))) {
        ++pos;
    }
    return pos < xml.size();
}

std::string XelReplayParser::parseQuotedValue(const std::string& xml, size_t& pos) {
    if (pos >= xml.size() || xml[pos] != '"') return "";
    ++pos; // skip opening quote
    
    size_t start = pos;
    while (pos < xml.size() && xml[pos] != '"') {
        ++pos;
    }
    std::string value = xml.substr(start, pos - start);
    if (pos < xml.size()) ++pos; // skip closing quote
    return decodeXmlEntities(value);
}

bool XelReplayParser::parseAttributes(const std::string& xml, size_t& pos, 
                                       std::vector<XmlAttribute>& attrs, bool& selfClosing) {
    selfClosing = false;
    
    while (pos < xml.size()) {
        skipWhitespace(xml, pos);
        
        if (pos >= xml.size()) return false;
        
        // Check for self-closing or end of tag
        if (xml[pos] == '/') {
            selfClosing = true;
            ++pos;
            if (pos < xml.size() && xml[pos] == '>') {
                ++pos;
                return true;
            }
            return false;
        }
        if (xml[pos] == '>') {
            ++pos;
            return true;
        }
        
        // Parse attribute name
        size_t nameStart = pos;
        while (pos < xml.size() && xml[pos] != '=' && xml[pos] != '>' && 
               xml[pos] != '/' && !std::isspace(static_cast<unsigned char>(xml[pos]))) {
            ++pos;
        }
        std::string attrName = xml.substr(nameStart, pos - nameStart);
        
        skipWhitespace(xml, pos);
        if (pos >= xml.size() || xml[pos] != '=') continue;
        ++pos; // skip '='
        skipWhitespace(xml, pos);
        
        // Parse attribute value
        std::string attrValue = parseQuotedValue(xml, pos);
        
        XmlAttribute attr;
        attr.name = attrName;
        attr.value = attrValue;
        attrs.push_back(std::move(attr));
    }
    return false;
}

std::string XelReplayParser::parseTextContent(const std::string& xml, size_t& pos, 
                                               const std::string& endTag) {
    size_t start = pos;
    std::string closingTag = "</" + endTag + ">";
    size_t endPos = xml.find(closingTag, pos);
    if (endPos == std::string::npos) {
        pos = xml.size();
        return "";
    }
    std::string content = xml.substr(start, endPos - start);
    pos = endPos + closingTag.size();
    return decodeXmlEntities(content);
}

bool XelReplayParser::parseElement(const std::string& xml, size_t& pos,
                                    XmlElement& element, std::string& errorMsg,
                                    size_t depth) {
    constexpr size_t MAX_XML_DEPTH = 64;
    if (depth > MAX_XML_DEPTH) {
        errorMsg = "Replay XML exceeds maximum nesting depth of " + std::to_string(MAX_XML_DEPTH);
        return false;
    }

    skipWhitespace(xml, pos);
    
    if (pos >= xml.size() || xml[pos] != '<') {
        errorMsg = "Expected '<' at position " + std::to_string(pos);
        return false;
    }
    ++pos; // skip '<'
    
    // Skip XML declaration, comments, CDATA, processing instructions
    if (pos < xml.size() && xml[pos] == '?') {
        size_t endPI = xml.find("?>", pos);
        if (endPI == std::string::npos) {
            errorMsg = "Unterminated processing instruction";
            return false;
        }
        pos = endPI + 2;
        return parseElement(xml, pos, element, errorMsg, depth); // Try next element
    }
    
    if (pos < xml.size() && xml[pos] == '!') {
        // Comment or CDATA
        if (xml.substr(pos, 3) == "!--") {
            size_t endComment = xml.find("-->", pos);
            if (endComment == std::string::npos) {
                errorMsg = "Unterminated comment";
                return false;
            }
            pos = endComment + 3;
            return parseElement(xml, pos, element, errorMsg, depth); // Try next element
        }
        if (xml.substr(pos, 8) == "![CDATA[") {
            size_t endCData = xml.find("]]>", pos);
            if (endCData == std::string::npos) {
                errorMsg = "Unterminated CDATA section";
                return false;
            }
            element.textContent = xml.substr(pos + 8, endCData - pos - 8);
            pos = endCData + 3;
            return true;
        }
        // DOCTYPE or other - skip to closing >
        size_t endDecl = xml.find('>', pos);
        if (endDecl != std::string::npos) {
            pos = endDecl + 1;
            return parseElement(xml, pos, element, errorMsg, depth);
        }
        errorMsg = "Unterminated declaration";
        return false;
    }
    
    // Parse tag name
    size_t nameStart = pos;
    while (pos < xml.size() && xml[pos] != '>' && xml[pos] != '/' && 
           !std::isspace(static_cast<unsigned char>(xml[pos]))) {
        ++pos;
    }
    element.tag = xml.substr(nameStart, pos - nameStart);
    
    if (element.tag.empty()) {
        errorMsg = "Empty element tag at position " + std::to_string(nameStart);
        return false;
    }
    
    // Parse attributes
    bool selfClosing = false;
    if (!parseAttributes(xml, pos, element.attributes, selfClosing)) {
        errorMsg = "Failed to parse attributes for <" + element.tag + ">";
        return false;
    }
    
    if (selfClosing) {
        return true;
    }
    
    // Parse content: text or child elements
    while (pos < xml.size()) {
        skipWhitespace(xml, pos);
        if (pos >= xml.size()) break;
        
        // Check for closing tag
        if (pos + 1 < xml.size() && xml[pos] == '<' && xml[pos + 1] == '/') {
            // Closing tag
            size_t closeEnd = xml.find('>', pos);
            if (closeEnd == std::string::npos) {
                errorMsg = "Unterminated closing tag for <" + element.tag + ">";
                return false;
            }
            pos = closeEnd + 1;
            return true;
        }
        
        // Check for child element
        if (xml[pos] == '<') {
            XmlElement child;
            if (!parseElement(xml, pos, child, errorMsg, depth + 1)) {
                return false;
            }
            element.children.push_back(std::move(child));
        } else {
            // Text content - find the next '<'
            size_t textStart = pos;
            while (pos < xml.size() && xml[pos] != '<') {
                ++pos;
            }
            element.textContent = decodeXmlEntities(xml.substr(textStart, pos - textStart));
        }
    }
    
    return true;
}

bool XelReplayParser::parseXml(const std::string& xml, std::string& errorMsg) {
    size_t pos = 0;
    
    // Skip BOM if present
    if (xml.size() >= 3 && 
        static_cast<unsigned char>(xml[0]) == 0xEF &&
        static_cast<unsigned char>(xml[1]) == 0xBB &&
        static_cast<unsigned char>(xml[2]) == 0xBF) {
        pos = 3;
    }
    
    skipWhitespace(xml, pos);
    
    // Skip XML declaration if present
    if (pos + 1 < xml.size() && xml[pos] == '<' && xml[pos + 1] == '?') {
        size_t endPI = xml.find("?>", pos);
        if (endPI != std::string::npos) {
            pos = endPI + 2;
        }
    }
    
    skipWhitespace(xml, pos);
    
    // Parse root element
    XmlElement root;
    if (!parseElement(xml, pos, root, errorMsg, 0)) {
        return false;
    }
    
    if (root.tag != "replay") {
        errorMsg = "Expected root element <replay>, got <" + root.tag + ">";
        return false;
    }
    
    // Process each <event> child
    constexpr size_t MAX_REPLAY_EVENTS = 100000;
    for (const auto& child : root.children) {
        if (child.tag != "event") continue;

        if (data_.totalEvents >= MAX_REPLAY_EVENTS) {
            errorMsg = "Replay XML exceeds maximum event count of " + std::to_string(MAX_REPLAY_EVENTS);
            return false;
        }
        
        ReplayEvent event = processEventElement(child);
        data_.totalEvents++;
        
        if (event.eventType == ReplayEventType::Skipped) {
            data_.skippedEvents++;
        } else {
            data_.replayableEvents++;
        }
        
        data_.allEvents.push_back(std::move(event));
    }
    
    // Group events into sessions
    groupEventsBySessions();
    
    return true;
}

// ============================================================================
// Event Processing
// ============================================================================

ReplayEvent XelReplayParser::processEventElement(const XmlElement& element) {
    ReplayEvent event;
    
    // Get event name and timestamp from attributes
    std::string eventName;
    for (const auto& attr : element.attributes) {
        if (attr.name == "name") eventName = attr.value;
        else if (attr.name == "timestamp") event.timestamp = attr.value;
    }
    
    // Extract <data> and <action> values
    std::string dataObjectName;
    std::string dataStatement;
    std::string dataBatchText;
    
    for (const auto& child : element.children) {
        std::string nameAttr;
        for (const auto& attr : child.attributes) {
            if (attr.name == "name") nameAttr = attr.value;
        }
        
        // Get the <value> child text
        // XEvent event_data uses CDATA sections: <value><![CDATA[text]]></value>
        // Our parser stores CDATA content as a child pseudo-element with empty tag,
        // so we check children if the value element's textContent is empty.
        std::string valueText;
        for (const auto& grandchild : child.children) {
            if (grandchild.tag == "value") {
                valueText = grandchild.textContent;
                if (valueText.empty() && !grandchild.children.empty()) {
                    // CDATA child: the text is in the first child's textContent
                    valueText = grandchild.children[0].textContent;
                }
                break;
            }
        }
        
        if (child.tag == "data") {
            if (nameAttr == "object_name") dataObjectName = valueText;
            else if (nameAttr == "statement") dataStatement = valueText;
            else if (nameAttr == "batch_text") dataBatchText = valueText;
            else if (nameAttr == "result") {
                // Result field: 0=OK, 1=Error, 2=Abort
                try { event.originalResult = std::stoi(valueText); } catch (...) { event.originalResult = 0; }
            }
            else if (nameAttr == "duration") {
                // sql_batch_completed/rpc_completed duration is reported in microseconds.
                try { event.originalDurationMs = std::stod(valueText) / 1000.0; } catch (...) { event.originalDurationMs = -1.0; }
            }
            else if (nameAttr == "cpu_time") {
                // sql_batch_completed/rpc_completed CPU time is reported in milliseconds.
                try { event.originalCpuMs = std::stod(valueText); } catch (...) { event.originalCpuMs = -1.0; }
            }
            else if (nameAttr == "logical_reads") {
                try { event.originalLogicalReads = std::stoll(valueText); } catch (...) { event.originalLogicalReads = -1; }
            }
            else if (nameAttr == "physical_reads") {
                try { event.originalPhysicalReads = std::stoll(valueText); } catch (...) { event.originalPhysicalReads = -1; }
            }
            else if (nameAttr == "writes") {
                try { event.originalWrites = std::stoll(valueText); } catch (...) { event.originalWrites = -1; }
            }
            else if (nameAttr == "row_count") {
                try { event.originalRowCount = std::stoll(valueText); } catch (...) { event.originalRowCount = -1; }
            }
        } else if (child.tag == "action") {
            if (nameAttr == "session_id") {
                try { event.sessionId = std::stoll(valueText); } catch (...) { event.sessionId = 0; }
            }
            else if (nameAttr == "database_name") event.databaseName = valueText;
        }
    }
    
    // Classify the event
    if (eventName == "sql_batch_completed") {
        event.eventType = ReplayEventType::SqlBatchCompleted;
        event.statementText = dataBatchText;
        event.objectName = eventName;
    }
    else if (eventName == "rpc_completed") {
        event.objectName = dataObjectName;
        event.statementText = dataStatement;
        event.eventType = classifyRpcEvent(dataObjectName);
        
        // Process based on RPC type
        switch (event.eventType) {
            case ReplayEventType::RpcExecuteSql:
            case ReplayEventType::RpcPrepExec:
                parseExecuteSqlParams(event);
                break;
                
            case ReplayEventType::RpcPrepare:
                // For sp_prepare, the statement is the SQL to prepare
                // The prepare handle comes from the statement text as well
                parseExecuteSqlParams(event);
                break;
                
            case ReplayEventType::RpcExecute:
                // sp_execute has a handle reference and parameters
                // Extract handle from statement text
                if (!event.statementText.empty()) {
                    // Statement text for sp_execute typically starts with the handle
                    // The format is handle number followed by parameter values
                    parseExecuteSqlParams(event);
                }
                break;
                
            case ReplayEventType::RpcUnprepare:
                // sp_unprepare just has the handle
                if (!event.statementText.empty()) {
                    try { event.prepareHandle = std::stoi(event.statementText); } catch (...) {}
                }
                break;
                
            case ReplayEventType::RpcUserProc:
                parseProcParams(event);
                break;
                
            default:
                break;
        }
    }
    else {
        event.eventType = ReplayEventType::Skipped;
    }
    
    return event;
}

ReplayEventType XelReplayParser::classifyRpcEvent(const std::string& objectName) {
    // Case-insensitive comparison
    std::string lower = objectName;
    std::transform(lower.begin(), lower.end(), lower.begin(), 
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    
    if (lower == "sp_executesql") return ReplayEventType::RpcExecuteSql;
    if (lower == "sp_prepexec")  return ReplayEventType::RpcPrepExec;
    if (lower == "sp_prepare")   return ReplayEventType::RpcPrepare;
    if (lower == "sp_execute")   return ReplayEventType::RpcExecute;
    if (lower == "sp_unprepare") return ReplayEventType::RpcUnprepare;
    if (lower == "sp_reset_connection") return ReplayEventType::RpcResetConnection;
    
    // sp_cursor* family - skip these
    if (lower.find("sp_cursor") == 0) return ReplayEventType::Skipped;
    
    // Everything else is a user stored procedure
    return ReplayEventType::RpcUserProc;
}

// ============================================================================
// Parameter Parsing
// ============================================================================

ReplayParamType XelReplayParser::inferParamType(const std::string& value) {
    if (value.empty()) return ReplayParamType::Null;
    
    // NULL literal
    std::string upper = value;
    std::transform(upper.begin(), upper.end(), upper.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    if (upper == "NULL") return ReplayParamType::Null;
    
    // N'...' - Unicode string
    if (value.size() >= 3 && (value[0] == 'N' || value[0] == 'n') && value[1] == '\'') {
        return ReplayParamType::WVarChar;
    }
    
    // '...' - ANSI string, but check for datetime pattern first
    if (value.size() >= 2 && value[0] == '\'') {
        // Check for datetime pattern: 'YYYY-MM-DD' (minimum 12 chars: 'YYYY-MM-DD')
        if (value.size() >= 12 && std::isdigit(static_cast<unsigned char>(value[1]))
            && std::isdigit(static_cast<unsigned char>(value[2]))
            && std::isdigit(static_cast<unsigned char>(value[3]))
            && std::isdigit(static_cast<unsigned char>(value[4]))
            && value[5] == '-'
            && std::isdigit(static_cast<unsigned char>(value[6]))
            && std::isdigit(static_cast<unsigned char>(value[7]))
            && value[8] == '-'
            && std::isdigit(static_cast<unsigned char>(value[9]))
            && std::isdigit(static_cast<unsigned char>(value[10]))) {
            return ReplayParamType::Datetime;
        }
        return ReplayParamType::VarChar;
    }
    
    // 0x... - Binary
    if (value.size() >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X')) {
        return ReplayParamType::Binary;
    }
    
    // Check for decimal (contains a dot)
    if (value.find('.') != std::string::npos) {
        // Verify it looks like a number
        bool isNumeric = true;
        for (size_t i = (value[0] == '-' || value[0] == '+') ? 1 : 0; i < value.size(); ++i) {
            if (!std::isdigit(static_cast<unsigned char>(value[i])) && value[i] != '.') {
                isNumeric = false;
                break;
            }
        }
        if (isNumeric) return ReplayParamType::Double;
    }
    
    // Check for integer
    bool isInteger = true;
    for (size_t i = (value[0] == '-' || value[0] == '+') ? 1 : 0; i < value.size(); ++i) {
        if (!std::isdigit(static_cast<unsigned char>(value[i]))) {
            isInteger = false;
            break;
        }
    }
    if (isInteger && !value.empty()) return ReplayParamType::BigInt;
    
    // Default to WVARCHAR for unrecognized formats
    return ReplayParamType::WVarChar;
}

std::string XelReplayParser::stripQuotes(const std::string& value, bool isNvarchar) {
    if (isNvarchar) {
        // N'value' -> value
        if (value.size() >= 3 && (value[0] == 'N' || value[0] == 'n') && value[1] == '\'') {
            std::string inner = value.substr(2, value.size() - 3);
            // Unescape doubled single quotes
            std::string result;
            result.reserve(inner.size());
            for (size_t i = 0; i < inner.size(); ++i) {
                if (i + 1 < inner.size() && inner[i] == '\'' && inner[i + 1] == '\'') {
                    result += '\'';
                    ++i;
                } else {
                    result += inner[i];
                }
            }
            return result;
        }
    } else {
        // 'value' -> value
        if (value.size() >= 2 && value[0] == '\'') {
            std::string inner = value.substr(1, value.size() - 2);
            // Unescape doubled single quotes
            std::string result;
            result.reserve(inner.size());
            for (size_t i = 0; i < inner.size(); ++i) {
                if (i + 1 < inner.size() && inner[i] == '\'' && inner[i + 1] == '\'') {
                    result += '\'';
                    ++i;
                } else {
                    result += inner[i];
                }
            }
            return result;
        }
    }
    return value;
}

std::string XelReplayParser::replaceParamMarkers(const std::string& sql) {
    // Replace @P1, @P2, ... and @pN with ? markers
    std::string result;
    result.reserve(sql.size());
    
    for (size_t i = 0; i < sql.size(); ++i) {
        if (sql[i] == '@' && i + 1 < sql.size() && 
            (sql[i + 1] == 'P' || sql[i + 1] == 'p')) {
            // Check if this is @P<digits> or @p<digits>
            size_t j = i + 2;
            while (j < sql.size() && std::isdigit(static_cast<unsigned char>(sql[j]))) {
                ++j;
            }
            if (j > i + 2) {
                // Replace @P<n> with ?
                result += '?';
                i = j - 1;
                continue;
            }
        }
        result += sql[i];
    }
    return result;
}

std::vector<std::string> XelReplayParser::splitParamValues(const std::string& paramList) {
    return splitTopLevelArgs(paramList, 0);
}

std::vector<std::string> XelReplayParser::splitTopLevelArgs(const std::string& text, size_t startPos) {
    // Split comma-separated arguments starting at startPos, respecting quoted strings.
    // Handles N'...' and '...' with escaped quotes ('').
    std::vector<std::string> args;
    std::string current;
    bool inQuote = false;
    
    for (size_t i = startPos; i < text.size(); ++i) {
        char c = text[i];
        
        if (c == '\'' && !inQuote) {
            inQuote = true;
            current += c;
        } else if (c == '\'' && inQuote) {
            // Check for escaped quote ('')
            if (i + 1 < text.size() && text[i + 1] == '\'') {
                current += c;
                current += text[++i];
            } else {
                inQuote = false;
                current += c;
            }
        } else if (c == ',' && !inQuote) {
            // Trim and add
            size_t s = current.find_first_not_of(" \t\r\n");
            size_t e = current.find_last_not_of(" \t\r\n");
            if (s != std::string::npos) {
                args.push_back(current.substr(s, e - s + 1));
            }
            current.clear();
        } else {
            current += c;
        }
    }
    
    // Add last argument
    size_t s = current.find_first_not_of(" \t\r\n");
    size_t e = current.find_last_not_of(" \t\r\n");
    if (s != std::string::npos) {
        args.push_back(current.substr(s, e - s + 1));
    }
    
    return args;
}

void XelReplayParser::parseExecuteSqlParams(ReplayEvent& event) {
    // sp_executesql statement text from XEvent trace looks like:
    //   exec sp_executesql N'SELECT @p1 AS val',N'@p1 INT',42
    //   exec sp_executesql N'SELECT @p1 AS val, @p2 AS label',N'@p1 INT, @p2 NVARCHAR(50)',99,N'replay_test'
    //
    // Structure: exec sp_executesql <inner_sql>, <param_defs>, <val1>, <val2>, ...
    // All three components are top-level comma-separated, but commas inside N'...' must be skipped.
    //
    // We need to:
    // 1. Extract the inner SQL (first N'...' argument)
    // 2. Replace @p1, @p2, ... with ? markers
    // 3. Skip the param definitions (second N'...' argument)
    // 4. Extract the remaining values as parameters
    
    if (event.statementText.empty()) return;
    
    const std::string& text = event.statementText;
    
    // Find "sp_executesql " (case-insensitive) to locate where args begin
    std::string lower = text;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    
    size_t spPos = lower.find("sp_executesql ");
    if (spPos == std::string::npos) {
        // Can't parse — leave as SQLExecDirect fallback
        event.parameterizedSql = event.statementText;
        return;
    }
    
    size_t argsStart = spPos + 14; // length of "sp_executesql "
    
    // Split the arguments at top-level commas (not inside quotes)
    std::vector<std::string> args = splitTopLevelArgs(text, argsStart);
    
    if (args.empty()) {
        event.parameterizedSql = event.statementText;
        return;
    }
    
    // First arg: inner SQL (e.g., N'SELECT @p1 AS val')
    std::string innerSql = args[0];
    // Strip N'...' wrapping
    if (innerSql.size() >= 3 && (innerSql[0] == 'N' || innerSql[0] == 'n') && innerSql[1] == '\'') {
        innerSql = innerSql.substr(2, innerSql.size() - 3);
        // Unescape doubled single quotes
        std::string unescaped;
        unescaped.reserve(innerSql.size());
        for (size_t i = 0; i < innerSql.size(); ++i) {
            unescaped += innerSql[i];
            if (innerSql[i] == '\'' && i + 1 < innerSql.size() && innerSql[i + 1] == '\'') {
                ++i; // skip doubled quote
            }
        }
        innerSql = unescaped;
    }
    
    // Replace @p1, @p2, @P1, @P2, etc. with ? markers
    event.parameterizedSql = replaceParamMarkers(innerSql);
    
    // If we only have 1 arg (no params), we're done — just execute the inner SQL directly
    if (args.size() <= 1) {
        return;
    }
    
    // Second arg is param definitions (e.g., N'@p1 INT, @p2 NVARCHAR(50)') — skip it
    // Remaining args are the actual parameter values
    if (args.size() > 2) {
        for (size_t i = 2; i < args.size(); ++i) {
            std::string val = args[i];
            // Trim whitespace
            size_t start = val.find_first_not_of(" \t\r\n");
            size_t end = val.find_last_not_of(" \t\r\n");
            if (start != std::string::npos) {
                val = val.substr(start, end - start + 1);
            }
            
            ReplayParamType ptype = inferParamType(val);
            bool isNull = (ptype == ReplayParamType::Null);
            std::string pval = stripQuotes(val, ptype == ReplayParamType::WVarChar);
            event.parameters.emplace_back(ptype, pval, isNull);
        }
    }
}

void XelReplayParser::parseProcParams(ReplayEvent& event) {
    // User stored proc statement text from XEvent trace looks like:
    //   exec dbo.sqlsim_test_proc 1,N'hello'
    //   exec dbo.MyProc @id=42,@name=N'test'
    //
    // The object_name field has the unqualified proc name (e.g., "sqlsim_test_proc")
    // The statement text has the full exec with schema prefix.
    //
    // We need to:
    // 1. Extract the schema-qualified proc name from the statement text
    // 2. Extract parameter values
    // 3. Build {CALL proc(?,?,...)} for SQLPrepare
    
    if (event.objectName.empty()) return;
    
    event.procName = event.objectName;
    
    if (event.statementText.empty()) {
        // No statement text — can't extract params, build a bare CALL
        event.parameterizedSql = "{CALL " + event.objectName + "}";
        return;
    }
    
    const std::string& text = event.statementText;
    
    // Find the proc name in the statement text to locate where params start
    // Statement looks like: "exec dbo.sqlsim_test_proc 1,N'hello'"
    // or: "exec [dbo].[MyProc] 1,N'hello'"
    // Find "exec " prefix (case-insensitive)
    std::string lower = text;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    
    size_t execPos = lower.find("exec ");
    size_t afterExec = (execPos != std::string::npos) ? execPos + 5 : 0;
    
    // Skip any leading whitespace after exec
    while (afterExec < text.size() && (text[afterExec] == ' ' || text[afterExec] == '\t')) {
        ++afterExec;
    }
    
    // The proc name runs until the first space or end of string
    // Handle qualified names like dbo.proc or [dbo].[proc]
    size_t procEnd = afterExec;
    bool inBracket = false;
    while (procEnd < text.size()) {
        if (text[procEnd] == '[') inBracket = true;
        else if (text[procEnd] == ']') inBracket = false;
        else if (!inBracket && (text[procEnd] == ' ' || text[procEnd] == '\t')) break;
        ++procEnd;
    }
    
    std::string qualifiedProcName = text.substr(afterExec, procEnd - afterExec);
    if (!qualifiedProcName.empty()) {
        event.procName = qualifiedProcName;
    }
    
    // Everything after the proc name (and whitespace) is the parameter list
    size_t paramsStart = procEnd;
    while (paramsStart < text.size() && (text[paramsStart] == ' ' || text[paramsStart] == '\t')) {
        ++paramsStart;
    }
    
    if (paramsStart >= text.size()) {
        // No parameters
        event.parameterizedSql = "{CALL " + event.procName + "}";
        return;
    }
    
    // Split parameters at top-level commas
    std::vector<std::string> paramValues = splitTopLevelArgs(text, paramsStart);
    
    for (auto& val : paramValues) {
        // Trim whitespace
        size_t start = val.find_first_not_of(" \t\r\n");
        size_t end = val.find_last_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        val = val.substr(start, end - start + 1);
        
        // Handle named params: @name=value → just use the value
        size_t eqPos = std::string::npos;
        bool inQuote = false;
        for (size_t i = 0; i < val.size(); ++i) {
            if (val[i] == '\'') inQuote = !inQuote;
            if (!inQuote && val[i] == '=') { eqPos = i; break; }
        }
        if (eqPos != std::string::npos && eqPos > 0 && val[0] == '@') {
            val = val.substr(eqPos + 1);
            // Trim again
            start = val.find_first_not_of(" \t");
            if (start != std::string::npos) val = val.substr(start);
        }
        
        ReplayParamType ptype = inferParamType(val);
        bool isNull = (ptype == ReplayParamType::Null);
        std::string pval = stripQuotes(val, ptype == ReplayParamType::WVarChar);
        event.parameters.emplace_back(ptype, pval, isNull);
    }
    
    // Build {CALL proc(?,?,...)}
    std::string callSql = "{CALL " + event.procName + "(";
    for (size_t i = 0; i < event.parameters.size(); ++i) {
        if (i > 0) callSql += ",";
        callSql += "?";
    }
    callSql += ")}";
    event.parameterizedSql = callSql;
}

// ============================================================================
// Session Grouping
// ============================================================================

void XelReplayParser::groupEventsBySessions() {
    // Group events by session_id, preserving order
    std::unordered_map<int64_t, size_t> sessionIndex;
    
    for (auto& event : data_.allEvents) {
        if (event.eventType == ReplayEventType::Skipped) continue;
        
        auto it = sessionIndex.find(event.sessionId);
        if (it == sessionIndex.end()) {
            sessionIndex[event.sessionId] = data_.sessions.size();
            ReplaySession session;
            session.sessionId = event.sessionId;
            session.databaseName = event.databaseName;
            
            if (event.eventType == ReplayEventType::RpcResetConnection) {
                session.usesPooling = true;
            } else {
                session.events.push_back(event);
            }
            
            data_.sessions.push_back(std::move(session));
        } else {
            auto& session = data_.sessions[it->second];
            if (event.eventType == ReplayEventType::RpcResetConnection) {
                session.usesPooling = true;
            } else {
                session.events.push_back(event);
            }
        }
    }
}

// ============================================================================
// File Parsing Entry Point
// ============================================================================

bool XelReplayParser::parseFile(const std::string& filePath, std::string& errorMsg) {
    // Read the entire file
    std::ifstream file(filePath, std::ios::binary);
    if (!file.is_open()) {
        errorMsg = "Cannot open replay file: " + filePath;
        return false;
    }
    
    // Get file size for validation
    file.seekg(0, std::ios::end);
    auto fileSize = file.tellg();
    file.seekg(0, std::ios::beg);
    
    if (fileSize == 0) {
        errorMsg = "Replay file is empty: " + filePath;
        return false;
    }
    
    // Limit file size to prevent memory issues (100 MB)
    const auto MAX_FILE_SIZE = static_cast<std::streamoff>(100 * 1024 * 1024);
    if (fileSize > MAX_FILE_SIZE) {
        errorMsg = "Replay file exceeds maximum size of 100 MB: " + filePath;
        return false;
    }
    
    std::string xml;
    try {
        xml.resize(static_cast<size_t>(fileSize));
    } catch (const std::bad_alloc&) {
        errorMsg = "Out of memory reading replay file: " + filePath;
        return false;
    }
    
    file.read(&xml[0], fileSize);
    file.close();
    
    // Parse the XML
    return parseXml(xml, errorMsg);
}

// ============================================================================
// Stress Mode Sequence Builder
// ============================================================================

void XelReplayParser::buildStressSequence() {
    // Build a flat sequence from all sessions for stress mode:
    // - Drop sp_prepare and sp_unprepare events
    // - Drop sp_reset_connection events  
    // - Keep all other events
    // - Sort by timestamp, keeping the converted event_sequence order for ties
    
    std::vector<ReplayEvent> stressEvents;
    stressEvents.reserve(data_.replayableEvents);
    
    for (const auto& event : data_.allEvents) {
        switch (event.eventType) {
            case ReplayEventType::RpcPrepare:
            case ReplayEventType::RpcUnprepare:
            case ReplayEventType::RpcResetConnection:
            case ReplayEventType::Skipped:
                // Skip these in stress mode
                break;
                
            case ReplayEventType::RpcExecute:
                // Promote sp_execute to a one-shot execution
                // In stress mode, we replay the statement text directly
                if (!event.statementText.empty()) {
                    ReplayEvent promoted = event;
                    promoted.eventType = ReplayEventType::RpcExecuteSql; // Treat as one-shot
                    stressEvents.push_back(std::move(promoted));
                }
                break;
                
            default:
                stressEvents.push_back(event);
                break;
        }
    }
    
    // Sort by timestamp. Most events in a busy capture share a timestamp, so the
    // sort must be stable to keep convert-xel.ps1's event_sequence order for ties.
    std::stable_sort(stressEvents.begin(), stressEvents.end(),
                     [](const ReplayEvent& a, const ReplayEvent& b) {
                         return a.timestamp < b.timestamp;
                     });
    
    data_.allEvents = std::move(stressEvents);
}

// ============================================================================
// Standalone Utility
// ============================================================================

ReplayParamType inferOdbcParamType(const std::string& value) {
    if (value.empty()) return ReplayParamType::Null;
    
    std::string upper = value;
    std::transform(upper.begin(), upper.end(), upper.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    if (upper == "NULL") return ReplayParamType::Null;
    
    if (value.size() >= 3 && (value[0] == 'N' || value[0] == 'n') && value[1] == '\'')
        return ReplayParamType::WVarChar;
    if (value.size() >= 2 && value[0] == '\'') {
        // Check for datetime pattern: 'YYYY-MM-DD'
        if (value.size() >= 12 && std::isdigit(static_cast<unsigned char>(value[1]))
            && std::isdigit(static_cast<unsigned char>(value[2]))
            && std::isdigit(static_cast<unsigned char>(value[3]))
            && std::isdigit(static_cast<unsigned char>(value[4]))
            && value[5] == '-'
            && std::isdigit(static_cast<unsigned char>(value[6]))
            && std::isdigit(static_cast<unsigned char>(value[7]))
            && value[8] == '-'
            && std::isdigit(static_cast<unsigned char>(value[9]))
            && std::isdigit(static_cast<unsigned char>(value[10]))) {
            return ReplayParamType::Datetime;
        }
        return ReplayParamType::VarChar;
    }
    if (value.size() >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X'))
        return ReplayParamType::Binary;
    
    if (value.find('.') != std::string::npos) {
        bool numeric = true;
        for (size_t i = (value[0] == '-' || value[0] == '+') ? 1 : 0; i < value.size(); ++i) {
            if (!std::isdigit(static_cast<unsigned char>(value[i])) && value[i] != '.') {
                numeric = false;
                break;
            }
        }
        if (numeric) return ReplayParamType::Double;
    }
    
    bool isInt = !value.empty();
    for (size_t i = (value[0] == '-' || value[0] == '+') ? 1 : 0; i < value.size(); ++i) {
        if (!std::isdigit(static_cast<unsigned char>(value[i]))) {
            isInt = false;
            break;
        }
    }
    if (isInt) return ReplayParamType::BigInt;
    
    return ReplayParamType::WVarChar;
}
