//
//  DJApp.swift
//  DJ
//

import SwiftUI
import UIKit
import MusicKit   // Needed for MusicAuthorization.request()

@main
struct DJApp: App {

    // MARK: - State Objects
    @StateObject private var ws = WebSocketManager(url: URL(string: WS_URL)!)
    @StateObject private var friendStore = FriendStore()

    // ✅ Add this line
    @Environment(\.scenePhase) private var scenePhase

    // ✅ Keep the app delegate hook
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

     
    var body: some Scene {
        WindowGroup {
            SessionRootView(ws: ws)
                .environmentObject(MusicManager.shared)
                .environmentObject(friendStore)
                .onAppear {
                    ws.connect()

                    Task {
                        // 1) Ask for Apple Music permission (iOS 15+)
                        if #available(iOS 15.0, *) {
                            //talya debug 3 5 line comment
//                            let status = await MusicAuthorization.request()
//                            guard status == .authorized else {
//                                print("🚫 MusicAuthorization denied: \(status)")
//                                return
//                            }
                        } else {
                            print("ℹ️ MusicAuthorization requires iOS 15+")
                        }

                        // 2) Fetch developer token from your unified Node server
                        //    (kept for future web-service calls and newer SDKs;
                        //     safe to fetch even if your SDK doesn’t need configure()).
                        do {
                            _ = try await TokenService.shared.fetchDeveloperToken()
                            print("✅ Developer token fetched")
                        } catch {
                            print("❌ Dev token fetch failed:", error.localizedDescription)
                        }
                    }

                    // Seed FriendStore immediately from cached friends
                    let mapped = ws.friends.map { Friend(id: $0.id, displayName: $0.displayName) }
                    friendStore.setFriends(mapped)
                }
            
            
            
    
//                .onChange(of: scenePhase) { phase in
//                    switch phase {
//                    case .inactive, .background:
//                        // ✅ always silence playback when leaving foreground
//                        //Task { @MainActor in MusicManager.shared.stopAllPlayback() }
//                        // (Optional) also end any DJ/follow session and socket:
//                        // ws.setDJ(on: false)
//                        // ws.unfollow()
//                        // ws.disconnect()
//                    default:
//                        break
//                    }
//                }

                // Keep FriendStore in sync with server updates
                .onReceive(ws.$friends) { list in
                    let mapped = list.map { Friend(id: $0.id, displayName: $0.displayName) }
                    friendStore.setFriends(mapped)
                    print("👥 friends -> \(mapped.map { $0.displayName })")
                }

                // Deep link: DJ://addfriend?id=<userId>
                .onOpenURL { url in
                    guard url.scheme == "DJ", url.host == "addfriend",
                          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let id = comps.queryItems?.first(where: { $0.name == "id" })?.value
                    else { return }
                    ws.sendAddFriend(friendId: id)
                    ws.sendListFriends() // refresh right away
                }
        }
    }

    // Optional manual deep-link handler
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "DJ", url.host == "addfriend" else { return }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { return }
        friendStore.addFriend(id: id)
    }
}
