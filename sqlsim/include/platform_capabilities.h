#pragma once

#if (defined(SQLSIM_PLATFORM_WINDOWS) + defined(SQLSIM_PLATFORM_LINUX) + defined(SQLSIM_PLATFORM_MACOS)) != 1
#error "Exactly one SQLSIM_PLATFORM_* definition is required"
#endif

namespace sqlsim::platform {

constexpr const char* name() {
#if defined(SQLSIM_PLATFORM_WINDOWS)
    return "Windows";
#elif defined(SQLSIM_PLATFORM_LINUX)
    return "Linux";
#else
    return "macOS";
#endif
}

constexpr bool supportsEntraInteractive() {
#if defined(SQLSIM_PLATFORM_WINDOWS)
    return true;
#else
    return false;
#endif
}

constexpr bool usesKerberosForTrustedConnection() {
#if defined(SQLSIM_PLATFORM_WINDOWS)
    return false;
#else
    return true;
#endif
}

} // namespace sqlsim::platform