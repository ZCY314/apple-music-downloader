import SwiftUI
import AppKit

@main
struct AMDLDesktopApp: App {
    var body: some Scene {
        WindowGroup { MainView().frame(minWidth: 760, minHeight: 620) }
            .windowStyle(.titleBar)
    }
}

struct MainView: View {
    @State private var links = ""
    @State private var searchTerm = ""
    @State private var quality = "ALAC"
    @State private var output = "Welcome to AMDL Desktop.\nPaste Apple Music album, song, artist or playlist links to begin."
    @State private var isRunning = false
    @State private var process: Process?
    private let configPath = NSHomeDirectory() + "/Music/AppleMusic/config.yaml"
    private var parsedLinks: [String] {
        links.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("https://music.apple.com/") || $0.hasPrefix("https://classical.music.apple.com/") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.system(size: 30, weight: .semibold)).foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AMDL Desktop").font(.system(size: 24, weight: .bold))
                    Text("Apple Music library downloader").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Label(isRunning ? "Downloading" : "Ready", systemImage: isRunning ? "arrow.down.circle.fill" : "checkmark.circle")
                    .foregroundStyle(isRunning ? .green : .secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Find music").font(.headline)
                    HStack {
                        TextField("Search Apple Music — e.g. Teresa Teng, Denon Mastersonic", text: $searchTerm)
                            .textFieldStyle(.roundedBorder).onSubmit { openSearch() }
                        Button("Search") { openSearch() }.buttonStyle(.bordered)
                            .disabled(searchTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Search opens Apple Music in your browser. Copy an album, song, artist or playlist link and paste it below.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Download queue").font(.headline)
                        Spacer()
                        Text("\(parsedLinks.count) valid link(s)").font(.caption).foregroundStyle(.secondary)
                        Button("Paste") {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                links = [links, text].filter { !$0.isEmpty }.joined(separator: "\n")
                            }
                        }.buttonStyle(.borderless)
                        Button("Clear") { links = "" }.buttonStyle(.borderless)
                    }
                    TextEditor(text: $links).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 115, maxHeight: 155)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                    Text("Paste one or more Apple Music URLs, one per line. Playlist songs are filed using their original album, artist and artwork.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Audio quality").font(.headline)
                    Picker("Audio quality", selection: $quality) {
                        Text("Lossless (ALAC)").tag("ALAC")
                        Text("Dolby Atmos").tag("ATMOS")
                        Text("AAC").tag("AAC")
                    }.pickerStyle(.segmented).frame(width: 310)
                }
                Spacer()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) } label: {
                    Label("Settings file", systemImage: "slider.horizontal.3")
                }.buttonStyle(.bordered)
            }
            HStack {
                Button { startDownload() } label: {
                    Label(isRunning ? "Downloading…" : "Start download", systemImage: "arrow.down.circle.fill").frame(minWidth: 150)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(isRunning || parsedLinks.isEmpty)
                if isRunning {
                    Button("Stop") { process?.terminate(); isRunning = false }.buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic"))
                } label: { Label("Open music folder", systemImage: "folder") }.buttonStyle(.bordered)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Activity").font(.headline)
                        Spacer()
                        Button("Clear log") { output = "" }.buttonStyle(.borderless)
                    }
                    ScrollView {
                        Text(output).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
                    }.frame(minHeight: 145, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }.padding(4)
            }
            HStack {
                Text("Lightweight native macOS interface").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Playlist tracks → original albums").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(22)
    }

    private func openSearch() {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.apple.com/search?term=" + encoded) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startDownload() {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("amdl"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            output += "\nERROR: bundled amdl executable is missing."
            return
        }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executable
        task.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Music/AppleMusic")
        var args = ["--config", configPath]
        if quality == "ATMOS" { args.append("--atmos") }
        if quality == "AAC" { args.append("--aac") }
        args.append(contentsOf: parsedLinks)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { output += chunk }
        }
        task.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                output += "\n\nFinished (exit code \(finished.terminationStatus))."
                isRunning = false
                process = nil
            }
        }
        do {
            output += "\n\nStarting \(parsedLinks.count) item(s) in \(quality)…\n"
            isRunning = true
            process = task
            try task.run()
        } catch {
            output += "\nFailed to start downloader: \(error.localizedDescription)"
            isRunning = false
            process = nil
        }
    }
}
