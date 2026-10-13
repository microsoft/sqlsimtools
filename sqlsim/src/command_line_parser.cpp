#include "command_line_parser.h"
#include "platform_capabilities.h"
#include "workload_config.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <climits>
#include <cctype>
#include <algorithm>
#include <cstdio>

#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

// Forward declaration of parseBatches from main.cpp
extern std::vector<std::string> parseBatches(const std::string& input);

namespace {

bool stdinIsTerminal() {
#ifdef _WIN32
    return _isatty(_fileno(stdin)) != 0;
#else
    return isatty(fileno(stdin)) != 0;
#endif
}

void clearSensitiveString(std::string& value) {
    volatile char* data = value.empty() ? nullptr : &value[0];
    for (size_t i = 0; i < value.size(); ++i) {
        data[i] = '\0';
    }
    value.clear();
}

bool readSecretFromStdin(std::string& destination, size_t maximumLength,
                         const std::string& option, std::string& errorMsg) {
    if (stdinIsTerminal()) {
        errorMsg = "sqlsim error: " + option + " - requires redirected stdin; pipe the credential to sqlsim";
        return false;
    }

    destination.clear();
    char character = 0;
    while (std::cin.get(character)) {
        if (character == '\n') {
            break;
        }
        if (character == '\r') {
            if (std::cin.peek() == '\n') {
                std::cin.get();
            }
            break;
        }
        if (destination.size() >= maximumLength) {
            clearSensitiveString(destination);
            errorMsg = "sqlsim error: Credential from stdin exceeds maximum length for " + option;
            return false;
        }
        destination.push_back(character);
    }

    if (destination.empty()) {
        errorMsg = "sqlsim error: Credential from stdin cannot be empty for " + option;
        return false;
    }
    return true;
}

} // namespace

// Helper function to escape connection string values
std::string escapeConnectionStringValue(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.length());
    
    for (char c : value) {
        // Block connection string metacharacters
        if (c == ';' || c == '{' || c == '}') {
            // Replace with space to avoid breaking the value while preventing injection
            escaped += ' ';
        } else {
            escaped += c;
        }
    }
    
    return escaped;
}

std::string CommandLineParser::getParamValue(int& index, char* argv[], int argc,
                                             const std::string& currentArg, 
                                             const std::string& flag) {
    if (currentArg.length() > flag.length()) {
        // Value is concatenated (e.g., "-n10")
        return currentArg.substr(flag.length());
    } else if (index + 1 < argc) {
        std::string nextArg = argv[index + 1];
        
        // Only an exact match for a known flag means the value is missing.
        //
        // Values legitimately begin with '-': a query that opens with a SQL
        // comment, a password, an output path, a negative number. Treating
        // every argument that starts with '-' as a flag silently discarded
        // those and reported the value as empty, so
        //   -Q "-- daily report
        //       SELECT ..."
        // failed with "Query cannot be empty". Matching whole flags keeps a
        // genuinely missing value detected, as in -Q -v, without guessing
        // about content.
        static const std::vector<std::string> knownFlags = {
            "-c", "-S", "-d", "-E", "-A", "-T", "-U", "-P", "-l", "-t", "-N", "-C", "-F", "-R", "-M",
            "-app", "-retry", "-retrydelay", "-n", "-r", "-p", "-Q", "-i", "-o", "-q", "-v", "-stoponerror", "-json", "-stream-json",
            "-reconnect", "-usepool", "-h", "-?", "--help", "--version",
            "-replay", "-replayfile", "-querystats", "-querystats-interval", "-querystats-file", "-workload"
        };
        
        for (const auto& knownFlag : knownFlags) {
            if (nextArg == knownFlag) {
                return ""; // The flag was supplied without its value.
            }
        }
        
        // Value is space-separated
        return argv[++index];
    }
    return "";
}

bool CommandLineParser::validateConnectionString(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Connection string cannot be empty (-c requires a value)";
        return false;
    }
    if (value.length() > 4096) {
        errorMsg = "sqlsim error: Connection string exceeds maximum length";
        return false;
    }
    return true;
}

bool CommandLineParser::validateServerName(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Server name cannot be empty (-S requires a value)";
        return false;
    }
    if (value.length() > 253) {
        errorMsg = "sqlsim error: Server name exceeds maximum length";
        return false;
    }
    // Check for connection string injection attempts (only block metacharacters that break connection strings)
    // Allow: letters, digits, hyphens, periods (FQDN), backslash (instance), colon (port), comma (failover partner)
    if (value.find_first_of(";{}") != std::string::npos) {
        errorMsg = "sqlsim error: Server name contains invalid characters (connection string metacharacters not allowed)";
        return false;
    }
    return true;
}

bool CommandLineParser::validateDatabaseName(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Database name cannot be empty (-d requires a value)";
        return false;
    }
    if (value.length() > 128) {
        errorMsg = "sqlsim error: Database name exceeds maximum length";
        return false;
    }
    
    // SQL Server allows two types of identifiers:
    // 1. Regular identifiers: Must start with letter/underscore/@/#, contain letters/digits/underscore/@/#/$
    // 2. Delimited identifiers (quoted): Can contain almost any characters including spaces
    // 
    // Since we pass the database name to ODBC connection string, we need to prevent
    // connection string injection but allow all valid SQL Server identifier characters.
    // Block only connection string metacharacters that would break the connection string.
    if (value.find_first_of(";{}") != std::string::npos) {
        errorMsg = "sqlsim error: Database name contains invalid characters (connection string metacharacters not allowed)";
        return false;
    }
    
    // SQL Server allows brackets in delimited identifiers [database name]
    // but we should not block them as they're valid. Users can quote names in the database itself.
    // Only prevent characters that are definitely invalid in all contexts or used for injection.
    
    return true;
}

