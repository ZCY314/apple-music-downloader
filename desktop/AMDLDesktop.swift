import SwiftUI
import AppKit
import Darwin
import ImageIO

@main
struct AMDLDesktopApp: App {
    @AppStorage("amdl.appearance") private var appearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(preferredScheme)
        }
        .windowStyle(.titleBar)
    }
}

struct CatalogItem: Decodable, Identifiable, Hashable {
    let type: String
    let name: String
    let detail: String
    let url: String
    let id: String
    let artwork: String
    var imageURL: URL? {
        let sized = artwork.replacingOccurrences(of: "{w}x{h}", with: "420x420")
        return URL(string: sized)
    }
}

struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

@MainActor
final class ArtworkStore {
    static let shared = ArtworkStore()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) async -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}

struct CatalogArtwork: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045))
                    .overlay(Image(systemName: "waveform").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.secondary.opacity(0.45)))
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ArtworkStore.shared.image(for: url)
        }
    }
}

enum AppPage: String, CaseIterable {
    case discover = "发现"
    case queue = "队列"
    case activity = "记录"
    case settings = "设置"

    var symbol: String {
        switch self {
        case .discover: return "sparkle.magnifyingglass"
        case .queue: return "square.stack.3d.up"
        case .activity: return "waveform.path"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct QueueJob: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var status: String = "待处理"
    var attempts: Int = 0
    var createdAt = Date()
    var message = ""
    var progress: Double?
    var stage: String?
    var currentTrack: Int?
    var totalTracks: Int?
    var transferred: String?
    var transferSpeed: String?
}

final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ value: String) {
        lock.lock()
        storage += value
        lock.unlock()
    }
    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct MainView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("amdl.appearance") private var appearance = "system"
    @State private var page: AppPage = .discover
    @State private var isSidebarVisible = true
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool
    @State private var searchType = "album"
    @State private var queueJobs: [QueueJob] = []
    @State private var historyJobs: [QueueJob] = []
    @State private var isPaused = false
    @State private var currentJobID: UUID?
    @State private var results: [CatalogItem] = []
    @State private var selectedIDs: Set<String> = []
    @State private var queueURLs: [String] = []
    @AppStorage("amdl.savedQueue") private var savedQueue = ""
    @AppStorage("amdl.queueJobs.v2") private var persistedJobs = ""
    @AppStorage("amdl.history.v2") private var persistedHistory = ""
    @State private var pastedLinks = ""
    @AppStorage("amdl.quality") private var quality = "ALAC"
    @AppStorage("amdl.language") private var language = "system"
    @AppStorage("amdl.storefront") private var storefront = "cn"
    @State private var isSearching = false
    @State private var isDownloading = false
    @State private var activity = "准备就绪。\n\n在「发现」中搜索音乐，或把 Apple Music 链接粘贴到下载队列。"
    @State private var downloadProcess: Process?
    @State private var searchMessage = ""
    @State private var configPath = NSHomeDirectory() + "/Music/AppleMusic/config.yaml"
    @State private var workspaceArtwork: NSImage?

