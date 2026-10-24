import AppKit

@MainActor
enum SupportAboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(string:
            String(localized: "Update Atlas is free. Supporting development is optional and never changes scanning or update results.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            + "\n" + String(localized: "Open Source", bundle: AppL10n.bundle, locale: AppL10n.locale) + " · GPL-3.0-only\n\n"
        )
        #if DEBUG
        credits.insert(NSAttributedString(string: String(localized: "Debug build", bundle: AppL10n.bundle, locale: AppL10n.locale) + "\n\n"), at: 0)
        #endif
        credits.append(NSAttributedString(
            string: String(localized: "Open Source Repository", bundle: AppL10n.bundle, locale: AppL10n.locale) + "\n",
            attributes: [.link: AboutLinks.repositoryURL]
        ))
        credits.append(NSAttributedString(
            string: "alperenalan.com\n",
            attributes: [.link: AboutLinks.websiteURL]
        ))
        if let url = SupportSettings.configuredURL {
            credits.append(NSAttributedString(
                string: String(localized: "Support Development", bundle: AppL10n.bundle, locale: AppL10n.locale),
                attributes: [.link: url]
            ))
        } else {
            credits.append(NSAttributedString(string: String(localized: "Support link is not available yet.", bundle: AppL10n.bundle, locale: AppL10n.locale)))
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
