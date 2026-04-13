import Foundation
import AudioToolbox

enum SoundEffectPlayer {
    // Soft "sent" tick
    private static let sendSoundID: SystemSoundID = 1104
    // Reply-complete subtle pop
    private static let replyCompleteSoundID: SystemSoundID = 1004

    static func playSend() {
        AudioServicesPlaySystemSound(sendSoundID)
    }

    static func playReplyComplete() {
        AudioServicesPlaySystemSound(replyCompleteSoundID)
    }
}
