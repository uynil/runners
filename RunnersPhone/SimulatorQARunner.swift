#if DEBUG && targetEnvironment(simulator)
import Foundation

/// CLI smoke scenarios for the paired simulator. No fixture data or network requests are added here.
@MainActor
enum SimulatorQARunner {
    static func run(watch: WatchConnection, maps: OfflineMapStore) async {
        let args = ProcessInfo.processInfo.arguments
        guard let action = args.first(where: { ["--qa-map-sync", "--qa-map-remove", "--qa-activity-receive"].contains($0) }),
              let offset = args.firstIndex(of: action), args.indices.contains(offset + 1),
              let id = UUID(uuidString: args[offset + 1]) else { return }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-qa-result.json")
        func finish(_ passed: Bool, _ message: String) {
            let result: [String: Any] = ["action": action, "mapID": id.uuidString, "passed": passed,
                                         "message": message, "at": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        for _ in 0..<150 {
            if watch.activated && watch.paired && watch.installed && watch.reachable { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard watch.activated && watch.paired && watch.installed && watch.reachable else {
            finish(false, "配对会话未就绪"); return
        }
        if action == "--qa-activity-receive" {
            for _ in 0..<300 {
                if let entry = watch.activities.entries.first(where: { $0.id == id }),
                   let encoded = try? ActivityStorage.encode(entry.archive), MapBundleStorage.digest(encoded) == entry.receipt.checksum {
                    finish(true, "手机实际活动归档落盘、校验且仅一条历史"); return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finish(false, watch.activities.error ?? "活动接收超时")
        } else if action == "--qa-map-sync" {
            guard let bundle = maps.bundles[id], let raw = try? MapBundleStorage.encode(bundle) else {
                finish(false, "缺少有效本地地图"); return
            }
            let checksum = MapBundleStorage.digest(raw)
            watch.send(bundle)
            for _ in 0..<300 {
                if watch.receipts[id]?.checksum == checksum { finish(true, "Watch 当前包落盘校验回执匹配"); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finish(false, watch.status(for: bundle))
        } else {
            guard watch.receipts[id] != nil else { finish(false, "缺少表端地图回执"); return }
            watch.removeFromWatch(id)
            for _ in 0..<300 {
                if watch.receipts[id] == nil { finish(true, "Watch 移除回执及清单已更新"); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finish(false, watch.removals[id] ?? "移除未确认")
        }
    }
}
#endif
