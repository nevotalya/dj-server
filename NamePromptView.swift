//
//  NamePromptView.swift
//  DJ
//
//  Minimal prompt to set/display a persistent user name.
//  Use with .sheet(isPresented:) and pass ws.sendSetName in onSubmit.
//

import SwiftUI

struct NamePromptView: View {
    /// Called when the user taps Save (you typically pass `ws.sendSetName`)
    var onSubmit: (String) -> Void

    /// Optional prefill (e.g., ws.myDisplayName)
    private let initialName: String

    @State private var name: String = ""
    @State private var error: String?

    // Custom init so we can prefill cleanly
    init(onSubmit: @escaping (String) -> Void, initialName: String = "") {
        self.onSubmit = onSubmit
        self.initialName = initialName
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text("Choose your display name")
                    .font(.title3).bold()
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if let e = error {
                        Text(e)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button(action: submit) {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isValid(name) ? Color.blue : Color.blue.opacity(0.4))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!isValid(name))

                Spacer()
            }
            .padding()
            .navigationTitle("Set Name")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Clear any stale error if we open with a prefilled name
            if isValid(name) { error = nil }
        }
    }

    // MARK: - Actions / Validation

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Please enter a name."
            return
        }
        guard trimmed.count <= 24 else {
            error = "Name must be 24 characters or fewer."
            return
        }
        onSubmit(trimmed)
        // Sheet will auto-dismiss when ws.requiresName becomes false after server "hello"
    }

    private func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 24
    }
}
