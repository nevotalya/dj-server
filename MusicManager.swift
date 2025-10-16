//
//  MusicManager.swift
//  DJ
//
//  Reads now-playing from the Music app (system player) for the DJ,
//  and controls playback on the app player for listeners.
//  Also surfaces Apple Music catalog ID (playbackStoreID) for syncing.
//

import Foundation
import MediaPlayer
import AVFAudio

#if canImport(MusicKit)
import MusicKit
#endif

@MainActor
final class MusicManager: ObservableObject {
    static let shared = MusicManager()

    // MARK: - Published state for UI & sync
    @Published var currentTitle: String?
    @Published var currentArtist: String?
    @Published var currentDuration: TimeInterval?
    @Published var currentPosition: TimeInterval = 0
    @Published var isPlaying: Bool = false

    /// Apple Music catalog/store ID of the current track (preferred for syncing)
    @Published var currentPlaybackStoreID: String?

    /// Convenience alias used elsewhere in the app
    var currentCatalogSongId: String? { currentPlaybackStoreID }

    /// Last locally queued playlist persistentID (useful metadata to broadcast)
    @Published var lastQueuedPlaylistPID: MPMediaEntityPersistentID?

    /// Listener needs one user gesture before MusicKit allows programmatic play
    @Published var audioEnabledByUser = false

    @Published var lastQueuedPlaylistName: String? {
        didSet {
            UserDefaults.standard.set(lastQueuedPlaylistName, forKey: playlistNameKey)
        }
    }
    
    
    enum Mode { case dj, listener }
    @Published private(set) var mode: Mode = .dj
    
    private let playlistNameKey = "lastQueuedPlaylistName.v1"
    // MARK: - Players
    /// Reads what the **Music app** is playing (DJ case)
    private let readPlayer  = MPMusicPlayerController.systemMusicPlayer
    /// Controls playback for the **listener** device
    let playPlayer = MPMusicPlayerController.applicationQueuePlayer

    private var positionTimer: Timer?

    private init() {
        configureAudioSessionIfPossible()
        beginObservingPlayers()
        refreshFromPlayers()
        startPositionTimer()
        self.lastQueuedPlaylistName = UserDefaults.standard.string(forKey: playlistNameKey)
    }

    deinit {
        positionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        readPlayer.endGeneratingPlaybackNotifications()
        playPlayer.endGeneratingPlaybackNotifications()
    }

    // MARK: - Track navigation (works for both paths)
//    func nextTrack() {
//        #if canImport(MusicKit)
//        if #available(iOS 16.0, *), audioEnabledByUser {
//            Task { try? await ApplicationMusicPlayer.shared.skipToNextEntry() }
//            return
//        }
//        #endif
//        playPlayer.skipToNextItem()
//        refreshFromPlayers()
//    }
//
//    func previousTrack() {
//        #if canImport(MusicKit)
//        if #available(iOS 16.0, *), audioEnabledByUser {
//            Task { try? await ApplicationMusicPlayer.shared.skipToPreviousEntry() }
//            return
//        }
//        #endif
//        playPlayer.skipToPreviousItem()
//        refreshFromPlayers()
//    }
    
    // MusicManager.swift
    @MainActor
    func stopAllPlayback() {
        // App-queue player (listener)
        playPlayer.pause()
        playPlayer.stop()
        playPlayer.shuffleMode = .off
        playPlayer.repeatMode  = .none

        // System Music app player (DJ / any residual)
        let sys = MPMusicPlayerController.systemMusicPlayer
        sys.pause()
        sys.stop()
        sys.shuffleMode = .off
        sys.repeatMode  = .none

        // MusicKit player (if used)
        #if canImport(MusicKit)
        if #available(iOS 16.0, *) {
            Task { @MainActor in
                try? await ApplicationMusicPlayer.shared.pause()
                // (No public “stop”; pausing is sufficient to silence playback.)
            }
        }
        #endif

