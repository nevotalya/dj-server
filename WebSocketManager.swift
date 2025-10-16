//
//  WebSocketManager.swift
//  DJ
//

import Foundation
import Combine

final class WebSocketManager: ObservableObject {
    // MARK: - Public state for UI
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var userId: String
    @Published var myDisplayName: String?
    @Published var onlineUsers: [UserInfo] = []
    @Published var friends: [UserInfo] = []
    @Published var followingDJId: String? = nil
    @Published var requiresName: Bool = false
    @Published var errors: String?

    enum ConnectionStatus: String { case disconnected, connecting, connected }

    // MARK: - Internal
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private let decoder = JSONDecoder()

    // local cache keys
    private let idKey = "userId.v1"
    private let nameKey = "displayName.v1"
    private let friendsKey = "friends.cache.v1"

    // MARK: - Clock sync publisher (for ClockSync.swift)
    private let clockPongSubject = PassthroughSubject<ClockPong, Never>()
    var clockPongPublisher: AnyPublisher<ClockPong, Never> {
        clockPongSubject.eraseToAnyPublisher()
    }

    // MARK: - Remote users (includes following)
    struct RemoteUser: Codable, Identifiable {
        let id: String
        let displayName: String
        let isDJ: Bool
        let following: String?
        let online: Bool
    }
    @Published var remoteUsersSnapshot: [RemoteUser] = []

    // MARK: - Init
    init(url: URL) {
        self.url = url

        if let saved = UserDefaults.standard.string(forKey: idKey) {
            self.userId = saved
        } else {
            let new = "user_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            self.userId = new
            UserDefaults.standard.set(new, forKey: idKey)
        }

        self.myDisplayName = UserDefaults.standard.string(forKey: nameKey)

        if let data = UserDefaults.standard.data(forKey: friendsKey),
           let list = try? JSONDecoder().decode([UserInfo].self, from: data) {
            self.friends = list
        }

        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    convenience init(urlString: String) { self.init(url: URL(string: urlString)!) }

    deinit {
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Connect / Reconnect
    func connect() {
        guard task == nil else { return }
        connectionStatus = .connecting

        let t = session.webSocketTask(with: url)
        task = t
        t.resume()

        receiveLoop()
        identifySelf()
        startHeartbeat()
    }

    func disconnect() {
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionStatus = .disconnected
    }

    
    @MainActor
    private func reconnect() {
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionStatus = .disconnected
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            connect()
        }
    }

    // Tell listeners to pause right now (final snapshot)
    @MainActor
    func sendPlaybackStopNow() {
        var p: [String: Any] = [
            "position": MusicManager.shared.currentPosition,
            "isPlaying": false,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let pid = MusicManager.shared.currentSongPID { p["songPID"] = UInt64(pid) }
        if let cid = MusicManager.shared.currentPlaybackStoreID, !cid.isEmpty {
            p["catalogSongId"] = cid
        }
        if let t = MusicManager.shared.currentTitle  { p["title"] = t }
        if let a = MusicManager.shared.currentArtist { p["artist"] = a }

        sendJSON(["type": "playback", "payload": p])
    }
    
    // MARK: - Heartbeat
    private func startHeartbeat() {
        stopHeartbeat()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.task?.sendPing { error in
                if let error = error {
                    print("WS ping error:", error.localizedDescription)
                    Task { @MainActor in self.reconnect() }
                } else {
                    Task { @MainActor in
                        if self.connectionStatus != .connected { self.connectionStatus = .connected }
                    }
                }
            }
        }
        if let pingTimer { RunLoop.main.add(pingTimer, forMode: .common) }
    }
    private func stopHeartbeat() { pingTimer?.invalidate(); pingTimer = nil }

    // MARK: - Raw send
    private func sendRawText(_ text: String) {
        guard let task else { return }
        task.send(.string(text)) { [weak self] err in
            if let err = err {
                print("❌ WS send error:", err.localizedDescription)
                DispatchQueue.main.async { self?.errors = err.localizedDescription }
            }
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8)
        else { print("❌ encode failed for", obj); return }
        sendRawText(text)
    }

    // MARK: - Identify / Profile
    private func identifySelf() {
        var payload: [String: Any] = ["id": userId]
        if let n = myDisplayName, !n.trimmingCharacters(in: .whitespaces).isEmpty {
            payload["displayName"] = n
        }
        sendJSON(["type": "identify", "payload": payload])
    }

    func sendSetName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendJSON(["type": "setName", "payload": ["displayName": trimmed]])
    }

    // MARK: - DJ / Follow
    func setDJ(on: Bool) {
        sendJSON(["type": "setDJ", "payload": ["on": on]])
        if !on {
                Task { @MainActor in
                    // Immediately pause my player and notify listeners to pause
                    //MusicManager.shared.pause()
                    self.sendPlaybackStopNow()
                }
            }
        
    }

    func follow(djId: String) {
        sendJSON(["type": "follow", "payload": ["djId": djId]])
        print("📤 follow → \(djId)")
    }

    func unfollow() {
        sendJSON(["type": "unfollow"])
        print("📤 unfollow")
    }

    // MARK: - Friends
    func sendAddFriend(friendId: String) { sendJSON(["type": "addFriend", "payload": ["friendId": friendId]]) }
    func sendListFriends()               { sendJSON(["type": "listFriends"]) }
    func sendListUsers()                 { sendJSON(["type": "listUsers"]) }

