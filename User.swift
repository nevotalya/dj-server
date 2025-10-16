//
//  User.swift
//  DJ
//
//  Created by talya on 11/10/2025.
//

import Foundation

struct User: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let isDJ: Bool
}

