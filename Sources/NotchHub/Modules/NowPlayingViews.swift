import AppKit
import SwiftUI

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45))
                        .foregroundColor(Palette.dim)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

/// Three bars; animates only while playing (the timeline is paused otherwise).
struct VisualizerBars: View {
    var playing: Bool
    var color: Color = Palette.green

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * (5.0 + Double(i) * 1.7) + Double(i) * 1.3
                    let h = playing ? 4 + 8 * abs(sin(phase)) : 3
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: h)
                }
            }
            .frame(height: 14)
        }
    }
}

struct NowPlayingCollapsedView: View {
    @ObservedObject var module: NowPlayingModule

    var body: some View {
        WingsBar(wingWidth: module.collapsedWingWidth) {
            ArtworkView(image: module.artwork, size: 18, corner: 4)
        } right: {
            VisualizerBars(playing: module.track?.isPlaying == true)
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var module: NowPlayingModule

    var body: some View {
        switch module.status {
        case .noPlayer:
            message("Spotify or Music isn't running.", icon: "music.note")
        case .needsConsent:
            PermissionNotice(systemImage: "music.note",
                             message: "Now Playing asks macOS for permission to control Spotify / Music.",
                             buttonTitle: "Connect") { module.connect() }
        case .denied(let player):
            PermissionNotice(systemImage: "lock.fill",
                             message: "NotchHub isn't allowed to control \(player.appName). Turn it on under Privacy & Security › Automation.",
                             settingsURL: SystemSettingsURL.automation)
        case .ready:
            if let track = module.track {
                player(track)
            } else {
                message("Nothing playing.", icon: "music.note")
            }
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            Text(text).font(.system(size: 12))
        }
        .foregroundColor(Palette.dim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func player(_ track: TrackState) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(image: module.artwork, size: 72, corner: 10)
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.dim)
                        .lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Scrubber(module: module, duration: track.duration,
                             position: module.position(at: context.date))
                }
                HStack(spacing: 12) {
                    IconButton(systemImage: "backward.fill", size: 13, help: "Previous") { module.previous() }
                    IconButton(systemImage: track.isPlaying ? "pause.fill" : "play.fill", size: 17,
                               tint: .white, help: "Play / pause") { module.playPause() }
                    IconButton(systemImage: "forward.fill", size: 13, help: "Next") { module.next() }
                    Spacer(minLength: 6)
                    Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundColor(Palette.dim)
                    Slider(value: Binding(get: { module.scrubVolume ?? track.volume },
                                          set: { module.scrubVolume = $0 }),
                           in: 0...100) { editing in
                        if !editing, let v = module.scrubVolume {
                            module.setVolume(v)
                            module.scrubVolume = nil
                        }
                    }
                    .controlSize(.mini)
                    .frame(width: 80)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct Scrubber: View {
    @ObservedObject var module: NowPlayingModule
    var duration: Double
    var position: Double

    private static func format(_ s: Double) -> String {
        let total = max(0, Int(s))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        let shown = module.scrubPosition ?? position
        HStack(spacing: 6) {
            Text(Self.format(shown))
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(Palette.dim)
                .frame(width: 30, alignment: .trailing)
            Slider(value: Binding(get: { shown }, set: { module.scrubPosition = $0 }),
                   in: 0...max(1, duration)) { editing in
                if !editing, let p = module.scrubPosition {
                    module.seek(to: p)
                    module.scrubPosition = nil
                }
            }
            .controlSize(.mini)
            .disabled(duration <= 0)
            Text(Self.format(duration))
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(Palette.dim)
                .frame(width: 30, alignment: .leading)
        }
    }
}

struct NowPlayingSettingsView: View {
    @ObservedObject var module: NowPlayingModule

    var body: some View {
        Picker("Player", selection: $module.settings.preference) {
            ForEach(NowPlayingModule.Preference.allCases, id: \.self) { p in
                Text(p.label).tag(p)
            }
        }
        Text("Uses AppleScript (Automation permission, asked the first time you open the tab). NotchHub never launches Spotify or Music.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
