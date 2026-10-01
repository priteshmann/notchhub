import AppKit
import SwiftUI

enum Palette {
    static let focus = Color(red: 1.0, green: 0x6B / 255.0, blue: 0x4A / 255.0)        // #FF6B4A
    static let green = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0) // #34C759
    static let blue = Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 1.0)           // #0A84FF
    static let orange = Color(red: 1.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)        // #FF9F0A
    static let red = Color(red: 1.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)           // #FF453A
    static let dim = Color.white.opacity(0.55)

    static func color(_ tint: TransientTint) -> Color {
        switch tint {
        case .white: return .white
        case .green: return green
        case .orange: return orange
        case .red: return red
        case .blue: return blue
        }
    }
}

struct ProgressBar: View {
    var progress: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(color)
                    .frame(width: max(0, geo.size.width * min(1, max(0, progress))))
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(prominent ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? fill : fill.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Plain SF Symbol button with a fixed tap target.
struct IconButton: View {
    var systemImage: String
    var size: CGFloat = 13
    var tint: Color = .white.opacity(0.8)
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(tint)
                .frame(width: max(20, size + 10), height: max(20, size + 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Inline message shown when a permission is missing. Never a crash, never a modal.
struct PermissionNotice: View {
    var systemImage: String
    var message: String
    var buttonTitle: String = "Allow in System Settings"
    var settingsURL: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundColor(Palette.dim)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle) {
                if let action {
                    action()
                } else if let settingsURL, let url = URL(string: settingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(PillButtonStyle(fill: .white, prominent: false))
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum SystemSettingsURL {
    static let automation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    static let calendars = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    static let camera = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
}

/// The collapsed overlay for a transient: icon (optionally an animated fill) left, text right.
/// Both halves slide out from behind the notch.
struct TransientBar: View {
    var transient: Transient
    var wingWidth: CGFloat

    var body: some View {
        let tint = Palette.color(transient.tint)
        WingsBar(wingWidth: wingWidth) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if let fill = transient.fill {
                    BatteryFillIcon(level: fill, color: tint)
                } else {
                    Image(systemName: transient.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(tint)
                }
            }
            .padding(.trailing, 10)
            .id(transient.id)
            .transition(.asymmetric(insertion: .offset(x: 40).combined(with: .opacity), removal: .opacity))
        } right: {
            HStack {
                Text(transient.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .id(transient.id)
            .transition(.asymmetric(insertion: .offset(x: -40).combined(with: .opacity), removal: .opacity))
        }
    }
}

/// Battery outline whose fill sweeps up to `level` (loops while shown).
struct BatteryFillIcon: View {
    var level: Double
    var color: Color

    var body: some View {
        PhaseAnimator([0.0, 1.0]) { phase in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    .frame(width: 24, height: 12)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: max(1, 20 * min(1, max(0, level)) * (0.25 + 0.75 * phase)), height: 8)
                    .padding(.leading, 2)
            }
        } animation: { phase in
            phase == 1 ? .easeOut(duration: 0.9) : .linear(duration: 0.01)
        }
    }
}
