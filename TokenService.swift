//
//  TokenService.swift
//  DJ
//
//  Created by talya on 14/10/2025.
//

import Foundation

enum TokenError: Error { case invalidResponse }

final class TokenService {
    static let shared = TokenService()
    private init() {}

    // Change to your server’s URL/IP for real device tests
    private let endpoint = URL(string: "http://192.168.68.112:8080/v1/developer-token")!

    func fetchDeveloperToken() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: endpoint)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty
        else { throw TokenError.invalidResponse }
        return token
    }
}
