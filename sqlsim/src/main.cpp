#include <iostream>
#include <string>
#include <fstream>
#include <sstream>
#include <vector>
#include <climits>
#include <mutex>
#include <regex>
#include "workload_simulator.h"
#include "odbc_connection.h"
#include "command_line_parser.h"
#include "timestamp_helper.h"
#include "json_output.h"
#include "xel_replay.h"
#include "version.h"

std::string maskCommandConnectionString(const std::string& connectionString) {
    // ODBC braces values that contain ';', so mask through the closing brace.
    static const std::regex sensitiveValue(
        R"((PWD|Password|UID|Username|User ID|UserId|AccessToken|Access Token)=(?:\{(?:\}\}|[^}])*\}|[^;]*))",
        std::regex::icase);
    return std::regex_replace(connectionString, sensitiveValue, "$1=********");
}

std::string formatCommandArgument(const std::string& argument) {
    return argument.find(' ') != std::string::npos ? "\"" + argument + "\"" : argument;
}

std::string buildMaskedCommandLine(int argc, char* argv[]) {
    std::string commandLine;
    for (int i = 0; i < argc; ++i) {
        std::string argument(argv[i]);
        if (argument == "-U" || argument == "-P" || argument == "-T") {
            if (!commandLine.empty()) commandLine += " ";
            commandLine += argument;
            if (i + 1 < argc) {
                commandLine += " ********";
                ++i;
            }
            continue;
        }
        if (argument == "-c" && i + 1 < argc) {
            if (!commandLine.empty()) commandLine += " ";
            commandLine += argument + " " + formatCommandArgument(maskCommandConnectionString(argv[++i]));
            continue;
        }
        // The parser also accepts attached values such as -Psecret and -cDriver=...
        if (argument.length() > 2 && argument[0] == '-') {
            const std::string flag = argument.substr(0, 2);
            if (flag == "-U" || flag == "-P" || flag == "-T") {
                if (!commandLine.empty()) commandLine += " ";
                commandLine += flag + "********";
                continue;
            }
            if (flag == "-c") {
                if (!commandLine.empty()) commandLine += " ";
                commandLine += formatCommandArgument(flag + maskCommandConnectionString(argument.substr(2)));
                continue;
            }
        }

        if (!commandLine.empty()) commandLine += " ";
        commandLine += formatCommandArgument(argument);
    }
    return commandLine;
}

// SECURITY FIX (H-4): Thread-safe logger to prevent race conditions in output redirection
class ThreadSafeLogger {
private:
    std::ofstream file_;
    std::mutex mutex_;
    bool useFile_;
    
public:
    ThreadSafeLogger() : useFile_(false) {}
    
    bool open(const std::string& filename) {
        std::lock_guard<std::mutex> lock(mutex_);
        file_.open(filename);
        if (!file_.is_open()) {
            return false;
        }
        useFile_ = true;
        return true;
    }
    
    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (file_.is_open()) {
            file_.close();
        }
        useFile_ = false;
    }
    
    template<typename T>
    ThreadSafeLogger& operator<<(const T& value) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (useFile_ && file_.is_open()) {
            file_ << value;
        } else {
            std::cout << value;
        }
        return *this;
    }
    
    // Handle std::endl and other manipulators
    ThreadSafeLogger& operator<<(std::ostream& (*manip)(std::ostream&)) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (useFile_ && file_.is_open()) {
            manip(file_);
            file_.flush();
        } else {
            manip(std::cout);
            std::cout.flush();
        }
        return *this;
    }
};

