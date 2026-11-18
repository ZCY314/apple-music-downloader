import SwiftUI
import AppKit
import Darwin

@main
struct AMDLDesktopApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.light)
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
}

struct MainView: View {
    @State private var page: AppPage = .discover
    @State private var searchText = ""
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
    @AppStorage("amdl.storefront") private var storefront = "cn"
    @State private var isSearching = false
    @State private var isDownloading = false
    @State private var activity = "准备就绪。\n\n在「发现」中搜索音乐，或把 Apple Music 链接粘贴到下载队列。"
    @State private var downloadProcess: Process?
    @State private var searchMessage = ""
    @State private var configPath = NSHomeDirectory() + "/Music/AppleMusic/config.yaml"
    @State private var workspaceArtwork: NSImage?

    private let ink = Color(hex: 0x20211F)
    private let paper = Color(hex: 0xF6F6F2)
    private let muted = Color(hex: 0x777A75)
    private let accent = Color(hex: 0xA85B48)
    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: 28, alignment: .top)]

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
        HStack(spacing: 0) {
            sidebar
            ZStack {
                artworkBackdrop
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
        .background(Color(hex: 0xF6F3EB))
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
                activity = "尚未找到配置文件。首次运行时，请先检查 ~/Music/AppleMusic/config.yaml。"
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

                // A warm paper veil keeps the painting present without competing
                // with catalog artwork, labels, or controls.
                Color(hex: 0xF7F3E9).opacity(0.24)

                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0xFBF8F0).opacity(0.76), location: 0.0),
                        .init(color: Color(hex: 0xF8F5EC).opacity(0.54), location: 0.28),
                        .init(color: Color(hex: 0xF6F3EA).opacity(0.34), location: 0.68),
                        .init(color: Color(hex: 0xF7F3E9).opacity(0.58), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0xF8F5ED).opacity(0.48), location: 0.0),
                        .init(color: Color(hex: 0xF8F5ED).opacity(0.12), location: 0.34),
                        .init(color: Color(hex: 0xF8F5ED).opacity(0.08), location: 0.72),
                        .init(color: Color(hex: 0xF8F5ED).opacity(0.38), location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                RadialGradient(
                    colors: [Color.clear, Color(hex: 0x40382D).opacity(0.075)],
                    center: .center,
                    startRadius: min(geometry.size.width, geometry.size.height) * 0.22,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.78
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: "waveform").font(.system(size: 21, weight: .regular)).foregroundStyle(ink)
                }
                Text("AMDL").font(.system(size: 17, weight: .semibold, design: .default)).tracking(0.8).foregroundStyle(ink)
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 42)

            VStack(spacing: 6) {
                ForEach(AppPage.allCases, id: \.self) { item in
                    Button {
                        page = item
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: item.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                            Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            Spacer()
                            if item == .queue && unfinishedJobCount > 0 {
                                Text("\(unfinishedJobCount)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(muted)
                            }
                        }
                        .foregroundStyle(page == item ? ink : muted)
                        .padding(.horizontal, 11).frame(height: 42)
                        .background(page == item ? Color(hex: 0xE8E9E3) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 13)
                }
            }
            Spacer()
        }
        .frame(width: 194)
        .background(Color(hex: 0xF6F3EB).opacity(0.48))
        .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.08)).frame(width: 1) }
    }

    private var topBar: some View {
        HStack {
            Text(page.rawValue)
                .font(.system(size: 23, weight: .semibold, design: .default)).foregroundStyle(ink)
            Spacer()
            if isDownloading {
                Text(isPaused ? "已暂停" : "正在下载")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            }
        }
        .padding(.horizontal, 38).padding(.top, 30).padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xF8F5ED).opacity(0.58), Color(hex: 0xF8F5ED).opacity(0.22)],
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
                    TextField("搜索专辑、歌曲、歌单、厂牌或策展人", text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .onSubmit { Task { await searchCatalog() } }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(muted)
                            .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(Color(hex: 0xF8F6F0).opacity(0.66)).clipShape(RoundedRectangle(cornerRadius: 8))
                Picker("类型", selection: $searchType) {
                    Text("专辑").tag("album")
                    Text("歌曲").tag("song")
                    Text("艺人").tag("artist")
                    Text("歌单").tag("playlist")
                    Text("厂牌").tag("record-labels")
                    Text("策展人").tag("curators")
                }
                .pickerStyle(.menu).frame(width: 112)
                Button {
                    Task { await searchCatalog() }
                } label: {
                    HStack(spacing: 8) {
                        if isSearching { ProgressView().controlSize(.small).tint(paper) }
                        else { Image(systemName: "arrow.right") }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 44, height: 44).background(ink).foregroundStyle(paper).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(isSearching || searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !searchMessage.isEmpty {
                Text(searchMessage).font(.system(size: 10)).foregroundStyle(muted)
            }

            HStack(alignment: .firstTextBaseline) {
                if !results.isEmpty {
                    Text("结果")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(ink)
                }
                Spacer()
                if !selectedIDs.isEmpty {
                    Button {
                        addSelectedToQueue()
                    } label: {
                        Label("加入队列 · \(selectedIDs.count)", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(searchText.isEmpty ? "搜索音乐" : "没有找到匹配项")
                .font(.system(size: 28, weight: .medium, design: .default)).foregroundStyle(ink)
            Text(searchText.isEmpty ? "搜索专辑、歌曲、艺人或歌单" : "检查拼写，或尝试更短的关键词。")
                .font(.system(size: 12)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
        .padding(.horizontal, 2)
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
                    AsyncImage(url: item.imageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color(hex: 0xE8E9E3))
                            .overlay(Image(systemName: "waveform").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(muted.opacity(0.55)))
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 23, weight: .regular))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(paper, accent)
                            .padding(9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
            .opacity(selected ? 0.78 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name), \(item.detail)")
        .accessibilityHint(item.type == "record-labels" || item.type == "curators" ? "打开 Apple Music 页面" : (selected ? "取消选择" : "选择此项目"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.16), value: selected)
        .contextMenu {
            if item.type != "record-labels" && item.type != "curators" {
                Button("加入队列") { if !queueJobs.contains(where: { $0.url == item.url }) { queueJobs.append(QueueJob(url: item.url, message: item.name)) } }
            }
            Button("在 Apple Music 中打开") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
        }
    }

    private var queuePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("下载队列").font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
                }
                Spacer()
                Button {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        pastedLinks = [pastedLinks, value].filter { !$0.isEmpty }.joined(separator: "\n")
                    }
                } label: { Label("粘贴链接", systemImage: "doc.on.clipboard").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.bordered)
            }
            TextEditor(text: $pastedLinks)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10).frame(height: 110)
                .background(Color(hex: 0xFBF9F3).opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if pastedLinks.isEmpty {
                        Text("粘贴 Apple Music 链接，每行一个……")
                            .font(.system(size: 12)).foregroundStyle(muted.opacity(0.65)).padding(16).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("下载任务").font(.system(size: 18, weight: .medium)).foregroundStyle(ink)
                Spacer()
                Text("\(unfinishedJobCount + queueURLs.count + validPastedLinks.count) 个待处理").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                Button("清空") { queueJobs.removeAll(); queueURLs.removeAll(); pastedLinks = "" }.buttonStyle(.plain).foregroundStyle(muted).disabled(isDownloading)
            }
            if invalidPastedLinkCount > 0 {
                Label("\(invalidPastedLinkCount) 行不是有效的 Apple Music 链接，已忽略。", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(accent)
            }
            if queueJobs.isEmpty && queueURLs.isEmpty && validPastedLinks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(muted)
                    Text("队列是空的").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                    Text("从搜索结果添加，或粘贴链接。").font(.system(size: 10)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("任务").font(.system(size: 17, weight: .medium)).foregroundStyle(ink)
                    Spacer()
                    Text("\(queueJobs.filter { $0.status == "完成" }.count) / \(queueJobs.count + queueURLs.count + validPastedLinks.count) 完成").font(.system(size: 10)).foregroundStyle(muted)
                    if isDownloading && !isPaused {
                        Button { pauseQueue() } label: { Label("暂停", systemImage: "pause.fill") }.buttonStyle(.bordered)
                    } else if isPaused {
                        Button { resumeQueue() } label: { Label("继续", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(ink)
                    }
                    Button { retryFailedJobs() } label: { Label("重试失败", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).disabled(!queueJobs.contains { $0.status == "失败" })
                }
                List {
                    ForEach(queueJobs) { job in
                        HStack(spacing: 12) {
                            Image(systemName: job.status == "完成" ? "checkmark.circle.fill" : job.status == "失败" ? "exclamationmark.circle.fill" : job.status == "下载中" ? "arrow.down.circle.fill" : "circle.dashed")
                                .foregroundStyle(job.status == "失败" ? Color.red : job.status == "完成" ? Color.green : accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(string: job.url)?.lastPathComponent ?? job.url).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(job.message.isEmpty ? job.url : job.message).font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
                            }
                            Spacer()
                            Text(job.status).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                            if job.status == "失败" {
                                Button { retryJob(job.id) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                            }
                            Button { removeJob(job.id) } label: { Image(systemName: "xmark").foregroundStyle(muted) }
                                .buttonStyle(.plain).accessibilityLabel("移除任务")
                        }.listRowBackground(Color(hex: 0xFBF9F3).opacity(0.42))
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("音质").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(muted)
                    Picker("音质", selection: $quality) {
                        Text("ALAC 无损").tag("ALAC")
                        Text("Dolby Atmos").tag("ATMOS")
                        Text("AAC").tag("AAC")
                    }.pickerStyle(.segmented).frame(width: 330)
                }
                Spacer()
                Button {
                    startDownload()
                } label: {
                    Label(isDownloading ? (isPaused ? "已暂停" : "正在下载…") : "开始下载", systemImage: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
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
                Text("活动记录").font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Button("清空记录") { activity = "" }.buttonStyle(.plain).foregroundStyle(muted)
                if isDownloading && !isPaused {
                    Button("暂停") { pauseQueue() }.buttonStyle(.bordered)
                } else if isPaused {
                    Button("恢复") { resumeQueue() }.buttonStyle(.borderedProminent).tint(ink)
                }
            }
            ScrollView {
                Text(activity.isEmpty ? "暂无活动。" : activity)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(18)
            }
            .background(Color(hex: 0xFBF9F3).opacity(0.58)).clipShape(RoundedRectangle(cornerRadius: 14))
            if !historyJobs.isEmpty {
                Text("最近完成 · \(historyJobs.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
                ForEach(historyJobs.prefix(8)) { job in
                    HStack { Text(URL(string: job.url)?.lastPathComponent ?? job.url).lineLimit(1); Spacer(); Text(job.status).foregroundStyle(muted) }
                        .font(.system(size: 10)).padding(.vertical, 3)
                }
            }
            HStack {
                Label(isPaused ? "下载已暂停" : (isDownloading ? "下载进程运行中" : "下载进程空闲"), systemImage: isPaused ? "pause.circle.fill" : (isDownloading ? "arrow.down.circle.fill" : "checkmark.circle"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Button("打开音乐文件夹") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic"))
                }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 34).padding(.bottom, 26)
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("音乐目录").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("首选地区").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                    Text("更改后会写入现有 AMDL 配置。").font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Picker("地区", selection: $storefront) {
                    Text("中国大陆 · CN").tag("cn")
                    Text("香港 · HK").tag("hk")
                    Text("台湾 · TW").tag("tw")
                    Text("新加坡 · SG").tag("sg")
                    Text("美国 · US").tag("us")
                }.frame(width: 220)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("下载位置").font(.system(size: 20, weight: .medium)).foregroundStyle(ink)
                Text(NSHomeDirectory() + "/Music/AppleMusic").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")) }.buttonStyle(.bordered)
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
            if combined.isEmpty { searchMessage = "没有找到结果，试试更短的关键词。" }
        } catch {
            searchMessage = "检索失败：\(error.localizedDescription)"
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
        var args = ["--config", configPath]
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
            DispatchQueue.main.async {
                appendActivity(chunk)
                if let idx = queueJobs.firstIndex(where: { $0.id == job.id }) {
                    queueJobs[idx].message = String(chunk.suffix(140)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        task.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let idx = queueJobs.firstIndex(where: { $0.id == job.id }) else { return }
                let status = finished.terminationStatus == 0 ? "完成" : "失败"
                queueJobs[idx].status = status
                queueJobs[idx].message = status == "完成" ? "已保存到音乐资料库" : "进程退出代码 \(finished.terminationStatus)"
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
            appendActivity("\n\n开始下载 · \(job.url) · \(quality)\n")
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
