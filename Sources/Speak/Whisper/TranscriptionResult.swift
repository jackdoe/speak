import Foundation

struct TranscriptionSegment {
    let text: String
    let startTime: Int64
    let endTime: Int64
}

struct TranscriptionResult {
    let segments: [TranscriptionSegment]
    let audioDurationMs: Double
    let transcriptionTimeMs: Double
    let modelName: String

    var fullText: String {
        segments.map(\.text).joined()
    }

    var realTimeFactor: Double {
        guard audioDurationMs > 0 else { return 0 }
        return transcriptionTimeMs / audioDurationMs
    }
}
