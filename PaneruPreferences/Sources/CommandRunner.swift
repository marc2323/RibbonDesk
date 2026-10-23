import Foundation

private final class CommandOutput: @unchecked Sendable {
    // One writer, read only after the dispatch group has completed.
    var data = Data()
}

enum CommandRunner {
    static func run(_ arguments: [String], executable: String, timeout: Double) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Drain while the child runs. A long ribbon's state can exceed the pipe
        // buffer and otherwise deadlock before the process can exit.
        let collected = CommandOutput()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            collected.data = output.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw CommandFailure(message: "Paneru did not respond in time.")
        }
        reader.wait()
        let text = String(decoding: collected.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandFailure(message: String(text.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
