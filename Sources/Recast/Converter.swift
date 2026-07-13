import Foundation
import ImageIO
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

enum Mode: String, CaseIterable, Identifiable, Sendable {
    case images = "Images"
    case video = "Video"
    var id: String { rawValue }
    var systemImage: String { self == .images ? "photo" : "film" }
    var dropIcon: String { self == .images ? "photo.on.rectangle.angled" : "film.stack" }
    var inputUTTypes: [UTType] {
        self == .images ? [.heic, .heif] : [.quickTimeMovie, .mpeg4Movie]
    }
    var inputExtensions: Set<String> {
        Set(inputUTTypes.flatMap { $0.tags[.filenameExtension] ?? [] })
    }
    var dropPrompt: String {
        self == .images ? "Drop HEIC or HEIF photos" : "Drop HEVC or ProRes video"
    }
    /// Names the codecs those extensions can hold, so the per-file codec badge makes sense.
    var dropHint: String? {
        self == .images
            ? "Convert to everyday JPEG or PNG files"
            : "Convert to a broadly compatible H.264 MP4"
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    var id: String { rawValue }
    var utType: UTType { self == .jpeg ? .jpeg : .png }
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

enum ConversionError: LocalizedError {
    case unreadable, writeFailed, incompatibleVideo
    var errorDescription: String? {
        switch self {
        case .unreadable: "Could not read source"
        case .writeFailed: "Failed to write output"
        case .incompatibleVideo: "This video cannot be converted to an H.264 MP4"
        }
    }
}

enum Converter {
    /// .heic/.heif → JPEG/PNG. Caller inserts the returned URL into `reserved` on success.
    static func convertImage(
        source: URL,
        destinationDir: URL?,
        format: OutputFormat,
        jpegQuality: Double,
        reserved: Set<URL>
    ) throws -> URL {
        guard let imgSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imgSource) > 0 else {
            throw ConversionError.unreadable
        }

        let outURL = outputURL(
            source: source, destinationDir: destinationDir,
            ext: format.fileExtension, reserved: reserved
        )

        guard let dest = CGImageDestinationCreateWithURL(
            outURL as CFURL, format.utType.identifier as CFString, 1, nil
        ) else { throw ConversionError.writeFailed }

        var options: [CFString: Any] = [:]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }

        // Primary image only: JPEG and PNG are single-image formats, so companion frames in a
        // multi-image HEIC (Live Photo / burst) have nowhere to go. Index 0 is the correct choice.
        CGImageDestinationAddImageFromSource(dest, imgSource, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: outURL)  // don't leave a truncated file behind
            throw ConversionError.writeFailed
        }
        return outURL
    }

    /// .mov/.mp4 → H.264 .mp4: prefer H.264 passthrough, then re-encode when MP4 compatibility requires it.
    static func convertVideo(
        source: URL,
        destinationDir: URL?,
        reserved: Set<URL>
    ) async throws -> URL {
        let outURL = outputURL(source: source, destinationDir: destinationDir, ext: "mp4", reserved: reserved)
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: source)
            let preset = try await pickCompatiblePreset(for: asset)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw ConversionError.writeFailed
            }
            try await session.export(to: outURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        return outURL
    }

    /// Friendly codec name of a video file's first video track (e.g. "H.264", "HEVC", "ProRes"),
    /// or nil if it has no readable video track.
    static func videoCodecName(for url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let desc = try? await track.load(.formatDescriptions).first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(desc)
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        default:
            let bytes = (0..<4).map { UInt8(code >> (8 * (3 - $0)) & 0xFF) }
            guard bytes.allSatisfy({ (32...126).contains($0) }) else { return "Other" }
            let tag = String(bytes.map { Character(UnicodeScalar($0)) })
            return tag.hasPrefix("ap") ? "ProRes" : tag.uppercased()  // ProRes fourCCs all start "ap"
        }
    }

    /// Output is always H.264. Compatible H.264 sources pass through; incompatible H.264 tracks and
    /// other codecs re-encode with HighestQuality, which preserves resolution.
    private static func pickCompatiblePreset(for asset: AVURLAsset) async throws -> String {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ConversionError.unreadable }
        let isH264 = if let description = try await track.load(.formatDescriptions).first {
            CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264
        } else {
            false
        }

        let presets = isH264
            ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
            : [AVAssetExportPresetHighestQuality]
        for preset in presets where await AVAssetExportSession.compatibility(
            ofExportPreset: preset,
            with: asset,
            outputFileType: .mp4
        ) {
            return preset
        }
        throw ConversionError.incompatibleVideo
    }

    static func outputURL(source: URL, destinationDir: URL?, ext: String, reserved: Set<URL>) -> URL {
        let dir = destinationDir ?? source.deletingLastPathComponent()
        let baseName = source.deletingPathExtension().lastPathComponent
        let fileManager = FileManager.default
        var candidate = dir.appendingPathComponent("\(baseName).\(ext)")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            candidate = dir.appendingPathComponent("\(baseName) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
