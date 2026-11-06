import SwiftUI
import UIKit

@MainActor enum OrientationPolicy {
    static var mask: UIInterfaceOrientationMask = .portrait
    static func restorePortrait() {
        mask = .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

@MainActor final class PlayerAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { OrientationPolicy.mask }
}

struct LandscapePlayback: UIViewControllerRepresentable {
    let request: PlaybackRequest
    let library: LibraryStore
    let close: () -> Void
    func makeUIViewController(context: Context) -> LandscapeHostingController {
        LandscapeHostingController(rootView: PlaybackScreen(request: request, library: library, close: close))
    }
    func updateUIViewController(_ controller: LandscapeHostingController, context: Context) {}
}

final class LandscapeHostingController: UIHostingController<PlaybackScreen> {
    private weak var playbackScene: UIWindowScene?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationPolicy.mask = .landscape
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playbackScene = view.window?.windowScene
        playbackScene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        playbackScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        OrientationPolicy.mask = .portrait
        playbackScene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        playbackScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
}
