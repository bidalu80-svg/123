import Foundation
import AVFoundation
import Speech

enum SpeechToTextError: LocalizedError {
    case speechAuthorizationDenied
    case microphoneAuthorizationDenied
    case recognizerUnavailable
    case recognizerNotReady
    case audioEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .speechAuthorizationDenied:
            return "请在系统设置里开启语音识别权限。"
        case .microphoneAuthorizationDenied:
            return "请在系统设置里开启麦克风权限。"
        case .recognizerUnavailable:
            return "当前设备不支持语音识别。"
        case .recognizerNotReady:
            return "语音识别服务暂不可用，请稍后再试。"
        case .audioEngineUnavailable:
            return "音频输入不可用。"
        }
    }
}

@MainActor
final class SpeechToTextService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""

    private let localeIdentifier: String
    private var speechRecognizer: SFSpeechRecognizer?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = localeIdentifier
        self.speechRecognizer = SpeechToTextService.makeRecognizer(localeIdentifier: localeIdentifier)
    }

    func startRecording() async throws {
        if isRecording {
            stopRecording()
        }

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw SpeechToTextError.speechAuthorizationDenied
        }

        let microphoneGranted = await requestMicrophoneAuthorization()
        guard microphoneGranted else {
            throw SpeechToTextError.microphoneAuthorizationDenied
        }

        guard let recognizer = speechRecognizer ?? SpeechToTextService.makeRecognizer(localeIdentifier: localeIdentifier) else {
            throw SpeechToTextError.recognizerUnavailable
        }
        speechRecognizer = recognizer

        guard recognizer.isAvailable else {
            throw SpeechToTextError.recognizerNotReady
        }

        transcript = ""
        try configureAudioSession()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        let format = outputFormat.sampleRate > 0 ? outputFormat : inputFormat
        guard format.sampleRate > 0 else {
            throw SpeechToTextError.audioEngineUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stopRecording(cancelTask: false)
                    }
                }

                if error != nil {
                    self.stopRecording(cancelTask: false)
                }
            }
        }
    }

    func stopRecording() {
        stopRecording(cancelTask: true)
    }

    func clearTranscript() {
        transcript = ""
    }

    private func stopRecording(cancelTask: Bool) {
        guard isRecording || recognitionTask != nil || recognitionRequest != nil else { return }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()

        recognitionRequest?.endAudio()
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func makeRecognizer(localeIdentifier: String) -> SFSpeechRecognizer? {
        let preferred = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        if preferred != nil {
            return preferred
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans-CN"))
            ?? SFSpeechRecognizer(locale: .current)
    }
}
