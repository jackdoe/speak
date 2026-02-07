import Foundation
import CWhisper

guard CommandLine.arguments.count >= 2 else {
    print("Usage: SpeakBenchmark <model_path>")
    print("  model_path: Path to a whisper.cpp .bin model file")
    exit(1)
}

let modelPath = CommandLine.arguments[1]

guard FileManager.default.fileExists(atPath: modelPath) else {
    print("Error: Model file not found at \(modelPath)")
    exit(1)
}

let sampleRate = 16000

func generateTone(durationSeconds: Double, baseFrequency: Float = 440.0) -> [Float] {
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

func generateWithSilenceGap(totalSeconds: Double, silenceStart: Double, silenceDuration: Double) -> [Float] {
    var samples = generateTone(durationSeconds: totalSeconds)
    let gapStart = Int(silenceStart * Double(sampleRate))
    let gapEnd = min(Int((silenceStart + silenceDuration) * Double(sampleRate)), samples.count)
    for i in gapStart..<gapEnd {
        samples[i] = 0
    }
    return samples
}

func currentMemoryMB() -> Double {
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

struct Scenario {
    let name: String
    let samples: [Float]
}

let scenarios: [Scenario] = [
    Scenario(name: "Short utterance (2s)", samples: generateTone(durationSeconds: 2.0)),
    Scenario(name: "Medium utterance (10s)", samples: generateTone(durationSeconds: 10.0)),
    Scenario(name: "Long recording (60s)", samples: generateTone(durationSeconds: 60.0)),
    Scenario(name: "Silence gap (5s, 2s gap)", samples: generateWithSilenceGap(totalSeconds: 5.0, silenceStart: 1.5, silenceDuration: 2.0)),
]

print("SpeakBenchmark")
print("==============")
print("Model: \(modelPath)")
print()

print("Loading model...")
let loadStart = CFAbsoluteTimeGetCurrent()

var cparams = whisper_context_default_params()
cparams.use_gpu = true

guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
    print("Error: Failed to load model")
    exit(1)
}

let loadTime = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0
print(String(format: "Model loaded in %.0f ms", loadTime))
print()

let header = String(format: "%-28s  %8s  %10s  %7s  %4s  %8s",
    "Scenario", "Audio", "Transc.", "RTF", "Seg", "Mem MB")
print(header)
print(String(repeating: "-", count: header.count))

for scenario in scenarios {
    let audioDurationMs = Double(scenario.samples.count) / Double(sampleRate) * 1000.0
    let memBefore = currentMemoryMB()

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    let threadCount = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
    params.n_threads = threadCount
    params.no_context = true
    params.print_special = false
    params.print_progress = false
    params.print_realtime = false
    params.print_timestamps = false

    let langStr = "en"
    let langCStr = langStr.withCString { strdup($0) }!
    params.language = UnsafePointer(langCStr)

    let start = CFAbsoluteTimeGetCurrent()
    let result = scenario.samples.withUnsafeBufferPointer { buffer in
        whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

    free(langCStr)

    let memAfter = currentMemoryMB()
    let memDelta = memAfter - memBefore
    let rtf = audioDurationMs > 0 ? elapsed / audioDurationMs : 0

    var segmentCount: Int32 = 0
    var fullText = ""
    if result == 0 {
        segmentCount = whisper_full_n_segments(ctx)
        for i in 0..<segmentCount {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                fullText += String(cString: cStr)
            }
        }
    }

    let audioStr: String
    if audioDurationMs < 1000 {
        audioStr = String(format: "%.0f ms", audioDurationMs)
    } else {
        audioStr = String(format: "%.1f s", audioDurationMs / 1000.0)
    }

    let transcStr: String
    if elapsed < 1000 {
        transcStr = String(format: "%.0f ms", elapsed)
    } else {
        transcStr = String(format: "%.2f s", elapsed / 1000.0)
    }

    let row = String(format: "%-28s  %8s  %10s  %6.3fx  %4d  %7.1f",
        scenario.name, audioStr, transcStr, rtf, segmentCount, memDelta)
    print(row)

    if !fullText.isEmpty {
        let truncated = fullText.count > 80 ? String(fullText.prefix(80)) + "..." : fullText
        print("  -> \(truncated)")
    }
}

whisper_free(ctx)

print()
print("Done.")