bool CommandLineParser::validateUsername(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Username cannot be empty (-U requires a value)";
        return false;
    }
    if (value.length() > 128) {
        errorMsg = "sqlsim error: Username exceeds maximum length";
        return false;
    }
    // Check for connection string injection attempts
    if (value.find_first_of(";{}") != std::string::npos) {
        errorMsg = "sqlsim error: Username contains invalid characters (connection string metacharacters not allowed)";
        return false;
    }
    return true;
}

bool CommandLineParser::validatePassword(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Password cannot be empty (-P requires a value)";
        return false;
    }
    if (value.length() > 128) {
        errorMsg = "sqlsim error: Password exceeds maximum length";
        return false;
    }
    // Check for connection string injection attempts
    if (value.find_first_of(";{}") != std::string::npos) {
        errorMsg = "sqlsim error: Password contains invalid characters (connection string metacharacters not allowed)";
        return false;
    }
    return true;
}

bool CommandLineParser::validateAccessToken(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Access token cannot be empty (-T requires a value)";
        return false;
    }
    // Generic validation without revealing token structure details
    if (value.length() < 10 || value.length() > 10000) {
        errorMsg = "sqlsim error: Invalid access token format";
        return false;
    }
    return true;
}

bool CommandLineParser::validateFilePath(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Input file path cannot be empty (-i requires a value)";
        return false;
    }
    if (value.find('\0') != std::string::npos) {
        errorMsg = "sqlsim error: Invalid file path format";
        return false;
    }
    if (value.length() > 4096) {
        errorMsg = "sqlsim error: File path exceeds maximum length";
        return false;
    }
    return true;
}

bool CommandLineParser::validateQuery(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Query cannot be empty (-Q requires a value)";
        return false;
    }
    if (value.length() > 1048576) {
        errorMsg = "sqlsim error: Query exceeds maximum size";
        return false;
    }
    return true;
}

bool CommandLineParser::validateAppName(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Application name cannot be empty (-app requires a value)";
        return false;
    }
    if (value.length() > 128) {
        errorMsg = "sqlsim error: Application name exceeds maximum length";
        return false;
    }
    // Check for connection string injection attempts
    if (value.find_first_of(";{}") != std::string::npos) {
        errorMsg = "sqlsim error: Application name contains invalid characters (connection string metacharacters not allowed)";
        return false;
    }
    return true;
}

bool CommandLineParser::validateHostname(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Certificate hostname cannot be empty (-F requires a value)";
        return false;
    }
    if (value.length() > 253) {
        errorMsg = "sqlsim error: Certificate hostname exceeds maximum length";
        return false;
    }
    // Check for connection string injection attempts
    if (value.find_first_of(";{}") != std::string::npos) {
        errorMsg = "sqlsim error: Certificate hostname contains invalid characters (connection string metacharacters not allowed)";
        return false;
    }
    return true;
}

bool CommandLineParser::validateEncryptionLevel(const std::string& value, std::string& errorMsg) {
    if (value != "o" && value != "m" && value != "s") {
        errorMsg = "sqlsim error: Invalid encryption level '" + value + 
                  "'. Valid options: o (optional), m (mandatory), s (strict)";
        return false;
    }
    return true;
}

bool CommandLineParser::validateReplayMode(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Replay mode cannot be empty (-replay requires 'fast' or 'stress')";
        return false;
    }
    if (value != "fast" && value != "stress") {
        errorMsg = "sqlsim error: Invalid replay mode '" + value + 
                  "'. Valid options: fast (faithful per-session), stress (flattened workload)";
        return false;
    }
    return true;
}

bool CommandLineParser::validateReplayFile(const std::string& value, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Replay file path cannot be empty (-replayfile requires a value)";
        return false;
    }
    if (value.find('\0') != std::string::npos) {
        errorMsg = "sqlsim error: Invalid replay file path format";
        return false;
    }
    if (value.length() > 4096) {
        errorMsg = "sqlsim error: Replay file path exceeds maximum length";
        return false;
    }
    return true;
}

bool CommandLineParser::validateTimeout(const std::string& value, int& output, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Timeout value cannot be empty";
        return false;
    }
    try {
        output = std::stoi(value);
        if (output < 0 || output > 86400) {
            errorMsg = "sqlsim error: Timeout must be between 0 and 86400 seconds";
            return false;
        }
    } catch (const std::invalid_argument&) {
        errorMsg = "sqlsim error: Invalid timeout value";
        return false;
    } catch (const std::out_of_range&) {
        errorMsg = "sqlsim error: Timeout value out of range";
        return false;
    }
    return true;
}

bool CommandLineParser::validateThreadCount(const std::string& value, int& output, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Thread count cannot be empty (-n requires a value)";
        return false;
    }
    try {
        output = std::stoi(value);
        if (output < 1 || output > INT_MAX) {
            errorMsg = "sqlsim error: Number of threads must be between 1 and " + std::to_string(INT_MAX);
            return false;
        }
    } catch (const std::invalid_argument&) {
        errorMsg = "sqlsim error: Invalid thread count value";
        return false;
    } catch (const std::out_of_range&) {
        errorMsg = "sqlsim error: Thread count value out of range";
        return false;
    }
    return true;
}

bool CommandLineParser::validateIterations(const std::string& value, int& output, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Iteration count cannot be empty (-r requires a value)";
        return false;
    }
    try {
        output = std::stoi(value);
        if (output < 1 || output > INT_MAX) {
            errorMsg = "sqlsim error: Iterations per thread must be between 1 and " + std::to_string(INT_MAX);
            return false;
        }
    } catch (const std::invalid_argument&) {
        errorMsg = "sqlsim error: Invalid iteration count value";
        return false;
    } catch (const std::out_of_range&) {
        errorMsg = "sqlsim error: Iteration count value out of range";
        return false;
    }
    return true;
}

