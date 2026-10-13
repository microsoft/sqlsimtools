#include "platform_termination.h"

#include <csignal>
#include <cstdlib>
#include <unistd.h>

namespace {

struct sigaction previousSigintAction {};
struct sigaction previousSigtermAction {};

void terminationHandler(int signalNumber) {
    constexpr char message[] = "\nReceived termination signal - exiting immediately...\n";
    const ssize_t bytesWritten = write(STDERR_FILENO, message, sizeof(message) - 1);
    static_cast<void>(bytesWritten);
    std::_Exit(128 + signalNumber);
}

} // namespace

namespace sqlsim::platform {

void installTerminationHandlers() {
    struct sigaction action {};
    action.sa_handler = terminationHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(SIGINT, &action, &previousSigintAction);
    sigaction(SIGTERM, &action, &previousSigtermAction);
}

void uninstallTerminationHandlers() {
    sigaction(SIGINT, &previousSigintAction, nullptr);
    sigaction(SIGTERM, &previousSigtermAction, nullptr);
}

} // namespace sqlsim::platform