#pragma once

#include <cerrno>
#include <string>
#include <system_error>

#ifdef _WIN32
#include <filesystem>
#endif

/**
 * Explains why a file could not be opened, for messages such as
 * "Cannot open input file: <path> (<reason>)".
 *
 * Set errno to 0 before the open, capture it immediately after the open
 * fails, and pass the captured value here.
 */
inline std::string describeFileOpenFailure([[maybe_unused]] const std::string& path, int savedErrno) {
#ifdef _WIN32
    // sqlsim is not long-path aware, so Windows rejects a full path longer than
    // 259 characters but reports it as "path not found". Name the real cause.
    constexpr size_t maxPathLength = 259;
    if (path.rfind("\\\\?\\", 0) != 0) {
        std::error_code pathError;
        const auto fullPath = std::filesystem::absolute(path, pathError);
        const size_t length = pathError ? path.size() : fullPath.native().size();
        if (length > maxPathLength) {
            return "the full path is " + std::to_string(length) + " characters; Windows allows " +
                   std::to_string(maxPathLength) + " unless the path starts with \\\\?\\";
        }
    }
#endif
    if (savedErrno == 0) {
        return "the operating system did not report a reason";
    }
    // MSVC reports "no such file or directory", glibc "No such file or directory".
    std::string reason = std::generic_category().message(savedErrno);
    if (!reason.empty() && reason[0] >= 'a' && reason[0] <= 'z') {
        reason[0] = static_cast<char>(reason[0] - 'a' + 'A');
    }
    return reason;
}
