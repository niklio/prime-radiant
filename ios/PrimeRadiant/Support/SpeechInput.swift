import AVFoundation
import Foundation
import Observation
import Speech

/// Voice input for the pill (handoff §2.3): SFSpeechRecognizer with on-device
/// recognition when available, server fallback with the standard permission
/// strings. The live transcript renders above the pill and stays editable
/// before send.
@MainActor
@Observable
final class SpeechInput {

    enum State: Equatable {
        case idle
        case denied
        case listening
    }

    private(set) var state: State = .idle
    /// Live transcript; the pill binds to this so the user can edit before send.
    var transcript = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    #if DEBUG
        /// `-PRDebugVoice` capture state: present the listening surface with a
        /// fixed in-progress transcript, no mic or speech engine. Stopping goes
        /// through the normal `stop()` path (audio engine is idle; harmless).
        func debugFakeListening(transcript: String) {
            self.transcript = transcript
            state = .listening
        }
    #endif

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard state != .listening else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.state = .denied
                    return
                }
                self.beginRecognition()
            }
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        state = .idle
    }

    private func beginRecognition() {
        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            state = .denied
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = true
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            return
        }

        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }
}
