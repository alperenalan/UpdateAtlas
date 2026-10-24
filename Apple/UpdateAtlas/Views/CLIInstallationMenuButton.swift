import SwiftUI

struct CLIInstallationMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(LanguageSettings.languageKey) private var languageCode = LanguageSettings.defaultLanguageCode

    var body: some View {
        Button {
            openWindow(id: "cli-installation")
        } label: {
            Label(
                String(localized: "Install Command Line Tool…", bundle: AppL10n.bundle, locale: LanguageSettings.effectiveLocale(for: languageCode)),
                systemImage: "terminal"
            )
            .labelStyle(.titleAndIcon)
        }
    }
}
