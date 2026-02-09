import Foundation
import Observation

struct WhisperModel: Identifiable, Codable {
    let id: String
    let path: String
    let size: Int64

    var name: String {
        ModelNameFormatter.displayName(for: id)
    }

    var isEnglishOnly: Bool {
        id.contains(".en")
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    enum CodingKeys: String, CodingKey {
        case id, path, size
    }
}

@Observable
class ModelManager {
    var availableModels: [WhisperModel] = []
    var currentModel: WhisperModel?
    var isLoading: Bool = false

    private var whisperContext: WhisperContext?

    private static let vadFilename = "ggml-silero-v6.2.0.bin"

    static var vadModelPath: String {
        for dir in vadSearchDirectories {
            let path = dir.appendingPathComponent(vadFilename).path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return modelsDirectory.appendingPathComponent(vadFilename).path
    }

    static var vadModelExists: Bool {
        FileManager.default.fileExists(atPath: vadModelPath)
    }

    private static var vadSearchDirectories: [URL] {
        [
            modelsDirectory,
            Bundle.main.bundleURL.appendingPathComponent("Resources/models", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/models", isDirectory: true),
        ]
    }

    func releaseContext() {
        whisperContext = nil
        currentModel = nil
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Speak/models", isDirectory: true)
    }

    private var bundledModelsDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Resources/models", isDirectory: true)
    }

    private var workingDirectoryModels: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/models", isDirectory: true)
    }

    init() {
        scanForModels()
    }

    func scanForModels() {
        var found: [WhisperModel] = []
        let fm = FileManager.default

        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        for directory in [Self.modelsDirectory, bundledModelsDirectory, workingDirectoryModels] {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            for file in files where file.pathExtension == "bin" {
                let filename = file.deletingPathExtension().lastPathComponent
                guard !filename.hasPrefix("ggml-silero") else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let fileSize = attrs[.size] as? Int64 else {
                    continue
                }
                let model = WhisperModel(
                    id: filename,
                    path: file.path,
                    size: fileSize
                )
                found.append(model)
            }
        }

        availableModels = found.sorted { $0.size < $1.size }
    }

    private static let savedModelKey = "SelectedModelID"

    func loadModel(_ model: WhisperModel, settings: WhisperSettings = .load()) async throws -> WhisperContext {
        if let current = currentModel, current.id == model.id, let ctx = whisperContext {
            return ctx
        }

        isLoading = true
        defer { isLoading = false }

        let context = try WhisperContext(modelPath: model.path, settings: settings)
        currentModel = model
        whisperContext = context

        UserDefaults.standard.set(model.id, forKey: Self.savedModelKey)
        return context
    }

    func loadSavedOrFirstAvailable(settings: WhisperSettings = .load()) async throws -> WhisperContext {
        if let savedID = UserDefaults.standard.string(forKey: Self.savedModelKey),
           let saved = availableModels.first(where: { $0.id == savedID }) {
            return try await loadModel(saved, settings: settings)
        }
        guard let model = availableModels.first else {
            throw WhisperError.modelLoadFailed("No models found")
        }
        return try await loadModel(model, settings: settings)
    }
}
