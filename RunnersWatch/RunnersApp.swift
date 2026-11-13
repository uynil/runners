import SwiftUI
import WatchKit

@MainActor
final class RunnersWatchDelegate: NSObject, WKApplicationDelegate {
    let recorder = WorkoutRecorder()

    func handleActiveWorkoutRecovery() { recorder.recoverIfNeeded() }
}

@main
struct RunnersApp: App {
    @WKApplicationDelegateAdaptor(RunnersWatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var maps = WatchMapReceiver()

    var body: some Scene {
        let recorder = delegate.recorder
        return WindowGroup {
            NavigationStack { ContentView() }.ignoresSafeArea().environmentObject(recorder).environmentObject(maps).environmentObject(maps.activities)
                .task { recorder.recoverIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { recorder.recoverIfNeeded() }
                }
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
