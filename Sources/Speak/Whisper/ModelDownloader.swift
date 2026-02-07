import Foundation

struct RemoteModel: Identifiable, Equatable {
    let filename: String
    let size: Int64
    let url: URL
    var isDownloaded: Bool = false

    var id: String { filename }

    var displayName: String {
        ModelNameFormatter.displayName(for: filename)
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

@Observable
class ModelDownloader: NSObject {
    var remoteModels: [RemoteModel] = []
    var isRefreshing: Bool = false
    var error: String?

    var downloadProgress: [String: Double] = [:]
    var downloadErrors: [String: String] = [:]

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]

    private static let hfRepoURL = "https://huggingface.co/ggerganov/whisper.cpp"
    private static let hfAPIURL = "https://huggingface.co/api/models/ggerganov/whisper.cpp"
    private static let hfResolveBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    func refreshModelList(localModels: [WhisperModel] = []) async {
        isRefreshing = true
        error = nil
        defer { isRefreshing = false }

        do {
            let models = try await fetchRemoteModels()
            let localFilenames = Set(localModels.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            remoteModels = models.map { model in
                var m = model
                m.isDownloaded = localFilenames.contains(model.filename)
                return m
            }
        } catch {
            self.error = error.localizedDescription
            NSLog("[ModelDownloader] Failed to fetch model list: %@", error.localizedDescription)
            remoteModels = Self.fallbackModels(localModels: localModels)
        }
    }

    private func fetchRemoteModels() async throws -> [RemoteModel] {
        let treeURL = URL(string: "\(Self.hfAPIURL)/tree/main")!
        let (data, response) = try await URLSession.shared.data(from: treeURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        var models: [RemoteModel] = []
        for file in files {
            guard let path = file["path"] as? String,
                  path.hasPrefix("ggml-"),
                  path.hasSuffix(".bin") else { continue }

            var size: Int64 = 0
            if let s = file["size"] as? Int64 {
                size = s
            } else if let s = file["size"] as? Int {
                size = Int64(s)
            } else if let lfs = file["lfs"] as? [String: Any],
                      let s = lfs["size"] as? Int64 {
                size = s
            } else if let lfs = file["lfs"] as? [String: Any],
                      let s = lfs["size"] as? Int {
                size = Int64(s)
            }
            if size == 0 { size = Self.estimatedSize(for: path) }

            let downloadURL = URL(string: "\(Self.hfResolveBase)/\(path)")!

            models.append(RemoteModel(
                filename: path,
                size: size,
                url: downloadURL
            ))
        }

        return models.sorted { $0.size < $1.size }
    }

    func download(_ model: RemoteModel, onComplete: @escaping (Result<URL, Error>) -> Void) {
        guard activeTasks[model.filename] == nil else { return }

        try? FileManager.default.createDirectory(at: ModelManager.modelsDirectory, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: model.url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.handleDownloadComplete(filename: model.filename, tempURL: tempURL, error: error)
            }
        }

        activeTasks[model.filename] = task
        completionHandlers[model.filename] = onComplete
        downloadProgress[model.filename] = 0.0
        downloadErrors.removeValue(forKey: model.filename)

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress[model.filename] = progress.fractionCompleted
            }
        }
        progressObservations[model.filename] = observation

        NSLog("[ModelDownloader] Starting download: %@", model.filename)
        task.resume()
    }

    func cancelDownload(_ filename: String) {
        activeTasks[filename]?.cancel()
        cleanupTask(filename)
        downloadProgress.removeValue(forKey: filename)
    }

    var isDownloading: Bool {
        !activeTasks.isEmpty
    }

    private func handleDownloadComplete(filename: String, tempURL: URL?, error: Error?) {
        let handler = completionHandlers[filename]
        cleanupTask(filename)

        if let error = error {
            downloadProgress.removeValue(forKey: filename)
            downloadErrors[filename] = error.localizedDescription
            handler?(.failure(error))
            return
        }

        guard let tempURL = tempURL else {
            downloadProgress.removeValue(forKey: filename)
            downloadErrors[filename] = "No file received"
            handler?(.failure(URLError(.cannotCreateFile)))
            return
        }

        let destURL = ModelManager.modelsDirectory.appendingPathComponent(filename)
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            downloadProgress[filename] = 1.0

            if let idx = remoteModels.firstIndex(where: { $0.filename == filename }) {
                remoteModels[idx].isDownloaded = true
            }

            NSLog("[ModelDownloader] Downloaded: %@ -> %@", filename, destURL.path)
            handler?(.success(destURL))
        } catch {
            downloadProgress.removeValue(forKey: filename)
            downloadErrors[filename] = error.localizedDescription
            handler?(.failure(error))
        }
    }

    private func cleanupTask(_ filename: String) {
        progressObservations[filename]?.invalidate()
        progressObservations.removeValue(forKey: filename)
        activeTasks.removeValue(forKey: filename)
        completionHandlers.removeValue(forKey: filename)
    }

    private static func estimatedSize(for filename: String) -> Int64 {
        if filename.contains("tiny") { return 75_000_000 }
        if filename.contains("base") { return 142_000_000 }
        if filename.contains("small") { return 466_000_000 }
        if filename.contains("medium") { return 1_500_000_000 }
        if filename.contains("large-v3-turbo-q5") { return 547_000_000 }
        if filename.contains("large-v3-turbo") { return 800_000_000 }
        if filename.contains("large") { return 2_900_000_000 }
        return 0
    }

    private static func fallbackModels(localModels: [WhisperModel]) -> [RemoteModel] {
        let localFilenames = Set(localModels.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        let models: [(String, Int64)] = [
            ("ggml-tiny.en.bin", 75_000_000),
            ("ggml-tiny.bin", 75_000_000),
            ("ggml-base.en.bin", 142_000_000),
            ("ggml-base.bin", 142_000_000),
            ("ggml-small.en.bin", 466_000_000),
            ("ggml-small.bin", 466_000_000),
            ("ggml-medium.en.bin", 1_500_000_000),
            ("ggml-medium.bin", 1_500_000_000),
            ("ggml-large-v3.bin", 2_900_000_000),
            ("ggml-large-v3-turbo.bin", 800_000_000),
            ("ggml-large-v3-turbo-q5_0.bin", 547_000_000),
        ]
        return models.map { (filename, size) in
            RemoteModel(
                filename: filename,
                size: size,
                url: URL(string: "\(hfResolveBase)/\(filename)")!,
                isDownloaded: localFilenames.contains(filename)
            )
        }
    }
}
