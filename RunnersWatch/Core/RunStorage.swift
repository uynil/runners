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
        guard !FileManager.default.fileExists(atPath: samples.path),
              FileManager.default.createFile(atPath: samples.path, contents: nil) else {
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

    /// Reopen, never recreate, the original sample file. Replay persisted counters
    /// because a batch may have reached disk after the last atomic summary.
    func reopen(_ summary: RunSummary, asOf now: Date) throws -> (summary: RunSummary, lastSampleAt: Date) {
        let folder = baseURL.appendingPathComponent(summary.id.uuidString, isDirectory: true)
        let samplesURL = folder.appendingPathComponent("samples.ndjson")
        let size = try samplesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: samplesURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var restored = summary, lastDate = summary.startedAt
        var gpsCount = 0, heart = WorkoutMetrics()
        var completeLength = data.count, discardedTail: Data?
        let lines = data.split(separator: 0x0A)
        for (index, line) in lines.enumerated() {
            let sample: RunSample
            do { sample = try decoder.decode(RunSample.self, from: Data(line)) }
            catch {
                // A crash during append may leave only the final record incomplete.
                guard index == lines.count - 1, data.last != 0x0A else { throw error }
                discardedTail = Data(line)
                completeLength = data.count - line.count
                break
            }
            if sample.timestamp <= now, sample.kind != "gps" || sample.acceptedForDistance == true {
                lastDate = max(lastDate, sample.timestamp)
            }
            if sample.kind == "gps" {
                gpsCount += 1
                if let distance = sample.cumulativeDistanceMeters, distance.isFinite {
                    restored.distanceMeters = max(restored.distanceMeters, distance)
                }
            } else if sample.kind == "heartRate", let rate = sample.heartRate { heart.recordHeartRate(rate) }
        }
        restored.gpsSampleCount = max(summary.gpsSampleCount, gpsCount)
        if heart.heartRateCount > summary.heartSampleCount {
            restored.heartSampleCount = heart.heartRateCount
            if restored.metrics == nil { restored.metrics = WorkoutMetrics() }
            restored.metrics?.heartRateCount = heart.heartRateCount
            restored.metrics?.heartRateSum = heart.heartRateSum
            restored.metrics?.maximumHeartRate = heart.maximumHeartRate
        }
        try handle?.close()
        let reopened = try FileHandle(forWritingTo: samplesURL)
        if let discardedTail {
            let backup = folder.appendingPathComponent("interrupted-sample-\(UUID().uuidString).partial")
            try discardedTail.write(to: backup, options: .atomic)
            try reopened.truncate(atOffset: UInt64(completeLength))
        }
        try reopened.seekToEnd()
        if completeLength > 0, data[completeLength - 1] != 0x0A { try reopened.write(contentsOf: Data([0x0A])) }
        handle = reopened; runURL = folder
        pending = Data(); bufferedSamples = 0
        return (restored, lastDate)
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
