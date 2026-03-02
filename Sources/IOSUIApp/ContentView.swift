import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var api = ChatAPI()
    @State private var input: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var showCamera = false
    @State private var pendingImage: UIImage?
    @State private var composerHeight: CGFloat = 56
    @State private var sessionKey: String = Self.makeSessionKey()
    @State private var showNewChatConfirm = false
    @State private var recoverableSnapshot: SavedChatSnapshot?
    @State private var didBootstrap = false
    @FocusState private var inputFocused: Bool

    private static let snapshotKey = "lastChatSnapshot"

    var body: some View {
        VStack(spacing: 10) {
            settingsBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { msg in
                            bubble(msg)
                                .id(msg.id)
                        }

                        if isSending {
                            typingBubble
                                .id("typing-indicator")
                        }

                        Color.clear
                            .frame(height: composerHeight + 10)
                            .id("bottom-spacer")
                    }
                    .padding(.horizontal)
                }
                .contentShape(Rectangle())
                .onTapGesture { inputFocused = false }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: messages.count) { _ in
                    withAnimation {
                        proxy.scrollTo("bottom-spacer", anchor: .bottom)
                    }
                }
                .onChange(of: isSending) { sending in
                    if sending {
                        withAnimation {
                            proxy.scrollTo("typing-indicator", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: inputFocused) { focused in
                    guard focused else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        withAnimation {
                            proxy.scrollTo("bottom-spacer", anchor: .bottom)
                        }
                    }
                }
            }

            if let pendingImage {
                HStack {
                    Image(uiImage: pendingImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))

                    Button("Remove") { self.pendingImage = nil }
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                Button {
                    inputFocused = false
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                    showCamera = true
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 34, height: 34)
                }
                .disabled(isSending || !UIImagePickerController.isSourceTypeAvailable(.camera))

                TextField("Type message", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)

                Button(isSending ? "..." : "Send") {
                    Task { await send() }
                }
                .disabled(isSending || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImage == nil))
            }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { composerHeight = g.size.height }
                        .onChange(of: g.size.height) { h in composerHeight = h }
                }
            )
            .padding()
        }
        .onAppear {
            guard !didBootstrap else { return }
            didBootstrap = true
            recoverableSnapshot = Self.loadSnapshot()
            // Cold launch default: new chat with empty history.
            startNewChat()
            inputFocused = true
        }
        .onChange(of: messages.count) { _ in
            guard !messages.isEmpty else { return }
            let snapshot = SavedChatSnapshot(sessionKey: sessionKey, messages: messages, savedAt: Date())
            Self.saveSnapshot(snapshot)
            recoverableSnapshot = snapshot
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                pendingImage = image
            }
            .ignoresSafeArea()
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 8) {
            TextField("Backend URL", text: $api.backendURL)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Spacer()

            if recoverableSnapshot != nil {
                Button {
                    restorePreviousChat()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Continue previous chat")
            }

            Button {
                showNewChatConfirm = true
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Start fresh chat")
            .confirmationDialog("Start new chat?", isPresented: $showNewChatConfirm, titleVisibility: .visible) {
                Button("Start New Chat", role: .destructive) {
                    startNewChat()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears current on-screen messages. You can still recover your previous chat.")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func startNewChat() {
        sessionKey = Self.makeSessionKey()
        messages = []
    }

    private func restorePreviousChat() {
        guard let snapshot = recoverableSnapshot else { return }
        sessionKey = snapshot.sessionKey
        messages = snapshot.messages
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.role == "assistant" {
                VStack(alignment: .leading, spacing: 4) {
                    if let b64 = m.imageBase64, let ui = UIImage.fromBase64(b64) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if !m.text.isEmpty {
                        Text(m.text)
                            .padding(10)
                            .background(Color.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if let ms = m.responseTimeMs {
                        Text(formatResponseTime(ms))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.leading, 6)
                    }
                }
                Spacer()
            } else {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let b64 = m.imageBase64, let ui = UIImage.fromBase64(b64) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if !m.text.isEmpty {
                        Text(m.text)
                            .padding(10)
                            .background(Color.green.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var typingBubble: some View {
        HStack {
            TypingIndicatorView()
                .padding(10)
                .background(Color.blue.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
    }

    private func formatResponseTime(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1000.0)
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageToSend = pendingImage
        guard !text.isEmpty || imageToSend != nil else { return }

        input = ""
        pendingImage = nil

        messages.append(.init(role: "user", text: text, imageBase64: imageToSend?.jpegData(compressionQuality: 0.75)?.base64EncodedString()))
        isSending = true
        let startedAt = Date()
        defer { isSending = false }

        do {
            let reply = try await api.send(text, image: imageToSend, sessionKey: sessionKey)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            messages.append(.init(role: "assistant", text: reply, responseTimeMs: elapsedMs))
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            messages.append(.init(role: "assistant", text: "Error: \(error.localizedDescription)", responseTimeMs: elapsedMs))
        }
    }

    private static func makeSessionKey() -> String {
        "ios-ui-\(UUID().uuidString.lowercased())"
    }

    private static func saveSnapshot(_ snapshot: SavedChatSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    private static func loadSnapshot() -> SavedChatSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(SavedChatSnapshot.self, from: data)
    }
}


private struct SavedChatSnapshot: Codable {
    let sessionKey: String
    let messages: [ChatMessage]
    let savedAt: Date
}

private struct TypingIndicatorView: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = Int(t * 3) % 3

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .opacity(i == phase ? 1.0 : 0.25)
                }
            }
        }
        .frame(height: 12)
        .accessibilityLabel("Assistant is typing")
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }
    }
}

private extension UIImage {
    static func fromBase64(_ value: String) -> UIImage? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return UIImage(data: data)
    }
}
