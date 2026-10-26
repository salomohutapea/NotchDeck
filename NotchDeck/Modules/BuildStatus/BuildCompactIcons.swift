import SwiftUI

enum BuildPlatform: String, CaseIterable {
    case android, ios, other

    var rank: Int {
        switch self { case .android: return 30; case .ios: return 31; case .other: return 32 }
    }
}

extension BuildRecord {
    /// Android for Gradle, iOS for Xcode; command-line builds are guessed from their command / folder.
    var platform: BuildPlatform {
        switch source {
        case .gradle: return .android
        case .xcode: return .ios
        case .cli:
            let text = (title + " " + (cwd ?? "")).lowercased()
            if text.contains("gradle") || text.contains("android") || text.contains("adb ") { return .android }
            if text.contains("xcodebuild") || text.contains("xcode") || text.contains("pod ")
                || text.range(of: "\\bios\\b", options: .regularExpression) != nil { return .ios }
            return .other
        }
    }
}

/// Collapsed-notch build icon: platform logo, spinning ring while building, ✓ / ✗ badge afterwards.
struct BuildPlatformIcon: View {
    let platform: BuildPlatform
    let status: BuildStatus
    var progress: Double?

    private var logoTint: Color {
        switch platform {
        case .android: return Color(red: 0.24, green: 0.86, blue: 0.52)
        case .ios: return .white
        case .other: return Color(red: 1.0, green: 0.62, blue: 0.25)
        }
    }

    var body: some View {
        ZStack {
            logo.frame(width: 13, height: 13).foregroundStyle(logoTint)
            if status == .running {
                if let p = progress {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.6)
                        Circle().trim(from: 0, to: max(0.03, p))
                            .stroke(Color(red: 1.0, green: 0.62, blue: 0.25), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20, height: 20)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                        Circle().trim(from: 0, to: 0.3)
                            .stroke(Color(red: 1.0, green: 0.62, blue: 0.25), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * 360))
                    }
                    .frame(width: 20, height: 20)
                }
            }
        }
        .frame(width: CompactItem.iconSize, height: CompactItem.iconSize)
        .overlay(alignment: .bottomTrailing) {
            if status != .running {
                Image(systemName: status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(status == .failed ? NotchTheme.danger : NotchTheme.success, .black)
                    .background(Circle().fill(Color.black).frame(width: 8, height: 8))
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        switch platform {
        case .android: Image("AndroidLogo").resizable().scaledToFit()
        case .ios: Image("AppleLogo").resizable().scaledToFit()
        case .other: Image(systemName: "hammer.fill").resizable().scaledToFit()
        }
    }
}
