import Foundation
import CWhisper

enum SamplingStrategy: String, Codable, CaseIterable {
    case greedy
    case beamSearch

    var whisperStrategy: whisper_sampling_strategy {
        switch self {
        case .greedy: return WHISPER_SAMPLING_GREEDY
        case .beamSearch: return WHISPER_SAMPLING_BEAM_SEARCH
        }
    }
}

struct WhisperSettings: Codable, Equatable {
    var strategy: SamplingStrategy = .greedy
    var temperature: Float = 0.0
    var bestOf: Int = 5
    var beamSize: Int = 5

    var language: String = "en"
    var translate: Bool = false

    var threadCount: Int = 0
    var useGPU: Bool = true
    var flashAttention: Bool = true

    var noContext: Bool = true
    var singleSegment: Bool = true
    var noTimestamps: Bool = true
    var tokenTimestamps: Bool = false
    var suppressBlank: Bool = true
    var suppressNonSpeechTokens: Bool = false
    var initialPrompt: String = ""
    var temperatureInc: Float = 0.2
    var carryInitialPrompt: Bool = true

    var entropyThreshold: Float = 2.0
    var logprobThreshold: Float = -1.0
    var noSpeechThreshold: Float = 0.6

    var sileroVADEnabled: Bool = true

    var vadEnabled: Bool = true
    var vadSpeechThreshold: Float = 0.007
    var vadSilenceThreshold: Float = 0.003
    var vadMinSpeechMs: Int = 60
    var vadMinSilenceMs: Int = 600
    var vadPrePaddingMs: Int = 200
    var vadPostPaddingMs: Int = 300

    var outputMode: OutputMode = .paste
    var typeSpeedMs: Int = 5
    var restoreClipboard: Bool = true
    var sendReturnDelayMs: Int = 200

    var hotkeyKeyCode: UInt16 = 0x6F
    var sendHotkeyKeyCode: UInt16 = 0x67
    var inputGain: Float = 1.0
    var keepMicWarm: Bool = true

    var transcriptionMode: TranscriptionMode = .buffered
    var releaseDelayMs: Int = 300

    var launchAtLogin: Bool = false

    var showOverlay: Bool = true
    var overlayPosition: OverlayPosition = .bottomRight

    enum OutputMode: String, Codable, CaseIterable, Equatable {
        case type = "Type (simulate keyboard)"
        case paste = "Paste (clipboard + Cmd+V)"
    }

    enum TranscriptionMode: String, Codable, CaseIterable, Equatable {
        case buffered = "Buffered (transcribe on release)"
        case continuous = "Continuous (transcribe on each pause)"
    }

    enum OverlayPosition: String, Codable, CaseIterable, Equatable {
        case topLeft = "Top Left"
        case topRight = "Top Right"
        case bottomLeft = "Bottom Left"
        case bottomRight = "Bottom Right"
    }

    var resolvedThreadCount: Int {
        if threadCount > 0 { return threadCount }
        return max(1, min(4, ProcessInfo.processInfo.processorCount - 2))
    }

    private static let defaultsKey = "WhisperSettings"

    static func load() -> WhisperSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(WhisperSettings.self, from: data) else {
            return WhisperSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
