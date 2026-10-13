#include "platform_termination.h"

#include <cstdlib>
#include <windows.h>

namespace {

BOOL WINAPI consoleControlHandler(DWORD controlType) {
    switch (controlType) {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
            std::_Exit(130);
        default:
            return FALSE;
    }
}

} // namespace

namespace sqlsim::platform {

void installTerminationHandlers() {
    SetConsoleCtrlHandler(consoleControlHandler, TRUE);
}

void uninstallTerminationHandlers() {
    SetConsoleCtrlHandler(consoleControlHandler, FALSE);
}

} // namespace sqlsim::platform