    private var isDark: Bool { colorScheme == .dark }
    private var ink: Color { isDark ? Color(hex: 0xF0EDE5) : Color(hex: 0x20211F) }
    private var paper: Color { isDark ? Color(hex: 0x252622) : Color(hex: 0xF6F6F2) }
    private var muted: Color { isDark ? Color(hex: 0xB6B4AC) : Color(hex: 0x777A75) }
    private var accent: Color { isDark ? Color(hex: 0xD18A72) : Color(hex: 0xA85B48) }
    private var surface: Color { isDark ? Color(hex: 0x20211F).opacity(0.72) : Color(hex: 0xF8F6F0).opacity(0.42) }
    private var selectedSurface: Color { isDark ? Color(hex: 0xF0EDE5).opacity(0.14) : Color(hex: 0xE8E9E3).opacity(0.78) }
    private var panelSurface: Color { isDark ? Color(hex: 0x171815).opacity(0.62) : Color(hex: 0xFBF9F3).opacity(0.36) }
    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 28, alignment: .top)]

    private var useEnglish: Bool {
        if language == "en" { return true }
        if language == "zh-Hans" { return false }
        return Locale.current.language.languageCode?.identifier == "en"
    }

    private func tr(_ chinese: String, _ english: String) -> String {
        useEnglish ? english : chinese
    }

    private func pageTitle(_ value: AppPage) -> String {
        switch value {
        case .discover: return tr("发现", "Discover")
        case .queue: return tr("队列", "Queue")
        case .activity: return tr("记录", "Activity")
        case .settings: return tr("设置", "Settings")
        }
    }

    private func displayStatus(_ value: String) -> String {
        switch value {
        case "待处理": return tr("待处理", "Pending")
        case "下载中": return tr("下载中", "Downloading")
        case "已暂停": return tr("已暂停", "Paused")
        case "完成": return tr("完成", "Completed")
        case "失败": return tr("失败", "Failed")
        default: return value
        }
    }

    private func isAppleMusicLink(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              components.scheme == "https",
              let host = components.host?.lowercased(),
              host == "music.apple.com" || host == "classical.music.apple.com" else { return false }
        return components.path.split(separator: "/").count >= 2
    }

    private var validPastedLinks: [String] {
        var seen = Set(queueJobs.map(\.url))
        return pastedLinks.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isAppleMusicLink($0) && seen.insert($0).inserted }
    }

    private var invalidPastedLinkCount: Int {
        pastedLinks.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isAppleMusicLink($0) }.count
    }

    private var unfinishedJobCount: Int {
        queueJobs.filter { $0.status != "完成" }.count
    }

    private func appendActivity(_ message: String) {
        activity += message
        if activity.count > 24000 {
            activity = String(activity.suffix(18000))
        }
    }

    var body: some View {
        ZStack {
            artworkBackdrop
            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    topBar
                    Group {
                        switch page {
                        case .discover: discoverPage
                        case .queue: queuePage
                        case .activity: activityPage
                        case .settings: settingsPage
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(isDark ? Color(hex: 0x171815) : Color(hex: 0xF6F3EB))
        .animation(.easeInOut(duration: 0.18), value: page)
        .onChange(of: searchType) { _ in results.removeAll(); selectedIDs.removeAll(); searchMessage = "" }
        .onChange(of: queueURLs) { newValue in savedQueue = newValue.joined(separator: "\n") }
        .onChange(of: queueJobs) { newValue in
            if let data = try? JSONEncoder().encode(newValue) { persistedJobs = data.base64EncodedString() }
        }
        .onChange(of: historyJobs) { newValue in
            if let data = try? JSONEncoder().encode(newValue) { persistedHistory = data.base64EncodedString() }
        }
        .onAppear {
            if activity == "准备就绪。\n\n在「发现」中搜索音乐，或把 Apple Music 链接粘贴到下载队列。" {
                activity = tr("准备就绪。\n\n在「发现」中搜索音乐，或把 Apple Music 链接粘贴到下载队列。", "Ready.\n\nSearch for music in Discover, or paste Apple Music links into the download queue.")
            }
            if let artworkURL = Bundle.main.url(forResource: "AutumnLandscape", withExtension: "jpg") {
                workspaceArtwork = NSImage(contentsOf: artworkURL)
            }
            if queueURLs.isEmpty && !savedQueue.isEmpty {
                let legacy = savedQueue.components(separatedBy: .newlines).filter { !$0.isEmpty }
                if queueJobs.isEmpty { queueJobs = legacy.map { QueueJob(url: $0) } }
                else { queueURLs = legacy }
                savedQueue = ""
            }
            if let data = Data(base64Encoded: persistedJobs), let decoded = try? JSONDecoder().decode([QueueJob].self, from: data) {
                queueJobs = decoded.map { job in var value = job; if value.status == "下载中" { value.status = "待处理"; value.message = "应用重新启动，等待继续" }; return value }
            }
            if let data = Data(base64Encoded: persistedHistory), let decoded = try? JSONDecoder().decode([QueueJob].self, from: data) { historyJobs = decoded }
            if !FileManager.default.fileExists(atPath: configPath) {
                activity = tr("尚未找到配置文件。首次运行时，请先检查 ~/Music/AppleMusic/config.yaml。", "Configuration file not found. Check ~/Music/AppleMusic/config.yaml before first use.")
            }
        }
    }

    private var artworkBackdrop: some View {
        GeometryReader { geometry in
            ZStack {
                if let workspaceArtwork {
                    Image(nsImage: workspaceArtwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Color(hex: 0xE9E3D6)
                }

                // Keep the original pigments visible. Contrast is provided by
                // local translucent surfaces, not a screen-wide grey veil.
                LinearGradient(
                    stops: [
                        .init(color: (isDark ? Color.black : Color(hex: 0xF8F3E8)).opacity(isDark ? 0.20 : 0.20), location: 0.0),
                        .init(color: Color.clear, location: 0.22),
                        .init(color: Color.clear, location: 0.76),
                        .init(color: (isDark ? Color.black : Color(hex: 0xF8F3E8)).opacity(isDark ? 0.28 : 0.12), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    colors: [(isDark ? Color.black : Color(hex: 0xF8F3E8)).opacity(0.10), .clear, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    private func sidebarButton(for item: AppPage) -> some View {
        let isSelected = page == item
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { page = item }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: item.symbol)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)
                Text(pageTitle(item))
                    .font(.system(size: 18, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 4)
                if item == .queue && unfinishedJobCount > 0 {
                    Text("\(unfinishedJobCount)")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(muted)
                }
            }
            .foregroundStyle(isSelected ? ink : muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? selectedSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(pageTitle(item))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 25)).foregroundStyle(ink)
                Text("AMDL").font(.system(size: 22, weight: .semibold)).tracking(0.8).foregroundStyle(ink)
            }
            .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 38)
            VStack(spacing: 5) {
                ForEach(AppPage.allCases, id: \.self) { item in
                    sidebarButton(for: item)
                }
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(width: 202).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial.opacity(0.62))
        .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.07)).frame(width: 1) }
        .zIndex(2)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: isSidebarVisible ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(width: 38, height: 38)
                    .background(surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSidebarVisible ? tr("隐藏边栏", "Hide sidebar") : tr("显示边栏", "Show sidebar"))
            Text(pageTitle(page))
                .font(.system(size: 30, weight: .semibold, design: .default)).foregroundStyle(ink)
            Spacer()
            if isDownloading {
                Text(isPaused ? tr("已暂停", "Paused") : tr("正在下载", "Downloading"))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(muted)
            }
        }
        .padding(.horizontal, 38).padding(.top, 30).padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [(isDark ? Color.black : Color(hex: 0xF8F3E8)).opacity(0.16), (isDark ? Color.black : Color(hex: 0xF8F3E8)).opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var discoverPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(muted)
                    TextField(tr("搜索专辑、歌曲、歌单、厂牌或策展人", "Search albums, songs, playlists, labels or curators"), text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 22, weight: .regular))
                        .focused($searchIsFocused)
                        .onSubmit { Task { await searchCatalog() } }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(muted)
                            .accessibilityLabel(tr("清除搜索", "Clear search"))
                    }
                }
                .padding(.horizontal, 17).frame(height: 52)
                .background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(searchIsFocused ? accent.opacity(0.55) : ink.opacity(0.10), lineWidth: searchIsFocused ? 1.3 : 0.8))
                .shadow(color: searchIsFocused ? accent.opacity(0.10) : .clear, radius: 8, x: 0, y: 2)
                .animation(.easeOut(duration: 0.18), value: searchIsFocused)
                Picker(tr("类型", "Type"), selection: $searchType) {
                    Text(tr("专辑", "Albums")).tag("album")
                    Text(tr("歌曲", "Songs")).tag("song")
                    Text(tr("艺人", "Artists")).tag("artist")
                    Text(tr("歌单", "Playlists")).tag("playlist")
                    Text(tr("厂牌", "Record Labels")).tag("record-labels")
                    Text(tr("策展人", "Curators")).tag("curators")
                }
                .pickerStyle(.menu).font(.system(size: 18, weight: .medium)).frame(width: 124)
                Button {
                    Task { await searchCatalog() }
                } label: {
                    HStack(spacing: 8) {
                        if isSearching { ProgressView().controlSize(.small).tint(paper) }
                        else { Image(systemName: "arrow.right") }
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52).background(accent).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(SoftPressStyle()).scaleEffect(isSearching ? 0.97 : 1).animation(.spring(response: 0.24, dampingFraction: 0.72), value: isSearching).disabled(isSearching || searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !searchMessage.isEmpty {
                Text(searchMessage).font(.system(size: 15)).foregroundStyle(muted)
            }

            HStack(alignment: .firstTextBaseline) {
                if !results.isEmpty {
                    Text(tr("结果", "Results"))
                        .font(.system(size: 24, weight: .medium)).foregroundStyle(ink)
                }
                Spacer()
                if !selectedIDs.isEmpty {
                    Button {
                        addSelectedToQueue()
                    } label: {
                        Label(tr("加入队列", "Add to Queue") + " · \(selectedIDs.count)", systemImage: "plus")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 8).background(accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }

            if results.isEmpty && !isSearching {
                emptyDiscovery
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(results) { item in
                            resultCard(item)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 38).padding(.bottom, 26)
    }

    private var emptyDiscovery: some View {
        Color.clear.frame(maxWidth: .infinity, minHeight: 280)
            .accessibilityHidden(true)
    }

    private func resultCard(_ item: CatalogItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        return Button {
            if item.type == "record-labels" || item.type == "curators" {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            } else if selected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    CatalogArtwork(url: item.imageURL)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26, weight: .regular))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(paper, accent)
                            .padding(9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ink.opacity(0.10), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.10), radius: 7, x: 0, y: 3)
                Text(item.name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
            .opacity(selected ? 0.78 : 1)
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel("\(item.name), \(item.detail)")
        .accessibilityHint(item.type == "record-labels" || item.type == "curators" ? tr("打开 Apple Music 页面", "Open Apple Music page") : (selected ? tr("取消选择", "Deselect item") : tr("选择此项目", "Select item")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.16), value: selected)
        .contextMenu {
            if item.type != "record-labels" && item.type != "curators" {
                Button(tr("加入队列", "Add to Queue")) { if !queueJobs.contains(where: { $0.url == item.url }) { queueJobs.append(QueueJob(url: item.url, message: item.name)) } }
            }
            Button(tr("在 Apple Music 中打开", "Open in Apple Music")) { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
        }
    }

    private var queuePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("下载队列", "Download Queue")).font(.system(size: 28, weight: .semibold)).foregroundStyle(ink)
                }
                Spacer()
                Button {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        pastedLinks = [pastedLinks, value].filter { !$0.isEmpty }.joined(separator: "\n")
                    }
                } label: { Label(tr("粘贴链接", "Paste Links"), systemImage: "doc.on.clipboard").font(.system(size: 16, weight: .semibold)) }
                    .buttonStyle(.bordered)
            }
            TextEditor(text: $pastedLinks)
                .font(.system(size: 17, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10).frame(height: 110)
                .background(panelSurface).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if pastedLinks.isEmpty {
                        Text(tr("粘贴 Apple Music 链接，每行一个……", "Paste Apple Music links, one per line…"))
                            .font(.system(size: 17)).foregroundStyle(muted.opacity(0.65)).padding(16).allowsHitTesting(false)
                    }
                }
            HStack {
                Text(tr("下载任务", "Downloads")).font(.system(size: 24, weight: .medium)).foregroundStyle(ink)
                Spacer()
                Text(tr("\(unfinishedJobCount + queueURLs.count + validPastedLinks.count) 个待处理", "\(unfinishedJobCount + queueURLs.count + validPastedLinks.count) pending")).font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
                Button(tr("清空", "Clear")) { queueJobs.removeAll(); queueURLs.removeAll(); pastedLinks = "" }.buttonStyle(.plain).foregroundStyle(muted).disabled(isDownloading)
            }
            if invalidPastedLinkCount > 0 {
                Label(tr("\(invalidPastedLinkCount) 行不是有效的 Apple Music 链接，已忽略。", "\(invalidPastedLinkCount) invalid Apple Music link(s) ignored."), systemImage: "exclamationmark.circle")
                    .font(.system(size: 15)).foregroundStyle(accent)
            }
            if queueJobs.isEmpty && queueURLs.isEmpty && validPastedLinks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(muted)
                    Text(tr("队列是空的", "Your queue is empty")).font(.system(size: 18, weight: .medium)).foregroundStyle(ink)
                    Text(tr("从搜索结果添加，或粘贴链接。", "Add items from search results or paste links.")).font(.system(size: 15)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text(tr("任务", "Tasks")).font(.system(size: 22, weight: .medium)).foregroundStyle(ink)
                    Spacer()
                    Text(tr("\(queueJobs.filter { $0.status == "完成" }.count) / \(queueJobs.count + queueURLs.count + validPastedLinks.count) 完成", "\(queueJobs.filter { $0.status == "完成" }.count) / \(queueJobs.count + queueURLs.count + validPastedLinks.count) completed")).font(.system(size: 15)).foregroundStyle(muted)
                    if isDownloading && !isPaused {
                        Button { pauseQueue() } label: { Label(tr("暂停", "Pause"), systemImage: "pause.fill") }.buttonStyle(.bordered)
                    } else if isPaused {
                        Button { resumeQueue() } label: { Label(tr("继续", "Resume"), systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(ink)
                    }
                    Button { retryFailedJobs() } label: { Label(tr("重试失败", "Retry Failed"), systemImage: "arrow.clockwise") }.buttonStyle(.bordered).disabled(!queueJobs.contains { $0.status == "失败" })
                }
                List {
                    ForEach(queueJobs) { job in
                        HStack(spacing: 12) {
                            Image(systemName: job.status == "完成" ? "checkmark.circle.fill" : job.status == "失败" ? "exclamationmark.circle.fill" : job.status == "下载中" ? "arrow.down.circle.fill" : "circle.dashed")
                                .foregroundStyle(job.status == "失败" ? Color.red : job.status == "完成" ? Color.green : accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(string: job.url)?.lastPathComponent ?? job.url).font(.system(size: 16, weight: .medium)).lineLimit(1)
                                Text(job.stage ?? (job.message.isEmpty ? job.url : job.message)).font(.system(size: 15)).foregroundStyle(muted).lineLimit(1)
                                if let progress = job.progress, job.status == "下载中" || job.status == "已暂停" {
                                    ProgressView(value: progress / 100).tint(accent).frame(maxWidth: 260)
                                    HStack(spacing: 9) {
                                        Text(String(format: "%.0f%%", progress))
                                        if let transferred = job.transferred { Text(transferred) }
                                        if let speed = job.transferSpeed { Text(speed) }
                                        if let current = job.currentTrack, let total = job.totalTracks { Text("Track \(current)/\(total)") }
                                    }
                                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(muted)
                                }
                            }
                            Spacer()
                            Text(displayStatus(job.status)).font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
                            if job.status == "失败" {
                                Button { retryJob(job.id) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                            }
                            Button { removeJob(job.id) } label: { Image(systemName: "xmark").foregroundStyle(muted) }
                                .buttonStyle(.plain).accessibilityLabel(tr("移除任务", "Remove task"))
                        }.listRowBackground(panelSurface.opacity(0.78))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("音质", "Audio Quality")).font(.system(size: 15, weight: .bold)).tracking(1.1).foregroundStyle(muted)
                    Picker(tr("音质", "Audio Quality"), selection: $quality) {
                        Text(tr("ALAC 无损", "ALAC Lossless")).tag("ALAC")
                        Text("Dolby Atmos").tag("ATMOS")
                        Text("AAC").tag("AAC")
                    }.pickerStyle(.segmented).frame(width: 330)
                }
                Spacer()
                Button {
                    startDownload()
                } label: {
                    Label(isDownloading ? (isPaused ? tr("已暂停", "Paused") : tr("正在下载…", "Downloading…")) : tr("开始下载", "Start Download"), systemImage: "arrow.down.to.line")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(height: 44).background(accent).clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain).disabled(isDownloading || (queueURLs.isEmpty && validPastedLinks.isEmpty && !queueJobs.contains(where: { $0.status == "待处理" })))
                .opacity(isDownloading || (!queueURLs.isEmpty || !validPastedLinks.isEmpty || queueJobs.contains(where: { $0.status == "待处理" })) ? 1 : 0.48)
            }
        }
        .padding(.horizontal, 34).padding(.bottom, 28)
    }

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("活动记录", "Activity")).font(.system(size: 28, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Button(tr("清空记录", "Clear Activity")) { activity = "" }.buttonStyle(.plain).foregroundStyle(muted)
                if isDownloading && !isPaused {
                    Button(tr("暂停", "Pause")) { pauseQueue() }.buttonStyle(.bordered)
                } else if isPaused {
                    Button(tr("恢复", "Resume")) { resumeQueue() }.buttonStyle(.borderedProminent).tint(ink)
                }
            }
            ScrollView {
                Text(activity.isEmpty ? tr("暂无活动。", "No activity yet.") : activity)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(18)
            }
            .background(panelSurface).clipShape(RoundedRectangle(cornerRadius: 14))
            if !historyJobs.isEmpty {
                Text(tr("最近完成", "Recently Completed") + " · \(historyJobs.count)").font(.system(size: 20, weight: .medium)).foregroundStyle(ink)
                ForEach(historyJobs.prefix(8)) { job in
                    HStack { Text(URL(string: job.url)?.lastPathComponent ?? job.url).lineLimit(1); Spacer(); Text(displayStatus(job.status)).foregroundStyle(muted) }
                        .font(.system(size: 15)).padding(.vertical, 3)
                }
            }
            HStack {
                Label(isPaused ? tr("下载已暂停", "Downloads paused") : (isDownloading ? tr("下载进程运行中", "Download process running") : tr("下载进程空闲", "Download process idle")), systemImage: isPaused ? "pause.circle.fill" : (isDownloading ? "arrow.down.circle.fill" : "checkmark.circle"))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Button(tr("打开音乐文件夹", "Open Music Folder")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic"))
                }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 34).padding(.bottom, 26)
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("外观", "Appearance")).font(.system(size: 18, weight: .semibold)).foregroundStyle(ink)
                    Text(tr("默认跟随 macOS 外观，也可手动选择。", "Follow macOS appearance by default, or choose manually.")).font(.system(size: 15)).foregroundStyle(muted)
                }
                Spacer()
                Picker(tr("外观", "Appearance"), selection: $appearance) {
                    Text(tr("跟随系统", "System")).tag("system")
                    Text(tr("浅色", "Light")).tag("light")
                    Text(tr("深色", "Dark")).tag("dark")
                }.pickerStyle(.segmented).frame(width: 270)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("界面语言", "Interface Language")).font(.system(size: 18, weight: .semibold)).foregroundStyle(ink)
                    Text(tr("选择应用显示语言。", "Choose the language used throughout the app.")).font(.system(size: 15)).foregroundStyle(muted)
                }
                Spacer()
                Picker(tr("界面语言", "Interface Language"), selection: $language) {
                    Text(tr("跟随系统", "System")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }.pickerStyle(.segmented).frame(width: 270)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("音乐目录", "Music Library")).font(.system(size: 26, weight: .semibold)).foregroundStyle(ink)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("首选地区", "Preferred Storefront")).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                    Text(tr("更改后会写入现有 AMDL 配置。", "Changes are saved to your existing AMDL configuration.")).font(.system(size: 15)).foregroundStyle(muted)
                }
                Spacer()
                Picker(tr("地区", "Storefront"), selection: $storefront) {
                    Text(tr("中国大陆 · CN", "Mainland China · CN")).tag("cn")
                    Text(tr("香港 · HK", "Hong Kong · HK")).tag("hk")
                    Text(tr("台湾 · TW", "Taiwan · TW")).tag("tw")
                    Text(tr("新加坡 · SG", "Singapore · SG")).tag("sg")
                    Text(tr("美国 · US", "United States · US")).tag("us")
                }.frame(width: 220)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("下载位置", "Download Location")).font(.system(size: 26, weight: .medium)).foregroundStyle(ink)
                Text(NSHomeDirectory() + "/Music/AppleMusic").font(.system(size: 16, design: .monospaced)).foregroundStyle(muted)
                Button(tr("在 Finder 中打开", "Reveal in Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")) }.buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(.horizontal, 34).padding(.bottom, 28)
        .onChange(of: storefront) { _ in updateStorefrontConfig() }
    }

    @MainActor
    private func searchCatalog() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        selectedIDs.removeAll()
        results.removeAll()
        searchMessage = ""
        defer { isSearching = false }
        do {
            let found = try await runJSONSearch(type: searchType, query: query)
            var combined: [CatalogItem] = []
            var seen = Set<String>()
            for item in found where seen.insert(item.id).inserted {
                combined.append(item)
            }
            results = combined
            searchMessage = ""
            if combined.isEmpty { searchMessage = tr("没有找到结果，试试更短的关键词。", "No results. Try a shorter search term.") }
        } catch {
            searchMessage = tr("检索失败：", "Search failed: ") + error.localizedDescription
            appendActivity("\n检索错误：\(error.localizedDescription)")
        }
    }

    private func runJSONSearch(type: String, query: String) async throws -> [CatalogItem] {
        let args = ["--config", configPath, "--search", type, "--json-search"] + query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let data = try await runAMDL(arguments: args)
        return try JSONDecoder().decode([CatalogItem].self, from: data)
    }

    private func runAMDL(arguments: [String]) async throws -> Data {
        let executable = Bundle.main.resourceURL?.appendingPathComponent("amdl")
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic/amdl")
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSearchProcess(executable: executable, arguments: arguments)
        }.value
    }

    nonisolated private static func runSearchProcess(executable: URL, arguments: [String]) throws -> Data {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        try task.run()

        var outputData = Data()
        var errorData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        task.waitUntilExit()
        readers.wait()

        guard task.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail?.isEmpty == false ? detail! : "AMDL 检索进程退出，代码 \(task.terminationStatus)。"
            throw NSError(domain: "AMDL", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return outputData
    }

    private func addSelectedToQueue() {
        let chosen = results.filter { selectedIDs.contains($0.id) }
        for item in chosen where !queueJobs.contains(where: { $0.url == item.url }) {
            queueJobs.append(QueueJob(url: item.url, message: item.name))
        }
        selectedIDs.removeAll()
        page = .queue
    }

    private func startDownload() {
        let urls = queueURLs + validPastedLinks
        guard (!urls.isEmpty || queueJobs.contains(where: { $0.status == "待处理" })), !isDownloading else { return }
        updateStorefrontConfig()
        for url in urls {
            if let existing = queueJobs.firstIndex(where: { $0.url == url }) {
                if queueJobs[existing].status == "失败" {
                    queueJobs[existing].status = "待处理"
                    queueJobs[existing].message = "等待重试"
                }
            } else {
                queueJobs.append(QueueJob(url: url))
            }
        }
        queueURLs.removeAll()
        pastedLinks = ""
        isPaused = false
        startNextJob()
        page = .queue
    }

    private func startNextJob() {
        guard !isPaused, !isDownloading else { return }
        guard let index = queueJobs.firstIndex(where: { $0.status == "待处理" }) else {
            isDownloading = false
            currentJobID = nil
            return
        }
        let job = queueJobs[index]
        currentJobID = job.id
        queueJobs[index].status = "下载中"
        queueJobs[index].attempts += 1
        isDownloading = true
        let executable = Bundle.main.resourceURL?.appendingPathComponent("amdl")
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic/amdl")
        let task = Process()
        let pipe = Pipe()
        let outputBuffer = ProcessOutputBuffer()
        var args = ["--config", configPath, "--exit-on-error", "--json"]
        if quality == "ATMOS" { args.append("--atmos") }
        if quality == "AAC" { args.append("--aac") }
        args.append(job.url)
        task.executableURL = executable
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            outputBuffer.append(chunk)
            DispatchQueue.main.async {
                appendActivity(chunk)
                if let idx = queueJobs.firstIndex(where: { $0.id == job.id }) {
                    updateJobProgress(at: idx, from: chunk)
                }
            }
        }
        task.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let idx = queueJobs.firstIndex(where: { $0.id == job.id }) else { return }
                let summary = Self.downloadSummary(from: outputBuffer.value)
                let hasSavedTracks = summary.map { !$0.isEmpty } ?? false
                let status = finished.terminationStatus == 0 && hasSavedTracks ? "完成" : "失败"
                queueJobs[idx].status = status
                queueJobs[idx].message = status == "完成"
                    ? tr("已保存 \(summary?.count ?? 0) 首曲目", "Saved \(summary?.count ?? 0) track(s)")
                    : (finished.terminationStatus != 0
                        ? tr("下载失败，退出代码 \(finished.terminationStatus)，查看活动记录中的详细错误", "Download failed (exit \(finished.terminationStatus)); inspect Activity for the error")
                        : tr("没有曲目成功写入；查看活动记录中的 CLI 结果", "No tracks were saved; inspect the CLI result in Activity"))
                historyJobs.insert(queueJobs[idx], at: 0)
                if historyJobs.count > 100 { historyJobs = Array(historyJobs.prefix(100)) }
                appendActivity("\n\n\(status) · exit \(finished.terminationStatus)\n")
                downloadProcess = nil
                currentJobID = nil
                isDownloading = false
                if !isPaused { startNextJob() }
            }
        }
        do {
            activity = ""
            appendActivity("开始下载 · \(job.url) · \(quality)\n")
            downloadProcess = task
            try task.run()
        } catch {
            queueJobs[index].status = "失败"
            queueJobs[index].message = error.localizedDescription
            isDownloading = false
            downloadProcess = nil
            appendActivity("\n启动失败：\(error.localizedDescription)")
            startNextJob()
        }
    }

    private func updateJobProgress(at index: Int, from chunk: String) {
        let cleaned = chunk.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = cleaned.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            queueJobs[index].stage = value
            if let range = value.range(of: #"([0-9]{1,3})%"#, options: .regularExpression),
               let percent = Double(value[range].dropLast()) {
                queueJobs[index].progress = min(100, max(0, percent))
            }
            if let track = value.range(of: #"Track ([0-9]+) of ([0-9]+)"#, options: .regularExpression) {
                let numbers = value[track].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if numbers.count >= 2 {
                    queueJobs[index].currentTrack = numbers[0]
                    queueJobs[index].totalTracks = numbers[1]
                }
            }
            if let open = value.firstIndex(of: "("), let close = value[open...].firstIndex(of: ")") {
                let metrics = value[value.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if let first = metrics.first { queueJobs[index].transferred = first }
                if metrics.count > 1 { queueJobs[index].transferSpeed = metrics[1] }
            }
            queueJobs[index].message = String(value.suffix(180))
        }
    }

    private static func downloadSummary(from output: String) -> [[String: Any]]? {
        for line in output.components(separatedBy: .newlines).reversed() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.first == "[", candidate.last == "]",
                  let data = candidate.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            return value
        }
        return nil
    }

    private func pauseQueue() {
        guard let process = downloadProcess, process.isRunning else { return }
        if kill(pid_t(process.processIdentifier), SIGSTOP) == 0 {
            isPaused = true
            if let id = currentJobID, let index = queueJobs.firstIndex(where: { $0.id == id }) { queueJobs[index].status = "已暂停" }
            appendActivity("\n下载已暂停。")
        }
    }

    private func resumeQueue() {
        guard let process = downloadProcess, process.isRunning else { isPaused = false; startNextJob(); return }
        if kill(pid_t(process.processIdentifier), SIGCONT) == 0 {
            isPaused = false
            if let id = currentJobID, let index = queueJobs.firstIndex(where: { $0.id == id }) { queueJobs[index].status = "下载中" }
            appendActivity("\n下载已恢复。")
        }
    }

    private func retryJob(_ id: UUID) {
        guard let index = queueJobs.firstIndex(where: { $0.id == id }), !isDownloading else { return }
        queueJobs[index].status = "待处理"
        queueJobs[index].message = "等待重试"
        startNextJob()
    }

    private func retryFailedJobs() {
        guard !isDownloading else { return }
        for index in queueJobs.indices where queueJobs[index].status == "失败" {
            queueJobs[index].status = "待处理"
            queueJobs[index].message = "等待重试"
        }
        startNextJob()
    }

    private func removeJob(_ id: UUID) {
        guard currentJobID != id else { return }
        queueJobs.removeAll { $0.id == id }
    }

    private func updateStorefrontConfig() {
        guard let data = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        let pattern = "(?m)^  storefront: \"[a-zA-Z]{2}\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(data.startIndex..., in: data)
        let updated = regex.stringByReplacingMatches(in: data, range: range, withTemplate: "  storefront: \"\(storefront)\"")
        try? updated.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
