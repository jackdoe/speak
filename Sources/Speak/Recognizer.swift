import CoreML

final class Recognizer: @unchecked Sendable {
    static let directory = URL.applicationSupportDirectory.appending(path: "Speak/parakeet-tdt-0.6b-v2-coreml", directoryHint: .isDirectory)
    static let rate = 16000
    static let samplesPerFrame = 1280

    private static let blank: Int32 = 1024
    private static let maxSymbolsPerFrame = 5

    private struct Prediction {
        let output: MLMultiArray
        let h: MLMultiArray
        let c: MLMultiArray
    }

    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let window: Int
    private let state: [Int]
    private let pieces: [String]

    init() throws {
        guard FileManager.default.fileExists(atPath: Self.directory.path) else {
            throw Failure("no model in \(Self.directory.path), run make model")
        }
        preprocessor = try Self.withoutStandardOutput { try Self.load("Preprocessor", .all) }
        encoder = try Self.load("Encoder", .cpuAndNeuralEngine)
        decoder = try Self.load("Decoder", .cpuOnly)
        joint = try Self.load("JointDecision", .cpuOnly)
        window = try Self.window(of: preprocessor)
        state = try Self.shape(of: "h_in", in: decoder)
        pieces = try Self.vocabulary()
        _ = try transcribe([Float](repeating: 0, count: Self.rate))
    }

    func transcribe(_ samples: [Float]) throws -> String {
        var transcript: [String] = []
        var start = 0
        var kept = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            let tokens = try decode(samples, start ..< end)
            let cut = end < samples.count ? Seam.cut(samples, after: tokens, before: end) : end
            transcript += tokens.filter { (kept ..< cut).contains($0.position) }.map(\.piece)
            kept = cut
            start = end < samples.count ? cut - Seam.context : end
        }
        return transcript.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func decode(_ samples: [Float], _ range: Range<Int>) throws -> [Token] {
        let audio = samples[range]
        let signal = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        signal.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            let end = buffer.update(fromContentsOf: audio)
            UnsafeMutableBufferPointer(rebasing: buffer[end...]).update(repeating: 0)
        }
        let features = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": signal,
            "audio_length": Self.array([Int32(audio.count)], shape: [1]),
        ]))
        let encoded = try encoder.prediction(from: features)
        let frames = try Self.output("encoder", of: encoded)
        let count = try Self.output("encoder_length", of: encoded)[0].intValue
        guard frames.dataType == .float32 else { throw Failure("encoder output is not float32") }

        let dimension = frames.shape[1].intValue
        let channelStride = frames.strides[1].intValue
        let timeStride = frames.strides[2].intValue
        let step = try MLMultiArray(shape: [1, NSNumber(value: dimension), 1], dataType: .float32)
        let zeros = MLMultiArray(MLShapedArray<Float>(repeating: 0, shape: state))

        return try frames.withUnsafeBufferPointer(ofType: Float.self) { source in
            var prediction = try predict(Self.blank, h: zeros, c: zeros)
            var tokens: [Token] = []
            var t = 0
            var emitted = 0
            while t < count {
                step.withUnsafeMutableBufferPointer(ofType: Float.self) { target, strides in
                    for d in 0 ..< dimension {
                        target[d * strides[1]] = source[d * channelStride + t * timeStride]
                    }
                }
                let decision = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "encoder_step": step,
                    "decoder_step": prediction.output,
                ]))
                let token = try Self.output("token_id", of: decision)[0].int32Value
                var skip = try Self.output("duration", of: decision)[0].intValue
                if token != Self.blank {
                    tokens.append(Token(piece: pieces[Int(token)], position: range.lowerBound + t * Self.samplesPerFrame))
                    prediction = try predict(token, h: prediction.h, c: prediction.c)
                    emitted += 1
                }
                if skip > 0 { emitted = 0 }
                if emitted >= Self.maxSymbolsPerFrame || (token == Self.blank && skip == 0) {
                    emitted = 0
                    skip = 1
                }
                t += skip
            }
            return tokens
        }
    }

    private func predict(_ token: Int32, h: MLMultiArray, c: MLMultiArray) throws -> Prediction {
        let result = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": Self.array([token], shape: [1, 1]),
            "target_length": Self.array([1], shape: [1]),
            "h_in": h,
            "c_in": c,
        ]))
        return Prediction(
            output: try Self.output("decoder", of: result),
            h: try Self.output("h_out", of: result),
            c: try Self.output("c_out", of: result))
    }

    private static func withoutStandardOutput<T>(_ body: () throws -> T) rethrows -> T {
        fflush(nil)
        let standardOutput = dup(STDOUT_FILENO)
        let null = open("/dev/null", O_WRONLY)
        dup2(null, STDOUT_FILENO)
        close(null)
        defer {
            fflush(nil)
            dup2(standardOutput, STDOUT_FILENO)
            close(standardOutput)
        }
        return try body()
    }

    private static func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return try MLModel(contentsOf: directory.appending(path: name + ".mlmodelc"), configuration: configuration)
    }

    private static func window(of preprocessor: MLModel) throws -> Int {
        guard let range = preprocessor.modelDescription.inputDescriptionsByName["audio_signal"]?
            .multiArrayConstraint?.shapeConstraint.sizeRangeForDimension.last?.rangeValue
        else { throw Failure("preprocessor input audio_signal has no length range") }
        return NSMaxRange(range) - 1
    }

    private static func shape(of input: String, in model: MLModel) throws -> [Int] {
        guard let shape = model.modelDescription.inputDescriptionsByName[input]?.multiArrayConstraint?.shape else {
            throw Failure("model input \(input) is missing")
        }
        return shape.map(\.intValue)
    }

    private static func vocabulary() throws -> [String] {
        let entries = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appending(path: "parakeet_vocab.json")))
        return try (0 ..< Int(blank)).map { id in
            guard let piece = entries[String(id)] else { throw Failure("vocabulary lacks token \(id)") }
            return piece
        }
    }

    private static func array(_ values: [Int32], shape: [Int]) -> MLMultiArray {
        MLMultiArray(MLShapedArray<Int32>(scalars: values, shape: shape))
    }

    private static func output(_ name: String, of provider: MLFeatureProvider) throws -> MLMultiArray {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else {
            throw Failure("model output \(name) is missing")
        }
        return array
    }
}