    // MARK: - Clock sync
    func sendClockPing() {
        let now = Date().timeIntervalSince1970
        sendJSON(["type": "clockPing", "payload": ["clientTime": now]])
    }

    // MARK: - Receive loop
    private func receiveLoop() {
        Task.detached { [weak self] in
            guard let self else { return }
            while let t = self.task {
                do {
                    let message = try await t.receive()
                    switch message {
                    case .string(let text):
                        Task { @MainActor in
                            if self.connectionStatus != .connected { self.connectionStatus = .connected }
                        }
                        self.handleServerText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleServerText(text)
                        }
                    @unknown default: break
                    }
                } catch {
                    print("❌ WS receive error:", error.localizedDescription)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self.reconnect()
                    return
                }
            }
        }
    }

    // MARK: - Incoming
    private func handleServerText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        let payload = json["payload"]

        switch type {
        case "hello":
            if let p = payload as? [String: Any],
               let displayName = p["displayName"] as? String {
                DispatchQueue.main.async {
                    self.myDisplayName = displayName
                    UserDefaults.standard.set(displayName, forKey: self.nameKey)
                    
                    // ✅ close the prompt
                    self.requiresName = false
                        
                }
            }
            sendListFriends()

        case "requireName":
            DispatchQueue.main.async { self.requiresName = true }

        case "users":
            if let arr = payload as? [[String: Any]] {
                let full: [RemoteUser] = arr.compactMap { d in
                    guard let id = d["id"] as? String,
                          let name = d["displayName"] as? String,
                          let isDJ = d["isDJ"] as? Bool else { return nil }
                    return RemoteUser(id: id,
                                      displayName: name,
                                      isDJ: isDJ,
                                      following: d["following"] as? String,
                                      online: (d["online"] as? Bool) ?? false)
                }
                let lite: [UserInfo] = full.map { UserInfo(id: $0.id, displayName: $0.displayName, isDJ: $0.isDJ) }
                DispatchQueue.main.async {
                    self.remoteUsersSnapshot = full
                    self.onlineUsers = lite
                    if let me = full.first(where: { $0.id == self.userId }) {
                        self.followingDJId = me.following
                    }
                }
            }

        case "friendsList":
            if let arr = payload as? [[String: Any]] {
                let list = arr.compactMap { d -> UserInfo? in
                    guard let id = d["id"] as? String else { return nil }
                    let name = (d["displayName"] as? String) ?? "(unnamed)"
                    return UserInfo(id: id, displayName: name, isDJ: false)
                }
                DispatchQueue.main.async {
                    self.friends = list
                    if let data = try? JSONEncoder().encode(list) {
                        UserDefaults.standard.set(data, forKey: self.friendsKey)
                    }
                }
            }

        case "playback":
            if let d = payload as? [String: Any] {
                let pos  = (d["position"] as? NSNumber)?.doubleValue ?? 0
                let play = (d["isPlaying"] as? Bool) ?? false
                let ts   = (d["timestamp"] as? NSNumber)?.doubleValue
                let spid = (d["songPID"] as? NSNumber)?.uint64Value
                let ppid = (d["playlistPID"] as? NSNumber)?.uint64Value

                let catalogId = d["catalogSongId"] as? String
                let title = d["title"] as? String
                let artist = d["artist"] as? String

                let update = PlaybackStateUpdate(
                    position: pos,
                    isPlaying: play,
                    serverTimestamp: ts,
                    songPID: spid,
                    playlistPID: ppid,
                    catalogSongId: catalogId,
                    title: title,
                    artist: artist
                )

                Task { @MainActor in
                    if let t = title  { MusicManager.shared.currentTitle = t }
                    if let a = artist { MusicManager.shared.currentArtist = a }
                    SyncCoordinator.shared.applyRemoteUpdate(update)
                }
            }

        case "clockPong":
            if let p = payload as? [String: Any] {
                let server = (p["serverTime"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
                let echo   = (p["echo"] as? NSNumber)?.doubleValue
                clockPongSubject.send(ClockPong(serverTime: server, echoClientTime: echo))
            }

        default:
            break
        }
    }
}

// MARK: - SyncOutbound
extension WebSocketManager: SyncOutbound {
    /// Touch MusicManager only on main actor to avoid actor-isolation warnings.
    @MainActor
    func sendPlayback(position: TimeInterval,
                      isPlaying: Bool,
                      songPID: UInt64?,
                      playlistPID: UInt64?) {
        var p: [String: Any] = [
            "position": position,
            "isPlaying": isPlaying,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let songPID     { p["songPID"] = songPID }
        if let playlistPID { p["playlistPID"] = playlistPID }

        // Prefer Apple Music catalog/store ID (from system player's nowPlayingItem.playbackStoreID on the DJ)
        if let cid = MusicManager.shared.currentPlaybackStoreID, !cid.isEmpty {
            p["catalogSongId"] = cid
        }
        // Nice-to-have UI metadata
        if let t = MusicManager.shared.currentTitle  { p["title"] = t }
        if let a = MusicManager.shared.currentArtist { p["artist"] = a }

        sendJSON(["type": "playback", "payload": p])
    }
}

// MARK: - ClockSync model
struct ClockPong {
    let serverTime: TimeInterval
    let echoClientTime: TimeInterval?
}
