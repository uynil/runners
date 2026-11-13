import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class PhoneStore: ObservableObject {
    @Published private(set) var routes: [PlannedRoute] = []
    @Published var error: String?
    @Published private(set) var libraryAvailable = true
    private let library: RouteLibrary

    init() {
        library = RouteLibrary(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runners/routes.json"))
        reload()
    }

    func reload() {
        do { routes = try library.load(); libraryAvailable = true }
        catch { libraryAvailable = false; self.error = "无法读取线路库。原文件已保留。\(error.localizedDescription)" }
    }

    func save(_ next: [PlannedRoute]) {
        guard libraryAvailable else { error = "请先恢复线路库读取，避免覆盖原文件。"; return }
        do { try library.save(next); routes = next }
        catch { self.error = "保存失败，原有线路未修改。\(error.localizedDescription)" }
    }

    func update(_ route: PlannedRoute) {
        save(routes.map { $0.id == route.id ? route : $0 })
    }

    static let importTypes: [UTType] = [UTType(filenameExtension: "gpx"), UTType(filenameExtension: "kml"), .xml].compactMap { $0 }

    nonisolated static func readFile(_ url: URL) throws -> [PlannedRoute] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let stream = InputStream(url: url)
        guard let stream else { throw RouteImportError.invalid("无法打开所选文件。") }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? RouteImportError.invalid("文件读取失败。") }
            if count == 0 { break }
            guard data.count + count <= RouteImporter.maximumBytes else {
                throw RouteImportError.invalid("文件超过 10 MB，请先拆分线路。")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try RouteImporter.read(data, sourceName: url.lastPathComponent)
    }
}
