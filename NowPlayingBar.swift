import SwiftUI

struct NowPlayingBar: View {
    @EnvironmentObject var music: MusicManager

    /// Pass true if the local device may control playback (i.e., NOT following a DJ)
    let isControllable: Bool

    private var controlsOpacity: Double { isControllable ? 1.0 : 0.35 }

    var body: some View {
        HStack(spacing: 12) {
            // Title / artist
            VStack(alignment: .leading, spacing: 2) {
                Text(music.currentTitle ?? "Nothing Playing")
                    .font(.subheadline).bold()
                    .lineLimit(1)
                Text(music.currentArtist ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Controls
            HStack(spacing: 14) {
                Button(action: { if isControllable { music.previousTrack() } }) {
                    Image(systemName: "backward.fill")
                }
                .disabled(!isControllable)

                Button(action: {
                    if isControllable {
                        music.isPlaying ? music.pause() : music.play()
                    }
                }) {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                }
                .disabled(!isControllable)

                Button(action: { if isControllable { music.nextTrack() } }) {
                    Image(systemName: "forward.fill")
                }
                .disabled(!isControllable)
            }
            .opacity(controlsOpacity)
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }
}
