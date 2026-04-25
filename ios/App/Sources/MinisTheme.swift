import SwiftUI
import UIKit

enum MinisTheme {
    static let appBackgroundUIColor = UIColor(
        dynamicProvider: { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.05, green: 0.055, blue: 0.06, alpha: 1)
                : UIColor.white
        }
    )
    static let appBackground = Color(
        appBackgroundUIColor
    )
    static let panelBackground = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1)
                : UIColor.white
        }
    )
    static let elevatedBackground = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.12, green: 0.125, blue: 0.135, alpha: 1)
                : UIColor(red: 0.972, green: 0.972, blue: 0.964, alpha: 1)
        }
    )
    static let userBubble = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.19, green: 0.19, blue: 0.22, alpha: 1)
                : UIColor(red: 0.945, green: 0.945, blue: 0.940, alpha: 1)
        }
    )
    static let softPill = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.16, green: 0.165, blue: 0.18, alpha: 1)
                : UIColor(red: 0.963, green: 0.963, blue: 0.955, alpha: 1)
        }
    )
    static let subtleStroke = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.11)
                : UIColor.black.withAlphaComponent(0.055)
        }
    )
    static let strongStroke = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.18)
                : UIColor.black.withAlphaComponent(0.10)
        }
    )
    static let secondaryText = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.72, green: 0.72, blue: 0.75, alpha: 1)
                : UIColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1)
        }
    )
    static let modelDot = Color(red: 0.16, green: 0.77, blue: 0.39)
    static let accentBlue = Color(red: 0.10, green: 0.48, blue: 0.97)
    static let accentGreen = Color(red: 0.14, green: 0.74, blue: 0.41)
    static let accentOrange = Color(red: 0.96, green: 0.61, blue: 0.17)
    static let accentBlueUIColor = UIColor(red: 0.10, green: 0.48, blue: 0.97, alpha: 1)
    static let accentGreenUIColor = UIColor(red: 0.14, green: 0.74, blue: 0.41, alpha: 1)
    static let codeCard = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.045, blue: 0.05, alpha: 1)
                : UIColor(red: 0.055, green: 0.058, blue: 0.062, alpha: 1)
        }
    )
    static let codeViewport = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.98)
                : UIColor.black.withAlphaComponent(0.95)
        }
    )
    static let codeStroke = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.10)
                : UIColor.white.withAlphaComponent(0.07)
        }
    )
    static let codeText = UIColor(red: 0.33, green: 0.95, blue: 0.58, alpha: 1)
    static let codeSecondaryText = UIColor(red: 0.82, green: 0.87, blue: 0.83, alpha: 1)
    static let codeComment = UIColor(red: 0.58, green: 0.69, blue: 0.61, alpha: 1)
    static let assistantUIFont = UIFont.systemFont(ofSize: 17, weight: .medium)
    static let assistantStrongUIFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
    static let composerUIFont = UIFont.systemFont(ofSize: 17, weight: .regular)
    static let codeUIFont = UIFont.monospacedSystemFont(ofSize: 15.5, weight: .medium)
    static let sparklePrimaryColor = Color(red: 0.79, green: 0.74, blue: 0.58)
    static let sparkleSecondaryColor = Color(red: 0.84, green: 0.80, blue: 0.66)
    static let sparklePrimaryUIColor = UIColor(red: 0.79, green: 0.74, blue: 0.58, alpha: 1)
    static let sparkleSecondaryUIColor = UIColor(red: 0.84, green: 0.80, blue: 0.66, alpha: 1)
}

struct IEXASparkleMark: View {
    var primarySize: CGFloat = 18
    var secondarySize: CGFloat = 9.5
    var width: CGFloat = 26
    var height: CGFloat = 22
    var secondaryOffsetX: CGFloat = -5
    var secondaryOffsetY: CGFloat = -2

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "sparkles")
                .font(.system(size: primarySize, weight: .semibold))
                .foregroundStyle(MinisTheme.sparklePrimaryColor)

            Image(systemName: "sparkles")
                .font(.system(size: secondarySize, weight: .bold))
                .foregroundStyle(MinisTheme.sparkleSecondaryColor)
                .offset(x: secondaryOffsetX, y: secondaryOffsetY)
        }
        .frame(width: width, height: height)
    }
}
