// SimpleSessionViewModel.swift
// DJ

import Foundation
import Combine

@MainActor
final class SimpleSessionViewModel: ObservableObject {
    @Published var isDJ: Bool = false
    @Published var djs: [UserInfo] = []

    private let ws: WebSocketManager
    private var bag = Set<AnyCancellable>()
    private let me: String

    init(ws: WebSocketManager) {
        self.ws = ws
        self.me = ws.userId

        // Keep UI derived state in sync with server users list
        ws.$onlineUsers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] users in
                guard let self = self else { return }
                if let meUser = users.first(where: { $0.id == self.me }) {
                    self.isDJ = meUser.isDJ
                }
                self.djs = users.filter { $0.isDJ && $0.id != self.me }
            }
            .store(in: &bag)
    }

    // Toggle between DJ and Listener roles
    func toggleDJ() {
        if isDJ {
            // 1) Tell followers to pause immediately (while we're still a DJ)
            ws.sendPlaybackStopNow()
            // (tiny delay to ensure it goes out before we drop DJ state)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.ws.setDJ(on: false)
                SyncCoordinator.shared.stopBroadcasting()
                //MusicManager.shared.pause() // local safety pause
                self.isDJ = false
                print("🛑 stopDJ sent")
            }
        } else {
            // Start DJing
            isDJ = true
            ws.setDJ(on: true)
            SyncCoordinator.shared.startBroadcasting(outbound: ws)
            MusicManager.shared.enterDJMode() // ensure our app isn’t forcing listener playback
            print("🎧 startDJ sent")
        }
    }

    
    
    @MainActor func listen(to dj: UserInfo) {
        // Clear smoothing so the next snapshot is treated as "new track"
        SyncCoordinator.shared.resetForNewFollow()

        // Enter listener mode (clears queues/players)
        MusicManager.shared.enterListenerMode()

        // Then follow the DJ (server will broadcast a snapshot shortly)
        ws.follow(djId: dj.id)
    }

    @MainActor func stopListening() {
        ws.unfollow()

        // Reset and go back to DJ-read mode
        SyncCoordinator.shared.resetForNewFollow()
        MusicManager.shared.pause()   // stop immediately on this device
        MusicManager.shared.enterDJMode()
    }
    
    
    // Who is listening to me right now (based on server's snapshot)
    func listenersOfMe(ws: WebSocketManager) -> [UserInfo] {
        let myId = ws.userId
        return ws.remoteUsersSnapshot
            .filter { $0.following == myId }
            .map { UserInfo(id: $0.id, displayName: $0.displayName, isDJ: $0.isDJ) }
    }

    // Helper if you ever need to compute DJs from an arbitrary list
    func currentDJs(from users: [UserInfo]) -> [UserInfo] {
        users.filter { $0.isDJ && $0.id != me }
    }
}
