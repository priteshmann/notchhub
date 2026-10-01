import SwiftUI

struct NotchRootView: View {
    @ObservedObject var hub: HubStore
    var openSettings: () -> Void

    private static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)

    private var bottomRadius: CGFloat {
        if hub.expanded { return 24 }
        return hub.isIdle ? 10 : 12
    }

    var body: some View {
        let size = hub.shapeSize
        let content = hub.contentSize
        let shape = NotchShape(fillet: hub.fillet, bottomRadius: bottomRadius)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            shape.fill(hub.flashColor.opacity(hub.flashOn ? 0.55 : 0))
            VStack(spacing: 0) {
                topRow(width: content.width)
                    .frame(width: content.width, height: hub.notchHeight)
                if hub.expanded {
                    TabStrip(hub: hub)
                        .frame(width: content.width, height: HubStore.tabStripHeight)
                        .transition(.opacity)
                    expandedBody
                        .frame(width: content.width, height: hub.bodyHeight, alignment: .top)
                        .transition(.opacity)
                }
            }
            .frame(width: content.width)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .overlay {
            if !hub.expanded {
                // Click the collapsed notch to expand (hover does too).
                Color.clear
                    .contentShape(shape)
                    .onTapGesture { hub.requestExpand() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .environment(\.notchWidth, hub.notchWidth)
        .animation(Self.spring, value: hub.expanded)
        .animation(Self.spring, value: size)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hub.transient?.id)
    }

    @ViewBuilder
    private func topRow(width: CGFloat) -> some View {
        if hub.expanded {
            HeaderStrip(hub: hub, wingWidth: max(0, (width - hub.notchWidth) / 2), openSettings: openSettings)
        } else {
            switch hub.collapsed {
            case .idle:
                Color.clear
            case .transient(let t):
                TransientBar(transient: t, wingWidth: HubStore.transientWingWidth)
            case .module(let m):
                (m.collapsedView ?? AnyView(Color.clear))
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let module = hub.selectedModule {
            module.expandedView
                .id(module.id)
        } else {
            Text("Turn a module on in Settings.")
                .font(.system(size: 12))
                .foregroundColor(Palette.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The notch row while expanded: left-wing items | notch | right-wing items + gear.
struct HeaderStrip: View {
    @ObservedObject var hub: HubStore
    var wingWidth: CGFloat
    var openSettings: () -> Void

    var body: some View {
        let headers = hub.headerModules
        WingsBar(wingWidth: wingWidth) {
            HStack(spacing: 8) {
                ForEach(headers.filter { $0.headerPlacement == .left }.map(\.id), id: \.self) { id in
                    hub.module(id)?.headerView
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
        } right: {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(headers.filter { $0.headerPlacement == .right }.map(\.id), id: \.self) { id in
                    hub.module(id)?.headerView
                }
                IconButton(systemImage: "gearshape.fill", size: 12, tint: .white.opacity(0.7),
                           help: "Settings", action: openSettings)
            }
            .padding(.trailing, 12)
        }
    }
}

/// Tab icons (20 pt tap targets) + tab-row header items (the next calendar event).
struct TabStrip: View {
    @ObservedObject var hub: HubStore

    var body: some View {
        let selected = hub.selectedModule?.id
        HStack(spacing: 4) {
            ForEach(hub.visibleTabs.map(\.id), id: \.self) { id in
                if let module = hub.module(id) {
                    Button {
                        hub.select(id)
                    } label: {
                        Image(systemName: module.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(id == selected ? .black : .white.opacity(0.75))
                            .frame(width: 28, height: 22)
                            .background(Capsule().fill(id == selected ? Color.white : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(module.title)
                }
            }
            Spacer(minLength: 4)
            ForEach(hub.headerModules.filter { $0.headerPlacement == .tabRow }.map(\.id), id: \.self) { id in
                hub.module(id)?.headerView
            }
        }
        .padding(.horizontal, 14)
    }
}
