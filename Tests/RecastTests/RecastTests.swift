import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Recast

@Suite("Output naming")
struct OutputNamingTests {
    @Test("Existing and reserved names receive the next suffix")
    func uniqueOutputURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("photo.heic")
        let firstOutput = directory.appendingPathComponent("photo.jpg")
        let reservedOutput = directory.appendingPathComponent("photo 2.jpg")
        try Data().write(to: firstOutput)

        let output = Converter.outputURL(
            source: source,
            destinationDir: directory,
            ext: "jpg",
            reserved: [reservedOutput]
        )

        #expect(output.lastPathComponent == "photo 3.jpg")
    }

    @Test("HEIC photos convert to readable JPEG files")
    func imageConversion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())

        let source = directory.appendingPathComponent("photo.heic")
        let destination = try #require(CGImageDestinationCreateWithURL(
            source as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let output = try Converter.convertImage(
            source: source,
            destinationDir: directory,
            format: .jpeg,
            jpegQuality: 0.85,
            reserved: []
        )

        #expect(output.pathExtension == "jpg")
        #expect(CGImageSourceCreateWithURL(output as CFURL, nil) != nil)
    }
}

@Suite("Conversion queue")
@MainActor
struct ConversionQueueTests {
    @Test("Unsupported inputs are reported and ignored")
    func inputFiltering() {
        let model = ConvertModel()
        let photo = URL(filePath: "/tmp/photo.heif")
        let document = URL(filePath: "/tmp/notes.txt")

        #expect(model.add([photo, document]) == 1)
        #expect(model.files == [photo])
        #expect(model.notice != nil)
    }

    @Test("Successful inputs leave the queue while failures remain")
    func completionRemovesOnlySuccesses() {
        let model = ConvertModel()
        let first = URL(filePath: "/tmp/first.heic")
        let second = URL(filePath: "/tmp/second.heic")
        model.add([first, second])

        model.finish(
            successfulURLs: [first],
            failures: [.init(url: second, reason: "Test failure")],
            total: 2,
            cancelled: false
        )

        #expect(model.files == [second])
        #expect(model.failures.map(\.url) == [second])
        #expect(model.lastSummary == "Converted 1 of 2 · 1 failed")
    }

    @Test("Cancellation keeps unprocessed inputs available")
    func cancellationKeepsRemainingInputs() {
        let model = ConvertModel()
        let first = URL(filePath: "/tmp/first.heic")
        let second = URL(filePath: "/tmp/second.heic")
        model.add([first, second])

        model.finish(
            successfulURLs: [first],
            failures: [],
            total: 2,
            cancelled: true
        )

        #expect(model.files == [second])
        #expect(model.lastSummary == "Cancelled after 1 of 2")
    }
}
