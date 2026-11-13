import Foundation

struct NavigationSettings: Codable, Equatable {
    static let key = "runnersNavigationSettings"
    var version = UUID()
    var junctionHaptics = true
    var offRouteHaptics = true

    static func load() -> Self? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}

struct MapReceipt: Codable {
    let routeID: UUID
    let checksum: String
    let receivedAt: Date
    var routeName: String? = nil
}

struct MapStorageReport: Codable {
    let mapBytes: Int64
    let availableBytes: Int64?
    let reportedAt: Date
    var supportedMapSchema: Int? = nil
}

struct MapRemovalCommand: Codable, Identifiable {
    var id = UUID()
    let mapID: UUID
    let expectedChecksum: String
}

struct MapRemovalReceipt: Codable {
    let commandID: UUID
    let mapID: UUID
    let removed: Bool
    let message: String
}

struct MapRemovalQueue: Codable {
    var pending: [MapRemovalCommand] = []
    var results: [MapRemovalReceipt] = []
    mutating func apply(to storage: MapBundleStorage, activityProtected: Bool) throws {
        guard !activityProtected else { return }
        for command in pending {
            let url = storage.fileURL(command.mapID)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let matches = try !exists || MapBundleStorage.digest(Data(contentsOf: url)) == command.expectedChecksum
            if matches, exists { try storage.remove(command.mapID) }
            results.removeAll { $0.commandID == command.id }
            results.append(MapRemovalReceipt(commandID: command.id, mapID: command.mapID, removed: matches,
                message: matches ? "已从 Watch 移除" : "Watch 上地图版本已改变，未执行删除"))
        }
        pending = []
        results = Array(results.suffix(20))
    }
    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
