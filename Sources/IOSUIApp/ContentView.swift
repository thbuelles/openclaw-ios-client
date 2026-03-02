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

    @State private var threads: [SavedChatThread] = []
    @State private var currentThreadID: UUID?
    @State private var currentSessionKey: String = ""
    @State private var showThreadPicker = false
    @State private var threadPendingDelete: SavedChatThread?
    @State private var showDeleteAllConfirm = false
    @State private var showBackendInfo = false

    @FocusState private var inputFocused: Bool

    private static let threadsKey = "chatThreadsV1"

    var body: some View {
        ZStack(alignment: .leading) {
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
                .onTapGesture {
                    inputFocused = false
                    showBackendInfo = false
                }
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
            loadThreads()
            if currentThreadID == nil {
                createNewThreadAndSelect()
            }
            inputFocused = true
        }
        .onChange(of: messages.count) { _ in
            persistCurrentThread(messages: messages)
        }
        .onChange(of: showThreadPicker) { showing in
            if showing { inputFocused = false }
        }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    pendingImage = image
                }
                .ignoresSafeArea()
            }

            if showThreadPicker {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showThreadPicker = false } }

                threadPickerDrawer
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showThreadPicker)
    }

    private var displayHost: String {
        let raw = api.backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let host = url.host else { return raw }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    private var settingsBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    inputFocused = false
                    showBackendInfo = false
                    withAnimation(.easeInOut(duration: 0.2)) { showThreadPicker = true }
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5).frame(width: 16, height: 2.5)
                        RoundedRectangle(cornerRadius: 1.5).frame(width: 16, height: 2.5)
                        RoundedRectangle(cornerRadius: 1.5).frame(width: 16, height: 2.5)
                    }
                    .foregroundStyle(Color.blue)
                    .frame(width: 38, height: 38)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Show all chats")

                Spacer()

                Button {
                    inputFocused = false
                    showBackendInfo.toggle()
                } label: {
                    Image("ChatLogoFaded")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showBackendInfo = false
                    createNewThreadAndSelect()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 38, height: 38)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("New chat")
            }

            if showBackendInfo {
                Text(displayHost)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.black.opacity(0.96))
    }

    private var threadPickerDrawer: some View {
        List {
            ForEach(threadsSortedByRecency) { thread in
                HStack(spacing: 10) {
                    Button {
                        selectThread(thread)
                        withAnimation(.easeInOut(duration: 0.2)) { showThreadPicker = false }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.previewTitle)
                                .font(.body)
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button {
                        threadPendingDelete = thread
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete chat")
                }
                .listRowBackground(Color(red: 0.18, green: 0.18, blue: 0.18))
            }

            if !threads.isEmpty {
                Button {
                    showDeleteAllConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete All")
                            .foregroundColor(.red)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(red: 0.18, green: 0.18, blue: 0.18))
            }
        }
        .listStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.18, green: 0.18, blue: 0.18))
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { threadPendingDelete != nil },
                set: { if !$0 { threadPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let thread = threadPendingDelete {
                    deleteThread(thread)
                }
                threadPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                threadPendingDelete = nil
            }
        }
        .confirmationDialog("Delete all chats?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                deleteAllThreads()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var threadsSortedByRecency: [SavedChatThread] {
        threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func createNewThreadAndSelect() {
        let id = UUID()
        currentThreadID = id
        currentSessionKey = "ios-ui-\(id.uuidString.lowercased())"
        messages = []
    }

    private func selectThread(_ thread: SavedChatThread) {
        currentThreadID = thread.id
        currentSessionKey = thread.sessionKey
        messages = thread.messages
    }

    private func persistCurrentThread(messages: [ChatMessage]) {
        guard let currentThreadID else { return }
        guard !messages.isEmpty else { return }

        if let idx = threads.firstIndex(where: { $0.id == currentThreadID }) {
            threads[idx].messages = messages
            threads[idx].updatedAt = Date()
        } else {
            let thread = SavedChatThread(
                id: currentThreadID,
                sessionKey: currentSessionKey.isEmpty ? "ios-ui-\(currentThreadID.uuidString.lowercased())" : currentSessionKey,
                messages: messages,
                createdAt: Date(),
                updatedAt: Date()
            )
            threads.append(thread)
        }
        saveThreads()
    }

    private func deleteThread(_ thread: SavedChatThread) {
        threads.removeAll { $0.id == thread.id }
        saveThreads()

        if currentThreadID == thread.id {
            createNewThreadAndSelect()
        }
    }

    private func deleteAllThreads() {
        threads = []
        saveThreads()
        createNewThreadAndSelect()
    }

    private func loadThreads() {
        guard let data = UserDefaults.standard.data(forKey: Self.threadsKey),
              let parsed = try? JSONDecoder().decode([SavedChatThread].self, from: data) else {
            threads = []
            currentThreadID = nil
            currentSessionKey = ""
            return
        }

        threads = parsed

        // Cold launch default: start fresh; older chats remain recoverable in picker.
        currentThreadID = nil
        currentSessionKey = ""
        messages = []
    }

    private func saveThreads() {
        if let data = try? JSONEncoder().encode(threads) {
            UserDefaults.standard.set(data, forKey: Self.threadsKey)
        }
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
        guard !currentSessionKey.isEmpty else { return }

        input = ""
        pendingImage = nil

        messages.append(.init(role: "user", text: text, imageBase64: imageToSend?.jpegData(compressionQuality: 0.75)?.base64EncodedString()))
        isSending = true
        let startedAt = Date()
        defer { isSending = false }

        do {
            let reply = try await api.send(text, image: imageToSend, sessionKey: currentSessionKey)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            messages.append(.init(role: "assistant", text: reply, responseTimeMs: elapsedMs))
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            messages.append(.init(role: "assistant", text: "Error: \(error.localizedDescription)", responseTimeMs: elapsedMs))
        }
    }
}

private struct SavedChatThread: Identifiable, Codable {
    let id: UUID
    let sessionKey: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    var previewTitle: String {
        let firstPrompt = messages.first(where: { $0.role == "user" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "new chat"
        if firstPrompt.isEmpty { return "new chat" }

        let words = firstPrompt.split(whereSeparator: { $0.isWhitespace })
        if words.count <= 8 { return firstPrompt }
        return words.prefix(8).joined(separator: " ") + "..."
    }
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
