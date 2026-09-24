import SwiftUI
import AppKit
import AutoVolumeShared

struct SettingsView: View {
    let viewModel: AppViewModel
    let updateService: UpdateService

    @State private var logLevel: LogLevel
    @State private var openFinderAfterMount: Bool
    @State private var autoMountNTFSReadWrite: Bool

    init(viewModel: AppViewModel, updateService: UpdateService) {
        self.viewModel = viewModel
        self.updateService = updateService
        _logLevel = State(initialValue: viewModel.settings.logLevel)
        _openFinderAfterMount = State(initialValue: viewModel.settings.openFinderAfterMount)
        _autoMountNTFSReadWrite = State(initialValue: viewModel.settings.autoMountNTFSReadWrite)
    }

    /// A direct binding onto `viewModel.language` rather than local `@State`. `viewModel.language`'s
    /// setter reverts both `L10n` and `settings` if persisting fails (see `AppViewModel.language`);
    /// a local `@State` seeded once at `init` would keep showing the unsaved selection after such a
    /// revert, since nothing would write the reverted value back into it. Binding straight to the
    /// view model means the Picker always reflects whatever `viewModel.settings.language` actually
    /// is, including after a revert.
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { viewModel.language },
            set: { viewModel.language = $0 }
        )
    }

    var body: some View {
        let _ = viewModel.languageRevision
        TabView {
            generalTab
                .tabItem { Text(L10n.t(.settingsTabGeneral)) }
            ntfsTab
                .tabItem { Text(L10n.t(.settingsTabNTFS)) }
            AboutTabView(viewModel: viewModel, updateService: updateService)
                .tabItem { Text(L10n.t(.settingsTabAbout)) }
        }
        .frame(width: 480, height: 420)
        .onChange(of: logLevel) { _, newValue in
            viewModel.updateSettings(viewModel.settings.updating(logLevel: newValue))
        }
        .onChange(of: openFinderAfterMount) { _, newValue in
            viewModel.updateSettings(viewModel.settings.updating(openFinderAfterMount: newValue))
        }
        .onChange(of: autoMountNTFSReadWrite) { _, newValue in
            viewModel.updateSettings(viewModel.settings.updating(autoMountNTFSReadWrite: newValue))
        }
    }

    private var generalTab: some View {
        Form {
            Section(L10n.t(.settingsLanguage)) {
                Picker(L10n.t(.settingsLanguage), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
            }

            Section(L10n.t(.settingsSectionLogging)) {
                Picker(L10n.t(.settingsLogLevel), selection: $logLevel) {
                    Text(L10n.t(.settingsLogLevelAll)).tag(LogLevel.info)
                    Text(L10n.t(.settingsLogLevelWarning)).tag(LogLevel.warning)
                    Text(L10n.t(.settingsLogLevelError)).tag(LogLevel.error)
                }
                Text(L10n.t(.settingsLogLevelHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t(.settingsSectionMounting)) {
                Toggle(L10n.t(.settingsOpenFinderAfterMount), isOn: $openFinderAfterMount)
                Text(L10n.t(.settingsOpenFinderAfterMountHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var ntfsTab: some View {
        Form {
            Section(L10n.t(.settingsSectionNTFS)) {
                Toggle(L10n.t(.settingsNtfsAutoMount), isOn: $autoMountNTFSReadWrite)
                Text(L10n.t(.settingsNtfsAutoMountHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutTabView: View {
    let viewModel: AppViewModel
    let updateService: UpdateService

    private static let githubURL = URL(string: "https://github.com/mengyuefeitian/AutoVolume")!
    private static let websiteURL = URL(string: "https://www.xiaoanhome.xyz/autovolume")!

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "-"
        let build = info["CFBundleVersion"] as? String ?? "-"
        return L10n.t(.aboutVersion, version, build)
    }

    var body: some View {
        // `viewModel` is read here (rather than this view taking no observable state) purely to
        // register a SwiftUI dependency on `languageRevision` — see the doc comment on that
        // property in AppViewModel — so a live language switch re-renders this tab's strings
        // instead of only the tabs already visible when the window was displayed.
        let _ = viewModel.languageRevision
        // Wrapped in a ScrollView so long captions (e.g. ru/ja translations of the update
        // button, or a narrow window) can scroll instead of clipping the icon/title/version/
        // links/button stack against the fixed 480×420 Settings window.
        ScrollView {
            VStack(spacing: 16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }

                Text(L10n.t(.aboutProductName))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Link("GitHub", destination: Self.githubURL)
                    Text(Self.githubURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Link(L10n.t(.aboutWebsite), destination: Self.websiteURL)
                    Text(Self.websiteURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(L10n.t(.menuCheckForUpdates)) {
                    updateService.checkForUpdates()
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal)
        }
    }
}
