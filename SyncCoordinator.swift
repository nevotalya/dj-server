//
//  SyncCoordinator.swift
//  DJ
//
//  Hybrid sync coordinator:
//  - DJ: broadcast via WebSocketManager (adds catalogSongId/title/artist if present).
//  - Listener: prefer Apple Music catalog IDs; fall back to MediaPlayer persistentID.
//  - Adds hysteresis to avoid “hiccups” (too-frequent seek/play/pause).
//

import Foundation
import MediaPlayer

#if canImport(MusicKit)
import MusicKit
#endif

// Outbound interface (your WebSocketManager conforms)
protocol SyncOutbound: AnyObject {
    @MainActor func sendPlayback(position: TimeInterval,
                                 isPlaying: Bool,
                                 songPID: UInt64?,
                                 playlistPID: UInt64?)
}

// Snapshot sent from server (DJ → listeners)
struct PlaybackStateUpdate: Codable {
    let position: TimeInterval
    let isPlaying: Bool
    let serverTimestamp: TimeInterval?
    let songPID: UInt64?
    let playlistPID: UInt64?
    let catalogSongId: String?
    let title: String?
    let artist: String?
}

@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()
    private init() {}

    // MARK: - DJ broadcasting
    private weak var outbound: SyncOutbound?
    private var djTimer: Timer?

    // MARK: - Listener smoothing state
    private var lastAppliedSongPID: MPMediaEntityPersistentID?
    private var lastAppliedCatalogID: String?
    private var lastSeekTime: TimeInterval = 0
    private var lastPlayPauseChangeAt: TimeInterval = 0
    private var lastDesiredPlaying: Bool?

    // MARK: - Tuneables
    // Try to land a little ahead to counter latency on listeners.
    private let leadBias: TimeInterval = -0.25      // subtract from predicted DJ position (try 0.30–0.45)
    private let smallDrift: TimeInterval = 0.08    // ignore tiny drift
    private let broadcastInterval: TimeInterval = 0.5
    private let driftTolerance: TimeInterval   = 0.35
    private let minSeekInterval: TimeInterval  = 1.2
    private let minControlGap: TimeInterval    = 0.8

    // MARK: - Clock offset provider (serverTime - clientNow)
    private var clockOffsetProvider: () -> Double = { 0 }
    func configureClockOffsetProvider(_ provider: @escaping () -> Double) {
        clockOffsetProvider = provider
    }

    // MARK: - DJ: start/stop
    func startBroadcasting(outbound: SyncOutbound) {
        self.outbound = outbound
        djTimer?.invalidate()

        djTimer = Timer.scheduledTimer(withTimeInterval: broadcastInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mm = MusicManager.shared
            outbound.sendPlayback(
                position: mm.currentPosition,
                isPlaying: mm.isPlaying,
                songPID: mm.currentSongPID.map { UInt64($0) },
                playlistPID: mm.lastQueuedPlaylistPID.map { UInt64($0) }
            )
        }
        if let djTimer { RunLoop.main.add(djTimer, forMode: .common) }
    }

    // Call this whenever you begin following a DJ (or stop following)
    @MainActor
    func resetForNewFollow() {
        lastAppliedSongPID = nil
        lastAppliedCatalogID = nil
        lastDesiredPlaying = nil
        lastSeekTime = 0
        lastPlayPauseChangeAt = 0
    }
    
    func stopBroadcasting() {
        djTimer?.invalidate()
        djTimer = nil
        outbound = nil
    }

    // MARK: - Listener: apply remote snapshot
    func applyRemoteUpdate(_ u: PlaybackStateUpdate) {
        let mm   = MusicManager.shared
        let nowS = Date().timeIntervalSince1970
        let off  = clockOffsetProvider() // serverTime - clientNow

        // Predict DJ's "now" on this device and subtract a small bias.
        let correctedPos: TimeInterval = {
            guard let t = u.serverTimestamp else { return max(0, u.position - leadBias) }
            let elapsed = nowS - t - off
            return max(0, u.position + max(0, elapsed) - leadBias)
        }()

        // ====== 1) Preferred: Apple Music catalog ID path ======
        #if canImport(MusicKit)
        if let cid = u.catalogSongId, !cid.isEmpty, #available(iOS 16.0, *) {
            let nowAbs = CFAbsoluteTimeGetCurrent()

            // New track? Replace queue & line up once.
            if lastAppliedCatalogID != cid {
                lastAppliedCatalogID = cid
                lastAppliedSongPID = nil

                // ✅ Launch async MusicKit queue/prepare from non-async context.
                Task { @MainActor in
                    await mm.replaceQueueWithCatalogID(cid,
                                                       startAt: correctedPos,
                                                       autoplay: u.isPlaying)
                }

                lastSeekTime = nowAbs
                lastPlayPauseChangeAt = nowAbs
                lastDesiredPlaying = u.isPlaying

                // One-shot safety nudge in case initial play was swallowed.
                if u.isPlaying {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        if !mm.isPlaying {
                            mm.seek(to: correctedPos)
                            mm.play()
                        }
                    }
                }
                return
            }

            // Same track: drift & play/pause smoothing
            let currentPos = ApplicationMusicPlayer.shared.playbackTime
            let drift = correctedPos - currentPos
            let nowAbs2 = CFAbsoluteTimeGetCurrent()

            if abs(drift) > driftTolerance, nowAbs2 - lastSeekTime > minSeekInterval {
                ApplicationMusicPlayer.shared.playbackTime = max(0, correctedPos)
                lastSeekTime = nowAbs2
            }

            if lastDesiredPlaying != u.isPlaying, nowAbs2 - lastPlayPauseChangeAt > minControlGap {
                if u.isPlaying {
                    Task { @MainActor in try? await ApplicationMusicPlayer.shared.play() }
                } else {
                    Task { @MainActor in try? await ApplicationMusicPlayer.shared.pause() }
                }
                lastDesiredPlaying = u.isPlaying
                lastPlayPauseChangeAt = nowAbs2
            }
            return
        }
        #endif

        // ====== 2) Fallback: local MediaPlayer PID path ======
        if let spid = u.songPID {
            let target = MPMediaEntityPersistentID(spid)
            let nowAbs = CFAbsoluteTimeGetCurrent()

            // New track? Replace & line up.
            if mm.currentSongPID != target || lastAppliedSongPID != target {
                if mm.replaceQueue(withSongPID: target) {
                    lastAppliedSongPID = target
                    lastAppliedCatalogID = nil
                    mm.seek(to: correctedPos)
                    if u.isPlaying { mm.play() } else { mm.pause() }
                    lastPlayPauseChangeAt = nowAbs
                    lastSeekTime = nowAbs
                    lastDesiredPlaying = u.isPlaying
                }
                return
            }

            // Same track: drift smoothing
            let drift = correctedPos - mm.currentPosition
            if u.isPlaying {
                if abs(drift) > driftTolerance, nowAbs - lastSeekTime > minSeekInterval {
                    mm.seek(to: correctedPos)
                    lastSeekTime = nowAbs
                }
            } else if abs(drift) > smallDrift {
                mm.seek(to: correctedPos)
                lastSeekTime = nowAbs
            }

            // Play/pause smoothing
            if lastDesiredPlaying != u.isPlaying, nowAbs - lastPlayPauseChangeAt > minControlGap {
                if u.isPlaying && !mm.isPlaying { mm.play() }
                if !u.isPlaying && mm.isPlaying { mm.pause() }
                lastDesiredPlaying = u.isPlaying
                lastPlayPauseChangeAt = nowAbs
            }
            return
        }

        // ====== 3) No IDs → align only ======
        let nowAbs = CFAbsoluteTimeGetCurrent()
        let drift = correctedPos - mm.currentPosition
        if abs(drift) > driftTolerance, nowAbs - lastSeekTime > minSeekInterval {
            mm.seek(to: correctedPos)
            lastSeekTime = nowAbs
        }
        if lastDesiredPlaying != u.isPlaying, nowAbs - lastPlayPauseChangeAt > minControlGap {
            if u.isPlaying && !mm.isPlaying { mm.play() }
            if !u.isPlaying && mm.isPlaying { mm.pause() }
            lastDesiredPlaying = u.isPlaying
            lastPlayPauseChangeAt = nowAbs
        }
    }
}
