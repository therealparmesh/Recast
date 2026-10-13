import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Recast

@Suite("Output naming")
struct OutputNamingTests {
    @Test("Existing and reserved names receive the next suffix")
    func uniqueOutputURL() throws {
        let dir = try TempDir()
        try Data().write(to: dir.file("photo.jpg"))

        let output = Converter.outputURL(
            source: dir.file("photo.heic"), destinationDir: dir.url, ext: "jpg",
            reserved: [dir.file("photo 2.jpg")]
        )

        #expect(output.lastPathComponent == "photo 3.jpg")
    }

    @Test("Without a destination, output goes beside the source")
    func defaultsToSourceFolder() throws {
        let dir = try TempDir()
        let source = try dir.folder("album").appendingPathComponent("photo.heic")

        let output = Converter.outputURL(source: source, destinationDir: nil, ext: "jpg", reserved: [])

        #expect(output == source.deletingPathExtension().appendingPathExtension("jpg"))
    }
}

@Suite("Photo conversion")
struct PhotoConversionTests {
    @Test("HEIC converts to a readable file of the chosen format", arguments: OutputFormat.allCases)
    func convertsHEIC(format: OutputFormat) throws {
        let dir = try TempDir()
        let source = dir.file("photo.heic")
        try makeHEIC(at: source, width: 4, height: 2)

        let output = try Converter.convertImage(
            source: source, destinationDir: nil, format: format, jpegQuality: 0.85, reserved: []
        )

        #expect(output == dir.file("photo.\(format.fileExtension)"))
        let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(image) as String? == format.utType.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2)
    }

    @Test("A corrupt photo fails without leaving a file behind")
    func corruptPhoto() throws {
        let dir = try TempDir()
        let source = dir.file("broken.heic")
        try Data("not an image".utf8).write(to: source)

        #expect(throws: ConversionError.unreadable) {
            try Converter.convertImage(
                source: source, destinationDir: nil, format: .jpeg, jpegQuality: 0.85, reserved: []
            )
        }
        #expect(dir.contents == ["broken.heic"])
    }
}

@Suite("Video conversion")
struct VideoConversionTests {
    @Test("H.264 and HEVC movies become H.264 MP4", arguments: [AVVideoCodecType.h264, .hevc])
    func convertsMovie(codec: AVVideoCodecType) async throws {
        let dir = try TempDir()
        let source = dir.file("clip.mov")
        try await makeMovie(at: source, codec: codec)

        let output = try await Converter.convertVideo(source: source, destinationDir: nil, reserved: [])

        #expect(output == dir.file("clip.mp4"))
        #expect(await Converter.videoCodecName(for: output) == "H.264")
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let size = try await #require(tracks.first).load(.naturalSize)
        #expect(size == CGSize(width: 128, height: 128))
    }

    @Test("Codec names are friendly, and non-video files have none")
    func codecNames() async throws {
        let dir = try TempDir()
        try await makeMovie(at: dir.file("h264.mov"), codec: .h264)
        try await makeMovie(at: dir.file("hevc.mov"), codec: .hevc)
        try Data("not a movie".utf8).write(to: dir.file("fake.mov"))

        #expect(await Converter.videoCodecName(for: dir.file("h264.mov")) == "H.264")
        #expect(await Converter.videoCodecName(for: dir.file("hevc.mov")) == "HEVC")
        #expect(await Converter.videoCodecName(for: dir.file("fake.mov")) == nil)
    }

    @Test("A corrupt movie fails without leaving a file behind")
    func corruptMovie() async throws {
        let dir = try TempDir()
        let source = dir.file("broken.mov")
        try Data("not a movie".utf8).write(to: source)

        await #expect(throws: (any Error).self) {
            try await Converter.convertVideo(source: source, destinationDir: nil, reserved: [])
        }
        #expect(dir.contents == ["broken.mov"])
    }
}

@Suite("Conversion queue")
@MainActor
struct ConversionQueueTests {
    private let defaults = MemoryDefaults()

    private func makeModel() -> ConvertModel {
        ConvertModel(defaults: defaults)
    }

    @Test("Unsupported and duplicate inputs are skipped and reported")
    func inputFiltering() throws {
        let model = makeModel()
        let photo = URL(filePath: "/tmp/photo.heif")
        let upperCase = URL(filePath: "/tmp/LOUD.HEIC")

        #expect(model.add([photo, URL(filePath: "/tmp/notes.txt"), URL(filePath: "/tmp/clip.mov")]) == 1)
        #expect(model.notice == "Skipped 2 unsupported or duplicate files")
        #expect(model.add([photo, upperCase]) == 1)
        #expect(model.notice == "Skipped 1 unsupported or duplicate file")
        #expect(model.files == [photo, upperCase])
    }

