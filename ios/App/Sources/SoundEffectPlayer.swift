import Foundation
import AudioToolbox
import UIKit

enum SoundEffectPlayer {
    // Reply-complete subtle pop
    private static let replyCompleteSoundID: SystemSoundID = 1004

    static func playSend() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Keep send and reply-complete sound consistent.
        AudioServicesPlaySystemSound(replyCompleteSoundID)
    }

    static func playReplyComplete() {
        AudioServicesPlaySystemSound(replyCompleteSoundID)
    }
}
