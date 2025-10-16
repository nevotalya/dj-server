//
//  Models.swift
//  DJ
//
//  Created by talya on 10/10/2025.
//

import Foundation

// Server user snapshot
struct UserInfo: Identifiable, Codable {
    var id: String
    var displayName: String
    var isDJ: Bool
    var listeningTo: String?
    var lastSeen: String?
}

// Outgoing / incoming payloads
struct PresencePayload: Codable {
    var id: String
    var displayName: String
    var isDJ: Bool
    var listeningTo: String?
    var lastSeen: String
}

struct StartStopDJPayload: Codable { var id: String }

struct JoinDJPayload: Codable {
    var listenerId: String
    var djId: String
}

struct UserListPayload: Codable { var users: [UserInfo] }

struct ErrorPayload: Codable { var message: String }

// Playback (used later with MusicKit; safe to keep now)
struct PlaybackPayload: Codable {
    var trackId: String       // Apple Music catalog id (future)
    var position: Double      // seconds into track
    var isPlaying: Bool
    var serverTime: String    // server stamps seconds; we store as String for lenience
}

// Clock sync (NTP-like)
struct ClockSyncRequestPayload: Codable { let clientSend: Double }
struct ClockSyncResponsePayload: Codable {
    let clientSend: Double
    let serverReceive: Double
    let serverSend: Double
}

// Simple friend type for Manage Friends UI
//struct Friend: Identifiable, Equatable {
//    let id: String
//    let displayName: String
//}
