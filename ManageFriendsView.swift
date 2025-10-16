//
//  ManageFriendsView.swift
//  DJ
//

import SwiftUI

struct ManageFriendsView: View {
    @ObservedObject var ws: WebSocketManager
    @Environment(\.dismiss) private var dismiss

    @State private var showShare = false
    @State private var manualId: String = ""
    @State private var infoText: String?

    // Quickly check if a friend is online using the current users snapshot
    private func isOnline(_ friendId: String) -> Bool {
        ws.remoteUsersSnapshot.first(where: { $0.id == friendId })?.online ?? false
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Share link
                Button {
                    showShare = true
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .imageScale(.medium)
                        Text("Share Friend Link")
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .imageScale(.medium)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showShare) {
                    ShareSheet(items: [shareText, shareURL])
                }

                // Optional: manual add (paste a friend ID)
                HStack(spacing: 10) {
                    TextField("Paste friend ID…", text: $manualId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button("Add") {
                        addFriendManually()
                    }
                    .disabled(manualId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
                }

                if let info = infoText {
                    Text(info)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Friends list
                List {
                    Section(header: Text("My Friends")) {
                        let list = ws.friends.sorted {
                            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                        }
                        if list.isEmpty {
                            Text("No friends yet. Share your link or paste a friend ID.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(list, id: \.id) { f in
                                HStack(spacing: 12) {
                                    // Online/offline dot
                                    Circle()
                                        .fill(isOnline(f.id) ? Color.green : Color.red)
                                        .frame(width: 10, height: 10)

                                    Image(systemName: "person.fill")
                                        .foregroundColor(.blue)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.displayName).fontWeight(.medium)
                                        Text(f.id).font(.caption2).foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Manage Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Ask server for the latest friends
                ws.sendListFriends()
                infoText = "Your friend link adds people to BOTH lists."
            }
        }
    }

    // MARK: - Share helpers
    private var shareText: String {
        let name = ws.myDisplayName ?? "Friend"
        return "Add \(name) on DJ"
    }

    private var shareURL: URL {
        // Deep link: DJ://addfriend?id=<yourId>&name=<yourName>
        let id = ws.userId
        let name = (ws.myDisplayName ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "DJ://addfriend?id=\(id)&name=\(name)")!
    }

    // MARK: - Manual add
    private func addFriendManually() {
        let trimmed = manualId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ws.sendAddFriend(friendId: trimmed)
        infoText = "Friend request sent."
        manualId = ""
        // The server will push an updated friendsList to BOTH users on success
    }
}

// MARK: - UIKit share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