bool CommandLineParser::validateRetryCount(const std::string& value, int& output, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Retry count cannot be empty (-retry requires a value)";
        return false;
    }
    try {
        output = std::stoi(value);
        if (output < 0 || output > 255) {
            errorMsg = "sqlsim error: Connect retry count must be between 0 and 255";
            return false;
        }
    } catch (const std::invalid_argument&) {
        errorMsg = "sqlsim error: Invalid retry count value";
        return false;
    } catch (const std::out_of_range&) {
        errorMsg = "sqlsim error: Retry count value out of range";
        return false;
    }
    return true;
}

bool CommandLineParser::validateRetryDelay(const std::string& value, int& output, std::string& errorMsg) {
    if (value.empty()) {
        errorMsg = "sqlsim error: Retry delay cannot be empty (-retrydelay requires a value)";
        return false;
    }
    try {
        output = std::stoi(value);
        if (output < 1 || output > 60) {
            errorMsg = "sqlsim error: Connect retry interval must be between 1 and 60 seconds";
            return false;
        }
    } catch (const std::invalid_argument&) {
        errorMsg = "sqlsim error: Invalid retry delay value";
        return false;
    } catch (const std::out_of_range&) {
        errorMsg = "sqlsim error: Retry delay value out of range";
        return false;
    }
    return true;
}

std::string CommandLineParser::buildConnectionString(
    const std::string& server,
    const std::string& database,
    const std::string& username,
    const std::string& password,
    bool useIntegratedSecurity,
    const std::string& entraAuthType,
    const std::string& accessToken,
    const std::string& encryptionLevel,
    bool trustServerCertificate,
    const std::string& certificateHostname,
    bool readOnlyIntent,
    bool multiSubnetFailover,
    const std::string& appName,
    int connectRetryCount,
    int connectRetryInterval) {
    
    // Phase 3 Optimization: Use ostringstream for efficient string building
    // Avoids repeated allocations from += operator
    std::ostringstream connStr;
    connStr << "Driver={ODBC Driver 18 for SQL Server};Server=" << server << ";";
    
    if (!database.empty()) {
        connStr << "Database=" << database << ";";
    }
    
    // Authentication. The methods are mutually exclusive, enforced by
    // validateConfiguration. An access token contributes no keyword here: it
    // is applied through SQLSetConnectAttr with SQL_COPT_SS_ACCESS_TOKEN.
    // Certificate handling below is shared by every authentication mode.
    if (useIntegratedSecurity) {
        connStr << "Trusted_Connection=Yes;";
    } else if (!entraAuthType.empty()) {
        connStr << "Authentication=" << entraAuthType << ";";
        if (!username.empty()) {
            connStr << "UID=" << username << ";";
        }
        if (!password.empty()) {
            connStr << "PWD=" << password << ";";
        }
    } else if (!username.empty()) {
        connStr << "UID=" << username << ";";
        if (!password.empty()) {
            connStr << "PWD=" << password << ";";
        }
    }
    
    // TDS 8.0 encryption
    if (!encryptionLevel.empty()) {
        if (encryptionLevel == "o") {
            connStr << "Encrypt=Optional;";
        } else if (encryptionLevel == "m") {
            connStr << "Encrypt=Mandatory;";
        } else if (encryptionLevel == "s") {
            connStr << "Encrypt=Strict;";
        }
    }
    
    // Certificate handling, matching sqlcmd (Go): with neither -N nor -C the
    // connection is negotiated without validating the server certificate; -N
    // without -C requires validation; -C trusts it outright.
    //
    // Token authentication used to force TrustServerCertificate=Yes here and
    // so could never validate, which mattered most for Azure SQL, where the
    // server presents a certificate from a trusted authority and the
    // connection crosses the internet. It now follows the same rule as every
    // other authentication mode.
    if (trustServerCertificate) {
        connStr << "TrustServerCertificate=Yes;";
    } else if (!encryptionLevel.empty()) {
        connStr << "TrustServerCertificate=No;";
    } else {
        connStr << "TrustServerCertificate=Yes;";
    }
    
    if (!certificateHostname.empty()) {
        connStr << "HostNameInCertificate=" << certificateHostname << ";";
    }
    
    // Additional options
    if (readOnlyIntent) {
        connStr << "ApplicationIntent=ReadOnly;";
    }
    if (multiSubnetFailover) {
        connStr << "MultiSubnetFailover=Yes;";
    }
    if (!appName.empty()) {
        connStr << "APP=" << appName << ";";
    }
    
    // Retry settings - only add if explicitly specified
    if (connectRetryCount > 0) {
        connStr << "ConnectRetryCount=" << connectRetryCount << ";";
        connStr << "ConnectRetryInterval=" << connectRetryInterval << ";";
    }
    
    return connStr.str();
}

