import SwiftUI
import AppKit
import Security
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
    case queue = "下载队列"
    case activity = "任务记录"
    case settings = "偏好设置"

    var symbol: String {
        switch self {
        case .discover: return "sparkle.magnifyingglass"
        case .queue: return "square.stack.3d.up"
        case .activity: return "waveform.path"
        case .settings: return "slider.horizontal.3"
        }
    }
}

enum SecureStore {
    private static let service = "org.zcy314.amdl.hunyuan"
    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) {
        let key = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key"
        ] as [String: Any]
        if value.isEmpty {
            SecItemDelete(key as CFDictionary)
            return
        }
        let update = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(key as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var insert = key
            insert[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(insert as CFDictionary, nil)
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
    @AppStorage("amdl.useHunyuan") private var useHunyuan = true
    @State private var hunyuanKey = ""
    @State private var isSearching = false
    @State private var isDownloading = false
    @State private var activity = "准备就绪。\n\n在「发现」中搜索音乐，或把 Apple Music 链接粘贴到下载队列。"
    @State private var downloadProcess: Process?
    @State private var searchMessage = "CN 中国大陆目录优先"
    @State private var configPath = NSHomeDirectory() + "/Music/AppleMusic/config.yaml"

    private let ink = Color(hex: 0x292A25)
    private let paper = Color(hex: 0xF1EBDD)
    private let muted = Color(hex: 0x77756B)
    private let accent = Color(hex: 0xA84F3B)
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var validPastedLinks: [String] {
        pastedLinks.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("https://music.apple.com/") || $0.hasPrefix("https://classical.music.apple.com/") }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                ZStack {
                    GeometryReader { geometry in
                        if let image = NSImage(contentsOf: Bundle.main.resourceURL?.appendingPathComponent("AutumnLandscape.jpg") ?? URL(fileURLWithPath: "/nonexistent")) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().overlay(paper.opacity(0.70))
                        } else { paper }
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
        }
        .background(paper)
        .onChange(of: queueURLs) { newValue in savedQueue = newValue.joined(separator: "\n") }
        .onChange(of: queueJobs) { newValue in
            if let data = try? JSONEncoder().encode(newValue) { persistedJobs = data.base64EncodedString() }
        }
        .onChange(of: historyJobs) { newValue in
            if let data = try? JSONEncoder().encode(newValue) { persistedHistory = data.base64EncodedString() }
        }
        .onAppear {
            hunyuanKey = SecureStore.read()
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(accent).frame(width: 38, height: 38)
                    Image(systemName: "waveform").font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("AMDL").font(.system(size: 17, weight: .black, design: .rounded)).tracking(1.4)
                    Text("MUSIC ARCHIVE").font(.system(size: 8, weight: .bold, design: .rounded)).tracking(2.1).foregroundStyle(.white.opacity(0.45))
                }.foregroundStyle(.white)
            }
            .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 52)

            Text("工作空间").font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(.white.opacity(0.36))
                .padding(.horizontal, 24).padding(.bottom, 13)
            VStack(spacing: 6) {
                ForEach(AppPage.allCases, id: \.self) { item in
                    Button {
                        page = item
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: item.symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
                            Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            Spacer()
                            if item == .queue && !queueURLs.isEmpty {
                                Text("\(queueURLs.count)").font(.system(size: 10, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(accent).foregroundStyle(ink).clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(page == item ? ink : .white.opacity(0.72))
                        .padding(.horizontal, 13).frame(height: 43)
                        .background(page == item ? accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 13)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text("NATIVE FOR MAC").font(.system(size: 9, weight: .bold)).tracking(1.3)
                }.foregroundStyle(.white.opacity(0.58))
                Text("山水入藏。\n音乐归本。")
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .lineSpacing(4).foregroundStyle(.white.opacity(0.82))
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 218)
        .background(ink)
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("AMDL  /  \(page.rawValue)")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(muted)
                Text(page == .discover ? "把想听的，带回自己的收藏。" :
                     page == .queue ? "整理好，再一次下载。" :
                     page == .activity ? "每一次下载，都有迹可循。" : "只设置一次，其余交给 AMDL。")
                    .font(.system(size: 23, weight: .medium, design: .serif)).foregroundStyle(ink)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(isDownloading ? Color.orange : Color(hex: 0x76A95C)).frame(width: 7, height: 7)
                Text(isDownloading ? "正在下载" : "系统就绪").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.7)).clipShape(Capsule())
        }
        .padding(.horizontal, 34).padding(.top, 27).padding(.bottom, 24)
        .background(paper)
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
                        Button { searchText = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(muted)
                    }
                }
                .padding(.horizontal, 16).frame(height: 48)
                .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.07)))
                Picker("类型", selection: $searchType) {
                    Text("专辑").tag("album")
                    Text("歌曲").tag("song")
                    Text("艺人").tag("artist")
                    Text("歌单").tag("playlist")
                    Text("厂牌").tag("record-labels")
                    Text("策展人").tag("curators")
                }
                .pickerStyle(.menu).frame(width: 125)
                Button {
                    Task { await searchCatalog() }
                } label: {
                    HStack(spacing: 8) {
                        if isSearching { ProgressView().controlSize(.small).tint(ink) }
                        else { Image(systemName: "arrow.right") }
                        Text(isSearching ? "检索中" : "搜索")
                    }
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(ink)
                    .frame(width: 104, height: 48).background(accent).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(isSearching || searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 8) {
                Label("CN 优先", systemImage: "globe.asia.australia").font(.system(size: 10, weight: .bold)).foregroundStyle(ink)
                    .padding(.horizontal, 9).padding(.vertical, 6).background(accent.opacity(0.65)).clipShape(Capsule())
                Text(searchType == "playlist" ? "Playlist 目录：TW · HK · US" : "CN 优先 · HK · TW · SG · US").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                Circle().fill(muted.opacity(0.35)).frame(width: 3, height: 3)
                Text(useHunyuan && !hunyuanKey.isEmpty ? "混元智能增强已启用" : "Apple Music 原生检索")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Text(searchMessage).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(results.isEmpty ? "探索音乐" : "检索结果")
                    .font(.system(size: 25, weight: .medium, design: .serif)).foregroundStyle(ink)
                Spacer()
                if !selectedIDs.isEmpty {
                    Button {
                        addSelectedToQueue()
                    } label: {
                        Label("加入队列  ·  \(selectedIDs.count)", systemImage: "plus")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
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
        .padding(.horizontal, 34).padding(.bottom, 22)
    }

    private var emptyDiscovery: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("听见更多，\n收藏更多。")
                        .font(.system(size: 39, weight: .medium, design: .serif)).lineSpacing(1).foregroundStyle(ink)
                    Text("从一张专辑开始。也可以探索歌单、厂牌与策展人。")
                        .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                    HStack(spacing: 8) {
                        suggestion("邓丽君")
                        suggestion("百代百年系列")
                        suggestion("Denon Mastersonic")
                    }.padding(.top, 4)
                }
                Spacer()
                ZStack {
                    Circle().fill(Color(hex: 0xE7E4D9)).frame(width: 170, height: 170)
                    Circle().stroke(ink.opacity(0.09), lineWidth: 1).frame(width: 138, height: 138)
                    Image(systemName: "record.circle").font(.system(size: 105, weight: .ultraLight)).foregroundStyle(ink.opacity(0.8))
                    Circle().fill(accent).frame(width: 14, height: 14)
                }.padding(.trailing, 34)
            }
            .padding(26).frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
            .background(Color(hex: 0xEAE7DC)).clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 14) {
                featureTile("01", "逐曲归档", "歌单里的每首歌回到原专辑")
                featureTile("02", "无损优先", "ALAC、Atmos 与 AAC")
                featureTile("03", "本地收藏", "封面、曲目信息与歌词")
            }
        }
    }

    private func suggestion(_ value: String) -> some View {
        Button(value) { searchText = value; Task { await searchCatalog() } }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.72)).clipShape(Capsule()).buttonStyle(.plain)
    }

    private func featureTile(_ number: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Color(hex: 0x82916D))
            Text(title).font(.system(size: 15, weight: .medium, design: .serif)).foregroundStyle(ink)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(15)
        .background(.white.opacity(0.72)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func resultCard(_ item: CatalogItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        return Button {
            if selected { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: item.imageURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color(hex: 0xE3E0D6))
                            .overlay(Image(systemName: "waveform").font(.system(size: 25)).foregroundStyle(muted.opacity(0.55)))
                    }
                    .frame(height: 150).frame(maxWidth: .infinity).clipped()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                            .foregroundStyle(accent).background(ink.clipShape(Circle())).padding(10)
                    }
                }
                Text(item.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).lineLimit(2).multilineTextAlignment(.leading)
                Text(item.detail).font(.system(size: 10)).foregroundStyle(muted).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(10).background(selected ? accent.opacity(0.16) : .white.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? ink.opacity(0.45) : ink.opacity(0.06), lineWidth: selected ? 1.2 : 0.7))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("加入下载队列") { if !queueJobs.contains(where: { $0.url == item.url }) { queueJobs.append(QueueJob(url: item.url, message: item.name)) } }
            Button("在 Apple Music 中打开") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
        }
    }

    private var queuePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("下载清单").font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(ink)
                    Text("专辑、单曲、艺人或 Playlist 链接均可；Playlist 将逐曲解析并归入原专辑。")
                        .font(.system(size: 11)).foregroundStyle(muted)
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
                .background(.white.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if pastedLinks.isEmpty {
                        Text("粘贴 Apple Music 链接，每行一个……")
                            .font(.system(size: 12)).foregroundStyle(muted.opacity(0.65)).padding(16).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("待下载项目").font(.system(size: 18, weight: .medium, design: .serif)).foregroundStyle(ink)
                Spacer()
                Text("\(queueURLs.count + validPastedLinks.count) 个链接").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                Button("清空") { if !isDownloading { queueJobs.removeAll(); queueURLs.removeAll(); pastedLinks = "" } }.buttonStyle(.plain).foregroundStyle(muted)
            }
            if queueJobs.isEmpty && queueURLs.isEmpty && validPastedLinks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(muted)
                    Text("队列是空的").font(.system(size: 13, weight: .medium, design: .serif)).foregroundStyle(ink)
                    Text("从搜索结果添加，或粘贴链接。").font(.system(size: 10)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.42)).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                HStack {
                    Text("任务").font(.system(size: 17, weight: .medium, design: .serif)).foregroundStyle(ink)
                    Spacer()
                    Text("\(queueJobs.filter { $0.status == "完成" }.count) / \(queueJobs.count) 完成").font(.system(size: 10)).foregroundStyle(muted)
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
                            Button { removeJob(job.id) } label: { Image(systemName: "xmark").foregroundStyle(muted) }.buttonStyle(.plain)
                        }.listRowBackground(Color.white.opacity(0.44))
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
                    Label(isDownloading ? (isPaused ? "已暂停" : "正在下载…") : "加入并开始", systemImage: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(ink)
                        .padding(.horizontal, 22).frame(height: 44).background(accent).clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain).disabled(isDownloading || (queueURLs.isEmpty && validPastedLinks.isEmpty && !queueJobs.contains(where: { $0.status == "待处理" })))
            }
        }
        .padding(.horizontal, 34).padding(.bottom, 28)
    }

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("运行日志").font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(ink)
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
            .background(.white.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 14))
            if !historyJobs.isEmpty {
                Text("最近完成 · \(historyJobs.count)").font(.system(size: 15, weight: .medium, design: .serif)).foregroundStyle(ink)
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
                Text("目录与检索").font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(ink)
                Text("中国大陆目录为默认首选；其余地区用于补充匹配。").font(.system(size: 11)).foregroundStyle(muted)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("混元智能检索").font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(ink)
                Text("使用腾讯混元联网增强，为模糊歌名、中文系列名和别名生成更好的检索词；最终结果仍由 Apple Music 目录核验。").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
                Toggle("启用混元搜索增强", isOn: $useHunyuan).toggleStyle(.switch).font(.system(size: 12, weight: .medium))
                SecureField("腾讯混元 API Key（保存在 macOS 钥匙串）", text: $hunyuanKey)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 480)
                HStack {
                    Button("安全保存密钥") { SecureStore.save(hunyuanKey); activity += "\n混元 API Key 已保存到钥匙串。" }
                        .buttonStyle(.borderedProminent).tint(ink)
                    Text(hunyuanKey.isEmpty ? "尚未配置密钥：仍可使用原生目录检索。" : "密钥已填写；保存后启用增强检索。")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("下载位置").font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(ink)
                Text(NSHomeDirectory() + "/Music/AppleMusic").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")) }.buttonStyle(.bordered)
            }
            Spacer()
            Text("AMDL Desktop · 原生 SwiftUI · 无 Electron · 无后台常驻服务")
                .font(.system(size: 10)).foregroundStyle(muted)
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
        searchMessage = "正在连接 Apple Music 目录…"
        defer { isSearching = false }
        do {
            var queries = [query]
            var usedHunyuan = false
            if useHunyuan && !hunyuanKey.isEmpty {
                do {
                    let expanded = try await hunyuanQueries(for: query)
                    let alternatives = expanded.filter { $0.caseInsensitiveCompare(query) != .orderedSame }.prefix(2)
                    queries.append(contentsOf: alternatives)
                    usedHunyuan = !alternatives.isEmpty
                } catch {
                    searchMessage = "混元暂不可用，回退原生检索"
                    activity += "\n混元增强检索暂不可用：\(error.localizedDescription)；已自动回退 Apple Music 原生检索。"
                }
            }
            var combined: [CatalogItem] = []
            var seen = Set<String>()
            for term in queries.prefix(4) {
                let found = try await runJSONSearch(type: searchType, query: term)
                for item in found where seen.insert(item.id).inserted {
                    combined.append(item)
                }
            }
            results = combined
            searchMessage = usedHunyuan ? "混元增强 · \(queries.count) 组检索词" : "Apple Music · CN 优先"
            if combined.isEmpty { searchMessage = "没有找到结果，试试更短的关键词。" }
        } catch {
            searchMessage = "检索失败"
            activity += "\n检索错误：\(error.localizedDescription)"
        }
    }

    private func hunyuanQueries(for query: String) async throws -> [String] {
        guard let url = URL(string: "https://api.hunyuan.cloud.tencent.com/v1/chat/completions") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("Bearer \(hunyuanKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prompt = "你是 Apple Music 中文音乐目录检索专家。针对用户输入的音乐关键词，考虑繁简体、中文别名、英文/拼音、唱片系列、艺人名和常见译名，给出最多 3 个最有价值的 Apple Music 搜索短语。不要回答问题，不要编造专辑或歌曲。只返回 JSON 字符串数组，不要 Markdown。原始词：\(query)"
        let body: [String: Any] = [
            "model": "hunyuan-turbos-latest",
            "messages": [
                ["role": "system", "content": "只输出合法 JSON 数组，最多三项。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "enable_enhancement": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Hunyuan", code: 1, userInfo: [NSLocalizedDescriptionKey: "混元服务暂不可用，请检查 API Key 或网络。"])
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = root?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String else { return [] }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start <= end {
            let json = String(trimmed[start...end])
            if let array = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
            }
        }
        return []
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
            let task = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.executableURL = executable
            task.arguments = arguments
            task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")
            task.standardOutput = outputPipe
            task.standardError = errorPipe
            try task.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail?.isEmpty == false ? detail! : "AMDL 检索进程退出，代码 \(task.terminationStatus)。"
                throw NSError(domain: "AMDL", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
            return data
        }.value
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
                activity += chunk
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
                activity += "\n\n\(status) · exit \(finished.terminationStatus)\n"
                downloadProcess = nil
                currentJobID = nil
                isDownloading = false
                if !isPaused { startNextJob() }
            }
        }
        do {
            activity += "\n\n开始下载 · \(job.url) · \(quality)\n"
            downloadProcess = task
            try task.run()
        } catch {
            queueJobs[index].status = "失败"
            queueJobs[index].message = error.localizedDescription
            isDownloading = false
            downloadProcess = nil
            activity += "\n启动失败：\(error.localizedDescription)"
            startNextJob()
        }
    }

    private func pauseQueue() {
        guard let process = downloadProcess, process.isRunning else { return }
        if kill(pid_t(process.processIdentifier), SIGSTOP) == 0 {
            isPaused = true
            if let id = currentJobID, let index = queueJobs.firstIndex(where: { $0.id == id }) { queueJobs[index].status = "已暂停" }
            activity += "\n下载已暂停。"
        }
    }

    private func resumeQueue() {
        guard let process = downloadProcess, process.isRunning else { isPaused = false; startNextJob(); return }
        if kill(pid_t(process.processIdentifier), SIGCONT) == 0 {
            isPaused = false
            if let id = currentJobID, let index = queueJobs.firstIndex(where: { $0.id == id }) { queueJobs[index].status = "下载中" }
            activity += "\n下载已恢复。"
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
