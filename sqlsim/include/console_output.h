#pragma once

#include <iostream>
#include <mutex>
#include <sstream>
#include <string>

/**
 * Serializes every write to std::cout and std::cerr.
 *
 * Both streams share one lock because -o points them at the same file
 * buffer. Callers format text in a private stream first, so the lock is held
 * only for the write itself and the shared streams' formatting state (such as
 * std::fixed and std::setprecision) is never changed.
 */
class ConsoleOutput {
public:
    static void write(std::ostream& target, const std::string& text, bool flush = false) {
        std::lock_guard<std::mutex> lock(mutex());
        target.write(text.data(), static_cast<std::streamsize>(text.size()));
        if (flush) {
            target.flush();
        }
    }

    static void flush() {
        std::lock_guard<std::mutex> lock(mutex());
        std::cerr.flush();
        std::cout.flush();
    }

private:
    static std::mutex& mutex() {
        static std::mutex consoleMutex;
        return consoleMutex;
    }
};

/**
 * One console message built in a private stream.
 *
 * Formatting manipulators affect only this message. The complete text is
 * written in one locked operation when the message is destroyed, which for a
 * temporary such as ConsoleMessage(std::cout) << ... is the end of the
 * statement. std::endl and std::flush request a flush after the write.
 */
class ConsoleMessage {
public:
    explicit ConsoleMessage(std::ostream& target) : target_(target) {}

    ConsoleMessage(const ConsoleMessage&) = delete;
    ConsoleMessage& operator=(const ConsoleMessage&) = delete;

    ~ConsoleMessage() {
        try {
            ConsoleOutput::write(target_, buffer_.str(), flush_);
        } catch (...) {
            // A destructor must not throw; a failed console write is dropped.
        }
    }

    template <typename T>
    ConsoleMessage& operator<<(const T& value) {
        buffer_ << value;
        return *this;
    }

    ConsoleMessage& operator<<(std::ostream& (*manip)(std::ostream&)) {
        using Manipulator = std::ostream& (*)(std::ostream&);
        if (manip == static_cast<Manipulator>(std::endl<char, std::char_traits<char>>) ||
            manip == static_cast<Manipulator>(std::flush<char, std::char_traits<char>>)) {
            flush_ = true;
        }
        manip(buffer_);
        return *this;
    }

    ConsoleMessage& operator<<(std::ios_base& (*manip)(std::ios_base&)) {
        manip(buffer_);
        return *this;
    }

private:
    std::ostream& target_;
    std::ostringstream buffer_;
    bool flush_ = false;
};
