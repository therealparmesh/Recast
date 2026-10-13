import SwiftUI

struct ContentView: View {
    @Bindable var model: ConvertModel
    @AppStorage("jpegQuality") private var jpegQuality = 0.85

    var body: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: $model.mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            DropTile(model: model)

            options
        }
        .disabled(model.isWorking)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .animation(.smooth(duration: 0.2), value: model.files.isEmpty)
    }

    private var options: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Output")
                Spacer()
                if model.mode == .photos {
                    Picker("Output", selection: $model.format) {
                        ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text("H.264 MP4")
                        .foregroundStyle(.secondary)
                }
            }

            if model.mode == .photos && model.format == .jpeg {
                Divider()
                HStack(spacing: 10) {
                    Text("Quality")
                    Slider(value: $jpegQuality, in: 0...1)
                    Text("\(Int(jpegQuality * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            HStack {
                Text("Save to")
                Spacer()
                Menu {
                    Button("Same Folder as Source") { model.destinationDir = nil }
                    Button("Choose Folder…") { model.pickDestination() }
                } label: {
                    Text(model.destinationDir?.lastPathComponent ?? "Same Folder as Source")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .fixedSize()
                .help(model.destinationDir?.path(percentEncoded: false) ?? "Save beside each source file")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let status = model.status {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let summary = model.lastSummary {
                let hasFailures = !model.failures.isEmpty
                Label(summary, systemImage: hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(hasFailures ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            } else if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isWorking {
                Button("Cancel") { model.cancel() }
                    .controlSize(.large)
                    .disabled(model.isCancelling)
            } else {
                Button {
                    model.run(jpegQuality: jpegQuality)
                } label: {
                    Text("Convert")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.files.isEmpty)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct DropTile: View {
    let model: ConvertModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(isTargeted ? 0.6 : 0.35))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )

            if model.files.isEmpty {
                Button(action: model.pickFiles) {
                    empty
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel("Choose \(model.mode.rawValue.lowercased()) to convert")
                .accessibilityHint("You can also drop files here")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls) > 0
        } isTargeted: { isTargeted = $0 }
        .animation(.smooth(duration: 0.18), value: isTargeted)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: model.mode.dropIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
            Text(model.mode.dropPrompt)
                .font(.headline)
            Text("or click to choose files")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(model.mode.dropHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("^[\(model.files.count) file](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Files…") { model.pickFiles() }
                Button("Clear Files", role: .destructive) { model.clear() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.files, id: \.self) { url in
                        FileRow(
                            url: url,
                            icon: model.mode.systemImage,
                            codec: model.codecNames[url],
                            failure: model.failure(for: url)
                        ) {
                            model.remove(url)
                        }
                    }
                }
            }
        }
    }
}

private struct FileRow: View {
    let url: URL
    let icon: String
    let codec: String?
    let failure: ConvertModel.Failure?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let codec {
                        Text(codec)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                if let failure {
                    Text(failure.reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(url.lastPathComponent)")
            .help("Remove \(url.lastPathComponent)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

#Preview { ContentView(model: ConvertModel()).frame(width: 540, height: 560) }