        // Clear UI state
        currentTitle = nil
        currentArtist = nil
        currentDuration = nil
        currentPlaybackStoreID = nil
        isPlaying = false
        currentPosition = 0
    }
    
    
    // MARK: - Reliable start of Apple Music track on the listener (app queue)
    @MainActor
    func startCatalogOnListener(storeID: String,
                                at position: TimeInterval,
                                autoplay: Bool) {
        // Ensure we are in listener mode and the system player cannot steal audio
        enterListenerMode()
        let sys = MPMusicPlayerController.systemMusicPlayer
        sys.pause(); sys.stop()

        // Build store queue for this single track
        let desc = MPMusicPlayerStoreQueueDescriptor(storeIDs: [storeID])
        playPlayer.stop()                    // clear any previous local queue
        playPlayer.shuffleMode = .off
        playPlayer.repeatMode  = .none
        playPlayer.setQueue(with: desc)

        // Seek and (maybe) play
        let t = max(0, position)
        playPlayer.currentPlaybackTime = t
        if autoplay { playPlayer.play() } else { playPlayer.pause() }

        // Nudge: after a short delay, if we expected to play but we aren't yet, try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if autoplay && self.playPlayer.playbackState != .playing {
                // Re-apply seek (some SDKs drop the first seek if buffering) and play again
                self.playPlayer.currentPlaybackTime = t
                self.playPlayer.play()
            }
        }

        // Update UI snapshot right away
        refreshFromPlayers()
    }
    
    // MARK: - Permissions (optional for metadata; required for Apple Music playback)
    func requestMediaLibraryAccessIfNeeded() async {
        let status = MPMediaLibrary.authorizationStatus()
        if status == .notDetermined {
            await withCheckedContinuation { cont in
                MPMediaLibrary.requestAuthorization { _ in cont.resume() }
            }
        }
    }

    // MARK: - One-time user unlock for listener autoplay
    func enableAudioByUser() {
        audioEnabledByUser = true
        // tiny no-op after a user tap; helps MusicKit allow programmatic play
        playPlayer.pause()
    }

    // MARK: - Controls (listener playback via app player / MusicKit)
