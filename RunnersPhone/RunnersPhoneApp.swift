import SwiftUI

@main
struct RunnersPhoneApp: App {
    @StateObject private var store = PhoneStore()
    @StateObject private var watch = WatchConnection()
    @StateObject private var maps = OfflineMapStore()
    @StateObject private var strava = StravaStore()
    var body: some Scene {
        WindowGroup {
            PhoneContentView().environmentObject(store).environmentObject(watch).environmentObject(maps).environmentObject(watch.activities)
                .environmentObject(strava)
                .tint(.green)
                #if DEBUG && targetEnvironment(simulator)
                .task { await SimulatorQARunner.run(watch: watch, maps: maps) }
                #endif
        }
    }
}
