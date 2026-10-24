import CryptoKit
import Foundation

struct CLIInventoryQuery {
    enum Command: String { case scan, check }
    enum QueryError: Error, Equatable { case invalidArguments, unknownOwner }

    let command: Command
    private(set) var progress = CLIProgressPreference.automatic
    private(set) var offline = false
    private(set) var failOnUpdates = false
    private(set) var includeSystem = false
    private(set) var includePaths = false
    private(set) var folders: [URL] = []
    private(set) var docker: Bool?
    private(set) var updatesOnly = false
    private(set) var kind: InventoryItemKind?
    private(set) var ownerID: String?
    private(set) var childrenOnly = false

    init(arguments: [String]) throws {
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw QueryError.invalidArguments
        }
        self.command = command
        var seen = Set<String>()
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard option == "--folder" || seen.insert(option).inserted else { throw QueryError.invalidArguments }
            switch option {
            case "--progress", "--no-progress":
                guard progress == .automatic else { throw QueryError.invalidArguments }
                progress = option == "--progress" ? .enabled : .disabled
            case "--offline": offline = true
            case "--fail-on-updates": failOnUpdates = true
            case "--include-system": includeSystem = true
            case "--include-paths": includePaths = true
            case "--docker", "--no-docker":
                guard docker == nil else { throw QueryError.invalidArguments }
                docker = option == "--docker"
            case "--folder":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/"), folders.count < 16 else {
                    throw QueryError.invalidArguments
                }
                folders.append(URL(fileURLWithPath: arguments[index], isDirectory: true))
            case "--updates-only": updatesOnly = true
            case "--kind":
                index += 1
                guard index < arguments.count, let kind = InventoryItemKind(rawValue: arguments[index]) else {
                    throw QueryError.invalidArguments
                }
                self.kind = kind
            case "--manager", "--children-of":
                index += 1
                guard ownerID == nil, index < arguments.count,
                      Self.isOpaqueID(arguments[index]) else { throw QueryError.invalidArguments }
                ownerID = arguments[index]
                childrenOnly = option == "--children-of"
            default: throw QueryError.invalidArguments
            }
            index += 1
        }
    }

    // Filter after checking the complete inventory. Display/output choices must not
    // change the underlying count or cause an absent update source to look current.
    func selectedItems(in inventory: [InstalledApplication]) throws -> [InstalledApplication] {
        var selectedIDs: Set<String>?
        if let ownerID {
            guard let owner = inventory.first(where: { Self.opaqueID($0.id) == ownerID }) else {
                throw QueryError.unknownOwner
            }
            var descendants: Set<String> = [owner.id]
            let inventoryIDs = Set(inventory.map(\.id))
            let firstParentByBundle = inventory.reduce(into: [String: String]()) { parents, item in
                if parents[item.bundleIdentifier] == nil { parents[item.bundleIdentifier] = item.id }
            }
            // Resolve legacy bundle-ID ownership exactly as the GUI does. Explicit
            // inventory identities take priority; ambiguous bundle-only ownership is
            // assigned to the first canonical parent, rather than every installation.
            let children = Dictionary(grouping: inventory, by: { item -> String in
                if let parentID = item.parentInventoryID,
                   inventoryIDs.contains(parentID) { return parentID }
                if let bundleID = item.parentManagerBundleIdentifier,
                   let parentID = firstParentByBundle[bundleID] { return parentID }
                return ""
            })
            var pending = [owner.id]
            while let parentID = pending.popLast() {
                for child in children[parentID] ?? [] where descendants.insert(child.id).inserted {
                    pending.append(child.id)
                }
            }
            if childrenOnly { descendants.remove(owner.id) }
            selectedIDs = descendants
        }
        return inventory.filter { item in
            (selectedIDs?.contains(item.id) ?? true)
                && (!updatesOnly || item.updateCheck.availability == .updateAvailable)
                && (kind == nil || item.kind == kind)
        }.sorted { $0.id < $1.id }
    }

    static func opaqueID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func isOpaqueID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct CLIInventorySummary: Codable, Equatable {
    let inventoryItemCount: Int
    let returnedItemCount: Int
    let availableUpdateCount: Int
    let returnedUpdateCount: Int
    let sourcePendingCount: Int
    let checkFailedCount: Int

    init(inventory: [InstalledApplication], returned: [InstalledApplication]) {
        inventoryItemCount = inventory.count
        returnedItemCount = returned.count
        availableUpdateCount = inventory.filter { $0.updateCheck.availability == .updateAvailable }.count
        returnedUpdateCount = returned.filter { $0.updateCheck.availability == .updateAvailable }.count
        sourcePendingCount = inventory.filter { $0.updateCheck.availability == .sourcePending }.count
        checkFailedCount = inventory.filter { $0.updateCheck.availability == .checkFailed }.count
    }
}

enum CLIProgressPreference { case automatic, enabled, disabled }
