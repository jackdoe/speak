import Foundation
import Observation

@Observable
class PerformanceMonitor {
    var lastResult: TranscriptionResult?
    var totalTranscriptions: Int = 0
    var averageRTF: Double = 0

    private var rtfSum: Double = 0

    var lastAudioDurationMs: Double {
        lastResult?.audioDurationMs ?? 0
    }

    var lastTranscriptionTimeMs: Double {
        lastResult?.transcriptionTimeMs ?? 0
    }

    var lastRTF: Double {
        lastResult?.realTimeFactor ?? 0
    }

    func record(_ result: TranscriptionResult) {
        lastResult = result
        totalTranscriptions += 1
        rtfSum += result.realTimeFactor
        averageRTF = rtfSum / Double(totalTranscriptions)
    }

    var summary: String {
        guard totalTranscriptions > 0 else { return "No transcriptions yet" }
        let timeStr = String(format: "%.1fs", lastTranscriptionTimeMs / 1000.0)
        let rtfStr = String(format: "%.2fx", lastRTF)
        return "\(timeStr) (RTF: \(rtfStr))"
    }
}
