import Foundation
import Speech
import AVFoundation

@MainActor final class SpeechCapture: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcript = ""
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var holding = false
    private var tapped = false
    private var generation = UUID()
    private var interruption: NSObjectProtocol?
    override init() {
        super.init()
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel() } }
    }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }
    private var onFinished: ((String) -> Void)?
    private var finalTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    func begin(onFinished: @escaping (String) -> Void) {
        guard !holding, !recording, request == nil else { return }
        feedbackTask?.cancel()
        generation = UUID(); let captureID = generation
        holding = true; error = nil; transcript = ""; self.onFinished = onFinished
        Task {
            let mic = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
            let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            guard holding, generation == captureID else { return }
            guard mic, speech == .authorized else { error = "Allow Microphone and Speech Recognition in Settings to speak to your agent."; holding = false; return }
            do { try startEngine() } catch { self.error = error.localizedDescription; cancel() }
        }
    }
    private func startEngine() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw DeviceError.message("Speech recognition is unavailable. Try again when connected to the internet.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device transcription when this language/device supports it.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw DeviceError.message("The microphone is unavailable.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; tapped = true
        let captureID = generation
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.request != nil, self.generation == captureID else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true { self.finish() }
                else if let error {
                    self.cancel()
                    let failure = error as NSError
                    if failure.domain == "kAFAssistantErrorDomain", failure.code == 1110 {
                        self.showNoSpeechFeedback()
                    } else { self.error = error.localizedDescription }
                }
            }
        }
        engine.prepare(); try engine.start(); recording = true
    }
    func end() {
        holding = false
        guard recording else { return }
        stopAudio(); request?.endAudio()
        finalTask = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); guard !Task.isCancelled else { return }; finish() }
    }
    func cancel() { generation = UUID(); holding = false; finalTask?.cancel(); stopAudio(); recognition?.cancel(); recognition = nil; request = nil; onFinished = nil }
    private func finish() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = onFinished
        cancel()
        if !text.isEmpty { completion?(text) } else { showNoSpeechFeedback() }
    }
    private func showNoSpeechFeedback() {
        feedbackTask?.cancel()
        let captureID = generation
        let message = "No speech was captured. Hold three fingers and try again."
        error = message
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.generation == captureID, self.error == message else { return }
            self.error = nil
        }
    }
    private func stopAudio() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
