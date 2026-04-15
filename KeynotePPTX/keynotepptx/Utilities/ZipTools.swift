import Foundation

enum ZipTools {

    static func unzip(archive: URL, to destination: URL) async throws {
        try await runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-q", "-o", archive.path, "-d", destination.path]
        )
    }

    /// Rezip a directory into a ZIP archive.
    /// Uses /usr/bin/zip with currentDirectoryURL so paths inside the archive
    /// are relative (no __MACOSX resource-fork directories that corrupt PPTX).
    static func rezip(directory: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        try await runProcess(
            executable: "/usr/bin/zip",
            arguments: ["-r", "-q", output.path, "."],
            cwd: directory
        )
    }

    // MARK: - Private

    private static func runProcess(
        executable: String,
        arguments: [String],
        cwd: URL? = nil
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }

            let errPipe = Pipe()
            process.standardError = errPipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: ZipError.failed("\(executable): \(msg)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum ZipError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let msg) = self { return msg }
            return nil
        }
    }
}
