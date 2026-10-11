import SwiftData
import SwiftUI

@main
struct TimestampCameraWorkPhotosApp: App {
    @State private var environment: AppEnvironment?

    /// Unit tests run inside this app; they build their own isolated environments.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isRunningTests {
                    Color.clear
                } else if let environment {
                    RootView()
                        .environment(environment)
                } else {
                    Color(.systemBackground)
                        .onAppear {
                            let created = AppEnvironment()
                            created.launch()
                            #if DEBUG
                            DebugSeeding.apply(to: created)
                            #endif
                            environment = created
                        }
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    /// Interface language chosen in Settings ("" = iPhone language). Changing it rebuilds the UI at
    /// once (strings are read when views are built); the selected tab is kept by the router.
    @AppStorage(InterfaceLanguage.defaultsKey) private var interfaceLanguage = ""

    var body: some View {
        Group {
            if let error = env.startupError {
                StartupErrorView(error: error)
            } else if let container = env.container {
                MainTabsView()
                    .modelContainer(container)
            }
        }
        .id(interfaceLanguage)
        .environment(\.locale, AppLanguage.current.formattingLocale)
    }
}

struct MainTabsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @Query(filter: #Predicate<AppPreferences> { $0.key == "main" }) private var preferences: [AppPreferences]

    var body: some View {
        @Bindable var router = env.router
        TabView(selection: $router.tab) {
            CameraScreen(isActive: router.tab == .camera && scenePhase == .active && onboardingCompleted)
                .tabItem { Label(L("tab.camera"), systemImage: "camera") }
                .tag(AppRouter.Tab.camera)
            ProjectsTab()
                .tabItem { Label(L("tab.projects"), systemImage: "folder") }
                .tag(AppRouter.Tab.projects)
            SettingsTab()
                .tabItem { Label(L("tab.settings"), systemImage: "gearshape") }
                .tag(AppRouter.Tab.settings)
        }
        .preferredColorScheme(colorScheme)
        .fullScreenCover(isPresented: Binding(get: { !onboardingCompleted }, set: { _ in })) {
            OnboardingView {
                onboardingCompleted = true
                env.analytics.track(.onboardingCompleted)
            }
            .preferredColorScheme(colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await env.entitlements.refreshEntitlements() }
            } else if phase == .background {
                env.location.setCameraActive(false)
            }
        }
        .onChange(of: env.entitlements.isPro) { _, _ in env.persistFreeSelection() }
        .task {
            await env.entitlements.waitUntilDetermined()
            env.persistFreeSelection()
        }
    }

    private var colorScheme: ColorScheme? {
        switch preferences.first?.theme ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct StartupErrorView: View {
    let error: AppError

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(Theme.destructive)
            Text(L("startup.error.title"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(error.displayMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.secondary)
            Text(L("startup.error.dataKept"))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.secondary)
            if let email = EnvironmentConfig.current.supportEmail {
                Button(L("support.copyEmail")) { UIPasteboard.general.string = email }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}
