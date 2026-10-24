import Foundation

enum AIIntegrationGuide {
    static let cliExecutablePath = "~/.local/bin/update-atlas"

    static var expandedCLIPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/update-atlas").path
    }

    static var cliQuickReference: [(command: String, summary: String)] {
        [
            ("update-atlas scan", String(localized: "Read-only local inventory scan (JSON output)", bundle: AppL10n.bundle, locale: AppL10n.locale)),
            ("update-atlas check --updates-only", String(localized: "Refresh catalog & check all sources, returning items with updates", bundle: AppL10n.bundle, locale: AppL10n.locale)),
            ("update-atlas check --kind game", String(localized: "Check games across Steam, Epic, GOG, Heroic, Battle.net, Riot & Prism", bundle: AppL10n.bundle, locale: AppL10n.locale)),
            ("update-atlas scan --kind virtualMachine", String(localized: "List UTM, VMware Fusion, Parallels, VirtualBox, Lima & Colima VMs", bundle: AppL10n.bundle, locale: AppL10n.locale)),
            ("update-atlas scan --kind wineBottle", String(localized: "List CrossOver, Whisky, Kegworks, Porting Kit & Wine bottles", bundle: AppL10n.bundle, locale: AppL10n.locale)),
            ("update-atlas skill", String(localized: "Print the SKILL.md instruction guide for AI coding agents", bundle: AppL10n.bundle, locale: AppL10n.locale))
        ]
    }

    static var skillMarkdown: String {
        """
        ---
        name: update-atlas
        description: Inspect macOS applications, package managers (Homebrew, npm, pip, pipx, uv, Cargo), game libraries, Windows bottles (CrossOver, Whisky, Wine), and virtual machines (UTM, VMware Fusion, Parallels, VirtualBox, Lima, Colima) using the read-only Update Atlas CLI.
        ---

        # Update Atlas — AI Agent Skill & CLI Guide

        Update Atlas is a read-only software inventory and update verification tool for macOS.
        It never installs updates from the CLI or executes untrusted binaries during discovery.

        ## Read-only CLI Commands

        When running shell commands directly, `update-atlas` always emits schema-versioned JSON to `stdout` (progress goes to `stderr`):

        - Fast local inventory scan:
          `~/.local/bin/update-atlas scan --no-progress`
        - Check all sources and return only items with available updates:
          `~/.local/bin/update-atlas check --updates-only --no-progress`
        - Filter by kind (`application`, `game`, `package`, `commandLineTool`, `wineBottle`, `virtualMachine`, `container`):
          `~/.local/bin/update-atlas scan --kind virtualMachine --no-progress`
        - Inspect children of a manager or Wine bottle (use the opaque `id` from a previous scan):
          `~/.local/bin/update-atlas scan --children-of <OPAQUE_ID> --no-progress`
        """
    }
}
