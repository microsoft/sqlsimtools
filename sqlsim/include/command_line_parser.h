#pragma once

#include <string>
#include <vector>
#include "workload_simulator.h"

/// @brief Result of command line parsing operation
struct ParseResult {
    bool success;
    std::string errorMessage;
    bool shouldShowHelp;
    bool showVersionOnly;
    
    ParseResult() : success(true), shouldShowHelp(false), showVersionOnly(false) {}
    ParseResult(bool showHelp, bool versionOnly = false) : success(true), shouldShowHelp(showHelp), showVersionOnly(versionOnly) {}
    
    static ParseResult error(const std::string& message) {
        ParseResult result;
        result.success = false;
        result.errorMessage = message;
        result.shouldShowHelp = false;
        result.showVersionOnly = false;
        return result;
    }
};

/// @brief Handles command line parameter parsing for sqlsim
class CommandLineParser {
public:
    /// @brief Parse command line arguments
    /// @param argc Argument count
    /// @param argv Argument values
    /// @param config Output: Populated workload configuration
    /// @return ParseResult indicating success/failure and any error messages
    ParseResult parse(int argc, char* argv[], WorkloadConfig& config);

private:
    // Parameter extraction and validation helpers
    std::string getParamValue(int& index, char* argv[], int argc, 
                             const std::string& currentArg, 
                             const std::string& flag);
    
    bool validateConnectionString(const std::string& value, std::string& errorMsg);
    bool validateServerName(const std::string& value, std::string& errorMsg);
    bool validateDatabaseName(const std::string& value, std::string& errorMsg);
    bool validateUsername(const std::string& value, std::string& errorMsg);
    bool validatePassword(const std::string& value, std::string& errorMsg);
    bool validateAccessToken(const std::string& value, std::string& errorMsg);
    bool validateFilePath(const std::string& value, std::string& errorMsg);
    bool validateQuery(const std::string& value, std::string& errorMsg);
    bool validateAppName(const std::string& value, std::string& errorMsg);
    bool validateHostname(const std::string& value, std::string& errorMsg);
    bool validateEncryptionLevel(const std::string& value, std::string& errorMsg);
    bool validateReplayMode(const std::string& value, std::string& errorMsg);
    bool validateReplayFile(const std::string& value, std::string& errorMsg);
    
    bool validateTimeout(const std::string& value, int& output, std::string& errorMsg);
    bool validateThreadCount(const std::string& value, int& output, std::string& errorMsg);
    bool validateIterations(const std::string& value, int& output, std::string& errorMsg);
    bool validateRetryCount(const std::string& value, int& output, std::string& errorMsg);
    bool validateRetryDelay(const std::string& value, int& output, std::string& errorMsg);
    
    // Connection string building
    std::string buildConnectionString(
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
        int connectRetryInterval);
    
    // Post-parsing validation
    bool validateConfiguration(
        const std::string& sqlServer,
        const std::string& accessToken,
        bool useIntegratedSecurity,
        const std::string& entraAuthType,
        const std::string& sqlUsername,
        const std::string& encryptionLevel,
        bool trustServerCertificate,
        const std::string& certificateHostname,
        const WorkloadConfig& config,
        std::string& errorMsg);
};
