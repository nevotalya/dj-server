//
//  MessageTypes.swift
//  DJ
//
//  Created by talya on 10/10/2025.
//

import Foundation

public enum MessageType: String, Codable {
    case presenceUpdate
    case joinDJ
    case leaveDJ
    case startDJ
    case identify
    case stopDJ
    case updateProfile
    case playbackUpdate
    case playback
    case userList
    case error
    case clockSyncRequest
    case clockSyncResponse
    case clockPing
    case clockPong
    case addFriendPair
    case friendAdded
    case friendsList
}

// Generic typed envelope
public struct WSMessage<Payload: Encodable>: Encodable {
    public let type: MessageType
    public let payload: Payload
}

// Minimal container used to peek the type before decoding payload
public struct WSMessageContainer: Decodable {
    public let type: MessageType
}

// Reply payload
//struct ClockPong: Codable {
//    let clientTime: Double
//    let serverTime: Double
//}

//struct ClockPongEnvelope: Codable {
//    let type: MessageType
//    let payload: ClockPong
//}
