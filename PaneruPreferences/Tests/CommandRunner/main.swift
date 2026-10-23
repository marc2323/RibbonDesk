import Foundation
struct CommandFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
let large = try CommandRunner.run(["-c", "print('x' * 1048576)"], executable: "/usr/bin/python3", timeout: 5)
precondition(large.utf8.count == 1048577, "Read output larger than the pipe buffer without deadlocking")
do {
    _ = try CommandRunner.run(["-c", "import sys; print('failed'); sys.exit(2)"], executable: "/usr/bin/python3", timeout: 5)
    preconditionFailure("Nonzero exit must throw")
} catch { precondition(error.localizedDescription == "failed") }
print("Command output checks passed")
