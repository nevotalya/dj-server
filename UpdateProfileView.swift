//
//  UpdateProfileView.swift
//  DJ
//

import SwiftUI

struct UpdateProfileView: View {
    @ObservedObject var ws: WebSocketManager
    @Environment(\.dismiss) private var dismiss

    @State private var nameText: String = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                // Current name (live from WebSocketManager)
                HStack {
                    Text("Current name:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(ws.myDisplayName ?? "—")
                        .font(.subheadline).bold()
                }

                // Editable field
                TextField("Enter new display name", text: $nameText)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let e = error {
                    Text(e).font(.footnote).foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: save) {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isValid(nameText) ? Color.blue : Color.blue.opacity(0.4))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!isValid(nameText))

                Spacer()
            }
            .padding()
            .navigationTitle("Update Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Close") { dismiss() })
        }
        .onAppear {
            // Prefill with latest known name
            nameText = ws.myDisplayName ?? ""
        }
        // If name changes remotely (e.g., from NamePrompt), reflect it here live
        .onReceive(ws.$myDisplayName) { new in
            // Only overwrite if user hasn't started editing something different
            if nameText.isEmpty || nameText == ws.myDisplayName {
                nameText = new ?? ""
            }
        }
    }

    private func save() {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Please enter a name."
            return
        }
        guard trimmed.count <= 24 else {
            error = "Name must be 24 characters or fewer."
            return
        }

        // Send to server; on "hello" the ws.myDisplayName updates automatically
        ws.sendSetName(trimmed)
        // Proactively update local while we wait for server ack (optional)
        ws.myDisplayName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "displayName")

        dismiss()
    }

    private func isValid(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 24
    }
}
