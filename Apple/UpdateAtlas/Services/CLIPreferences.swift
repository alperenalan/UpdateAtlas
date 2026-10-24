import Foundation

/// A narrow allowlist, shared with GUI preference keys; never arbitrary defaults writes.
struct CLIPreferences {
    enum PreferenceError: Error { case invalidArguments, invalidValue, unknownKey }
    enum Value: Encodable, Equatable {
        case bool(Bool), integer(Int), string(String), strings([String])
        func encode(to encoder: Encoder) throws {
            var box = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try box.encode(value)
            case .integer(let value): try box.encode(value)
            case .string(let value): try box.encode(value)
            case .strings(let value): try box.encode(value)
            }
        }
    }
    private struct Setting {
        let key: String
        let fallback: Value
    }
    let defaults: UserDefaults
    private static let definitions: [String: Setting] = [
        "include-system": .init(key: InventorySettings.includeSystemApplicationsKey, fallback: .bool(false)),
        "hide-system-python": .init(key: InventorySettings.hideSystemPythonUpdatesKey, fallback: .bool(true)),
        "allow-prerelease": .init(key: ReleaseChannelSettings.allowPrereleaseForStableKey, fallback: .bool(false)),
        "docker": .init(key: DiscoveryConfiguration.dockerKey, fallback: .bool(false)),
        "menu-bar": .init(key: MenuBarSettings.enabledKey, fallback: .bool(MenuBarSettings.defaultEnabled)),
        "menu-bar-icons": .init(key: MenuBarSettings.showAppIconsKey, fallback: .bool(MenuBarSettings.defaultShowAppIcons)),
        "launch-in-menu-bar": .init(key: LaunchAtLoginSettings.openInMenuBarOnlyKey,
                                     fallback: .bool(LaunchAtLoginSettings.defaultOpenInMenuBarOnly)),
        "background-checks": .init(key: "background-checks.enabled-v1", fallback: .bool(false)),
        "check-interval-hours": .init(key: "background-checks.interval-v1", fallback: .integer(6)),
        "notifications": .init(key: "notifications.updates-enabled-v1", fallback: .bool(false)),
        "notification-sound": .init(key: "notifications.sound-enabled-v1", fallback: .bool(false))
    ]
    func settings() -> [String: Value] {
        var output = Self.definitions.mapValues { setting -> Value in
            switch setting.fallback {
            case .bool(let fallback): return .bool(defaults.object(forKey: setting.key) as? Bool ?? fallback)
            case .integer(let fallback): return .integer(defaults.object(forKey: setting.key) as? Int ?? fallback)
            default: return setting.fallback
            }
        }
        output["folders"] = .strings(DiscoveryConfiguration.current(from: defaults).folders.map(\.path))
        return output
    }
    func get(_ key: String) throws -> Value {
        guard let value = settings()[key] else { throw PreferenceError.unknownKey }
        return value
    }
    func set(_ key: String, value: String) throws {
        guard let definition = Self.definitions[key] else { throw PreferenceError.unknownKey }
        switch definition.fallback {
        case .bool:
            guard ["true", "false"].contains(value) else { throw PreferenceError.invalidValue }
            defaults.set(value == "true", forKey: definition.key)
        case .integer:
            guard let number = Int(value), [1, 3, 6, 12, 24].contains(number) else { throw PreferenceError.invalidValue }
            defaults.set(number, forKey: definition.key)
        default: throw PreferenceError.invalidValue
        }
    }
    func reset(_ key: String) throws {
        guard let definition = Self.definitions[key] else { throw PreferenceError.unknownKey }
        defaults.removeObject(forKey: definition.key)
    }
    func folder(_ operation: String, path: String) throws {
        guard path.hasPrefix("/"), ["add", "remove"].contains(operation) else { throw PreferenceError.invalidValue }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var folders = DiscoveryConfiguration.current(from: defaults).folders
        if operation == "add" {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw PreferenceError.invalidValue }
            folders = DiscoveryConfiguration(folders: folders + [url]).folders
            guard folders.count <= 16 else { throw PreferenceError.invalidValue }
        } else { folders.removeAll { $0 == url } }
        defaults.set(folders.map(\.path), forKey: DiscoveryConfiguration.foldersKey)
    }
}
