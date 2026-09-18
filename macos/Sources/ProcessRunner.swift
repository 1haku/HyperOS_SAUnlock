import Foundation
import Darwin

enum ProcessRunError: Error, CustomStringConvertible {
    case timedOut(TimeInterval)
    case io(String, Int32)

    var description: String {
        switch self {
        case .timedOut(let seconds):
            return "ADB command timed out after \(seconds) seconds."
        case .io(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

enum ProcessRunner {
    static func run(executable: String, arguments: [String],
                    timeout: TimeInterval = 30) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let readers = [output.fileHandleForReading, errors.fileHandleForReading]
        defer {
            readers.forEach { $0.closeFile() }
            output.fileHandleForWriting.closeFile()
            errors.fileHandleForWriting.closeFile()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        for reader in readers {
            let descriptor = reader.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw ProcessRunError.io("Pipe setup", errno)
            }
        }
        try process.run()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()

        var descriptors = readers.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        var data = [Data(), Data()]
        var truncated = [false, false]
        let outputLimit = 1_048_576
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        var killed = false

        // Drain both pipes while the process runs. Nonblocking reads also bound the
        // wait when a subprocess inherits a pipe and keeps it open after ADB exits.
        while process.isRunning || descriptors.contains(where: { $0.fd >= 0 }) {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline {
                if !timedOut {
                    timedOut = true
                    if process.isRunning { process.terminate() }
                }
                if now >= deadline + 0.5, !killed {
                    killed = true
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                if !process.isRunning || now >= deadline + 1 { break }
            }
            let count = poll(&descriptors, nfds_t(descriptors.count), 50)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProcessRunError.io("Pipe polling", errno)
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 {
                let events = descriptors[index].revents
                if events & Int16(POLLNVAL) != 0 {
                    throw ProcessRunError.io("Pipe descriptor", EBADF)
                }
                guard events & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
                let bytes = read(descriptors[index].fd, &buffer, buffer.count)
                if bytes == 0 {
                    descriptors[index].fd = -1
                } else if bytes > 0 {
                    let kept = min(bytes, outputLimit - data[index].count)
                    data[index].append(contentsOf: buffer.prefix(kept))
                    truncated[index] = truncated[index] || kept < bytes
                } else if errno != EAGAIN && errno != EINTR {
                    throw ProcessRunError.io("Pipe read", errno)
                }
            }
        }
        if timedOut { throw ProcessRunError.timedOut(timeout) }
        process.waitUntilExit()
        let text = data.indices.map {
            String(decoding: data[$0], as: UTF8.self) + (truncated[$0] ? "\n[Output truncated]" : "")
        }
        return CommandResult(status: process.terminationStatus, stdout: text[0], stderr: text[1])
    }
}
