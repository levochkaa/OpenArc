// BrowserMobileDictation.swift

import AVFoundation
import Speech

/// Speech to text for the search field: the microphone streams into the
/// system's speech recognizer, which reports the words as they come.
@MainActor final class BrowserMobileDictation {
    // MARK: Internal

    /// The words heard so far, replacing the previous report.
    var onText: ((String) -> Void)?
    /// Listening started or stopped.
    var onListeningChange: ((Bool) -> Void)?

    private(set) var isListening = false

    // MARK: Private

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasTap = false
    /// Each start's number, so a late callback from an earlier one does nothing.
    private var generation = 0
    private var previousAudioSession: (
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
    )?

    // MARK: Private

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// The microphone's tap runs on the audio thread, so it is built outside
    /// the main actor.
    private nonisolated static func tap(
        feeding request: SFSpeechAudioBufferRecognitionRequest,
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func resultHandler(
        _ deliver: @escaping @MainActor @Sendable (String?, Bool) -> Void,
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isDone = result?.isFinal == true || error != nil
            Task { @MainActor in deliver(text, isDone) }
        }
    }

    // MARK: Internal

    /// Starts listening in `language` (a BCP 47 code, such as the keyboard's),
    /// or the device's language. Asks for the microphone and speech
    /// recognition the first time.
    func start(language: String?) {
        guard !isListening else { return }
        generation += 1
        let generation = generation
        isListening = true
        onListeningChange?(true)
        Task {
            let speech = await Self.speechAuthorization()
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard self.generation == generation, isListening else { return }
            guard speech == .authorized, microphone else {
                stop()
                return
            }
            begin(language: language, generation: generation)
        }
    }

    /// Stops listening; the words heard so far stay in the field.
    func stop() {
        guard isListening else { return }
        generation += 1
        isListening = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        restoreAudioSession()
        onListeningChange?(false)
    }

    private func begin(language: String?, generation: Int) {
        let recognizer = language.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            stop()
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On the device when it can, so the words never leave it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .search
        let session = AVAudioSession.sharedInstance()
        previousAudioSession = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                stop()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feeding: request))
            hasTap = true
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, done in
            guard let self, self.generation == generation, isListening else { return }
            if let text, !text.isEmpty { onText?(text) }
            if done { stop() }
        })
    }

    private func restoreAudioSession() {
        guard let previous = previousAudioSession else { return }
        previousAudioSession = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(previous.category, mode: previous.mode, options: previous.options)
    }
}
