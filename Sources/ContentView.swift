import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = ProcessingEngine()
    @State private var files: [FileItem] = []
    @State private var format: OutputFormat = .png
    @State private var suffix = ""
    @State private var stripMetadata = true
    @State private var colorIndex = 0.0
    @State private var quality = 80.0
    @State private var oxipngLevel = 6.0
    @State private var selection: Set<FileItem.ID> = []
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            fileList
            Divider()
            if engine.isProcessing {
                HStack {
                    Spacer()
                    Button("Cancel") { engine.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                .padding()
            } else {
                controls
            }
        }
        .frame(minWidth: 480, maxWidth: 480, minHeight: 400)
        .onOpenURL { url in
            if acceptedExtensions.contains(url.pathExtension.lowercased()) {
                addFile(url)
            }
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - File List

    private func removeSelected() {
        guard !engine.isProcessing else { return }
        files.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(files) { file in
                FileRowView(file: file)
            }
        }
        .onDeleteCommand { removeSelected() }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .overlay {
            if files.isEmpty && !engine.isProcessing {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.largeTitle)
                    Text("Drop image files here")
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Add Files...") { addFiles() }
                Spacer()
                Text("Save as")
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $format) {
                    ForEach(OutputFormat.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                TextField("optional suffix", text: $suffix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            Toggle("Strip metadata", isOn: $stripMetadata)

            VStack(alignment: .leading, spacing: 4) {
                Text("Colors: \(colorLabel(Int(colorIndex)))")
                Slider(value: $colorIndex, in: 0...Double(colorSteps.count - 1), step: 1)
            }

            if format == .png {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optimization: \(Int(oxipngLevel))")
                    Slider(value: $oxipngLevel, in: 0...6, step: 1)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: \(Int(quality))")
                    Slider(value: $quality, in: 0...100, step: 1)
                }
            }

            HStack {
                Spacer()
                Button("Optimize") { optimize() }
                    .disabled(files.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = acceptedImageTypes
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    private func addFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard !files.contains(where: { $0.url.standardizedFileURL == normalized }) else { return }
        files.append(FileItem(url: normalized))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      acceptedExtensions.contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async { addFile(url) }
            }
        }
        return true
    }

    private func optimize() {
        if let msg = engine.checkTools() {
            alertMessage = msg
            showAlert = true
            return
        }
        engine.start(
            files: files, format: format, suffix: suffix,
            stripMetadata: stripMetadata, colorIndex: Int(colorIndex),
            quality: Int(quality), oxipngLevel: Int(oxipngLevel)
        )
    }
}

// MARK: - File Row

struct FileRowView: View {
    @ObservedObject var file: FileItem

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: file.icon)
                .resizable()
                .frame(width: 20, height: 20)
            Text(file.filename)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch file.status {
        case .none:
            Text("\(file.originalSize / 1024) KB")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .done(let before, let after):
            Text(before > 0 ? "\(after * 100 / before)%" : "done")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let msg):
            Text(msg)
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        }
    }
}
