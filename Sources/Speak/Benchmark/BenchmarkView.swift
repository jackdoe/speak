import SwiftUI

struct BenchmarkView: View {
    @State private var runner = BenchmarkRunner()
    @State private var modelManager = ModelManager()
    @State private var selectedModelPath: String?
    @State private var settings = WhisperSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            if runner.isRunning {
                progressSection
            }
            if !runner.results.isEmpty {
                resultsTable
            }
            Spacer()
        }
        .padding()
        .frame(minWidth: 700, minHeight: 400)
        .onAppear {
            modelManager.scanForModels()
            selectedModelPath = modelManager.availableModels.first?.path
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Whisper Benchmark")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Runs transcription on generated audio to measure performance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Model:", selection: $selectedModelPath) {
                if modelManager.availableModels.isEmpty {
                    Text("No models found").tag(nil as String?)
                }
                ForEach(modelManager.availableModels) { model in
                    Text("\(model.name) (\(model.sizeDescription))")
                        .tag(model.path as String?)
                }
            }
            .frame(maxWidth: 300)

            Button(runner.isRunning ? "Running..." : "Run Benchmark") {
                runBenchmark()
            }
            .disabled(runner.isRunning || selectedModelPath == nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: runner.progress)
            Text("Running scenario \(Int(runner.progress * 4) + 1) of 4...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results")
                .font(.headline)

            Table(runner.results) {
                TableColumn("Scenario") { result in
                    Text(result.scenario)
                }
                .width(min: 140, ideal: 180)

                TableColumn("Audio") { result in
                    Text(formatDuration(result.audioDurationMs))
                }
                .width(min: 60, ideal: 70)

                TableColumn("Transcription") { result in
                    Text(formatDuration(result.transcriptionTimeMs))
                }
                .width(min: 80, ideal: 90)

                TableColumn("RTF") { result in
                    Text(String(format: "%.3fx", result.rtf))
                        .foregroundStyle(result.rtf < 1.0 ? .green : .orange)
                }
                .width(min: 60, ideal: 70)

                TableColumn("Segments") { result in
                    Text("\(result.segmentCount)")
                }
                .width(min: 60, ideal: 70)

                TableColumn("Memory") { result in
                    Text(String(format: "%.1f MB", result.memoryMB))
                }
                .width(min: 70, ideal: 80)

                TableColumn("Text") { result in
                    Text(result.transcribedText.isEmpty ? "(empty)" : result.transcribedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 100, ideal: 200)
            }
            .frame(minHeight: 160)
        }
    }

    private func runBenchmark() {
        guard let path = selectedModelPath else { return }
        Task {
            _ = await runner.runBenchmark(modelPath: path, settings: settings)
        }
    }

    private func formatDuration(_ ms: Double) -> String {
        if ms < 1000 {
            return String(format: "%.0f ms", ms)
        } else {
            return String(format: "%.2f s", ms / 1000.0)
        }
    }
}

enum BenchmarkWindow {
    private static var windowController: NSWindowController?

    static func show() {
        if let existing = windowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speak Benchmark"
        window.center()
        window.contentView = NSHostingView(rootView: BenchmarkView())
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
