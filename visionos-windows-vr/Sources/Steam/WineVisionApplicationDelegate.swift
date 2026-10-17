// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Reconnect the system-owned download session before background transfer
/// callbacks arrive, including when visionOS relaunches the app for them.
final class WineVisionApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SteamBackgroundTransfers.shared.prepare()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if !SteamBackgroundTransfers.shared.handleEvents(identifier: identifier, completionHandler: completionHandler) {
            completionHandler()
        }
    }
}
