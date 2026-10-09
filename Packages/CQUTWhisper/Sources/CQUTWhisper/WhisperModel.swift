import Foundation
import CryptoKit
import CQUTWhisperC

/// A model the app can run locally.
///
/// Whisper models are 32 MB to 574 MB, so they are not in the bundle: the user
/// picks one, it downloads into the app container, and it can be removed again
/// to reclaim the space. That is the same shape Moshi documents for its own
/// Whisper and Parakeet engines, and it is the only shape that works when the
/// smallest useful model is still larger than most apps.
public struct WhisperModel: Identifiable, Hashable, Sendable {
    public let name: String
    public let label: String
    public let bytes: Int64
    public let multilingual: Bool

    public var id: String { name }
    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The models the vendored build offers. Read from the C table rather than
    /// repeated here, so the catalog, the URLs and the hashes cannot drift
    /// apart — they are one table in one place.
    public static let all: [WhisperModel] = {
        var raw = [cqut_whisper_model](repeating: cqut_whisper_model(), count: 16)
        let count = raw.withUnsafeMutableBufferPointer { buffer in
            cqut_whisper_models(buffer.baseAddress, Int32(buffer.count))
        }
        return raw.prefix(Int(count)).map { entry in
            WhisperModel(
                name: entry.name.map { String(cString: $0) } ?? "",
                label: entry.label.map { String(cString: $0) } ?? "",
                bytes: entry.bytes,
                multilingual: entry.multilingual != 0
            )
        }
    }()

    /// English-only models are meaningfully more accurate for English at the
    /// same size, which is the trade the `.en` files exist to offer.
    public static let english = all.filter { !$0.multilingual }
    public static let multilingual = all.filter(\.multilingual)

    public var downloadURL: URL? {
        name.withCString { cqut_whisper_model_url($0) }.flatMap { URL(string: String(cString: $0)) }
    }

    var expectedSHA256: String? {
        name.withCString { cqut_whisper_model_sha256($0) }.map { String(cString: $0) }
    }
}

/// Where downloaded models live, and how to get one.
@Observable
public final class WhisperModelStore {
    /// A download in flight, reported so the UI can show a real percentage
    /// instead of an indeterminate spinner on a 574 MB transfer.
    public struct Download: Equatable, Sendable {
        public var model: String
        public var received: Int64
        public var total: Int64
        public var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }

    public private(set) var downloads: [String: Download] = [:]
    public private(set) var failure: String?

    private let directory: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func path(for model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.name)
    }

    /// Where a transcript can be written for a script to pick up. Documents
    /// rather than Application Support: `simctl get_app_container … data` maps
    /// to a host path either way, but Documents is the one a person would look
    /// in, and neither is user-visible in a shipped build.
    public var transcriptDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// True when the file is present. Size only: hashing 574 MB on every
    /// launch to answer "is it installed" would cost more than the download it
    /// is guarding. The hash is checked once, when the bytes arrive.
    public func isInstalled(_ model: WhisperModel) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path(for: model).path)[.size] as? Int64
        else { return false }
        // Exact-size check: a partial download is the failure worth catching,
        // and it is the one that would otherwise reach the model loader.
        return size == model.bytes
    }

    public func installedModels() -> [WhisperModel] {
        WhisperModel.all.filter(isInstalled)
    }

    public func remove(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: path(for: model))
    }

    /// Downloads and verifies, then puts the file in place. Throws with a
    /// message worth showing: a mismatch means the bytes were not the bytes
    /// the catalog describes, which is exactly the case a checksum is for.
    public func download(_ model: WhisperModel) async throws {
        guard let url = model.downloadURL else { throw WhisperError.unknownModel(model.name) }
        failure = nil
        downloads[model.name] = Download(model: model.name, received: 0, total: model.bytes)

        let staging = directory.appendingPathComponent("\(model.name).part")
        try? FileManager.default.removeItem(at: staging)

        let delegate = ProgressDelegate { [weak self] received in
            Task { @MainActor in
                guard var entry = self?.downloads[model.name] else { return }
                entry.received = received
                self?.downloads[model.name] = entry
            }
        }

        do {
            let (temp, response) = try await URLSession.shared.download(
                from: url, delegate: delegate)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw WhisperError.download("server returned \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: temp, to: staging)

            let digest = try Self.sha256(of: staging)
            if let expected = model.expectedSHA256, digest != expected {
                try? FileManager.default.removeItem(at: staging)
                throw WhisperError.checksum(model.name)
            }

            // Moved rather than left at the .part name so `isInstalled` never
            // sees a file that is complete but still being verified.
            try? FileManager.default.removeItem(at: path(for: model))
            try FileManager.default.moveItem(at: staging, to: path(for: model))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            downloads[model.name] = nil
            failure = "\(error)"
            throw error
        }
        downloads[model.name] = nil
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Streamed rather than read whole: the largest model is 574 MB, and
        // loading that into memory to hash it would be the largest allocation
        // in the app for no reason.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func progress(for model: WhisperModel) -> Download? { downloads[model.name] }
    public var isDownloading: Bool { !downloads.isEmpty }

    /// Reports bytes as they arrive. `URLSession`'s own progress reporting is
    /// on the task, which `download(from:delegate:)` does not return until it
    /// is finished — so the delegate is the only place the count is visible
    /// while the transfer is still running.
    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        let onProgress: @Sendable (Int64) -> Void
        init(onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onProgress(totalBytesWritten)
        }
    }
}

public enum WhisperError: Error, CustomStringConvertible {
    case unknownModel(String)
    case download(String)
    case checksum(String)
    case modelNotLoaded
    case failed(String)

    public var description: String {
        switch self {
        case .unknownModel(let name):
            "no download URL for \(name)"
        case .download(let message):
            "download failed: \(message)"
        case .checksum(let name):
            "\(name) did not match its checksum — the download was corrupted or truncated"
        case .modelNotLoaded:
            "no whisper model is loaded"
        case .failed(let message):
            message
        }
    }
}