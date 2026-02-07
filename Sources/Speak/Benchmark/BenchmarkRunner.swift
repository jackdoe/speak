import Foundation

struct BenchmarkResult: Identifiable {
    let id = UUID()
    let scenario: String
    let audioDurationMs: Double
    let transcriptionTimeMs: Double
    let rtf: Double
    let segmentCount: Int
    let transcribedText: String
    let memoryMB: Double
}

@Observable
class BenchmarkRunner {
    var isRunning = false
    var results: [BenchmarkResult] = []
    var progress: Double = 0.0

    private static let sampleRate: Int = 16000

    func runBenchmark(modelPath: String, settings: WhisperSettings) async -> [BenchmarkResult] {
        isRunning = true
        results = []
        progress = 0.0

        defer {
            isRunning = false
            progress = 1.0
        }

        let scenarios = buildScenarios()
        var output: [BenchmarkResult] = []

        let context: WhisperContext
        do {
            context = try WhisperContext(modelPath: modelPath, settings: settings)
        } catch {
            NSLog("[Benchmark] Failed to load model: %@", error.localizedDescription)
            return []
        }

        for (index, scenario) in scenarios.enumerated() {
            let result = await runScenario(scenario, context: context)
            output.append(result)
            results = output
            progress = Double(index + 1) / Double(scenarios.count)
        }

        return output
    }

    private struct Scenario {
        let name: String
        let samples: [Float]
    }

    private func buildScenarios() -> [Scenario] {
        let sr = Self.sampleRate
        return [
            Scenario(
                name: "Short utterance (2s)",
                samples: Self.generateTone(durationSeconds: 2.0, sampleRate: sr)
            ),
            Scenario(
                name: "Medium utterance (10s)",
                samples: Self.generateTone(durationSeconds: 10.0, sampleRate: sr)
            ),
            Scenario(
                name: "Long recording (60s)",
                samples: Self.generateTone(durationSeconds: 60.0, sampleRate: sr)
            ),
            Scenario(
                name: "Silence gap (5s, 2s gap)",
                samples: Self.generateWithSilenceGap(
                    totalSeconds: 5.0,
                    silenceStartSeconds: 1.5,
                    silenceDurationSeconds: 2.0,
                    sampleRate: sr
                )
            ),
        ]
    }

    private func runScenario(_ scenario: Scenario, context: WhisperContext) async -> BenchmarkResult {
        let audioDurationMs = Double(scenario.samples.count) / Double(Self.sampleRate) * 1000.0
        let memBefore = Self.currentMemoryMB()

        let start = CFAbsoluteTimeGetCurrent()
        let transcription = await context.transcribe(samples: scenario.samples)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        let memAfter = Self.currentMemoryMB()

        return BenchmarkResult(
            scenario: scenario.name,
            audioDurationMs: audioDurationMs,
            transcriptionTimeMs: elapsed,
            rtf: audioDurationMs > 0 ? elapsed / audioDurationMs : 0,
            segmentCount: transcription.segments.count,
            transcribedText: transcription.fullText,
            memoryMB: memAfter - memBefore
        )
    }

    static func generateTone(durationSeconds: Double, sampleRate: Int, baseFrequency: Float = 440.0) -> [Float] {
        let count = Int(durationSeconds * Double(sampleRate))
        var samples = [Float](repeating: 0, count: count)
        let sr = Float(sampleRate)

        let harmonics: [(freq: Float, amp: Float)] = [
            (baseFrequency, 0.3),
            (baseFrequency * 2.0, 0.15),
            (baseFrequency * 3.0, 0.08),
            (baseFrequency * 0.5, 0.1),
        ]

        for i in 0..<count {
            let t = Float(i) / sr
            var value: Float = 0
            for h in harmonics {
                value += h.amp * sinf(2.0 * .pi * h.freq * t)
            }
            let envelope = 0.8 + 0.2 * sinf(2.0 * .pi * 3.0 * t)
            samples[i] = value * envelope
        }

        return samples
    }

    static func generateWithSilenceGap(
        totalSeconds: Double,
        silenceStartSeconds: Double,
        silenceDurationSeconds: Double,
        sampleRate: Int
    ) -> [Float] {
        let totalCount = Int(totalSeconds * Double(sampleRate))
        let silenceStart = Int(silenceStartSeconds * Double(sampleRate))
        let silenceEnd = Int((silenceStartSeconds + silenceDurationSeconds) * Double(sampleRate))

        var samples = generateTone(durationSeconds: totalSeconds, sampleRate: sampleRate)

        let clampedStart = min(silenceStart, totalCount)
        let clampedEnd = min(silenceEnd, totalCount)
        for i in clampedStart..<clampedEnd {
            samples[i] = 0
        }

        return samples
    }

    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }
}