bool CommandLineParser::validateConfiguration(
    const std::string& sqlServer,
    const std::string& accessToken,
    bool useIntegratedSecurity,
    const std::string& entraAuthType,
    const std::string& sqlUsername,
    const std::string& /* encryptionLevel */,
    bool trustServerCertificate,
    const std::string& certificateHostname,
    const WorkloadConfig& config,
    std::string& errorMsg) {
    
    // Check for conflicting authentication options
    int authMethodCount = 0;
    if (useIntegratedSecurity) authMethodCount++;
    if (!entraAuthType.empty()) authMethodCount++;
    if (!accessToken.empty()) authMethodCount++;
    if (!sqlUsername.empty()) authMethodCount++;
    
    if (authMethodCount > 1) {
        errorMsg = "sqlsim error: Cannot mix authentication methods (-E, -A, -T, -U/-P)";
        return false;
    }
    
    // Validate TDS 8.0 parameter combinations
    if (!certificateHostname.empty() && trustServerCertificate) {
        errorMsg = "sqlsim error: Cannot use -F (certificate hostname) with -C (trust server certificate)\n"
                  "Use either -F for certificate validation or -C to bypass validation";
        return false;
    }
    
    // Validate connection behavior parameters
    if (config.useConnectionPooling && !config.reconnectPerIteration) {
        errorMsg = "sqlsim error: -usepool requires -reconnect (connection pooling only applies when reconnecting)";
        return false;
    }
    
    // Validate -Q and -i mutual exclusion
    if (!config.queries.empty() && !config.inputFile.empty()) {
        errorMsg = "sqlsim error: Cannot use -Q with -i (choose one query source)";
        return false;
    }

    // Validate replay mode parameters
    if (!config.replayMode.empty() || !config.replayFile.empty()) {
        if (config.replayMode.empty()) {
            errorMsg = "sqlsim error: -replayfile requires -replay <mode> (fast or stress)";
            return false;
        }
        if (config.replayFile.empty()) {
            errorMsg = "sqlsim error: -replay requires -replayfile <xmlfile>";
            return false;
        }
        // Mutual exclusion with -Q, -i, and -workload
        if (!config.queries.empty() || !config.inputFile.empty()) {
            errorMsg = "sqlsim error: Cannot use -replay with -Q or -i (queries come from replay file)";
            return false;
        }
        if (!config.workloadFile.empty()) {
            errorMsg = "sqlsim error: Cannot use -replay with -workload (choose one mode)";
            return false;
        }
        // Replay mode is incompatible with certain workload options
        if (config.usePreparedStatements) {
            errorMsg = "sqlsim error: Cannot use -p with -replay (replay uses its own ODBC methods per event type)";
            return false;
        }
        if (config.reconnectPerIteration) {
            errorMsg = "sqlsim error: Cannot use -reconnect with -replay (replay manages its own connections)";
            return false;
        }
        if (config.useConnectionPooling) {
            errorMsg = "sqlsim error: Cannot use -usepool with -replay (replay manages its own connections)";
            return false;
        }
    }
    
    // Validate workload file parameters
    if (!config.workloadFile.empty()) {
        // Mutual exclusion with -Q, -i, -replay
        if (!config.queries.empty() || !config.inputFile.empty()) {
            errorMsg = "sqlsim error: Cannot use -workload with -Q or -i (queries come from workload file)";
            return false;
        }
        if (!config.replayMode.empty()) {
            errorMsg = "sqlsim error: Cannot use -workload with -replay (choose one mode)";
            return false;
        }
    }
    
    // Check for authentication requirement
    if (!sqlServer.empty() && accessToken.empty() && !useIntegratedSecurity && 
        entraAuthType.empty() && sqlUsername.empty()) {
        errorMsg = "sqlsim error: Must specify either -E (Windows Auth), -A (Entra), -T (Access Token), or -U (SQL Auth)\n"
                  "For connection testing, use: sqlsim -S server -E";
        return false;
    }
    
    return true;
}

