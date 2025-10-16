import SwiftUI
import Combine
import MediaPlayer   // for iOS local playlist & playlist name lookup

struct SessionRootView: View {
    // MARK: - Inputs
    @ObservedObject var ws: WebSocketManager
    @StateObject private var clock: ClockSync
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var music: MusicManager   // 👈 access lastQueuedPlaylistPID

    @State private var showPlaylistPicker = false
    //@State private var showNamePrompt = false

    // MARK: - ViewModel
    @StateObject private var vm: SimpleSessionViewModel

    // MARK: - UI State
    @State private var showFriends = false
    @State private var showProfileSheet = false

    // MARK: - Init
    init(ws: WebSocketManager) {
        self.ws = ws
        _clock = StateObject(wrappedValue: ClockSync(ws: ws))
        _vm = StateObject(wrappedValue: SimpleSessionViewModel(ws: ws))
    }

    // MARK: - Derived state
    private var isActiveListener: Bool {
        ws.followingDJId != nil
    }

    private var resolvedPlaylistName: String? {
        guard let pid = music.lastQueuedPlaylistPID else { return nil }
        // Look up the playlist name from the media library
        let q = MPMediaQuery.playlists()
        let pred = MPMediaPropertyPredicate(
            value: NSNumber(value: pid),
            forProperty: MPMediaPlaylistPropertyPersistentID
        )
        q.addFilterPredicate(pred)
        if let playlists = q.collections as? [MPMediaPlaylist],
           let p = playlists.first {
            return p.name
        }
        return nil
    }

