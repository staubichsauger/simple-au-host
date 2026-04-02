import SwiftUI

@main
struct SimpleAUHostApp: App {
    @NSApplicationDelegateAdaptor(SimpleAUHostAppDelegate.self) private var appDelegate
    private let closeCoordinator = AppCloseCoordinator()

    init() {
        Thread.current.qualityOfService = .userInteractive
    }

    var body: some Scene {
        WindowGroup {
            HostModeRootView(closeCoordinator: closeCoordinator)
                .frame(minWidth: 1100, minHeight: 760)
                .background(MainWindowObserver(closeCoordinator: closeCoordinator))
                .task {
                    appDelegate.closeCoordinator = closeCoordinator
                }
        }
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.automatic)
    }
}

enum StudioTheme {
    static let backgroundTop = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let backgroundBottom = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let panelFill = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let panelSecondaryFill = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let panelStroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.55, green: 0.73, blue: 0.87)
    static let accentSoft = Color(red: 0.40, green: 0.58, blue: 0.72)
    static let warning = Color(red: 0.99, green: 0.66, blue: 0.12)
    static let danger = Color(red: 0.96, green: 0.38, blue: 0.33)
    static let mutedText = Color.white.opacity(0.50)
    static let strongText = Color.white.opacity(0.92)
}

struct StudioBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [StudioTheme.backgroundTop, StudioTheme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct StudioShell<Content: View, Toolbar: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let content: Content

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.toolbar = toolbar()
        self.content = content()
    }

    var body: some View {
        ZStack {
            StudioBackdrop()

            VStack(alignment: .leading, spacing: hasHeader ? 16 : 10) {
                if hasHeader {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(eyebrow.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .default))
                                .tracking(1.4)
                                .foregroundStyle(StudioTheme.accent)

                            Text(title)
                                .font(.system(size: 22, weight: .bold, design: .default))
                                .foregroundStyle(StudioTheme.strongText)

                            Text(subtitle)
                                .font(.system(size: 12, weight: .regular, design: .default))
                                .foregroundStyle(StudioTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                        toolbar
                    }
                }

                content
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }

    private var hasHeader: Bool {
        !eyebrow.isEmpty || !title.isEmpty || !subtitle.isEmpty
    }
}

struct StudioPanel<Content: View>: View {
    let title: String
    let subtitle: String?
    let compact: Bool
    @ViewBuilder let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.compact = compact
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            if !title.isEmpty || (subtitle?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .default))
                            .tracking(1.2)
                            .foregroundStyle(StudioTheme.accent)
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .regular, design: .default))
                            .foregroundStyle(StudioTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(compact ? 12 : 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StudioTheme.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StudioTheme.panelStroke, lineWidth: 1)
        )
    }
}

struct StudioBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium, design: .default))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct StudioMetricTile: View {
    let title: String
    let value: String
    let tint: Color

    init(_ title: String, value: String, tint: Color = .white) {
        self.title = title
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(1.0)
                .foregroundStyle(StudioTheme.mutedText)
            Text(value)
                .font(.system(size: 12, design: .monospaced).weight(.medium))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct StudioFieldLabel: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(StudioTheme.strongText)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular, design: .default))
                    .foregroundStyle(StudioTheme.mutedText)
            }
        }
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StudioTheme.accent)
            )
            .foregroundStyle(Color(red: 0.06, green: 0.08, blue: 0.10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct StudioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
            .foregroundStyle(StudioTheme.strongText)
    }
}

struct StudioDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StudioTheme.danger.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(StudioTheme.danger.opacity(0.24), lineWidth: 1)
            )
            .foregroundStyle(StudioTheme.danger)
    }
}
