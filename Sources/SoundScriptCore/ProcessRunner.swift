import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// stdout ve stderr'i aynı anda boşaltır. Sırayla okumak, stderr tamponu
/// dolduğunda prosesin kilitlenmesine yol açıyordu (özellikle yt-dlp/ffmpeg).
enum ProcessRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdin: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdin = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdin = nil
        }

        try process.run()

        let outReader = PipeReader(stdout.fileHandleForReading, onChunk: onStdout)
        let errReader = PipeReader(stderr.fileHandleForReading, onChunk: onStderr)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outReader.read()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errReader.read()
            group.leave()
        }

        if let input, let stdin {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        group.wait()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: outReader.data,
            stderr: errReader.data
        )
    }
}

private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var storage = Data()
    private let onChunk: (@Sendable (Data) -> Void)?

    init(_ handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
        self.handle = handle
        self.onChunk = onChunk
    }

    /// Veri geldiği anda okur: çağıran, süreç çalışırken ilerleme görebilsin.
    func read() {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            lock.lock()
            storage.append(chunk)
            lock.unlock()
            onChunk?(chunk)
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