//    func play()  {
//        #if canImport(MusicKit)
//        if #available(iOS 16.0, *), audioEnabledByUser {
//            Task { try? await ApplicationMusicPlayer.shared.play() }
//            return
//        }
//        #endif
//        playPlayer.play()
//        refreshFromPlayers()
//    }

    func enterDJMode() {
        mode = .dj
        // we only *read* from the system player here; do not control app player
        // (no other action needed)
    }

    func enterListenerMode() {
        mode = .listener

        // Stop the system player so it cannot resume old music
        let sys = MPMusicPlayerController.systemMusicPlayer
        sys.pause()
        sys.stop()
        sys.shuffleMode = .off
        sys.repeatMode  = .none

        // Clear the app queue (so we won't resume an old item)
        playPlayer.stop()
        playPlayer.shuffleMode = .off
        playPlayer.repeatMode  = .none

        // If you’re using MusicKit on iOS 16+, pause and forget our cached catalog
        #if canImport(MusicKit)
        if #available(iOS 16.0, *) {
            Task { try? await ApplicationMusicPlayer.shared.pause() }
        }
        #endif
        queuedCatalogID = nil

        refreshFromPlayers()
    }
    
    /// Make sure the system Music app won't resume an old track.
    func stopSystemPlayer() {
        // These are safe no-ops if it's already idle
        MPMusicPlayerController.systemMusicPlayer.pause()
        MPMusicPlayerController.systemMusicPlayer.stop()
    }

    /// Replace the listener (app) queue with exactly one local item by PID.
    func replaceQueueWithPID(_ pid: MPMediaEntityPersistentID,
                             startAt position: TimeInterval,
                             autoplay: Bool) {
        enterListenerMode()                      // 👈 ensure mode
        let sys = MPMusicPlayerController.systemMusicPlayer
        sys.pause(); sys.stop()

        let pred = MPMediaPropertyPredicate(value: pid, forProperty: MPMediaItemPropertyPersistentID)
        let q = MPMediaQuery.songs()
        q.addFilterPredicate(pred)
        guard let item = q.items?.first else { return }

        playPlayer.stop()
        playPlayer.shuffleMode = .off
        playPlayer.repeatMode  = .none
        playPlayer.setQueue(with: MPMediaItemCollection(items: [item]))
        playPlayer.currentPlaybackTime = max(0, position)
        autoplay ? playPlayer.play() : playPlayer.pause()

        refreshFromPlayers()
    }
    
    
    
    // In MusicManager

    @Published private(set) var queuedCatalogID: String?

    @available(iOS 16.0, *)
    func ensureCatalogQueued(id: String) async {
        guard queuedCatalogID != id else { return }          // ← don’t thrash the queue
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let res = try await req.response()
            guard let song = res.items.first else { return }

            ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: [song])
            try? await ApplicationMusicPlayer.shared.prepareToPlay()
            queuedCatalogID = id

            // update UI (optional)
            currentTitle  = song.title
            currentArtist = song.artistName
            currentDuration = song.duration ?? currentDuration
            currentPlaybackStoreID = id
        } catch {
            print("⚠️ ensureCatalogQueued error:", error.localizedDescription)
        }
    }
    
    /// Replace the listener (app) queue with exactly one Apple Music catalog item.
 
    @available(iOS 16.0, *)
    func replaceQueueWithCatalogID(_ storeID: String,
                                   startAt position: TimeInterval,
                                   autoplay: Bool) async {
        enterListenerMode()                      // 👈 ensure mode
        let sys = MPMusicPlayerController.systemMusicPlayer
        sys.pause(); sys.stop()

        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(storeID))
            let res = try await req.response()
            guard let song = res.items.first else { return }

            ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: [song])
            try? await ApplicationMusicPlayer.shared.prepareToPlay()
            ApplicationMusicPlayer.shared.playbackTime = max(0, position)
            if autoplay { try? await ApplicationMusicPlayer.shared.play() }
            else        { try? await ApplicationMusicPlayer.shared.pause() }

            // reflect to UI
            currentTitle  = song.title
            currentArtist = song.artistName
            currentDuration = song.duration ?? currentDuration
            currentPlaybackStoreID = storeID
            isPlaying = autoplay

        } catch {
            print("❌ replaceQueueWithCatalogID error:", error.localizedDescription)
        }
    }
    
    
