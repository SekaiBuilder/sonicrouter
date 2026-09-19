import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @EnvironmentObject private var audioStore: AudioDeviceStore
    @EnvironmentObject private var appStore: ApplicationAudioStore
    @ObservedObject private var l10n = L10n.shared

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: ProfilesDocument?
    @State private var confirmsForgetAll = false
    @State private var errorMessage: String?

    /// Far above any real export (1,000 profiles are a few hundred KB).
    private static let maximumImportBytes = 5_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if appStore.profiles.isEmpty {
                EmptyHint(
                    symbol: "bookmark",
                    title: l10n.t("Aún no hay ajustes guardados", "No saved settings yet", "保存された設定はまだありません"),
                    subtitle: l10n.t(
                        "Ajusta una app en el mezclador o importa un archivo y aparecerá aquí.",
                        "Adjust an app in the mixer or import a file and it will appear here.",
                        "ミキサーでアプリを調整するか、ファイルを読み込むとここに表示されます。"
                    )
                )
                .card()
                .padding(20)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(appStore.profiles.enumerated()), id: \.element.id) { index, profile in
                            ProfileRow(
                                profile: profile,
                                devices: audioStore.outputDevices,
                                onRemove: { appStore.removeProfile(profile) }
                            )
                            if index < appStore.profiles.count - 1 {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    )
                    .padding(20)
                }
            }
        }
        .alert(l10n.t("No se pudo completar", "Couldn't complete", "完了できませんでした"), isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            l10n.t("¿Olvidar todos los ajustes guardados?", "Forget all saved settings?", "保存済みの設定をすべて削除しますか？"),
            isPresented: $confirmsForgetAll
        ) {
            Button(l10n.t("Olvidar todos", "Forget all", "すべて削除"), role: .destructive) {
                appStore.removeAllProfiles()
            }
        } message: {
            Text(l10n.t(
                "Las apps que suenan ahora no cambian: solo se borra lo que se recuerda para la próxima vez.",
                "Apps playing now keep their current settings: only what is remembered for next time is erased.",
                "再生中のアプリはそのままです。次回のために記憶された設定だけが削除されます。"
            ))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(l10n.t("Ajustes guardados", "Saved settings", "保存済みの設定"))
                    .font(.system(size: 22, weight: .bold))
                Text(l10n.t(
                    "El volumen, la salida y el ecualizador de cada app se recuerdan y se aplican solos cuando esa app vuelve a sonar.",
                    "Each app's volume, output and equalizer are remembered and applied automatically when that app plays again.",
                    "アプリごとの音量・出力・イコライザーは記憶され、そのアプリが再び再生を始めると自動的に適用されます。"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    isImporting = true
                } label: {
                    Label(l10n.t("Importar…", "Import…", "読み込む…"), systemImage: "square.and.arrow.down")
                }
                .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                    handleImport(result)
                }

                Button {
                    startExport()
                } label: {
                    Label(l10n.t("Exportar…", "Export…", "書き出す…"), systemImage: "square.and.arrow.up")
                }
                .disabled(appStore.profiles.isEmpty)
                .fileExporter(
                    isPresented: $isExporting,
                    document: exportDocument,
                    contentType: .json,
                    defaultFilename: exportFilename
                ) { result in
                    handleExport(result)
                }

                Spacer()

                Button(role: .destructive) {
                    confirmsForgetAll = true
                } label: {
                    Label(l10n.t("Olvidar todos", "Forget all", "すべて削除"), systemImage: "trash")
                }
                .disabled(appStore.profiles.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var exportFilename: String {
        let day = Date.now.formatted(.iso8601.year().month().day())
        return "SonicRouter " + l10n.t("ajustes", "settings", "設定") + " " + day
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func startExport() {
        do {
            exportDocument = ProfilesDocument(data: try appStore.exportedProfilesData())
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleExport(_ result: Result<URL, any Error>) {
        exportDocument = nil
        switch result {
        case .success:
            let count = appStore.profiles.count
            appStore.controlStatus = l10n.t(
                "Ajustes exportados: \(count)",
                "Settings exported: \(count)",
                "設定を書き出しました: \(count)件"
            )
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maximumImportBytes else {
                    errorMessage = l10n.t(
                        "El archivo es demasiado grande para ser una exportación de SonicRouter.",
                        "The file is too large to be a SonicRouter export.",
                        "SonicRouterの書き出しファイルとしては大きすぎます。"
                    )
                    return
                }
                try appStore.importProfiles(from: Data(contentsOf: url))
            } catch {
                errorMessage = Self.message(for: error, l10n: l10n)
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func message(for error: any Error, l10n: L10n) -> String {
        switch error as? AudioProfileArchiveError {
        case .unrecognizedFormat:
            l10n.t(
                "El archivo no es una exportación de ajustes de SonicRouter.",
                "The file is not a SonicRouter settings export.",
                "SonicRouterの設定ファイルではありません。"
            )
        case .unsupportedVersion:
            l10n.t(
                "El archivo es de una versión más reciente de SonicRouter. Actualiza la app para importarlo.",
                "The file comes from a newer SonicRouter. Update the app to import it.",
                "新しいバージョンのSonicRouterで作成されたファイルです。アプリを更新してから読み込んでください。"
            )
        case .tooManyProfiles(let count):
            l10n.t(
                "El archivo tiene demasiados ajustes (\(count)).",
                "The file has too many entries (\(count)).",
                "ファイルの項目が多すぎます（\(count)件）。"
            )
        case .noProfiles:
            l10n.t(
                "El archivo no contiene ajustes utilizables.",
                "The file has no usable settings.",
                "ファイルに使用できる設定がありません。"
            )
        case nil:
            error.localizedDescription
        }
    }
}

private struct ProfileRow: View {
    let profile: AudioRouteProfile
    let devices: [AudioDevice]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let bundleID = profile.bundleIdentifier,
                   let icon = InstalledAppIcons.icon(forBundleIdentifier: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent.opacity(0.14))
                        Image(systemName: "app.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.appName)
                    .font(.headline)
                    .lineLimit(1)
                Text(profile.bundleIdentifier ?? L10n.shared.t("Sin identificador", "No identifier", "識別子なし"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(routeText, systemImage: profile.outputDeviceUID == nil ? "speaker.wave.2" : "airplayaudio")
                    .font(.caption)
                    .foregroundStyle(routeColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let equalizer = profile.equalizer, !equalizer.isFlat {
                    Label(equalizer.summary(L10n.shared), systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Text("\(Int((profile.volume * 100).rounded()))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(profile.volume <= 0.001 ? .red : .secondary)

            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.shared.t("Olvidar estos ajustes", "Forget these settings", "この設定を削除"))
        }
        .padding(.vertical, 9)
    }

    private var routeDevice: AudioDevice? {
        guard let uid = profile.outputDeviceUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// Where the app is sent when the profile is restored: the system default,
    /// a specific output, or one that is not connected right now.
    private var routeText: String {
        guard profile.outputDeviceUID != nil else {
            return L10n.shared.t("Salida predeterminada", "Default output", "既定の出力")
        }
        return routeDevice?.name ?? L10n.shared.t("Salida no conectada", "Output not connected", "出力が未接続")
    }

    private var routeColor: Color {
        guard profile.outputDeviceUID != nil else { return .secondary }
        return routeDevice == nil ? .orange : Theme.accent
    }
}

/// Icons of installed apps by bundle ID, looked up once through Launch
/// Services. Apps that are not installed fall back to a generic symbol.
@MainActor
enum InstalledAppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(forBundleIdentifier bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard !missing.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

/// JSON document handed to the save panel when exporting.
struct ProfilesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
