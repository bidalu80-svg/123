import Foundation
import AVFoundation
import Combine

@MainActor
final class SpeechPlaybackService: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    static let shared = SpeechPlaybackService()

    @Published private(set) var isSpeaking = false
    @Published private(set) var activeMessageID: UUID?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeGeneration = 0
    private var utteranceGenerations: [ObjectIdentifier: Int] = [:]

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func speak(message: ChatMessage) -> Bool {
        let text = Self.speakableText(from: message)
        return speak(text, messageID: message.id)
    }

    @discardableResult
    func speak(_ raw: String, messageID: UUID? = nil) -> Bool {
        let text = Self.normalizedSpeechText(from: raw)
        guard !text.isEmpty else { return false }

        activeGeneration += 1
        let generation = activeGeneration

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            deactivateAudioSession()
        }

        configureAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = preferredVoice(for: text)
        utteranceGenerations[ObjectIdentifier(utterance)] = generation
        activeMessageID = messageID
        isSpeaking = true
        synthesizer.speak(utterance)
        return true
    }

    @discardableResult
    func togglePlayback(for message: ChatMessage) -> Bool {
        if isPlaying(messageID: message.id) {
            stop(messageID: message.id)
            return true
        }
        return speak(message: message)
    }

    func stop(messageID: UUID? = nil) {
        guard messageID == nil || activeMessageID == messageID else { return }
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            resetPlaybackState()
        }
    }

    func isPlaying(messageID: UUID) -> Bool {
        activeMessageID == messageID && isSpeaking
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        completePlayback(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        completePlayback(for: utterance)
    }

    static func speakableText(from message: ChatMessage) -> String {
        var normalizedMessage = message
        normalizedMessage.isStreaming = false

        let segments = MessageContentParser.parse(normalizedMessage)
        var parts: [String] = []

        func appendPart(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if parts.last != trimmed {
                parts.append(trimmed)
            }
        }

        for segment in segments {
            switch segment {
            case .text(let text):
                appendPart(text)
            case .table(let headers, let rows):
                if headers.isEmpty {
                    appendPart("表格内容。")
                } else {
                    appendPart("表格内容，列为 \(headers.joined(separator: "、"))。")
                }
                if !rows.isEmpty {
                    appendPart("共 \(rows.count) 行。")
                }
            case .code, .file:
                appendPart("代码片段。")
            case .image:
                appendPart("图片。")
            case .video:
                appendPart("视频。")
            case .divider:
                appendPart("下一部分。")
            }
        }

        if parts.isEmpty {
            return normalizedSpeechText(from: message.copyableText)
        }
        return normalizedSpeechText(from: parts.joined(separator: "\n"))
    }

    static func normalizedSpeechText(from raw: String, limit: Int = 1_600) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "(?s)```.*?```", with: " 代码片段 ", options: .regularExpression)
            .replacingOccurrences(
                of: #"\[\[file:[^\]]+\]\]([\s\S]*?)\[\[endfile\]\]"#,
                with: " 代码文件 ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\[\[file:[^\]]+\]\]"#,
                with: " 代码文件 ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\[\[endfile\]\]"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"(?m)^\[FILE:[^\n]+\]\s*$"#,
                with: "代码文件",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: " 链接 ", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "" }
        return String(cleaned.prefix(limit))
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func completePlayback(for utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        let generation = utteranceGenerations.removeValue(forKey: identifier)
        guard generation == activeGeneration else { return }
        resetPlaybackState()
    }

    private func resetPlaybackState() {
        isSpeaking = false
        activeMessageID = nil
        deactivateAudioSession()
    }

    private func preferredVoice(for text: String) -> AVSpeechSynthesisVoice? {
        if containsChinese(text) {
            return AVSpeechSynthesisVoice(language: "zh-CN")
                ?? AVSpeechSynthesisVoice(language: "zh-Hans")
                ?? AVSpeechSynthesisVoice(language: "zh-TW")
        }
        return AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