//    func pause() {
//        #if canImport(MusicKit)
//        if #available(iOS 16.0, *), audioEnabledByUser {
//            Task { try? await ApplicationMusicPlayer.shared.pause() }
//            return
//        }
//        #endif
//        playPlayer.pause()
//        refreshFromPlayers()
//    }
//
//    func seek(to seconds: TimeInterval) {
//        #if canImport(MusicKit)
//        if #available(iOS 16.0, *), audioEnabledByUser {
//            ApplicationMusicPlayer.shared.playbackTime = max(0, seconds)
//            refreshFromPlayers()
//            return
//        }
//        #endif
//        playPlayer.currentPlaybackTime = max(0, seconds)
//        refreshFromPlayers()
//    }

    // MARK: - MusicKit direct play by store ID (listener path)
    #if canImport(MusicKit)
    @MainActor
    func playCatalogSongByStoreID(_ storeID: String,
                                  at position: TimeInterval,
                                  playing: Bool) async {
        // Ensure Apple Music permission (no-op if already authorized)
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            print("🚫 MusicAuthorization not authorized (\(status))")
            return
        }

        // Queue the Apple Music track by its store ID and start playback
        let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: [storeID])
        playPlayer.setQueue(with: descriptor)
        playPlayer.play()

        // Seek to the DJ’s position and honor play/pause
        playPlayer.currentPlaybackTime = max(0, position)
        if !playing { playPlayer.pause() }

        // Update published fields
        self.refreshFromPlayers()   // ✅ fixed (was refreshFromPlayer)
    }
    #endif

    // Put inside MusicManager

    private enum ControlTarget { case musicKit, appQueue, system }

    private func activeControlTarget() -> ControlTarget {
        #if canImport(MusicKit)
        if #available(iOS 16.0, *), audioEnabledByUser {
            // If we’ve queued anything via MusicKit recently, prefer it.
            // (We can't easily introspect queue contents, but play/pause no-ops if empty.)
            return .musicKit
        }
        #endif

        // If our application queue has something, prefer it
        if playPlayer.nowPlayingItem != nil || playPlayer.playbackState != .stopped {
            return .appQueue
        }

        // Otherwise fall back to whatever the Music app (system player) is doing
        return .system
    }

    // MARK: - Controls (route to active player)

    func play() {
        switch activeControlTarget() {
        case .musicKit:
            #if canImport(MusicKit)
            if #available(iOS 16.0, *) { Task { try? await ApplicationMusicPlayer.shared.play() } }
            #endif
        case .appQueue:
            playPlayer.play()
        case .system:
            MPMusicPlayerController.systemMusicPlayer.play()
        }
        refreshFromPlayers()
    }

    func pause() {
        switch activeControlTarget() {
        case .musicKit:
            #if canImport(MusicKit)
            if #available(iOS 16.0, *) { Task { try? await ApplicationMusicPlayer.shared.pause() } }
            #endif
        case .appQueue:
            playPlayer.pause()
        case .system:
            MPMusicPlayerController.systemMusicPlayer.pause()
        }
        refreshFromPlayers()
    }

    func seek(to seconds: TimeInterval) {
        let t = max(0, seconds)
        switch activeControlTarget() {
        case .musicKit:
            #if canImport(MusicKit)
            if #available(iOS 16.0, *) { ApplicationMusicPlayer.shared.playbackTime = t }
            #endif
        case .appQueue:
            playPlayer.currentPlaybackTime = t
        case .system:
            MPMusicPlayerController.systemMusicPlayer.currentPlaybackTime = t
        }
        refreshFromPlayers()
    }

    func nextTrack() {
        switch activeControlTarget() {
        case .musicKit:
            #if canImport(MusicKit)
            if #available(iOS 16.0, *) { Task { try? await ApplicationMusicPlayer.shared.skipToNextEntry() } }
            #endif
        case .appQueue:
            playPlayer.skipToNextItem()
        case .system:
            MPMusicPlayerController.systemMusicPlayer.skipToNextItem()
        }
        refreshFromPlayers()
    }

    func previousTrack() {
        switch activeControlTarget() {
        case .musicKit:
            #if canImport(MusicKit)
            if #available(iOS 16.0, *) { Task { try? await ApplicationMusicPlayer.shared.skipToPreviousEntry() } }
            #endif
        case .appQueue:
            playPlayer.skipToPreviousItem()
        case .system:
            MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem()
        }
        refreshFromPlayers()
    }
    
    
    
    // MARK: - Observing / Polling
    private func beginObservingPlayers() {
        readPlayer.beginGeneratingPlaybackNotifications()
        playPlayer.beginGeneratingPlaybackNotifications()

        let center = NotificationCenter.default
        // DJ reads (Music app player)
        center.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                           object: readPlayer, queue: .main) { [weak self] _ in
            self?.refreshFromPlayers()
        }
        center.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                           object: readPlayer, queue: .main) { [weak self] _ in
            self?.refreshFromPlayers()
        }
        // Listener control (app player)
        center.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                           object: playPlayer, queue: .main) { [weak self] _ in
            self?.refreshFromPlayers()
        }
        center.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                           object: playPlayer, queue: .main) { [weak self] _ in
            self?.refreshFromPlayers()
        }
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch self.mode {
            case .dj:
                let t = self.readPlayer.currentPlaybackTime
                self.currentPosition = (t.isFinite && t >= 0) ? t : 0
            case .listener:
                #if canImport(MusicKit)
                if #available(iOS 16.0, *), self.audioEnabledByUser {
                    self.currentPosition = max(0, ApplicationMusicPlayer.shared.playbackTime)
                } else {
                    let t = self.playPlayer.currentPlaybackTime
                    self.currentPosition = (t.isFinite && t >= 0) ? t : 0
                }
                #else
                let t = self.playPlayer.currentPlaybackTime
                self.currentPosition = (t.isFinite && t >= 0) ? t : 0
                #endif
            }
        }
        if let positionTimer { RunLoop.main.add(positionTimer, forMode: .common) }
    }

    private func refreshFromPlayers() {
        switch mode {
        case .dj:
            let item = readPlayer.nowPlayingItem
            currentTitle    = item?.title
            currentArtist   = item?.artist
            currentDuration = item?.playbackDuration
            currentPlaybackStoreID = item?.playbackStoreID
            isPlaying = (readPlayer.playbackState == .playing)

        case .listener:
            #if canImport(MusicKit)
            if #available(iOS 16.0, *), audioEnabledByUser {
                // let MusicKit drive state
                isPlaying = (ApplicationMusicPlayer.shared.state.playbackStatus == .playing)
            } else {
                isPlaying = (playPlayer.playbackState == .playing)
            }
            #else
            isPlaying = (playPlayer.playbackState == .playing)
            #endif

            let item = playPlayer.nowPlayingItem // reflect what *we* are playing
            currentTitle    = item?.title ?? currentTitle
            currentArtist   = item?.artist ?? currentArtist
            currentDuration = item?.playbackDuration ?? currentDuration
            currentPlaybackStoreID = item?.playbackStoreID ?? currentPlaybackStoreID
        }
    }

    // MARK: - Audio session (best effort)
    private func configureAudioSessionIfPossible() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("ℹ️ Audio session setup skipped:", error.localizedDescription)
        }
    }

    // MARK: - Local queue helpers (listener, PID path)
    func startLocalPlaylist(_ playlist: MPMediaPlaylist) {
        let items = playlist.items
        guard !items.isEmpty else { return }
        playPlayer.setQueue(with: MPMediaItemCollection(items: items))
        lastQueuedPlaylistPID = playlist.persistentID
        lastQueuedPlaylistName = playlist.name                // <-- set
        UserDefaults.standard.set(playlist.name, forKey: playlistNameKey) // <-- persist
        play()
    }

    /// Replace queue with a single local item by persistentID
    func replaceQueue(withSongPID pid: MPMediaEntityPersistentID) -> Bool {
        let pred = MPMediaPropertyPredicate(value: pid, forProperty: MPMediaItemPropertyPersistentID)
        let q = MPMediaQuery.songs()
        q.addFilterPredicate(pred)
        guard let item = q.items?.first else { return false }
        playPlayer.stop()
        playPlayer.setQueue(with: MPMediaItemCollection(items: [item]))
        return true
    }

    /// Current now-playing PID as seen by the Music app (0 or nil for streaming)
    var currentSongPID: MPMediaEntityPersistentID? {
        readPlayer.nowPlayingItem?.persistentID
    }
}

