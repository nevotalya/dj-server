//
//  AppDelegate.swift.swift
//  DJ
//
//  Created by talya on 16/10/2025.
//

// AppDelegate.swift (new tiny file)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        Task { @MainActor in MusicManager.shared.stopAllPlayback() }
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { @MainActor in MusicManager.shared.stopAllPlayback() }
    }
}
