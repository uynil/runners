import Foundation

/// Batches append-only samples; checkpoints contain metadata rather than rewriting the track.
final class RunStorage {
    private let baseURL: URL
    private var runURL: URL?
    private var handle: FileHandle?
    private var pending = Data()
    private var bufferedSamples = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runs", isDirectory: true)
    }

    deinit { try? handle?.close() }

    func begin(_ summary: RunSummary) throws {
        try handle?.close()
        let folder = baseURL.appendingPathComponent(summary.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = folder.appendingPathComponent("samples.ndjson")
        guard FileManager.default.createFile(atPath: samples.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: samples)
        runURL = folder
        pending = Data()
        bufferedSamples = 0
        try checkpoint(summary)
    }

    func append(_ sample: RunSample) throws {
        pending.append(try encoder.encode(sample))
        pending.append(0x0A)
        bufferedSamples += 1
        if bufferedSamples >= 12 { try flush() }
    }

    func checkpoint(_ summary: RunSummary) throws {
        guard let runURL else { throw CocoaError(.fileNoSuchFile) }
        try flush()
        try encoder.encode(summary).write(to: runURL.appendingPathComponent("summary.json"), options: .atomic)
        try handle?.synchronize()
    }

    func flush() throws {
        guard !pending.isEmpty else { return }
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        bufferedSamples = 0
    }

    func latestSummary() -> RunSummary? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let folders = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> RunSummary? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("summary.json")) else { return nil }
            return try? decoder.decode(RunSummary.self, from: data)
        }.max { $0.startedAt < $1.startedAt }
    }
}