#if canImport(MusicKit)
// MARK: - Apple Music catalog helpers (listener, catalog path)
@available(iOS 16.0, *)
extension MusicManager {
    /// Queue but don’t auto-play (used if user hasn’t tapped "Enable Audio" yet)
    func queueCatalogSong(id: String) async {
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let res = try await req.response()
            guard let song = res.items.first else { return }

            try await ApplicationMusicPlayer.shared.queue.insert(song, position: .tail)
            try? await ApplicationMusicPlayer.shared.prepareToPlay()
        } catch {
            print("⚠️ queueCatalogSong error:", error.localizedDescription)
        }
    }

    /// Queue + seek + optionally play (primary listener follow path)
    func playCatalogSong(id: String, at position: TimeInterval, autoplay: Bool) async {
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let res = try await req.response()
            guard let song = res.items.first else { return }

            // Replace the queue with only this song to avoid resume noise
            ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: [song])
            try? await ApplicationMusicPlayer.shared.prepareToPlay()
            ApplicationMusicPlayer.shared.playbackTime = max(0, position)
            if autoplay { try? await ApplicationMusicPlayer.shared.play() }

            // Update UI fields based on the catalog item (nice for listener UI)
            currentTitle  = song.title
            currentArtist = song.artistName
            currentDuration = song.duration ?? currentDuration
            currentPlaybackStoreID = id
            isPlaying = autoplay
        } catch {
            print("❌ playCatalogSong error:", error.localizedDescription)
        }
    }
}
#endif
