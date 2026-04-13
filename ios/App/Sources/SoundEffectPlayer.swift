import Foundation
import AudioToolbox
import UIKit

enum SoundEffectPlayer {
    // Telegram-like quick send tick fallback
    private static let sendSoundID: SystemSoundID = 1104
    // Reply-complete subtle pop
    private static let replyCompleteSoundID: SystemSoundID = 1004
    private static var customSendSoundID: SystemSoundID?
    private static var customSendSoundLoaded = false

    static func playSend() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let custom = loadCustomSendSoundIfNeeded() {
            AudioServicesPlaySystemSound(custom)
        } else {
            AudioServicesPlaySystemSound(sendSoundID)
        }
    }

    static func playReplyComplete() {
        AudioServicesPlaySystemSound(replyCompleteSoundID)
    }

    private static func loadCustomSendSoundIfNeeded() -> SystemSoundID? {
        if customSendSoundLoaded {
            return customSendSoundID
        }
        customSendSoundLoaded = true

        let url = Bundle.main.url(forResource: "telegram_send", withExtension: "wav")
            ?? Bundle.main.url(forResource: "telegram_send", withExtension: "caf")
        guard let url else {
            return nil
        }

        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            return nil
        }
        customSendSoundID = soundID
        return soundID
    }
}
