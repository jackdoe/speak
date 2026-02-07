import SwiftUI
import AppKit

@Observable
class RecordingOverlayState {
    var isVisible: Bool = false
    var isSpeaking: Bool = false
    var isTranscribing: Bool = false
    var audioLevel: Float = 0.0
    var speechDurationSec: Double = 0.0

    func update(audioEngine: AudioEngine) {
        isSpeaking = audioEngine.voiceActivityDetector.isSpeaking
        audioLevel = audioEngine.audioLevel
        speechDurationSec = Double(audioEngine.rawBuffer.count) / audioEngine.hardwareSampleRate
    }
}

struct RecordingOverlayView: View {
    let state: RecordingOverlayState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .shadow(color: dotColor.opacity(0.7), radius: state.isSpeaking ? 8 : 0)

            levelMeter
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                if state.isTranscribing {
                    Text("Processing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(state.isSpeaking ? "Listening" : "Paused")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.isSpeaking ? .green : .white.opacity(0.7))
                }

                Text(formatDuration(state.speechDurationSec))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.8))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        )
        .fixedSize()
    }

    private var dotColor: Color {
        if state.isTranscribing { return .blue }
        return state.isSpeaking ? .red : .orange
    }

    private var levelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(index: i))
                    .frame(width: 3)
            }
        }
    }

    private func barColor(index: Int) -> Color {
        let threshold = Float(index + 1) / 5.0 * 0.3
        let active = state.audioLevel > threshold
        if !active { return .white.opacity(0.1) }
        if index >= 4 { return .red }
        if index >= 3 { return .orange }
        return .green
    }

    private func formatDuration(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        if m > 0 { return String(format: "%d:%02d", m, s) }
        return String(format: "0:%02d", s)
    }
}

class RecordingOverlayController {
    static let shared = RecordingOverlayController()

    let state = RecordingOverlayState()
    private var window: NSPanel?
    private var updateTimer: Timer?

    func show(position: WhisperSettings.OverlayPosition, audioEngine: AudioEngine) {
        state.isVisible = true
        state.isTranscribing = false
        state.speechDurationSec = 0
        state.isSpeaking = false
        state.audioLevel = 0

        if window == nil {
            createWindow()
        }

        positionWindow(position)
        window?.orderFrontRegardless()

        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.state.update(audioEngine: audioEngine)
        }
    }

    func setTranscribing() {
        state.isTranscribing = true
        state.isSpeaking = false
        state.audioLevel = 0
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func hide() {
        updateTimer?.invalidate()
        updateTimer = nil
        state.isVisible = false
        window?.orderOut(nil)
    }

    private func createWindow() {
        let view = RecordingOverlayView(state: state)
        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        window = panel
    }

    private func positionWindow(_ position: WhisperSettings.OverlayPosition) {
        guard let window = window,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let margin: CGFloat = 20

        let origin: NSPoint
        switch position {
        case .topLeft:
            origin = NSPoint(x: screenFrame.minX + margin, y: screenFrame.maxY - windowSize.height - margin)
        case .topRight:
            origin = NSPoint(x: screenFrame.maxX - windowSize.width - margin, y: screenFrame.maxY - windowSize.height - margin)
        case .bottomLeft:
            origin = NSPoint(x: screenFrame.minX + margin, y: screenFrame.minY + margin)
        case .bottomRight:
            origin = NSPoint(x: screenFrame.maxX - windowSize.width - margin, y: screenFrame.minY + margin)
        }

        window.setFrameOrigin(origin)
    }
}
