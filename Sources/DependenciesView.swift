import AppKit
import SwiftUI

@MainActor
final class DependenciesModel: ObservableObject {
    struct Tool: Identifiable {
        let name: String
        let brewPackage: String
        var installed: Bool
        var id: String { name }
    }

    // name -> Homebrew package (cwebp ships in the `webp` formula).
    private static let allTools: [(name: String, brewPackage: String)] = [
        ("pngquant", "pngquant"),
        ("oxipng", "oxipng"),
        ("cwebp", "webp"),
        ("ffmpeg", "ffmpeg"),
    ]

    @Published var tools: [Tool] = []
    @Published var homebrewInstalled = false
    @Published var isInstalling = false
    @Published var installLog = ""

    private let resolver = ToolResolver()

    func refresh() {
        resolver.clearCache()
        homebrewInstalled = resolver.path(for: "brew") != nil
        tools = Self.allTools.map { name, pkg in
            Tool(name: name, brewPackage: pkg, installed: resolver.path(for: name) != nil)
        }
    }

    var missingTools: [Tool] { tools.filter { !$0.installed } }
    var allInstalled: Bool { homebrewInstalled && missingTools.isEmpty }

    func installMissing() {
        guard !isInstalling, let brew = resolver.path(for: "brew") else { return }
        let packages = missingTools.map(\.brewPackage)
        guard !packages.isEmpty else { return }

        isInstalling = true
        installLog = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install"] + packages
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        Task { @MainActor in
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                installLog = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus != 0, installLog.isEmpty {
                    installLog = "Homebrew exited with status \(process.terminationStatus)."
                }
            } catch {
                installLog = "Install failed: \(error.localizedDescription)"
            }
            refresh()
            isInstalling = false
        }
    }

    func openBrewSite() {
        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
    }
}

struct DependenciesView: View {
    @ObservedObject var model: DependenciesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dependencies").font(.title2).bold()

            if !model.homebrewInstalled {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Homebrew is not installed.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Opta installs its tools through Homebrew. Open brew.sh, follow the install steps, then relaunch Opta and click Refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open brew.sh") { model.openBrewSite() }
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(spacing: 6) {
                ForEach(model.tools) { tool in
                    HStack {
                        Image(systemName: tool.installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tool.installed ? .green : .red)
                        Text(tool.name)
                        Spacer()
                        Text(tool.installed ? "Installed" : "Missing")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            if model.homebrewInstalled, !model.missingTools.isEmpty {
                let n = model.missingTools.count
                Text("\(n) missing tool\(n == 1 ? "" : "s"). Install via Homebrew to enable \(n == 1 ? "this format" : "these formats").")
                Button {
                    model.installMissing()
                } label: {
                    if model.isInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Text("Install Missing Tools")
                    }
                }
                .disabled(model.isInstalling)
            }

            if model.allInstalled {
                Label("All tools are installed.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            if !model.installLog.isEmpty {
                Text(model.installLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
            HStack {
                Button("Refresh") { model.refresh() }.disabled(model.isInstalling)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380, height: 420)
        .onAppear { model.refresh() }
    }
}