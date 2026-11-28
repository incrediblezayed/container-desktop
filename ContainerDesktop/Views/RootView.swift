import ContainerKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .locating:
                ProgressView("Looking for Apple's container runtime…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .cliMissing:
                InstallCLIView()
            case .systemStopped, .startingSystem:
                SystemStoppedView()
            case .ready:
                MainSplitView()
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $model.isRunSheetPresented) {
            RunContainerSheet(prefillImage: model.runSheetPrefillImage)
                .environment(model)
                .onDisappear { model.runSheetPrefillImage = nil }
        }
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                ForEach(Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            switch model.section {
            case .containers: ContainersView()
            case .images: ImagesView()
            case .volumes: VolumesView()
            case .networks: NetworksView()
            case .system: SystemView()
            case .agents: AgentsView()
            }
        }
    }

    private func badge(for section: Section) -> Int {
        switch section {
        case .containers: model.runningCount
        default: 0
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Runtime \(model.status?.serverVersion ?? "running")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Onboarding

struct InstallCLIView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Install Apple's container tool")
                .font(.title2.bold())
            Text("Container Desktop is a graphical front end for Apple's open-source `container` runtime, which runs each Linux container in its own lightweight virtual machine. Install the signed package from GitHub, then come back here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            HStack {
                Button("Download from GitHub") {
                    openURL(URL(string: "https://github.com/apple/container/releases/latest")!)
                }
                .buttonStyle(.borderedProminent)
                Button("Check Again") { Task { await model.bootstrap() } }
            }
            Text("Already installed somewhere else? Set its path in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SystemStoppedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: model.phase == .startingSystem ? "gearshape.2" : "power")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: model.phase == .startingSystem)
            Text(model.phase == .startingSystem ? "Starting the container system…" : "The container system isn't running")
                .font(.title2.bold())
            Text(model.phase == .startingSystem
                 ? "The first start can take a minute while the Linux kernel downloads."
                 : "Start it to manage containers. This runs `container system start`.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.phase == .startingSystem {
                ProgressView().controlSize(.small)
            } else {
                Button("Start Container System") { Task { await model.startSystem() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
