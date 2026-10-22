import Foundation
import Darwin

enum PrivateLogs {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Paneru")
    }

    // Open relative to a verified directory. O_NONBLOCK prevents a precreated
    // FIFO from hanging startup; only single-link regular files are accepted.
    static func prepare(in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw posixError() }
        defer { close(dir) }
        try validate(dir, directory: true)
        for name in ["stdout.log", "stderr.log"] {
            let file = openat(dir, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
            guard file >= 0 else { throw posixError() }
            defer { close(file) }
            try validate(file, directory: false)
        }
    }

    private static func validate(_ descriptor: Int32, directory: Bool) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        let expected = directory ? S_IFDIR : S_IFREG
        guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == expected,
              directory || metadata.st_nlink == 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        guard fchmod(descriptor, directory ? 0o700 : 0o600) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
