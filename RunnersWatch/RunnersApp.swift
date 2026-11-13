import SwiftUI

@main
struct RunnersApp: App {
    @StateObject private var recorder = WorkoutRecorder()
    @StateObject private var maps = WatchMapReceiver()

    var body: some Scene {
        WindowGroup {
            NavigationStack { ContentView() }.ignoresSafeArea().environmentObject(recorder).environmentObject(maps).environmentObject(maps.activities)
                .onChange(of: recorder.phase != .idle && recorder.phase != .finished, initial: true) { _, protected in
                    maps.setActivityProtected(protected)
                    if !protected {
                        recorder.updateSelectedRoute(from: maps.bundles)
                        maps.syncActivities()
                    }
                }
                .onReceive(maps.$bundles) { bundles in
                    recorder.updateSelectedRoute(from: bundles)
                }
        }
    }
}