    @Test("Switching modes clears the queue")
    func modeSwitchClears() throws {
        let model = makeModel()
        model.add([URL(filePath: "/tmp/photo.heic")])

        model.mode = .videos

        #expect(model.files.isEmpty)
        #expect(model.add([URL(filePath: "/tmp/clip.mov"), URL(filePath: "/tmp/photo.heic")]) == 1)
    }

    @Test("Removing a file also drops its failure")
    func removeDropsFailure() throws {
        let model = makeModel()
        let first = URL(filePath: "/tmp/first.heic")
        let second = URL(filePath: "/tmp/second.heic")
        model.add([first, second])
        model.finish(successes: [], failures: [.init(url: first, reason: "Nope")], total: 2, cancelled: false)

        model.remove(first)

        #expect(model.files == [second])
        #expect(model.failure(for: first) == nil)
        #expect(model.lastSummary == nil)
    }

    @Test("Successful inputs leave the queue while failures remain")
    func completionRemovesOnlySuccesses() throws {
        let model = makeModel()
        let first = URL(filePath: "/tmp/first.heic")
        let second = URL(filePath: "/tmp/second.heic")
        model.add([first, second])

        model.finish(
            successes: [first], failures: [.init(url: second, reason: "Test failure")], total: 2, cancelled: false
        )

        #expect(model.files == [second])
        #expect(model.failures.map(\.url) == [second])
        #expect(model.lastSummary == "Converted 1 of 2 · 1 failed")
    }

    @Test("A run converts good files into the chosen folder and keeps failures")
    func runIntoDestination() async throws {
        let dir = try TempDir()
        let output = try dir.folder("out")
        let good = dir.file("good.heic")
        let broken = dir.file("broken.heic")
        try makeHEIC(at: good)
        try Data("not an image".utf8).write(to: broken)
        let model = makeModel()
        model.destinationDir = output
        model.format = .png
        model.add([good, broken])

        model.run(jpegQuality: 0.85)
        #expect(model.isWorking)
        try await waitUntil { !model.isWorking }

        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["good.png"])
        #expect(model.files == [broken])
        #expect(model.failure(for: broken)?.reason == "Can’t read this file")
        #expect(model.lastSummary == "Converted 1 of 2 · 1 failed")
    }

    @Test("Two sources with the same name get distinct outputs")
    func sameNameSources() async throws {
        let dir = try TempDir()
        let output = try dir.folder("out")
        let first = try dir.folder("a").appendingPathComponent("photo.heic")
        let second = try dir.folder("b").appendingPathComponent("photo.heic")
        try makeHEIC(at: first)
        try makeHEIC(at: second)
        let model = makeModel()
        model.destinationDir = output
        model.add([first, second])

        model.run(jpegQuality: 0.85)
        try await waitUntil { !model.isWorking }

        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names == ["photo 2.jpg", "photo.jpg"])
    }

    @Test("Cancelling stops the run and keeps unconverted files")
    func cancelKeepsRemaining() async throws {
        let dir = try TempDir()
        let sources = try (1...20).map { index in
            let url = dir.file("photo\(index).heic")
            try makeHEIC(at: url, width: 512, height: 512)
            return url
        }
        let model = makeModel()
        model.add(sources)

        model.run(jpegQuality: 0.85)
        model.cancel()
        #expect(model.status == "Cancelling…")
        try await waitUntil { !model.isWorking }

        let converted = sources.count - model.files.count
        #expect(!model.files.isEmpty)
        #expect(model.lastSummary == "Cancelled after \(converted) of \(sources.count)")
        #expect(model.status == nil)
    }

    @Test("Video files show their codec")
    func codecBadges() async throws {
        let dir = try TempDir()
        let clip = dir.file("clip.mov")
        try await makeMovie(at: clip, codec: .hevc)
        let model = makeModel()
        model.mode = .videos

        model.add([clip])
        try await waitUntil { model.codecNames[clip] != nil }

        #expect(model.codecNames[clip] == "HEVC")
        model.remove(clip)
        #expect(model.codecNames.isEmpty)
    }

    @Test("The save folder is remembered, unless it no longer exists")
    func remembersDestination() throws {
        let dir = try TempDir()
        let folder = try dir.folder("out")

        ConvertModel(defaults: defaults).destinationDir = folder
        #expect(ConvertModel(defaults: defaults).destinationDir?.standardizedFileURL == folder.standardizedFileURL)

        try FileManager.default.removeItem(at: folder)
        #expect(ConvertModel(defaults: defaults).destinationDir == nil)

        let model = ConvertModel(defaults: defaults)
        model.destinationDir = folder
        model.destinationDir = nil
        #expect(defaults.string(forKey: "destinationDir") == nil)
    }
}