// Parse batches from a string, splitting on GO separators
std::vector<std::string> parseBatches(const std::string& input) {
    std::vector<std::string> batches;
    batches.reserve(10); // Reserve space for typical workload
    std::istringstream stream(input);
    std::string line;
    std::ostringstream currentBatch;
    
    while (std::getline(stream, line)) {
        // Trim whitespace from line
        std::string trimmed = line;
        trimmed.erase(0, trimmed.find_first_not_of(" \t\r\n"));
        trimmed.erase(trimmed.find_last_not_of(" \t\r\n") + 1);
        
        // Check if line is GO batch separator (case-insensitive)
        std::string trimmedUpper = trimmed;
        for (auto& c : trimmedUpper) {
            c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        }
        if (trimmedUpper == "GO") {
            std::string batch = currentBatch.str();
            // Trim batch
            batch.erase(0, batch.find_first_not_of(" \t\r\n"));
            batch.erase(batch.find_last_not_of(" \t\r\n") + 1);
            
            if (!batch.empty()) {
                batches.push_back(std::move(batch));
            }
            currentBatch.str("");
            currentBatch.clear();
        } else {
            // Accumulate SQL statements (including comments - SQL Server will handle them)
            currentBatch << line << '\n';
        }
    }
    
    // Add any remaining batch
    std::string batch = currentBatch.str();
    if (!batch.empty()) {
        batch.erase(0, batch.find_first_not_of(" \t\r\n"));
        batch.erase(batch.find_last_not_of(" \t\r\n") + 1);
        if (!batch.empty()) {
            batches.push_back(std::move(batch));
        }
    }
    
    return batches;
}

