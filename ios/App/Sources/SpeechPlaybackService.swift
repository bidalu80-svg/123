import Foundation
import AVFoundation
import Combine

@MainActor
final class SpeechPlaybackService: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private struct VoiceStyle {
        let rate: Float
        let pitchMultiplier: Float
        let volume: Float
        let preUtteranceDelay: TimeInterval
        let postUtteranceDelay: TimeInterval
    }

    static let shared = SpeechPlaybackService()

    @Published private(set) var isSpeaking = false
    @Published private(set) var activeMessageID: UUID?
    var voicePreset: ReplySpeechVoicePreset = .systemNatural

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

        let style = preferredVoiceStyle(for: text, preset: voicePreset)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = style.rate
        utterance.pitchMultiplier = style.pitchMultiplier
        utterance.volume = style.volume
        utterance.preUtteranceDelay = style.preUtteranceDelay
        utterance.postUtteranceDelay = style.postUtteranceDelay
        utterance.voice = preferredVoice(for: text, preset: voicePreset)
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

    private func preferredVoice(for text: String, preset: ReplySpeechVoicePreset) -> AVSpeechSynthesisVoice? {
        let availableVoices = AVSpeechSynthesisVoice.speechVoices()
        if containsChinese(text) {
            let preferred = availableVoices
                .filter { voice in
                    let language = voice.language.lowercased()
                    return language.hasPrefix("zh-cn")
                        || language.contains("hans")
                        || language.hasPrefix("zh")
                }
                .sorted { lhs, rhs in
                    voiceScore(lhs, prefersChinese: true, preset: preset) > voiceScore(rhs, prefersChinese: true, preset: preset)
                }
                .first
            return preferred
                ?? AVSpeechSynthesisVoice(language: "zh-CN")
                ?? AVSpeechSynthesisVoice(language: "zh-Hans")
                ?? AVSpeechSynthesisVoice(language: "zh-TW")
        }
        let preferred = availableVoices
            .filter { $0.language.lowercased().hasPrefix("en") }
            .sorted { lhs, rhs in
                voiceScore(lhs, prefersChinese: false, preset: preset) > voiceScore(rhs, prefersChinese: false, preset: preset)
            }
            .first
        return preferred
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    private func preferredVoiceStyle(for text: String, preset: ReplySpeechVoicePreset) -> VoiceStyle {
        let isChinese = containsChinese(text)
        switch preset {
        case .systemNatural:
            return isChinese
                ? VoiceStyle(rate: 0.47, pitchMultiplier: 1.08, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.04)
                : VoiceStyle(rate: 0.49, pitchMultiplier: 1.03, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.03)
        case .livelyFemale:
            return isChinese
                ? VoiceStyle(rate: 0.49, pitchMultiplier: 1.16, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.03)
                : VoiceStyle(rate: 0.51, pitchMultiplier: 1.12, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.02)
        case .warmNarrator:
            return isChinese
                ? VoiceStyle(rate: 0.43, pitchMultiplier: 0.96, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.05)
                : VoiceStyle(rate: 0.45, pitchMultiplier: 0.95, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.04)
        case .doubaoLike:
            return isChinese
                ? VoiceStyle(rate: 0.50, pitchMultiplier: 1.14, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.02)
                : VoiceStyle(rate: 0.50, pitchMultiplier: 1.08, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.02)
        case .xiaoduLike:
            return isChinese
                ? VoiceStyle(rate: 0.48, pitchMultiplier: 1.04, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.02)
                : VoiceStyle(rate: 0.48, pitchMultiplier: 1.0, volume: 1.0, preUtteranceDelay: 0, postUtteranceDelay: 0.02)
        }
    }

    private func voiceScore(_ voice: AVSpeechSynthesisVoice, prefersChinese: Bool, preset: ReplySpeechVoicePreset) -> Int {
        let language = voice.language.lowercased()
        let name = voice.name.lowercased()
        let identifier = voice.identifier.lowercased()
        var score = 0

        if prefersChinese {
            if language.hasPrefix("zh-cn") { score += 120 }
            if language.contains("hans") { score += 80 }
            if language.hasPrefix("zh") { score += 40 }
            if name.contains("siri") || identifier.contains("siri") { score += 60 }
            if name.contains("tingting") || name.contains("meijia") || name.contains("xiaoxiao") { score += 24 }
        } else {
            if language.hasPrefix("en-us") { score += 120 }
            if language.hasPrefix("en") { score += 40 }
            if name.contains("siri") || identifier.contains("siri") { score += 60 }
            if name.contains("ava") || name.contains("samantha") || name.contains("allison") { score += 24 }
        }

        if identifier.contains("premium") { score += 30 }
        if identifier.contains("enhanced") { score += 20 }

        switch preset {
        case .systemNatural:
            break
        case .livelyFemale, .doubaoLike:
            if name.contains("tingting") || name.contains("siri") || name.contains("xiaoxiao") || name.contains("mei") {
                score += 36
            }
        case .warmNarrator:
            if name.contains("sin-ji") || name.contains("yating") || name.contains("alex") || name.contains("daniel") {
                score += 28
            }
        case .xiaoduLike:
            if name.contains("tingting") || name.contains("siri") || name.contains("yating") || name.contains("xiaobei") {
                score += 24
            }
        }
        return score
    }

    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