ParseResult CommandLineParser::parse(int argc, char* argv[], WorkloadConfig& config) {
    // Initialize default values
    config.numThreads = 1;
    config.iterationsPerThread = 1;
    config.usePreparedStatements = false;
    config.verbose = false;
    config.quietMode = false;
    config.stopOnError = false;
    config.reconnectPerIteration = false;
    config.useConnectionPooling = false;
    
    std::string sqlServer;
    std::string sqlDatabase;
    std::string sqlUsername;
    std::string sqlPassword;
    std::string inputFile;
    std::string appName = "sqlsim";  // Default application name for connection tracking
    int connectRetryCount = 0;
    int connectRetryInterval = 10;
    bool hasRetryCount = false;     // Track if -retry was explicitly set
    bool hasRetryDelay = false;     // Track if -retrydelay was explicitly set
    bool hasExplicitThreads = false;    // Track if -n was explicitly set
    bool hasExplicitIterations = false; // Track if -r was explicitly set
    bool useIntegratedSecurity = false;
    std::string entraAuthType;
    bool readOnlyIntent = false;
    bool multiSubnetFailover = false;
    std::string encryptionLevel;
    bool hasQueryOption = false;  // Track if -Q was used
    bool trustServerCertificate = false;
    std::string certificateHostname;
    
    // Show help if no arguments
    if (argc == 1) {
        ParseResult result(true);
        result.success = false;  // No args is an error
        return result;
    }
    
    // Parse command line arguments
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        std::string errorMsg;
        
        if (arg == "-h" || arg == "-?" || arg == "--help") {
            return ParseResult(true);
        }
        else if (arg == "--version") {
            return ParseResult(true, true);  // showHelp=true, showVersionOnly=true
        }
        else if (arg == "-c" || (arg.length() > 2 && arg.substr(0, 2) == "-c")) {
            std::string value = getParamValue(i, argv, argc, arg, "-c");
            if (!validateConnectionString(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            config.connectionString = value;
            
            // Extract server and database from connection string for display
            // Look for Server= or Data Source= (case-insensitive)
            std::string connStrLower = value;
            std::transform(connStrLower.begin(), connStrLower.end(), connStrLower.begin(), ::tolower);
            std::string connStrOptions = connStrLower;
            connStrOptions.erase(
                std::remove_if(connStrOptions.begin(), connStrOptions.end(),
                               [](unsigned char c) { return std::isspace(c) != 0; }),
                connStrOptions.end());
            
            size_t serverPos = connStrLower.find("server=");
            if (serverPos == std::string::npos) {
                serverPos = connStrLower.find("data source=");
                if (serverPos != std::string::npos) serverPos += 12;
            } else {
                serverPos += 7;
            }
            if (serverPos != std::string::npos) {
                size_t endPos = value.find(';', serverPos);
                config.serverName = value.substr(serverPos, endPos == std::string::npos ? std::string::npos : endPos - serverPos);
            }
            
            size_t dbPos = connStrLower.find("database=");
            if (dbPos == std::string::npos) {
                dbPos = connStrLower.find("initial catalog=");
                if (dbPos != std::string::npos) dbPos += 16;
            } else {
                dbPos += 9;
            }
            if (dbPos != std::string::npos) {
                size_t endPos = value.find(';', dbPos);
                config.databaseName = value.substr(dbPos, endPos == std::string::npos ? std::string::npos : endPos - dbPos);
            }
            
            if (config.serverName.empty()) config.serverName = "(from connection string)";
            if (config.databaseName.empty()) config.databaseName = "(default)";

            if (connStrOptions.find("authentication=activedirectoryinteractive") != std::string::npos &&
                !sqlsim::platform::supportsEntraInteractive()) {
                return ParseResult::error("sqlsim error: ActiveDirectoryInteractive is not supported by ODBC Driver 18 on " +
                                          std::string(sqlsim::platform::name()) + ". Use -T, ActiveDirectoryIntegrated, "
                                          "ActiveDirectoryMsi, or ActiveDirectoryServicePrincipal");
            }
            
            // Try to detect authentication method from connection string
            if (connStrOptions.find("trusted_connection=yes") != std::string::npos ||
                connStrOptions.find("integratedsecurity=") != std::string::npos) {
                config.authMethod = sqlsim::platform::usesKerberosForTrustedConnection()
                    ? "Integrated (Kerberos)"
                    : "Windows";
            } else if (connStrOptions.find("authentication=activedirectoryinteractive") != std::string::npos) {
                config.authMethod = "Entra Interactive";
            } else if (connStrOptions.find("authentication=activedirectoryintegrated") != std::string::npos) {
                config.authMethod = "Entra Integrated";
            } else if (connStrOptions.find("authentication=activedirectorymsi") != std::string::npos) {
                config.authMethod = "Entra Managed Identity";
            } else if (connStrOptions.find("authentication=activedirectoryserviceprincipal") != std::string::npos) {
                config.authMethod = "Entra Service Principal";
            } else if (connStrOptions.find("uid=") != std::string::npos ||
                       connStrOptions.find("userid=") != std::string::npos) {
                config.authMethod = "SQL Server";
            } else {
                config.authMethod = "(from connection string)";
            }
        }
        else if (arg == "-S" || (arg.length() > 2 && arg.substr(0, 2) == "-S")) {
            std::string value = getParamValue(i, argv, argc, arg, "-S");
            if (!validateServerName(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            sqlServer = value;
        }
        else if (arg == "-d" || (arg.length() > 2 && arg.substr(0, 2) == "-d")) {
            std::string value = getParamValue(i, argv, argc, arg, "-d");
            if (!validateDatabaseName(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            sqlDatabase = value;
        }
        else if (arg == "-E") {
            useIntegratedSecurity = true;
        }
        else if (arg == "-A") {
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                std::string nextArg = argv[i + 1];
                std::string nextArgUpper = nextArg;
                for (auto& c : nextArgUpper) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
                
                // Only consume next argument if it looks like a valid auth type (starts with "ACTIVEDIRECTORY")
                if (nextArgUpper.find("ACTIVEDIRECTORY") == 0) {
                    ++i;
                    
                    if (nextArgUpper == "ACTIVEDIRECTORYINTERACTIVE") {
                        entraAuthType = "ActiveDirectoryInteractive";
                    } else if (nextArgUpper == "ACTIVEDIRECTORYINTEGRATED") {
                        entraAuthType = "ActiveDirectoryIntegrated";
                    } else if (nextArgUpper == "ACTIVEDIRECTORYMSI") {
                        entraAuthType = "ActiveDirectoryMsi";
                    } else if (nextArgUpper == "ACTIVEDIRECTORYSERVICEPRINCIPAL") {
                        entraAuthType = "ActiveDirectoryServicePrincipal";
                    } else {
                        return ParseResult::error("Error: Unknown authentication type '" + nextArg + "'.\n"
                                                "Valid options: ActiveDirectoryInteractive, ActiveDirectoryIntegrated, "
                                                "ActiveDirectoryMsi, ActiveDirectoryServicePrincipal");
                    }
                } else {
                    // Next argument doesn't look like an auth type, use default
                    entraAuthType = "ActiveDirectoryInteractive";
                }
            } else {
                entraAuthType = "ActiveDirectoryInteractive";
            }
        }
        else if (arg == "-T" || (arg.length() > 2 && arg.substr(0, 2) == "-T")) {
            std::string value = getParamValue(i, argv, argc, arg, "-T");
            if (value == "-") {
                if (!readSecretFromStdin(config.accessToken, 10000, "-T", errorMsg)) {
                    return ParseResult::error(errorMsg);
                }
                if (!validateAccessToken(config.accessToken, errorMsg)) {
                    clearSensitiveString(config.accessToken);
                    return ParseResult::error(errorMsg);
                }
            } else if (!validateAccessToken(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            } else {
                config.accessToken = value;
            }
        }
        else if (arg == "-U" || (arg.length() > 2 && arg.substr(0, 2) == "-U")) {
            std::string value = getParamValue(i, argv, argc, arg, "-U");
            if (!validateUsername(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            sqlUsername = value;
        }
        else if (arg == "-P" || (arg.length() > 2 && arg.substr(0, 2) == "-P")) {
            std::string value = getParamValue(i, argv, argc, arg, "-P");
            if (value == "-") {
                if (!readSecretFromStdin(sqlPassword, 128, "-P", errorMsg)) {
                    return ParseResult::error(errorMsg);
                }
                if (!validatePassword(sqlPassword, errorMsg)) {
                    clearSensitiveString(sqlPassword);
                    return ParseResult::error(errorMsg);
                }
            } else if (!validatePassword(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            } else {
                sqlPassword = value;
                // SECURITY: Warn about password visibility (output to stderr)
                std::cerr << "WARNING: Password provided via command line is visible in process list and history." << std::endl;
            }
        }
        else if (arg == "-l" || (arg.length() > 2 && arg.substr(0, 2) == "-l")) {
            std::string value = getParamValue(i, argv, argc, arg, "-l");
            if (!validateTimeout(value, config.loginTimeout, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
        }
        else if (arg == "-t" || (arg.length() > 2 && arg.substr(0, 2) == "-t")) {
            std::string value = getParamValue(i, argv, argc, arg, "-t");
            if (!validateTimeout(value, config.queryTimeout, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
        }
        else if (arg == "-n" || (arg.length() > 2 && arg.substr(0, 2) == "-n")) {
            std::string value = getParamValue(i, argv, argc, arg, "-n");
            if (!validateThreadCount(value, config.numThreads, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            hasExplicitThreads = true;
        }
        else if (arg == "-r" || (arg.length() > 2 && arg.substr(0, 2) == "-r" && std::isdigit(arg[2]))) {
            std::string value = getParamValue(i, argv, argc, arg, "-r");
            if (!validateIterations(value, config.iterationsPerThread, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            hasExplicitIterations = true;
        }
        else if (arg == "-retrydelay" || (arg.length() > 11 && arg.substr(0, 11) == "-retrydelay")) {
            std::string value = getParamValue(i, argv, argc, arg, "-retrydelay");
            if (!validateRetryDelay(value, connectRetryInterval, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            hasRetryDelay = true;
        }
        else if (arg == "-retry" || (arg.length() > 6 && arg.substr(0, 6) == "-retry")) {
            std::string value = getParamValue(i, argv, argc, arg, "-retry");
            if (!validateRetryCount(value, connectRetryCount, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            hasRetryCount = true;
        }
        else if (arg == "-p") {
            config.usePreparedStatements = true;
        }
        else if (arg == "-Q" || (arg.length() > 2 && arg.substr(0, 2) == "-Q")) {
            std::string value = getParamValue(i, argv, argc, arg, "-Q");
            if (!validateQuery(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            std::vector<std::string> batches = parseBatches(value);
            if (batches.empty()) {
                return ParseResult::error("Error: Query contains no executable statements");
            }
            config.queries.insert(config.queries.end(), batches.begin(), batches.end());
            hasQueryOption = true;
        }
        else if (arg == "-i" || (arg.length() > 2 && arg.substr(0, 2) == "-i")) {
            std::string value = getParamValue(i, argv, argc, arg, "-i");
            if (!validateFilePath(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            inputFile = value;
            
            // Handle PowerShell dot-splitting for file extensions (e.g., -ifile.sql becomes -ifile and .sql)
            while (i + 1 < argc && argv[i + 1][0] == '.') {
                inputFile += argv[++i];
            }
        }
        else if (arg == "-q") {
            config.quietMode = true;
        }
        else if (arg == "-v") {
            config.verbose = true;
        }
        else if (arg == "-R") {
            readOnlyIntent = true;
        }
        else if (arg == "-M") {
            multiSubnetFailover = true;
        }
        else if (arg == "-N" || (arg.length() > 2 && arg.substr(0, 2) == "-N")) {
            std::string value;
            if (arg.length() > 2) {
                value = arg.substr(2);
            } else if (i + 1 < argc && argv[i + 1][0] != '-') {
                std::string nextArg = argv[i + 1];
                // Only consume next argument if it's a valid encryption level (o, m, or s)
                if (nextArg == "o" || nextArg == "m" || nextArg == "s") {
                    value = argv[++i];
                } else {
                    // Check if it looks like an invalid encryption level (single char that's not valid)
                    if (nextArg.length() == 1) {
                        return ParseResult::error("Error: Invalid encryption level '" + nextArg + 
                                                "'. Valid options: o (optional), m (mandatory), s (strict)");
                    }
                    // Otherwise, don't consume it - let it be parsed as another argument
                    // and use default encryption level
                }
            }
            if (value.empty()) {
                value = "m"; // Default to mandatory
            }
            if (!validateEncryptionLevel(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            encryptionLevel = value;
        }
        else if (arg == "-C") {
            trustServerCertificate = true;
        }
        else if (arg == "-F" || (arg.length() > 2 && arg.substr(0, 2) == "-F")) {
            std::string value = getParamValue(i, argv, argc, arg, "-F");
            if (!validateHostname(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            certificateHostname = value;
        }
        else if (arg == "-app" || (arg.length() > 4 && arg.substr(0, 4) == "-app")) {
            std::string value = getParamValue(i, argv, argc, arg, "-app");
            if (!validateAppName(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            appName = value;
        }
        else if (arg == "-stoponerror") {
            config.stopOnError = true;
        }
        else if (arg == "-json") {
            config.jsonOutput = true;
            config.finalJsonOutput = true;
        }
        else if (arg == "-stream-json") {
            config.streamJsonOutput = true;
            config.jsonOutput = true;
        }
        else if (arg == "-querystats") {
            config.queryStats = true;
        }
        else if (arg == "-querystats-interval" || (arg.length() > 20 && arg.substr(0, 20) == "-querystats-interval")) {
            std::string value = getParamValue(i, argv, argc, arg, "-querystats-interval");
            if (value.empty()) {
                return ParseResult::error("sqlsim error: -querystats-interval requires a value (seconds)");
            }
            try {
                config.queryStatsIntervalSec = std::stoi(value);
                if (config.queryStatsIntervalSec < 1) {
                    return ParseResult::error("sqlsim error: -querystats-interval must be >= 1");
                }
            } catch (...) {
                return ParseResult::error("sqlsim error: Invalid value for -querystats-interval: " + value);
            }
            config.queryStats = true; // -querystats-interval implies -querystats
        }
        else if (arg == "-querystats-file" || (arg.length() > 16 && arg.substr(0, 16) == "-querystats-file")) {
            std::string value = getParamValue(i, argv, argc, arg, "-querystats-file");
            if (value.empty()) {
                return ParseResult::error("sqlsim error: -querystats-file requires a file path");
            }
            config.queryStatsFile = value;
            
            // Handle PowerShell dot-splitting for file extensions
            while (i + 1 < argc && argv[i + 1][0] == '.') {
                config.queryStatsFile += argv[++i];
            }
        }
        else if (arg == "-reconnect") {
            config.reconnectPerIteration = true;
        }
        else if (arg == "-usepool") {
            config.useConnectionPooling = true;
        }
        else if (arg == "-replay" || (arg.length() > 7 && arg.substr(0, 7) == "-replay" && arg.substr(0, 11) != "-replayfile")) {
            std::string value = getParamValue(i, argv, argc, arg, "-replay");
            if (!validateReplayMode(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            config.replayMode = value;
        }
        else if (arg == "-replayfile" || (arg.length() > 11 && arg.substr(0, 11) == "-replayfile")) {
            std::string value = getParamValue(i, argv, argc, arg, "-replayfile");
            if (!validateReplayFile(value, errorMsg)) {
                return ParseResult::error(errorMsg);
            }
            config.replayFile = value;
            
            // Handle PowerShell dot-splitting for file extensions
            while (i + 1 < argc && argv[i + 1][0] == '.') {
                config.replayFile += argv[++i];
            }
        }
        else if (arg == "-workload" || (arg.length() > 9 && arg.substr(0, 9) == "-workload")) {
            std::string value = getParamValue(i, argv, argc, arg, "-workload");
            if (value.empty()) {
                return ParseResult::error("sqlsim error: -workload requires a JSON file path");
            }
            config.workloadFile = value;
            
            // Handle PowerShell dot-splitting for file extensions
            while (i + 1 < argc && argv[i + 1][0] == '.') {
                config.workloadFile += argv[++i];
            }
        }
        else if (arg == "-o" || (arg.length() > 2 && arg.substr(0, 2) == "-o")) {
            std::string value = getParamValue(i, argv, argc, arg, "-o");
            if (value.empty()) {
                return ParseResult::error("Error: -o requires output file path");
            }
            config.outputFile = value;
            
            // Handle PowerShell dot-splitting for file extensions (e.g., -ooutput.txt becomes -ooutput and .txt)
            while (i + 1 < argc && argv[i + 1][0] == '.') {
                config.outputFile += argv[++i];
            }
        }
        else {
            // Handle domain name continuation
            if (!arg.empty() && arg[0] == '.') {
                if (!sqlServer.empty()) {
                    sqlServer += arg;
                    continue;
                } else if (!sqlDatabase.empty()) {
                    sqlDatabase += arg;
                    continue;
                } else if (!config.connectionString.empty()) {
                    config.connectionString += arg;
                    continue;
                }
            }
            return ParseResult::error("sqlsim error: Unknown option: " + arg + ". Use -help to see valid parameters");
        }
    }
    
    // Store inputFile early so validateConfiguration can check for -i/-replay conflicts
    config.inputFile = inputFile;

    // Validate configuration
    std::string errorMsg;

    if (entraAuthType == "ActiveDirectoryInteractive" && !sqlsim::platform::supportsEntraInteractive()) {
        return ParseResult::error("sqlsim error: ActiveDirectoryInteractive is not supported by ODBC Driver 18 on " +
                                  std::string(sqlsim::platform::name()) + ". Use -T, ActiveDirectoryIntegrated, "
                                  "ActiveDirectoryMsi, or ActiveDirectoryServicePrincipal");
    }

    const bool usernameIsEntraCredential =
        entraAuthType == "ActiveDirectoryMsi" || entraAuthType == "ActiveDirectoryServicePrincipal";
    if (entraAuthType == "ActiveDirectoryServicePrincipal" && (sqlUsername.empty() || sqlPassword.empty())) {
        return ParseResult::error("sqlsim error: ActiveDirectoryServicePrincipal requires -U <client_id> and -P <client_secret>");
    }
    if (entraAuthType == "ActiveDirectoryMsi" && !sqlPassword.empty()) {
        return ParseResult::error("sqlsim error: ActiveDirectoryMsi does not accept -P");
    }
    if (!entraAuthType.empty() && !usernameIsEntraCredential && (!sqlUsername.empty() || !sqlPassword.empty())) {
        return ParseResult::error("sqlsim error: " + entraAuthType + " does not accept -U or -P");
    }

    if (!validateConfiguration(sqlServer, config.accessToken, useIntegratedSecurity, 
                               entraAuthType, usernameIsEntraCredential ? std::string() : sqlUsername, encryptionLevel,
                               trustServerCertificate, certificateHostname, config, errorMsg)) {
        return ParseResult::error(errorMsg);
    }
    if (config.streamJsonOutput && config.finalJsonOutput && config.outputFile.empty()) {
        return ParseResult::error("sqlsim error: Combining -stream-json with -json requires -o <final-result-file>");
    }
    
    // Warn if -n is specified in fast replay mode (thread count is determined by session count)
    if (config.replayMode == "fast" && config.numThreads != 1) {
        config.warnings.push_back("-n " + std::to_string(config.numThreads) + " ignored in fast replay mode (thread count is determined by session count)");
        config.numThreads = 1;  // Reset, will be set to session count later
    }
    
    // Warn if -n or -r specified with -workload (threads/iterations come from workload file)
    if (!config.workloadFile.empty()) {
        if (hasExplicitThreads) {
            config.warnings.push_back("-n " + std::to_string(config.numThreads) + " ignored with -workload (thread count is defined per workload entry in the JSON file)");
        }
        if (hasExplicitIterations) {
            config.warnings.push_back("-r " + std::to_string(config.iterationsPerThread) + " ignored with -workload (iterations are defined per workload entry in the JSON file)");
        }
    }
    
    // Default to localhost if connection parameters provided but no server specified
    // (matches sqlcmd behavior)
    if (sqlServer.empty() && 
        (useIntegratedSecurity || !sqlUsername.empty() || !entraAuthType.empty() || 
         !config.accessToken.empty() || !sqlDatabase.empty())) {
        sqlServer = "localhost";
    }
    
    // Build connection string if server was specified (or defaulted to localhost)
    if (!sqlServer.empty()) {
        if (!config.connectionString.empty()) {
            return ParseResult::error("Error: Cannot use both -c and -S/-d/-E/-U/-P options");
        }
        
        config.connectionString = buildConnectionString(
            sqlServer, sqlDatabase, sqlUsername, sqlPassword,
            useIntegratedSecurity, entraAuthType, config.accessToken,
            encryptionLevel, trustServerCertificate, certificateHostname,
            readOnlyIntent, multiSubnetFailover, appName,
            connectRetryCount, connectRetryInterval);
        clearSensitiveString(sqlPassword);
        
        // Store server and database names for display
        config.serverName = sqlServer;
        config.databaseName = sqlDatabase.empty() ? "(default)" : sqlDatabase;
        
        // Store authentication method for display
        if (!config.accessToken.empty()) {
            config.authMethod = "Access Token";
        } else if (useIntegratedSecurity) {
            config.authMethod = sqlsim::platform::usesKerberosForTrustedConnection()
                ? "Integrated (Kerberos)"
                : "Windows";
        } else if (!entraAuthType.empty()) {
            if (entraAuthType == "ActiveDirectoryInteractive") {
                config.authMethod = "Entra Interactive";
            } else if (entraAuthType == "ActiveDirectoryIntegrated") {
                config.authMethod = "Entra Integrated";
            } else if (entraAuthType == "ActiveDirectoryMsi") {
                config.authMethod = "Entra Managed Identity";
            } else if (entraAuthType == "ActiveDirectoryServicePrincipal") {
                config.authMethod = "Entra Service Principal";
            } else {
                config.authMethod = "Entra (" + entraAuthType + ")";
            }
        } else if (!sqlUsername.empty()) {
            config.authMethod = "SQL Server";
        }
        
        // Store additional options for display (only when used)
        config.inputFile = inputFile;
        config.appName = appName;
        config.retryCount = connectRetryCount;
        config.retryDelay = connectRetryInterval;
        config.hasRetryCount = hasRetryCount;
        config.hasRetryDelay = hasRetryDelay;
        // Store expanded encryption level for display
        if (encryptionLevel == "o") {
            config.encryptionLevel = "Optional";
        } else if (encryptionLevel == "m") {
            config.encryptionLevel = "Mandatory";
        } else if (encryptionLevel == "s") {
            config.encryptionLevel = "Strict";
        } else {
            config.encryptionLevel = encryptionLevel;  // Already expanded or empty
        }
        config.trustServerCertificate = trustServerCertificate;
        config.certificateHostname = certificateHostname;
        config.readOnlyIntent = readOnlyIntent;
        config.multiSubnetFailover = multiSubnetFailover;
    }
    
    // Store inputFile for display (works with both -c and -S modes)
    config.inputFile = inputFile;
    
    // Load queries from input file if specified
    if (!inputFile.empty() && !hasQueryOption) {
        std::ifstream file(inputFile);
        if (!file.is_open()) {
            return ParseResult::error("Error: Cannot open input file: " + inputFile);
        }
        
        std::stringstream buffer;
        buffer << file.rdbuf();
        file.close();
        
        std::vector<std::string> batches = parseBatches(buffer.str());
        config.queries.insert(config.queries.end(), batches.begin(), batches.end());
        
        if (config.queries.empty()) {
            return ParseResult::error("Error: No batches found in input file: " + inputFile);
        }
        
        // Note: "Loaded X batches" message is output in main.cpp after output redirection is set up
    }
    
    // Load workload file if specified
    if (!config.workloadFile.empty()) {
        try {
            config.workloadEntries = WorkloadFileParser::parse(config.workloadFile);
        } catch (const std::runtime_error& e) {
            return ParseResult::error("Error: " + std::string(e.what()));
        }
        
        // Expand workload entries into thread assignments and populate config.queries for display
        int totalThreads = 0;
        for (size_t wi = 0; wi < config.workloadEntries.size(); ++wi) {
            auto& entry = config.workloadEntries[wi];
            
            // If entry uses a file, load it now
            if (!entry.file.empty()) {
                std::ifstream wfile(entry.file);
                if (!wfile.is_open()) {
                    return ParseResult::error("Error: Cannot open workload script file: " + entry.file);
                }
                std::stringstream wbuf;
                wbuf << wfile.rdbuf();
                wfile.close();
                entry.queries = parseBatches(wbuf.str());
                if (entry.queries.empty()) {
                    return ParseResult::error("Error: No batches found in workload script: " + entry.file);
                }
            }
            
            // Create thread assignments for this workload group
            for (int t = 0; t < entry.threads; ++t) {
                ThreadAssignment ta;
                ta.queries = entry.queries;
                ta.iterations = entry.iterations;
                ta.duration_seconds = entry.duration_seconds;
                ta.workloadIndex = static_cast<int>(wi);
                ta.think_time_ms = entry.think_time_ms;
                config.threadAssignments.push_back(ta);
            }
            totalThreads += entry.threads;
        }
        
        // Set numThreads to total thread count from all workload groups
        config.numThreads = totalThreads;
        
        // Propagate ramp settings from workload entries to config
        if (!config.workloadEntries.empty() && config.workloadEntries[0].ramp_batch_size > 0) {
            config.rampBatchSize = config.workloadEntries[0].ramp_batch_size;
            config.rampDelayMs = config.workloadEntries[0].ramp_delay_ms;
        }
        
        // Collect all unique queries into config.queries for display purposes
        // (workerThread will use threadAssignments instead)
        config.queries.clear();
        for (const auto& entry : config.workloadEntries) {
            for (const auto& q : entry.queries) {
                // Add if not already present
                bool found = false;
                for (const auto& existing : config.queries) {
                    if (existing == q) { found = true; break; }
                }
                if (!found) config.queries.push_back(q);
            }
        }
    }
    
    // Final validation
    if (config.connectionString.empty()) {
        return ParseResult::error("Error: Connection information is required\n"
                                "Use -c for complete connection string, or -S with authentication (-E, -A, -T, or -U/-P)\n"
                                "For help: sqlsim -h");
    }
    
    return ParseResult();
}
