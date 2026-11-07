import Foundation
import WidgetKit

actor QueueWidgetPublisher {
    static let shared = QueueWidgetPublisher()
    private var lastSnapshot: QueueSnapshot?

    func update(_ snapshot: QueueSnapshot) {
        guard lastSnapshot != snapshot else { return }
        do {
            try QueueSnapshotStore.write(snapshot)
            lastSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: QueueSnapshot.kind)
        } catch {
            // Keep app playback usable when a signer removes the widget's group.
            // The widget shows an "Open Stream Anime" state without shared data.
        }
    }
}
