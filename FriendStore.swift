// FriendStore.swift
import Foundation

struct Friend: Identifiable, Equatable, Codable {
    let id: String
    var displayName: String
}

final class FriendStore: ObservableObject {
    @Published var friends: [Friend] = []

    func setFriends(_ list: [Friend]) {
        // de-dup + stable sort
        let unique = Dictionary(grouping: list, by: { $0.id }).compactMap { $0.value.first }
        friends = unique.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func addFriend(id: String, name: String? = nil) {
        if let idx = friends.firstIndex(where: { $0.id == id }) {
            if let n = name { friends[idx].displayName = n }
            return
        }
        friends.append(Friend(id: id, displayName: name ?? id))
        setFriends(friends)
    }

    func removeFriend(id: String) {
        friends.removeAll { $0.id == id }
    }
}
