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
    @State private var pingMs: Int?
    @State private var pingInFlight = false
    @State private var expandedSections: Set<DrawerSection> = []
    @State private var amazonItems: [SavedListItem] = []
    @State private var todoItems: [SavedListItem] = []
    @State private var miscItems: [SavedListItem] = []

    @FocusState private var inputFocused: Bool

    private static let threadsKey = "chatThreadsV1"
    private static let missedInboxThreadIDKey = "missedInboxThreadID"
    private static let currentThreadIDKey = "currentThreadID"
    private static let amazonItemsKey = "amazonItemsV1"
    private static let todoItemsKey = "todoItemsV1"
    private static let miscItemsKey = "miscItemsV1"

    private enum DrawerSection: String, Hashable {
        case amazon
        case todo
        case misc
        case allChats
    }

    private enum CommandCategory {
        case amazon
        case todo
        case misc
    }

    private let pingTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let eventsTicker = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    @State private var lastEventID: String = UserDefaults.standard.string(forKey: "lastEventID") ?? ""
    @State private var seenEventIDs: Set<String> = []
    @State private var didInitialEventsSync = false
    @State private var missedInboxThreadID: UUID?

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
            loadQuickLists()
            if currentThreadID == nil {
                createNewThreadAndSelect()
            }
            inputFocused = true
            Task { await pollEvents() }
        }
        .onChange(of: messages.count) { _ in
            persistCurrentThread(messages: messages)
        }
        .onChange(of: showThreadPicker) { showing in
            if showing { inputFocused = false }
        }
        .onChange(of: showBackendInfo) { showing in
            if showing {
                Task { await refreshPing() }
            }
        }
        .onReceive(pingTicker) { _ in
            guard showBackendInfo else { return }
            Task { await refreshPing() }
        }
        .onReceive(eventsTicker) { _ in
            Task { await pollEvents() }
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
                    .frame(width: UIScreen.main.bounds.width * 0.7)
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

    private var pingDisplay: String {
        if let pingMs { return "\(pingMs) ms" }
        if pingInFlight { return "measuring..." }
        return "--"
    }

    private func refreshPing() async {
        guard !pingInFlight else { return }
        pingInFlight = true
        defer { pingInFlight = false }

        let base = api.backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: base) else {
            pingMs = nil
            return
        }
        comps.path = "/health"
        comps.query = nil
        comps.fragment = nil

        guard let url = comps.url else {
            pingMs = nil
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0

        let started = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) else {
                pingMs = nil
                return
            }
            pingMs = max(1, Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            pingMs = nil
        }
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
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 38, height: 38)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("New chat")
            }

            if showBackendInfo {
                VStack(spacing: 2) {
                    Text(displayHost)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .lineLimit(1)
                    Text("Ping: \(pingDisplay)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.black.opacity(0.96))
    }

    private var threadPickerDrawer: some View {
        List {
            drawerCategoryHeader(title: "Amazon", section: .amazon)
            if expandedSections.contains(.amazon) {
                if amazonItems.isEmpty {
                    drawerPlaceholderRow("no amazon items yet")
                } else {
                    ForEach(amazonItems) { item in
                        drawerListItemRow(item) {
                            removeQuickListItem(item, category: .amazon)
                        }
                    }
                }
            }

            drawerCategoryHeader(title: "Todo", section: .todo)
            if expandedSections.contains(.todo) {
                if todoItems.isEmpty {
                    drawerPlaceholderRow("no todo items yet")
                } else {
                    ForEach(todoItems) { item in
                        drawerListItemRow(item) {
                            removeQuickListItem(item, category: .todo)
                        }
                    }
                }
            }

            drawerCategoryHeader(title: "Misc", section: .misc)
            if expandedSections.contains(.misc) {
                if miscItems.isEmpty {
                    drawerPlaceholderRow("no misc items yet")
                } else {
                    ForEach(miscItems) { item in
                        drawerListItemRow(item) {
                            removeQuickListItem(item, category: .misc)
                        }
                    }
                }
            }

            drawerCategoryHeader(title: "All Chats", section: .allChats)
            if expandedSections.contains(.allChats) {
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

                if !threadsSortedByRecency.isEmpty {
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

    @ViewBuilder
    private func drawerCategoryHeader(title: String, section: DrawerSection) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedSections.contains(section) {
                    expandedSections.remove(section)
                } else {
                    expandedSections.insert(section)
                }
            }
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.white)
                    .font(.headline)
                Spacer()
                Image(systemName: expandedSections.contains(section) ? "chevron.down" : "chevron.right")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color(red: 0.18, green: 0.18, blue: 0.18))
    }

    @ViewBuilder
    private func drawerPlaceholderRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.gray)
            .padding(.vertical, 6)
            .listRowBackground(Color(red: 0.18, green: 0.18, blue: 0.18))
    }

    @ViewBuilder
    private func drawerListItemRow(_ item: SavedListItem, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(item.text)
                .font(.body)
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete item")
        }
        .padding(.vertical, 4)
        .listRowBackground(Color(red: 0.18, green: 0.18, blue: 0.18))
    }

    private var threadsSortedByRecency: [SavedChatThread] {
        threads
            .filter { thread in
                thread.customTitle != "missed messages" && thread.messages.contains(where: { $0.role == "user" })
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func createNewThreadAndSelect() {
        let id = UUID()
        currentThreadID = id
        currentSessionKey = "ios-ui-\(id.uuidString.lowercased())"
        messages = []
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentThreadIDKey)
    }

    private func getOrCreateMissedInboxThread() -> SavedChatThread {
        if let existingID = missedInboxThreadID,
           let existing = threads.first(where: { $0.id == existingID }) {
            return existing
        }

        let id = UUID()
        let thread = SavedChatThread(
            id: id,
            sessionKey: "ios-missed-\(id.uuidString.lowercased())",
            messages: [],
            createdAt: Date(),
            updatedAt: Date(),
            customTitle: "missed messages"
        )

        threads.append(thread)
        missedInboxThreadID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.missedInboxThreadIDKey)
        saveThreads()
        return thread
    }

    private func appendMissedEventsToInbox(_ events: [ServerEvent]) {
        let newBodies = events
            .map { $0.message.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !newBodies.isEmpty else { return }

        var thread = getOrCreateMissedInboxThread()
        for body in newBodies {
            thread.messages.append(.init(role: "assistant", text: body))
        }
        thread.updatedAt = Date()

        if let idx = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[idx] = thread
        }
        saveThreads()
    }

    private func selectThread(_ thread: SavedChatThread) {
        currentThreadID = thread.id
        currentSessionKey = thread.sessionKey
        messages = thread.messages
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.currentThreadIDKey)
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
                updatedAt: Date(),
                customTitle: nil
            )
            threads.append(thread)
        }
        saveThreads()
    }

    private func deleteThread(_ thread: SavedChatThread) {
        threads.removeAll { $0.id == thread.id }

        if missedInboxThreadID == thread.id {
            missedInboxThreadID = nil
            UserDefaults.standard.removeObject(forKey: Self.missedInboxThreadIDKey)
        }

        saveThreads()

        if currentThreadID == thread.id {
            createNewThreadAndSelect()
        }
    }

    private func deleteAllThreads() {
        threads = []
        missedInboxThreadID = nil
        UserDefaults.standard.removeObject(forKey: Self.missedInboxThreadIDKey)

        // Immediately recreate/select inbox so UI always has an active chat.
        let missedThread = getOrCreateMissedInboxThread()
        selectThread(missedThread)

        saveThreads()
        showThreadPicker = false
        showDeleteAllConfirm = false
    }

    private func loadThreads() {
        if let data = UserDefaults.standard.data(forKey: Self.threadsKey),
           let parsed = try? JSONDecoder().decode([SavedChatThread].self, from: data) {
            threads = parsed
        } else {
            threads = []
        }

        if let raw = UserDefaults.standard.string(forKey: Self.missedInboxThreadIDKey),
           let id = UUID(uuidString: raw),
           threads.contains(where: { $0.id == id }) {
            missedInboxThreadID = id
        } else {
            missedInboxThreadID = nil
        }

        // On launch, always open "missed messages" as current chat.
        let missedThread = getOrCreateMissedInboxThread()
        selectThread(missedThread)
    }

    private func saveThreads() {
        if let data = try? JSONEncoder().encode(threads) {
            UserDefaults.standard.set(data, forKey: Self.threadsKey)
        }
    }

    private func loadQuickLists() {
        amazonItems = loadList(forKey: Self.amazonItemsKey)
        todoItems = loadList(forKey: Self.todoItemsKey)
        miscItems = loadList(forKey: Self.miscItemsKey)
    }

    private func loadList(forKey key: String) -> [SavedListItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let parsed = try? JSONDecoder().decode([SavedListItem].self, from: data) else {
            return []
        }
        return parsed
    }

    private func saveQuickLists() {
        saveList(amazonItems, key: Self.amazonItemsKey)
        saveList(todoItems, key: Self.todoItemsKey)
        saveList(miscItems, key: Self.miscItemsKey)
    }

    private func saveList(_ items: [SavedListItem], key: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func parseQuickListCommand(_ rawText: String) -> (category: CommandCategory, itemText: String)? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let prefixes: [(String, CommandCategory)] = [
            ("amazon", .amazon),
            ("todo", .todo),
            ("misc", .misc)
        ]

        for (prefix, category) in prefixes {
            if lower == prefix {
                return nil
            }
            if lower.hasPrefix(prefix + " ") || lower.hasPrefix(prefix + ":") {
                let body = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :\t\n"))
                guard !body.isEmpty else { return nil }
                return (category, body)
            }
        }
        return nil
    }

    private func addQuickListItem(text: String, category: CommandCategory) {
        let item = SavedListItem(id: UUID(), text: text, createdAt: Date())
        switch category {
        case .amazon:
            amazonItems.insert(item, at: 0)
        case .todo:
            todoItems.insert(item, at: 0)
        case .misc:
            miscItems.insert(item, at: 0)
        }
        saveQuickLists()
    }

    private func drawerSection(for category: CommandCategory) -> DrawerSection {
        switch category {
        case .amazon:
            return .amazon
        case .todo:
            return .todo
        case .misc:
            return .misc
        }
    }

    private func removeQuickListItem(_ item: SavedListItem, category: CommandCategory) {
        switch category {
        case .amazon:
            amazonItems.removeAll { $0.id == item.id }
        case .todo:
            todoItems.removeAll { $0.id == item.id }
        case .misc:
            miscItems.removeAll { $0.id == item.id }
        }
        saveQuickLists()
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
        .contextMenu {
            if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Copy") {
                    UIPasteboard.general.string = m.text
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

    private func pollEvents() async {
        let events = await api.fetchEvents(since: lastEventID.isEmpty ? nil : lastEventID)
        let firstSync = !didInitialEventsSync

        if !events.isEmpty {
            var newestID = lastEventID
            var unseenEvents: [ServerEvent] = []

            for event in events {
                newestID = event.id

                if seenEventIDs.contains(event.id) {
                    continue
                }
                seenEventIDs.insert(event.id)
                unseenEvents.append(event)

                if seenEventIDs.count > 500 {
                    seenEventIDs = Set(seenEventIDs.suffix(250))
                }
            }

            if firstSync {
                appendMissedEventsToInbox(unseenEvents)
            }

            if newestID != lastEventID {
                lastEventID = newestID
                UserDefaults.standard.set(newestID, forKey: "lastEventID")
            }
        }

        if firstSync {
            didInitialEventsSync = true
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageToSend = pendingImage
        guard !text.isEmpty || imageToSend != nil else { return }
        guard !currentSessionKey.isEmpty else { return }

        if imageToSend == nil, let command = parseQuickListCommand(text) {
            addQuickListItem(text: command.itemText, category: command.category)
            expandedSections.insert(drawerSection(for: command.category))
            input = ""
            pendingImage = nil
            return
        }

        if let missedID = missedInboxThreadID, missedID == currentThreadID {
            missedInboxThreadID = nil
            UserDefaults.standard.removeObject(forKey: Self.missedInboxThreadIDKey)
        }

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

private struct SavedListItem: Identifiable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
}

private struct SavedChatThread: Identifiable, Codable {
    let id: UUID
    let sessionKey: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date
    var customTitle: String?

    var previewTitle: String {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }

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