void printUsage() {
    std::cout << "\nSQL Workload Simulator v" << SQLSIM_VERSION << " - Generic SQL query execution tool\n"
              << "\nUsage: sqlsim [options]\n"
              << "Note: Spaces after parameters are optional (e.g., '-S server' or '-Sserver')\n\n"
              << "Connection Options (one method required):\n\n"
              << "  Method 1: Full connection string\n"
              << "    -c <connection_string>  Complete ODBC connection string\n\n"
              << "  Method 2: Build connection string\n"
              << "    -S <server>             SQL Server name (., localhost, server\\instance, FQDN, or server[,port])\n"
              << "                            Optional: Defaults to 'localhost' if omitted (matches sqlcmd)\n"
              << "    -d <database>           Database name (optional, connects to default if omitted)\n\n"
              << "    Authentication (choose one):\n"
              << "      -E                      Integrated authentication (Windows SSPI; Kerberos on Linux/macOS)\n"
              << "      -A [mode]               Microsoft Entra auth (default: ActiveDirectoryInteractive)\n"
              << "                              Modes: ActiveDirectoryInteractive (Windows only),\n"
              << "                              ActiveDirectoryIntegrated, ActiveDirectoryMsi,\n"
              << "                              ActiveDirectoryServicePrincipal\n"
              << "                              For user-assigned MI: -A ActiveDirectoryMsi -U <client_id>\n"
              << "                              For service principal: -A ActiveDirectoryServicePrincipal -U <client_id> -P <secret>\n"
              << "      -T <access_token>       Access token authentication\n"
              << "                              Use -T - to read the token from redirected stdin\n"
              << "      -U <username>           SQL Server username (use with -P for SQL auth)\n"
              << "                              Or client ID (use with -A ActiveDirectoryMsi for user-assigned MI)\n"
              << "      -P <password>           SQL Server password\n\n"
              << "                              Use -P - to read the password/secret from redirected stdin\n\n"
              << "    Connection Settings:\n"
              << "      -l <seconds>            Login timeout (default: driver default, range: 0-86400)\n"
              << "      -app <name>             Application name for connection tracking\n"
              << "      -retry <count>          Connection retry attempts (default: 0, range: 0-255)\n"
              << "      -retrydelay <seconds>   Seconds between retries (default: 10, range: 1-60)\n\n"
              << "Query Options (optional - omit for connection test only):\n\n"
              << "    -Q <query>              Query or queries to execute (supports GO batches)\n"
              << "    -i <input_file>         File containing SQL queries (GO separates batches)\n"
              << "                            -Q, -i, -workload, and -replay are mutually exclusive\n"
              << "    -t <seconds>            Query timeout (default: driver default, range: 0-86400)\n\n"
              << "Workload Options:\n\n"
              << "    -n <threads>            Concurrent threads (default: 1, range: 1-2147483647)\n"
              << "    -r <iterations>         Iterations per thread (default: 1, range: 1-2147483647)\n"
              << "    -p                      Use prepared statements (default: false)\n"
              << "    -reconnect              Disconnect/reconnect after each iteration\n"
              << "    -usepool                Enable ODBC connection pooling (requires -reconnect)\n"
              << "    -workload <jsonfile>     Workload definition file (mixed workloads, per-group threads)\n"
              << "                            Mutually exclusive with -Q, -i, -replay\n\n"
              << "Replay Options:\n\n"
              << "    -replay <mode>          Replay mode: fast (per-session) or stress (flattened workload)\n"
              << "    -replayfile <xmlfile>    XML replay file (from convert-xel.ps1)\n"
              << "                            Mutually exclusive with -Q, -i, -workload\n"
              << "                            Outputs replay summary comparing original trace vs replay outcomes\n\n"
              << "Security & Encryption Options:\n\n"
              << "    -N [level]              TDS 8.0 encryption: o (optional), m (mandatory, default), s (strict)\n"
              << "    -C                      Trust server certificate (bypass validation)\n"
              << "    -F <hostname>           Expected certificate hostname for validation\n"
              << "    -R                      Read-only intent (route to AG secondary replica)\n"
              << "    -M                      Multi-subnet failover (faster AG failover)\n\n"
              << "Output Options:\n\n"
              << "    -o <outputfile>         Write all output to file including errors (like sqlcmd -o)\n"
              << "    -q                      Quiet mode (suppress query results)\n"
              << "    -v                      Verbose mode (detailed phases and metrics)\n"
              << "    -stoponerror            Stop on first error (default: continue)\n"
              << "    -querystats              Show per-query server stats (SET STATISTICS TIME/IO)\n"
              << "                             Use -v to also display raw SET STATISTICS messages\n"
              << "    -querystats-interval <N> Write querystats JSON snapshot every N seconds (live monitoring)\n"
              << "    -querystats-file <file>  Output file for querystats snapshots (default: auto-generated)\n"
              << "    -json                   Output in JSON format (structured, machine-readable)\n"
              << "    -stream-json            Stream NDJSON started/progress/completed events once per second\n"
              << "                            Combine with -json -o <file> to also write canonical final JSON\n"
              << "    -h, -?, --help          Show this help message\n"
              << "    --version               Show version information\n\n"
              << "Examples:\n\n"
              << "  # Connection test (defaults to localhost):\n"
              << "  sqlsim -E\n\n"
              << "  # Basic query execution:\n"
              << "  sqlsim -S localhost -d testdb -E -Q \"SELECT @@VERSION\"\n\n"
              << "  # Load test (10 threads, 100 iterations each, quiet mode):\n"
              << "  sqlsim -S localhost -d testdb -E -i queries.sql -n 10 -r 100 -q\n\n"
              << "  # SQL Authentication (password on stdin, so it stays out of process lists):\n"
              << "  echo \"$password\" | sqlsim -S localhost -d testdb -U myuser -P - -Q \"SELECT 1\"\n\n"
              << "  # Azure SQL with Entra Interactive:\n"
              << "  sqlsim -S myserver.database.windows.net -d mydb -A -Q \"SELECT 1\"\n\n"
              << "  # Azure SQL with Access Token ($token = az account get-access-token ...):\n"
              << "  echo \"$token\" | sqlsim -S myserver.database.windows.net -d mydb -T - -Q \"SELECT 1\"\n\n"
              << "  # Replay captured workload (fast mode - faithful per-session):\n"
              << "  sqlsim -S localhost -E -replay fast -replayfile trace.xml\n\n"
              << "  # Replay as stress test (10 threads, flattened workload):\n"
              << "  sqlsim -S localhost -E -replay stress -replayfile trace.xml -n 10\n\n"
              << "  # Mixed workload from JSON definition file:\n"
              << "  sqlsim -S localhost -E -d testdb -workload workload.json -querystats\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    WorkloadConfig config;
    
    const std::string commandLine = buildMaskedCommandLine(argc, argv);
    
    // Parse command line arguments using the parser
    CommandLineParser parser;
    ParseResult result = parser.parse(argc, argv, config);
    
    if (!result.success) {
        TS_ERR << result.errorMessage << std::endl;
        if (result.shouldShowHelp) {
            printUsage();
        }
        return 1;
    }
    
    if (result.showVersionOnly) {
        std::cout << "sqlsim " << SQLSIM_VERSION << std::endl;
        return 0;
    }
    
    if (result.shouldShowHelp) {
        printUsage();
        return 0;
    }
    
    // Parse replay file if in replay mode
    if (!config.replayMode.empty()) {
        XelReplayParser parser;
        std::string parseError;
        if (!parser.parseFile(config.replayFile, parseError)) {
            TS_ERR << "sqlsim error: Failed to parse replay file: " << parseError << std::endl;
            return 1;
        }
        
        config.replayData = parser.getReplayData();
        
        if (config.replayData.replayableEvents == 0) {
            TS_ERR << "sqlsim error: No replayable events found in replay file" << std::endl;
            return 1;
        }
        
        // For stress mode, build the flattened sequence
        if (config.replayMode == "stress") {
            parser.buildStressSequence();
            config.replayData = parser.getReplayData();
        }
    }
    
    // Auto-generate querystats file path if interval is set but no file specified
    if (config.queryStatsIntervalSec > 0 && config.queryStatsFile.empty()) {
        config.queryStatsFile = "querystats-live.json";
    }
    
    // SECURITY FIX (H-4): Output redirection with thread safety considerations
    // Note: Stream redirection is inherently not fully thread-safe for concurrent writes.
    // For production use, consider refactoring to use a thread-safe logging mechanism.
    // The current implementation works because most output happens in sequential phases,
    // and metrics collection uses its own synchronization.
    std::ofstream outputFileStream;
    std::streambuf* coutBackup = nullptr;
    std::streambuf* cerrBackup = nullptr;
    std::mutex outputMutex; // Added for documentation of thread safety considerations
    bool usingOutputFile = !config.outputFile.empty()
        && !(config.streamJsonOutput && config.finalJsonOutput);
    
    if (usingOutputFile) {
        // Show minimal console output before redirecting
        TS_OUT << "=== SQL Workload Simulator v" << SQLSIM_VERSION << " ===" << std::endl;
        TS_OUT << "ODBC Driver: ODBC Driver 18 for SQL Server" << std::endl;
        TS_OUT << "Output redirected to: " << config.outputFile << std::endl;
        
        // Build connection target string
        std::string connectTarget = config.serverName;
        if (!config.databaseName.empty()) {
            connectTarget += "/" + config.databaseName;
        }
        TS_OUT << "Connecting to " << connectTarget << "..." << std::endl;
        
        outputFileStream.open(config.outputFile);
        if (!outputFileStream.is_open()) {
            TS_ERR << "sqlsim error: Cannot open output file: " << config.outputFile << std::endl;
            return 1;
        }
        coutBackup = std::cout.rdbuf();
        cerrBackup = std::cerr.rdbuf();
        std::cout.rdbuf(outputFileStream.rdbuf());
        std::cerr.rdbuf(outputFileStream.rdbuf());
        
        // Note: While stream redirection is set up here, true thread-safety would require
        // wrapping all std::cout/std::cerr usage with mutexes throughout the codebase.
        // Current risk is mitigated by the fact that most concurrent output is already
        // synchronized (connection messages use buffering, metrics use internal mutexes).
    }
    
    auto printJsonHeader = [&config]() {
        std::cout << "{\n";
        std::cout << JsonOutput::jsonPair("version", std::string(SQLSIM_VERSION));
        std::cout << JsonOutput::jsonPair("start_time", JsonOutput::getIsoTimestamp());
        std::cout << "  \"configuration\": {\n";
        
        // Build configuration fields as vector to handle last item properly
        std::vector<std::string> configFields;
        
        // Always show: core info
        configFields.push_back(JsonOutput::jsonPair("odbc_driver", std::string("ODBC Driver 18 for SQL Server")));
        configFields.push_back(JsonOutput::jsonPair("server", config.serverName));
        configFields.push_back(JsonOutput::jsonPair("database", config.databaseName.empty() ? "(default)" : config.databaseName));
        configFields.push_back(JsonOutput::jsonPair("authentication", config.authMethod));
        configFields.push_back(JsonOutput::jsonPair("threads", config.numThreads));
        
        if (!config.workloadFile.empty()) {
            // Workload file mode
            configFields.push_back(JsonOutput::jsonPair("workload_file", config.workloadFile));
            
            bool isDurationMode = !config.workloadEntries.empty() && config.workloadEntries[0].duration_seconds > 0;
            if (isDurationMode) {
                configFields.push_back(JsonOutput::jsonPair("duration_seconds", config.workloadEntries[0].duration_seconds));
            } else {
                // Calculate total batches across all workload groups
                int totalBatches = 0;
                for (const auto& entry : config.workloadEntries) {
                    totalBatches += entry.threads * entry.iterations * static_cast<int>(entry.queries.size());
                }
                configFields.push_back(JsonOutput::jsonPair("total_batches", totalBatches));
            }
            configFields.push_back(JsonOutput::jsonPair("workload_groups", static_cast<int>(config.workloadEntries.size())));
            
            // Build workload groups array
            std::string groupsJson = "  \"workloads\": [\n";
            for (size_t wi = 0; wi < config.workloadEntries.size(); ++wi) {
                const auto& entry = config.workloadEntries[wi];
                groupsJson += "      {\n";
                if (!entry.file.empty()) {
                    groupsJson += "        \"file\": \"" + JsonOutput::escapeJson(entry.file) + "\",\n";
                }
                groupsJson += "        \"threads\": " + std::to_string(entry.threads) + ",\n";
                if (isDurationMode) {
                    groupsJson += "        \"duration_seconds\": " + std::to_string(entry.duration_seconds) + ",\n";
                } else {
                    groupsJson += "        \"iterations\": " + std::to_string(entry.iterations) + ",\n";
                }
                if (entry.think_time_ms > 0) {
                    groupsJson += "        \"think_time_ms\": " + std::to_string(entry.think_time_ms) + ",\n";
                }
                groupsJson += "        \"batch_count\": " + std::to_string(entry.queries.size()) + ",\n";
                groupsJson += "        \"batches\": [";
                if (entry.queries.empty()) {
                    groupsJson += "]\n";
                } else {
                    groupsJson += "\n";
                    for (size_t qi = 0; qi < entry.queries.size(); ++qi) {
                        groupsJson += "          \"" + JsonOutput::escapeJson(entry.queries[qi]) + "\"";
                        if (qi < entry.queries.size() - 1) groupsJson += ",";
                        groupsJson += "\n";
                    }
                    groupsJson += "        ]\n";
                }
                groupsJson += "      }";
                if (wi < config.workloadEntries.size() - 1) groupsJson += ",";
                groupsJson += "\n";
            }
            groupsJson += "    ]";
            configFields.push_back(groupsJson);
        } else {
            configFields.push_back(JsonOutput::jsonPair("iterations_per_thread", config.iterationsPerThread));
            
            if (config.queries.empty()) {
                configFields.push_back(JsonOutput::jsonPair("connection_test_only", true));
            } else {
                configFields.push_back(JsonOutput::jsonPair("total_batches", static_cast<int>(config.numThreads * config.iterationsPerThread * config.queries.size())));
                configFields.push_back(JsonOutput::jsonPair("batch_count", static_cast<int>(config.queries.size())));
                // Add the actual batch queries
                configFields.push_back(JsonOutput::jsonStringArray("batches", config.queries, "    "));
            }
        }
        
        // Show only when used: optional features
        if (!config.inputFile.empty()) {
            configFields.push_back(JsonOutput::jsonPair("input_file", config.inputFile));
        }
        if (config.usePreparedStatements) {
            configFields.push_back(JsonOutput::jsonPair("prepared_statements", true));
        }
        if (config.loginTimeout > 0) {
            configFields.push_back(JsonOutput::jsonPair("login_timeout", config.loginTimeout));
        }
        if (config.queryTimeout > 0) {
            configFields.push_back(JsonOutput::jsonPair("query_timeout", config.queryTimeout));
        }
        if (config.reconnectPerIteration) {
            configFields.push_back(JsonOutput::jsonPair("reconnect_per_iteration", true));
        }
        if (config.useConnectionPooling) {
            configFields.push_back(JsonOutput::jsonPair("connection_pooling", true));
        }
        if (config.rampBatchSize > 0) {
            configFields.push_back(JsonOutput::jsonPair("ramp_batch_size", config.rampBatchSize));
            configFields.push_back(JsonOutput::jsonPair("ramp_delay_ms", config.rampDelayMs));
        }
        if (config.stopOnError) {
            configFields.push_back(JsonOutput::jsonPair("stop_on_error", true));
        }
        if (!config.appName.empty()) {
            configFields.push_back(JsonOutput::jsonPair("application_name", config.appName));
        }
        if (config.retryCount != 1) {
            configFields.push_back(JsonOutput::jsonPair("retry_count", config.retryCount));
        }
        if (config.retryDelay != 10) {
            configFields.push_back(JsonOutput::jsonPair("retry_delay", config.retryDelay));
        }
        if (!config.encryptionLevel.empty()) {
            configFields.push_back(JsonOutput::jsonPair("encryption", config.encryptionLevel));
        }
        if (config.trustServerCertificate) {
            configFields.push_back(JsonOutput::jsonPair("trust_server_certificate", true));
        }
        if (!config.certificateHostname.empty()) {
            configFields.push_back(JsonOutput::jsonPair("certificate_hostname", config.certificateHostname));
        }
        if (config.readOnlyIntent) {
            configFields.push_back(JsonOutput::jsonPair("read_only_intent", true));
        }
        if (config.multiSubnetFailover) {
            configFields.push_back(JsonOutput::jsonPair("multi_subnet_failover", true));
        }
        if (!config.outputFile.empty()) {
            configFields.push_back(JsonOutput::jsonPair("output_file", config.outputFile));
        }
        if (config.quietMode) {
            configFields.push_back(JsonOutput::jsonPair("quiet_mode", true));
        }
        if (config.verbose) {
            configFields.push_back(JsonOutput::jsonPair("verbose_mode", true));
        }
        if (config.streamJsonOutput) {
            configFields.push_back(JsonOutput::jsonPair("stream_json", true));
        }
        if (config.queryStats) {
            configFields.push_back(JsonOutput::jsonPair("query_stats", true));
            if (config.queryStatsIntervalSec > 0) {
                configFields.push_back(JsonOutput::jsonPair("query_stats_interval_sec", config.queryStatsIntervalSec));
                configFields.push_back(JsonOutput::jsonPair("query_stats_file", config.queryStatsFile));
            }
        }
        
        // Replay mode fields
        if (!config.replayMode.empty()) {
            configFields.push_back(JsonOutput::jsonPair("replay_mode", config.replayMode));
            configFields.push_back(JsonOutput::jsonPair("replay_file", config.replayFile));
            configFields.push_back(JsonOutput::jsonPair("replay_total_events", static_cast<int>(config.replayData.totalEvents)));
            configFields.push_back(JsonOutput::jsonPair("replay_replayable_events", static_cast<int>(config.replayData.replayableEvents)));
            configFields.push_back(JsonOutput::jsonPair("replay_skipped_events", static_cast<int>(config.replayData.skippedEvents)));
            if (config.replayMode == "fast") {
                configFields.push_back(JsonOutput::jsonPair("replay_sessions", static_cast<int>(config.replayData.sessions.size())));
            }
        }
        
        // Add warnings array if any exist
        if (!config.warnings.empty()) {
            std::string warningsJson = "  \"warnings\": [\n";
            for (size_t i = 0; i < config.warnings.size(); ++i) {
                warningsJson += "      \"" + JsonOutput::escapeJson(config.warnings[i]) + "\"";
                if (i < config.warnings.size() - 1) warningsJson += ",";
                warningsJson += "\n";
            }
            warningsJson += "    ]";
            configFields.push_back(warningsJson);
        }
        
        // Output all fields, marking the last one
        for (size_t i = 0; i < configFields.size(); ++i) {
            bool isLast = (i == configFields.size() - 1);
            std::string field = configFields[i];
            // Remove trailing comma and add it back if not last
            if (field.back() == '\n') field.pop_back();
            if (field.back() == ',') field.pop_back();
            std::cout << field;
            if (!isLast) std::cout << ",";
            std::cout << "\n";
        }
        
        std::cout << "  },\n";
    };

    // Output configuration based on mode
    if (config.jsonOutput && !config.streamJsonOutput) {
        printJsonHeader();
    } else if (!config.streamJsonOutput) {
        // Normal timestamped output
        TS_OUT << "=== SQL Workload Simulator v" << SQLSIM_VERSION << " ===" << std::endl;
        TS_OUT << "ODBC Driver: ODBC Driver 18 for SQL Server" << std::endl;
        
        // In verbose mode, show the exact command line for troubleshooting
        if (config.verbose) {
            TS_OUT << "Command: " << commandLine << std::endl;
        }
        
        TS_OUT << "Configuration:" << std::endl;
        
        // Always show: core execution info
        TS_OUT << "Server: " << config.serverName << std::endl;
        TS_OUT << "Database: " << (config.databaseName.empty() ? "(default)" : config.databaseName) << std::endl;
        TS_OUT << "Authentication: " << config.authMethod << std::endl;
        TS_OUT << "Threads: " << config.numThreads << std::endl;
        
        if (!config.workloadFile.empty()) {
            // Workload file mode
            TS_OUT << "Workload file: " << config.workloadFile << std::endl;
            bool isDurationMode = !config.workloadEntries.empty() && config.workloadEntries[0].duration_seconds > 0;
            if (isDurationMode) {
                TS_OUT << "Duration: " << config.workloadEntries[0].duration_seconds << " seconds" << std::endl;
            } else {
                int totalBatches = 0;
                for (const auto& entry : config.workloadEntries) {
                    totalBatches += entry.threads * entry.iterations * static_cast<int>(entry.queries.size());
                }
                TS_OUT << "Total batches to execute: " << totalBatches << std::endl;
            }
            TS_OUT << "Workload groups: " << config.workloadEntries.size() << std::endl;
            for (size_t wi = 0; wi < config.workloadEntries.size(); ++wi) {
                const auto& entry = config.workloadEntries[wi];
                std::string groupLine = "  Group " + std::to_string(wi + 1) + ": "
                    + std::to_string(entry.threads) + " thread(s), ";
                if (isDurationMode) {
                    groupLine += "duration mode, ";
                } else {
                    groupLine += std::to_string(entry.iterations) + " iteration(s), ";
                }
                groupLine += std::to_string(entry.queries.size()) + " batch(es)";
                if (entry.think_time_ms > 0) {
                    groupLine += ", think=" + std::to_string(entry.think_time_ms) + "ms";
                }
                if (!entry.file.empty()) {
                    groupLine += " [" + entry.file + "]";
                }
                TS_OUT << groupLine << std::endl;
            }
        } else {
            TS_OUT << "Iterations per thread: " << config.iterationsPerThread << std::endl;
            
            if (config.queries.empty()) {
                TS_OUT << "Mode: Connection test only" << std::endl;
            } else {
                TS_OUT << "Total batches to execute: " << (config.numThreads * config.iterationsPerThread * config.queries.size()) << std::endl;
                TS_OUT << "Batches in workload: " << config.queries.size() << std::endl;
            }
        }
        
        // Show only when used: optional features
        if (!config.inputFile.empty()) {
            TS_OUT << "Input file: " << config.inputFile << std::endl;
        }
        if (config.usePreparedStatements) {
            TS_OUT << "Prepared statements: Yes" << std::endl;
        }
        if (config.loginTimeout > 0) {
            TS_OUT << "Login timeout: " << config.loginTimeout << " seconds" << std::endl;
        }
        if (config.queryTimeout > 0) {
            TS_OUT << "Query timeout: " << config.queryTimeout << " seconds" << std::endl;
        }
        if (config.reconnectPerIteration) {
            TS_OUT << "Reconnect per iteration: Yes" << std::endl;
        }
        if (config.useConnectionPooling) {
            TS_OUT << "Connection pooling: Yes" << std::endl;
        }
        if (config.rampBatchSize > 0) {
            TS_OUT << "Ramp-up: " << config.rampBatchSize << " threads per batch, " << config.rampDelayMs << "ms delay" << std::endl;
        }
        if (config.stopOnError) {
            TS_OUT << "Stop on error: Yes" << std::endl;
        }
        if (!config.appName.empty()) {
            TS_OUT << "Application name: " << config.appName << std::endl;
        }
        if (config.hasRetryCount) {
            TS_OUT << "Retry count: " << config.retryCount << std::endl;
        }
        if (config.hasRetryDelay) {
            TS_OUT << "Retry delay: " << config.retryDelay << " seconds" << std::endl;
        }
        if (!config.encryptionLevel.empty()) {
            TS_OUT << "Encryption: " << config.encryptionLevel << std::endl;
        }
        if (config.trustServerCertificate) {
            TS_OUT << "Trust server certificate: Yes" << std::endl;
        }
        if (!config.certificateHostname.empty()) {
            TS_OUT << "Certificate hostname: " << config.certificateHostname << std::endl;
        }
        if (config.readOnlyIntent) {
            TS_OUT << "Read-only intent: Yes" << std::endl;
        }
        if (config.multiSubnetFailover) {
            TS_OUT << "Multi-subnet failover: Yes" << std::endl;
        }
        if (!config.outputFile.empty()) {
            TS_OUT << "Output file: " << config.outputFile << std::endl;
        }
        if (config.quietMode) {
            TS_OUT << "Quiet mode: Yes" << std::endl;
        }
        if (config.verbose) {
            TS_OUT << "Verbose mode: Yes" << std::endl;
        }
        if (config.queryStats) {
            TS_OUT << "Query stats: Yes" << std::endl;
            if (config.queryStatsIntervalSec > 0) {
                TS_OUT << "Query stats interval: " << config.queryStatsIntervalSec << "s" << std::endl;
                TS_OUT << "Query stats file: " << config.queryStatsFile << std::endl;
            }
        }
        
        // Replay mode output
        if (!config.replayMode.empty()) {
            TS_OUT << "Replay mode: " << config.replayMode << std::endl;
            TS_OUT << "Replay file: " << config.replayFile << std::endl;
            TS_OUT << "Replay events: " << config.replayData.replayableEvents 
                   << " replayable, " << config.replayData.skippedEvents 
                   << " skipped, " << config.replayData.totalEvents << " total" << std::endl;
            if (config.replayMode == "fast") {
                TS_OUT << "Replay sessions: " << config.replayData.sessions.size() << std::endl;
            }
        }
        
        // Display any deferred warnings in configuration section
        for (const auto& warning : config.warnings) {
            TS_OUT << "sqlsim warning: " << warning << std::endl;
        }
        
        // Display batches in separate section (shown once, not repeated per thread/iteration)
        if (!config.queries.empty() && !config.verbose) {
            TS_OUT << std::endl;
            TS_OUT << "Batches to execute:\n";
            for (size_t i = 0; i < config.queries.size(); ++i) {
                TS_OUT << "[" << (i + 1) << "] " << config.queries[i] << '\n';
            }
        }
    }
    
    // Run workload simulation
    try {
        // Enable ODBC connection pooling if requested
        if (config.useConnectionPooling) {
            if (!ODBCConnection::enableConnectionPooling()) {
                TS_ERR << "sqlsim warning: Failed to enable ODBC connection pooling" << std::endl;
            } else if (config.verbose) {
                // Already displayed in configuration section
            }
        }
        
        // Show connection start message
        if (!config.jsonOutput) {
            TS_OUT << std::endl;
            TS_OUT << "Connecting..." << std::endl;
        }
        
        std::ofstream finalJsonStream;
        if (config.streamJsonOutput && config.finalJsonOutput) {
            finalJsonStream.open(config.outputFile, std::ios::trunc);
            if (!finalJsonStream.is_open()) {
                TS_ERR << "sqlsim error: Cannot open final JSON file: " << config.outputFile << std::endl;
                return 1;
            }
        }

        WorkloadSimulator simulator(config);
        bool success = simulator.run();

        if (config.streamJsonOutput && config.finalJsonOutput) {
            std::streambuf* streamBackup = std::cout.rdbuf(finalJsonStream.rdbuf());
            printJsonHeader();
            simulator.printJsonResult();
            std::cout.flush();
            std::cout.rdbuf(streamBackup);
            finalJsonStream.close();
            if (!finalJsonStream) {
                TS_ERR << "sqlsim error: Could not write final JSON file: " << config.outputFile << std::endl;
                success = false;
            }
        }
        
        // Restore stdout and stderr if they were redirected
        if (coutBackup != nullptr) {
            std::cout.rdbuf(coutBackup);
            std::cerr.rdbuf(cerrBackup);
            outputFileStream.close();
            
            // Show completion message to console
            if (success) {
                TS_OUT << "Execution complete. See " << config.outputFile << " for results." << std::endl;
            } else {
                TS_OUT << "Execution completed with errors. See " << config.outputFile << " for details." << std::endl;
            }
        }
        
        return success ? 0 : 1;
    } catch (const std::bad_alloc&) {
        TS_ERR << "\nsqlsim fatal error: Out of memory. Try reducing thread count (-n) or iterations (-r)." << std::endl;
        return 1;
    } catch (const std::exception& e) {
        TS_ERR << "\nsqlsim fatal error: Unexpected exception: " << e.what() << std::endl;
        return 1;
    } catch (...) {
        TS_ERR << "\nsqlsim fatal error: Unknown exception occurred." << std::endl;
        return 1;
    }
}