    // MARK: - Connection pill
    @ViewBuilder
    private func connectionPill() -> some View {
        let (text, color): (String, Color) = {
            switch ws.connectionStatus {
            case .connected:    return ("Connected", .green)
            case .connecting:   return ("Connecting…", .orange)
            case .disconnected: return ("Disconnected", .red)
            }
        }()

        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundColor(.primary)
            Spacer()
            Button("Retry") { ws.connect() }
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 12) {
            connectionPill()

            // ✅ Show the "Pick Playlist" control for everyone EXCEPT active listeners
            if !isActiveListener {
                VStack {
                    Button("Pick Playlist") {
                        showPlaylistPicker = true
                    }
                    if let name = music.lastQueuedPlaylistName {
                        Text("🎵 \(name)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }

        NavigationView {
            content
                .navigationTitle(vm.isDJ ? "DJ Mode" : (isActiveListener ? "Listening" : ""))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(
                    leading:
                        Button(action: { showProfileSheet = true }) {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Update Profile"),
                    trailing:
                        Button(action: { showFriends = true }) {
                            Image(systemName: "person.2")
                        }
                        .accessibilityLabel("Manage Friends")
                )
        }
        .tint(.blue)

        // Sheets
        .sheet(isPresented: $showFriends) {
            ManageFriendsView(ws: ws)
                .environmentObject(friendStore)
        }
        .sheet(isPresented: $showProfileSheet) {
            UpdateProfileView(ws: ws)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerView { mpPlaylist in
                playLocalPlaylist(mpPlaylist)
            }
        }
        
        // Name prompt
//        .onReceive(ws.$requiresName) { need in
//            showNamePrompt = need
//        }
//        .sheet(isPresented: $showNamePrompt) {
//            NamePromptView(
//                onSubmit: { newName in ws.sendSetName(newName) },
//                initialName: ws.myDisplayName ?? ""
//            )
//        }
        .sheet(
            isPresented: Binding(
                get: { ws.requiresName },
                set: { ws.requiresName = $0 } // allow manual dismissal if needed
            )
        ) {
            NamePromptView(
                onSubmit: { newName in
                    ws.sendSetName(newName)
                    // No need to dismiss here — the "hello" handler will set requiresName = false
                },
                initialName: ws.myDisplayName ?? ""
            )
        }
        
        // Mini player
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar(isControllable: !isActiveListener)
                .environmentObject(MusicManager.shared)
                .padding(.bottom, 8)
        }

        // Connect + quick clock sync
        .onAppear {
            ws.connect()
            clock.performSync(samplesCount: 8, interval: 0.2)
        }
    }

    // MARK: - Content
    @ViewBuilder
    private var content: some View {
        VStack(spacing: 18) {
            primaryActionButton()

            if vm.isDJ {
                listenersList()
            } else {
                djsList()
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    // MARK: - Primary Button
    @ViewBuilder
    private func primaryActionButton() -> some View {
        Button(action: vm.toggleDJ) {
            Text(vm.isDJ ? "Stop DJing" : "Start DJing")
                .frame(maxWidth: .infinity)
                .padding()
                .background(vm.isDJ ? Color.red : Color.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }

    // MARK: - DJs List (Listen Mode)
    @ViewBuilder
    private func djsList() -> some View {
        VStack(spacing: 8) {
            if let fid = ws.followingDJId,
               let dj = ws.onlineUsers.first(where: { $0.id == fid }) {
                listeningChip(djName: dj.displayName)
            }

            List {
                Section(header: Text("DJs")) {
                    let djs = currentDJs()
                    if djs.isEmpty {
                        Text("No DJs yet").foregroundColor(.secondary)
                    } else {
                        ForEach(djs, id: \.id) { dj in
                            HStack {
                                Text("DJ \(dj.displayName)")
                                Spacer()
                                if ws.followingDJId == dj.id {
                                    Button("Stop Listening") { vm.stopListening() }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.red)
                                } else {
                                    Button("Listen") { vm.listen(to: dj) }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .tint(.blue)
        }
    }

    // MARK: - Listeners (DJ Mode)
    @ViewBuilder
    private func listenersList() -> some View {
        let listeners = vm.listenersOfMe(ws: ws)

        List {
            Section(header: Text("Listeners")) {
                if listeners.isEmpty {
                    Text("No listeners yet").foregroundColor(.secondary)
                } else {
                    ForEach(listeners, id: \.id) { u in
                        HStack {
                            Image(systemName: "person.fill").foregroundColor(.blue)
                            Text(u.displayName)
                            Spacer()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Blue Status Chip
    @ViewBuilder
    private func listeningChip(djName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones").foregroundColor(.white)
            Text("Listening to DJ \(djName)")
                .font(.subheadline)
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

//            Button {
//                showProfileSheet = true
//            } label: {
//                HStack(spacing: 4) {
//                    Image(systemName: "pencil")
//                    Text("Edit")
//                }
//                .font(.caption)
//                .padding(.horizontal, 10)
//                .padding(.vertical, 6)
//                .background(Color.white.opacity(0.9))
//                .foregroundColor(.blue)
//                .clipShape(Capsule())
//            }
//            .buttonStyle(.plain)

            Button {
                vm.stopListening()
            } label: {
                Text("Stop")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.blue)
                .shadow(color: Color.black.opacity(0.2), radius: 3, x: 0, y: 2)
        )
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: - Helpers
    private func currentDJs() -> [UserInfo] {
        ws.onlineUsers.filter { $0.isDJ }
    }

    /// Local-only playback via the system Music player (shows in Control Center / Music app)
    private func playLocalPlaylist(_ mpPlaylist: MPMediaPlaylist) {
        let items = mpPlaylist.items
        guard !items.isEmpty else { return }

        let player = MPMusicPlayerController.systemMusicPlayer
        let collection = MPMediaItemCollection(items: items)

        player.setQueue(with: collection)
        music.lastQueuedPlaylistName = mpPlaylist.name       // ✅ Save the name
        player.play()

        if let title = player.nowPlayingItem?.title {
            print("🎵 Now playing: \(title)")
        } else {
            print("⚠️ nowPlayingItem not set yet.")
        }
    }
}
