import Accelerate
import ApplicationServices
import Foundation

@MainActor final class Dictation {
    enum Target: String {
        case type, send, claude
    }

    private static let preroll = Recognizer.rate / 4
    private static let tail = Recognizer.rate * 3 / 20
    private static let patience = 1.0

    private let ring: Ring
    private let recognizer: Recognizer
    private let status: StatusItem
    private let worker = DispatchQueue(label: "speak.transcription", qos: .userInteractive)
    private var recording: (start: Int, target: Target)?
    private var pending = 0

    init(ring: Ring, recognizer: Recognizer, status: StatusItem) {
        self.ring = ring
        self.recognizer = recognizer
        self.status = status
    }

    func hold(_ target: Target, pressed: Bool) {
        Log.debug("\(target) \(pressed ? "pressed" : "released")")
        if pressed, recording == nil {
            recording = (max(0, ring.now - Self.preroll), target)
        } else if !pressed, let recording, recording.target == target {
            self.recording = nil
            pending += 1
            transcribe(from: recording.start, to: ring.now + Self.tail, target)
        }
        settle()
    }

    private func transcribe(from start: Int, to end: Int, _ target: Target) {
        let deadline = Date.now.addingTimeInterval(Double(Self.tail) / Double(Recognizer.rate) + Self.patience)
        worker.async { [ring, recognizer] in
            let samples = ring.slice(from: start, to: end, waitingUntil: deadline)
            let began = ContinuousClock.now
            var text = ""
            do {
                text = try recognizer.transcribe(samples)
            } catch {
                Log.error("\(error)")
            }
            let milliseconds = (ContinuousClock.now - began) / .milliseconds(1)
            let seconds = Double(samples.count) / Double(Recognizer.rate)
            Log.debug(String(format: "%.1fs audio, peak %.3f, %.0f ms, %d chars", seconds, samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples), milliseconds, text.count))
            Self.deliver(text, to: target)
            let summary = String(format: "%.1fs audio, %.0f ms", seconds, milliseconds) + (text.isEmpty ? ", nothing heard" : "")
            DispatchQueue.main.async { self.finished(summary) }
        }
    }

    nonisolated private static func deliver(_ text: String, to target: Target) {
        guard !text.isEmpty else { return }
        if target != .claude, !AXIsProcessTrusted() {
            Log.error("typing needs Accessibility permission for Speak")
        }
        switch target {
        case .type:
            Keyboard.type(text + " ")
        case .send:
            Keyboard.type(text)
            Keyboard.pressReturn()
        case .claude:
            do {
                try Claude.send(text)
            } catch {
                Log.error("\(error)")
            }
        }
    }

    private func finished(_ summary: String) {
        pending -= 1
        status.report(summary)
        settle()
    }

    private func settle() {
        status.show(recording != nil ? .recording : pending > 0 ? .transcribing : .idle)
    }
}
