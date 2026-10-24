import Foundation

enum NativeInventoryRow: Equatable {
    case application(InstalledApplication, depth: Int, hasChildren: Bool, managedUpdates: Int, expanded: Bool)

    var application: InstalledApplication? {
        if case .application(let application, _, _, _, _) = self { return application }
        return nil
    }

    @MainActor
    static func snapshot(from model: AppInventoryViewModel) -> [Self] {
        let matchingIDs = model.matchingApplicationIDs
        return model.visibleApplications.map { application in
            let hasChildren = model.hasManagedChildren(application, among: matchingIDs)
            return .application(application, depth: model.hierarchyDepth(of: application, among: matchingIDs),
                                hasChildren: hasChildren,
                                managedUpdates: model.managedUpdateCount(for: application),
                                expanded: hasChildren && model.expandedManagerIDs.contains(application.id))
        }
    }
}
