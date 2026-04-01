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
    static let backgroundTop = Color(red: 0.09, green: 0.11, blue: 0.14)
    static let backgroundBottom = Color(red: 0.03, green: 0.04, blue: 0.06)
    static let panelFill = Color(red: 0.10, green: 0.12, blue: 0.15)
    static let panelSecondaryFill = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let panelStroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.80, green: 0.96, blue: 0.32)
    static let accentSoft = Color(red: 0.53, green: 0.76, blue: 0.20)
    static let warning = Color(red: 0.99, green: 0.66, blue: 0.12)
    static let danger = Color(red: 0.96, green: 0.38, blue: 0.33)
    static let mutedText = Color.white.opacity(0.62)
    static let strongText = Color.white.opacity(0.96)
}

struct StudioBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [StudioTheme.backgroundTop, StudioTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(StudioTheme.accent.opacity(0.14))
                .frame(width: 520, height: 520)
                .blur(radius: 70)
                .offset(x: 360, y: -260)

            RoundedRectangle(cornerRadius: 160, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .frame(width: 920, height: 220)
                .rotationEffect(.degrees(-10))
                .offset(x: -220, y: 240)
                .blur(radius: 2)
        }
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

            VStack(alignment: .leading, spacing: hasHeader ? 24 : 14) {
                if hasHeader {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(eyebrow.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(2)
                                .foregroundStyle(StudioTheme.accent)

                            Text(title)
                                .font(.system(size: 34, weight: .black, design: .rounded))
                                .foregroundStyle(StudioTheme.strongText)

                            Text(subtitle)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(StudioTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                        toolbar
                    }
                }

                content
            }
            .padding(28)
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
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            if !title.isEmpty || (subtitle?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 6) {
                    if !title.isEmpty {
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(StudioTheme.accent)
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(StudioTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(compact ? 16 : 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [StudioTheme.panelSecondaryFill, StudioTheme.panelFill],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(StudioTheme.panelStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 24, y: 12)
    }
}

struct StudioBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(tint.opacity(0.16), in: Capsule())
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(StudioTheme.mutedText)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(StudioTheme.strongText)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StudioTheme.mutedText)
            }
        }
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [StudioTheme.accent, StudioTheme.accentSoft],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .foregroundStyle(Color.black.opacity(0.84))
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct StudioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .foregroundStyle(StudioTheme.strongText)
    }
}

struct StudioDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(StudioTheme.danger.opacity(configuration.isPressed ? 0.18 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(StudioTheme.danger.opacity(0.28), lineWidth: 1)
            )
            .foregroundStyle(StudioTheme.danger)
    }
}
