//
//  PlaylistPickerView.swift
//  DJ
//

import SwiftUI
import MediaPlayer

struct PlaylistPickerView: View {
    var onPick: (MPMediaPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localPlaylists: [MPMediaPlaylist] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView("Loading your playlists…")
                } else if let e = errorText {
                    VStack(spacing: 12) {
                        Text("Couldn’t load playlists").font(.headline)
                        Text(e).multilineTextAlignment(.center).foregroundColor(.secondary)
                        Button("Retry") { Task { await loadPlaylists() } }
                    }
                    .padding()
                } else {
                    List(localPlaylists, id: \.persistentID) { pl in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 56, height: 56)
                                .overlay(Image(systemName: "music.note.list").foregroundColor(.secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.name ?? "Untitled Playlist").lineLimit(1)
                                Text("On-device playlist")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onPick(pl)
                            dismiss()
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Pick a Playlist")
            .navigationBarItems(trailing: Button("Close") { dismiss() })
        }
        .task { await loadPlaylists() }
    }

    private func loadPlaylists() async {
        loading = true; errorText = nil

        let status = MPMediaLibrary.authorizationStatus()
        if status == .notDetermined {
            await withCheckedContinuation { cont in
                MPMediaLibrary.requestAuthorization { _ in cont.resume() }
            }
        }
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            await MainActor.run {
                errorText = "Media library access denied"
                loading = false
            }
            return
        }

        let query = MPMediaQuery.playlists()
        let collections = (query.collections as? [MPMediaPlaylist]) ?? []
        await MainActor.run {
            localPlaylists = collections
            loading = false
        }
    }
}
