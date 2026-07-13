import AppKit
import Observation

@MainActor
@Observable
final class ConvertModel {
    var mode: Mode = .images {
        didSet { if mode != oldValue { clear() } }
    }
    private(set) var files: [URL] = []
    var format: OutputFormat = .jpeg
    var destinationDir: URL?
    private(set) var isWorking = false
    private(set) var currentFileName: String?
    private(set) var currentIndex = 0
    private(set) var totalFiles = 0
    private(set) var lastSummary: String?
    private(set) var notice: String?
    private(set) var failures: [Failure] = []
    private(set) var codecNames: [URL: String] = [:]

    @ObservationIgnored private var conversionTask: Task<Void, Never>?
    @ObservationIgnored private var codecTask: Task<Void, Never>?

    struct Failure: Sendable {
        let url: URL
        let reason: String
    }

    var currentStatus: String? {
        if let currentFileName {
            return "Converting \(currentIndex) of \(totalFiles): \(currentFileName)"
        }
        return isWorking ? lastSummary : nil
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        guard !isWorking else { return 0 }
        let allowed = mode.inputExtensions
        var seen = Set(files)
        let addedURLs = urls.filter {
            allowed.contains($0.pathExtension.lowercased()) && seen.insert($0).inserted
        }
        files.append(contentsOf: addedURLs)

        let skipped = urls.count - addedURLs.count
        notice = skipped > 0
            ? "Skipped \(skipped) unsupported or duplicate \(skipped == 1 ? "file" : "files")"
            : nil
        if skipped > 0 { lastSummary = nil }

        if !addedURLs.isEmpty {
            lastSummary = nil
            refreshCodecNames()
        }
        return addedURLs.count
    }

    func failure(for url: URL) -> Failure? {
        failures.first { $0.url == url }
    }

    func remove(_ url: URL) {
        guard !isWorking else { return }
        files.removeAll { $0 == url }
        failures.removeAll { $0.url == url }
        lastSummary = nil
        refreshCodecNames()
    }

    func clear() {
        guard !isWorking else { return }
        codecTask?.cancel()
        codecTask = nil
        files.removeAll()
        codecNames = [:]
        lastSummary = nil
        notice = nil
        failures = []
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
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK { destinationDir = panel.url }
    }

    func run(jpegQuality: Double) {
        guard !files.isEmpty, !isWorking else { return }
        isWorking = true
        currentIndex = 0
        totalFiles = files.count
        currentFileName = nil
        lastSummary = nil
        notice = nil
        failures = []

        let snapshot = files
        let job = Job(mode: mode, destination: destinationDir, format: format, jpegQuality: jpegQuality)
        conversionTask = Task.detached(priority: .userInitiated) { [weak self] in
            var successfulURLs: [URL] = []
            var failures: [Failure] = []
            var reserved: Set<URL> = []
            var cancelled = false

            for (index, url) in snapshot.enumerated() {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                await self?.startItem(url, index: index, total: snapshot.count)
                do {
                    let output = try await Self.convert(url, job: job, reserved: reserved)
                    reserved.insert(output)
                    successfulURLs.append(url)
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failures.append(Failure(url: url, reason: error.localizedDescription))
                }
            }

            await self?.finish(
                successfulURLs: successfulURLs,
                failures: failures,
                total: snapshot.count,
                cancelled: cancelled
            )
        }
    }

    func cancel() {
        guard isWorking else { return }
        lastSummary = "Cancelling…"
        currentFileName = nil
        conversionTask?.cancel()
    }

    struct Job: Sendable {
        let mode: Mode
        let destination: URL?
        let format: OutputFormat
        let jpegQuality: Double
    }

    nonisolated static func convert(_ url: URL, job: Job, reserved: Set<URL>) async throws -> URL {
        try Task.checkCancellation()
        let sourceAccess = url.startAccessingSecurityScopedResource()
        let destinationAccess = job.destination?.startAccessingSecurityScopedResource() ?? false
        defer {
            if sourceAccess { url.stopAccessingSecurityScopedResource() }
            if destinationAccess { job.destination?.stopAccessingSecurityScopedResource() }
        }

        switch job.mode {
        case .images:
            return try Converter.convertImage(
                source: url, destinationDir: job.destination,
                format: job.format, jpegQuality: job.jpegQuality, reserved: reserved
            )
        case .video:
            return try await Converter.convertVideo(
                source: url, destinationDir: job.destination, reserved: reserved
            )
        }
    }

    func finish(
        successfulURLs: [URL],
        failures: [Failure],
        total: Int,
        cancelled: Bool
    ) {
        let successfulSet = Set(successfulURLs)
        files.removeAll { successfulSet.contains($0) }
        for url in successfulURLs { codecNames[url] = nil }

        isWorking = false
        conversionTask = nil
        currentFileName = nil
        currentIndex = 0
        totalFiles = 0
        self.failures = failures

        if cancelled {
            lastSummary = "Cancelled after \(successfulURLs.count) of \(total)"
        } else {
            lastSummary = "Converted \(successfulURLs.count) of \(total)"
                + (failures.isEmpty ? "" : " · \(failures.count) failed")
        }
    }

    private func startItem(_ url: URL, index: Int, total: Int) {
        currentFileName = url.lastPathComponent
        currentIndex = index + 1
        totalFiles = total
    }

    private func refreshCodecNames() {
        codecTask?.cancel()
        guard mode == .video, !files.isEmpty else {
            codecTask = nil
            codecNames = [:]
            return
        }

        let urls = files
        codecTask = Task { [weak self] in
            var names: [URL: String] = [:]
            for url in urls {
                guard !Task.isCancelled else { return }
                if let name = await Converter.videoCodecName(for: url) {
                    names[url] = name
                }
            }
            guard !Task.isCancelled, let self, self.mode == .video else { return }
            let currentFiles = Set(self.files)
            self.codecNames = names.filter { currentFiles.contains($0.key) }
            self.codecTask = nil
        }
    }
}
