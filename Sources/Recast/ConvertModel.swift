import AppKit
import Observation

@MainActor
@Observable
final class ConvertModel {
    var mode: Mode = .photos {
        didSet { if mode != oldValue { clear() } }
    }
    private(set) var files: [URL] = []
    var format: OutputFormat = .jpeg
    var destinationDir: URL? {
        didSet { defaults.set(destinationDir?.path(percentEncoded: false), forKey: Self.destinationKey) }
    }
    private(set) var isWorking = false
    private(set) var isCancelling = false
    private(set) var currentFileName: String?
    private(set) var currentIndex = 0
    private(set) var totalFiles = 0
    private(set) var lastSummary: String?
    private(set) var notice: String?
    private(set) var failures: [Failure] = []
    private(set) var codecNames: [URL: String] = [:]

    @ObservationIgnored private var conversionTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let destinationKey = "destinationDir"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A remembered folder that has since been deleted or moved falls back to the source folder.
        var isDirectory: ObjCBool = false
        if let path = defaults.string(forKey: Self.destinationKey),
           FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            destinationDir = URL(filePath: path, directoryHint: .isDirectory)
        }
    }

    struct Failure: Sendable {
        let url: URL
        let reason: String
    }

    var status: String? {
        guard isWorking else { return nil }
        if isCancelling { return "Cancelling…" }
        guard let currentFileName else { return nil }
        return "Converting \(currentIndex) of \(totalFiles): \(currentFileName)"
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        guard !isWorking else { return 0 }
        let allowed = mode.inputExtensions
        var seen = Set(files)
        let added = urls.filter {
            allowed.contains($0.pathExtension.lowercased()) && seen.insert($0).inserted
        }
        files.append(contentsOf: added)

        let skipped = urls.count - added.count
        notice = skipped > 0
            ? "Skipped \(skipped) unsupported or duplicate \(skipped == 1 ? "file" : "files")"
            : nil
        lastSummary = nil
        probeCodecs(added)
        return added.count
    }

    func failure(for url: URL) -> Failure? {
        failures.first { $0.url == url }
    }

    func remove(_ url: URL) {
        guard !isWorking else { return }
        files.removeAll { $0 == url }
        failures.removeAll { $0.url == url }
        codecNames[url] = nil
        lastSummary = nil
        notice = nil
    }

    func clear() {
        guard !isWorking else { return }
        files = []
        failures = []
        codecNames = [:]
        lastSummary = nil
        notice = nil
    }

    func pickFiles() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = mode.inputUTTypes
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func pickDestination() {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { destinationDir = panel.url }
    }

    func run(jpegQuality: Double) {
        guard !files.isEmpty, !isWorking else { return }
        isWorking = true
        isCancelling = false
        currentIndex = 0
        totalFiles = files.count
        currentFileName = nil
        lastSummary = nil
        notice = nil
        failures = []

        let snapshot = files
        let mode = mode, format = format, destination = destinationDir
        conversionTask = Task.detached(priority: .userInitiated) { [weak self] in
            var successes: [URL] = []
            var failures: [Failure] = []
            var reserved: Set<URL> = []
            var cancelled = false

            for (index, url) in snapshot.enumerated() {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                await self?.startItem(url, index: index)
                do {
                    let output = switch mode {
                    case .photos:
                        try Converter.convertImage(
                            source: url, destinationDir: destination,
                            format: format, jpegQuality: jpegQuality, reserved: reserved
                        )
                    case .videos:
                        try await Converter.convertVideo(
                            source: url, destinationDir: destination, reserved: reserved
                        )
                    }
                    reserved.insert(output)
                    successes.append(url)
                } catch {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    failures.append(Failure(url: url, reason: error.localizedDescription))
                }
            }

            await self?.finish(successes: successes, failures: failures, total: snapshot.count, cancelled: cancelled)
        }
    }

    func cancel() {
        guard isWorking else { return }
        isCancelling = true
        conversionTask?.cancel()
    }

    func finish(successes: [URL], failures: [Failure], total: Int, cancelled: Bool) {
        let done = Set(successes)
        files.removeAll { done.contains($0) }
        for url in successes { codecNames[url] = nil }

        isWorking = false
        isCancelling = false
        conversionTask = nil
        currentFileName = nil
        self.failures = failures

        lastSummary = cancelled
            ? "Cancelled after \(successes.count) of \(total)"
            : "Converted \(successes.count) of \(total)" + (failures.isEmpty ? "" : " · \(failures.count) failed")
    }

    private func startItem(_ url: URL, index: Int) {
        currentFileName = url.lastPathComponent
        currentIndex = index + 1
    }

    private func probeCodecs(_ urls: [URL]) {
        guard mode == .videos, !urls.isEmpty else { return }
        Task { [weak self] in
            for url in urls {
                guard let name = await Converter.videoCodecName(for: url) else { continue }
                // The file may have left the queue (or the mode changed) while probing.
                guard let self else { return }
                if self.files.contains(url) { self.codecNames[url] = name }
            }
        }
    }
}
