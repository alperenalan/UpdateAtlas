import SwiftUI

struct CatalogSettingsView: View {
    private static let rulePageSize = 40

    @ObservedObject var viewModel: AppInventoryViewModel
    @AppStorage(CatalogSettings.matchingEnabledKey)
    private var matchingEnabled = CatalogSettings.defaultMatchingEnabled
    @State private var searchText = ""
    @State private var sortedPublishers: [CatalogPublisherGroup] = []
    @State private var matchingPublishers: [CatalogPublisherGroup] = []
    @State private var expandedPublisherIDs = Set<String>()
    @State private var searchExpandedPublisherIDs = Set<String>()
    @State private var visibleRuleCounts: [String: Int] = [:]
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section("Catalog Matching") {
                Text("Official catalog updates are checked automatically while the app is open. Catalog matching can be turned off separately.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enable catalog matching", isOn: $matchingEnabled)
                    .disabled(viewModel.isScanning)
                Text("Catalog rules identify software and select its update source. Turning matching off keeps metadata and package-manager checks available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Source") {
                    Text(viewModel.catalogSnapshot?.source.title ?? String(localized: "Not loaded", bundle: AppL10n.bundle, locale: AppL10n.locale))
                }
                if let snapshot = viewModel.catalogSnapshot {
                    LabeledContent("Catalog loaded") {
                        Text(snapshot.loadedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                    }
                    LabeledContent("Catalog") {
                        let updated = snapshot.catalog.generatedAt.formatted(Date.FormatStyle(date: .abbreviated).locale(locale))
                        Text(String(format: String(localized: "Version %lld, updated %@", bundle: AppL10n.bundle, locale: AppL10n.locale), snapshot.catalog.revision, updated))
                    }
                    LabeledContent("Active rules") {
                        Text("\(viewModel.enabledCatalogRuleCount) / \(entries.count)")
                            .monospacedDigit()
                    }
                    if matchingEnabled, let warning = snapshot.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text(CatalogSettings.officialRemoteURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("", text: $searchText, prompt: Text("Search publishers and apps"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel("Search catalog rules")
                }
                if entries.isEmpty {
                    Text("No catalog rules are available from the current source.")
                        .foregroundStyle(.secondary)
                } else if matchingPublishers.isEmpty {
                    Text("No rules match your search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matchingPublishers) { publisher in
                        DisclosureGroup(isExpanded: publisherBinding(publisher.id)) {
                            ForEach(publisher.entries.prefix(visibleRuleCount(for: publisher))) { entry in
                                Toggle(isOn: ruleBinding(entry)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.displayName ?? entry.id)
                                            .lineLimit(2)
                                        Text([entry.publisher, entry.mechanism.name].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 3)
                                }
                                .help(entry.id)
                                .disabled(!matchingEnabled || viewModel.isScanning)
                            }
                            if visibleRuleCount(for: publisher) < publisher.entries.count {
                                Button("Show more rules") {
                                    visibleRuleCounts[publisher.id] = min(
                                        publisher.entries.count,
                                        visibleRuleCount(for: publisher) + Self.rulePageSize
                                    )
                                }
                                .buttonStyle(.borderless)
                            }
                        } label: {
                            HStack {
                                Text(publisher.title).fontWeight(.medium)
                                Spacer()
                                Text(publisher.entries.count, format: .number)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                HStack {
                    Text("Changes apply to the next scan and are shared with the CLI.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Now") { Task { await viewModel.scan() } }
                        .disabled(viewModel.isScanning)
                }
            } header: {
                Text("Catalog Rules")
            } footer: {
                Text("Disable a rule to use embedded metadata instead. Some software may then need a catalog rule or a verified version source.")
            }

        }
        .formStyle(.grouped)
        .onAppear(perform: refreshPublishers)
        .task { await viewModel.loadLocalCatalogIfNeeded() }
        .onChange(of: viewModel.catalogSnapshot?.loadedAt) { _, _ in refreshPublishers() }
        .onChange(of: searchText) { _, _ in refreshSearchResults() }
    }

    private var entries: [CatalogEntry] { viewModel.catalogSnapshot?.catalog.entries ?? [] }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func visibleRuleCount(for publisher: CatalogPublisherGroup) -> Int {
        min(publisher.entries.count, visibleRuleCounts[publisher.id] ?? Self.rulePageSize)
    }

    private func publisherBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: {
                isSearching ? searchExpandedPublisherIDs.contains(id) : expandedPublisherIDs.contains(id)
            },
            set: { expanded in
                if isSearching {
                    if expanded { searchExpandedPublisherIDs.insert(id) }
                    else { searchExpandedPublisherIDs.remove(id) }
                } else {
                    if expanded { expandedPublisherIDs.insert(id) }
                    else { expandedPublisherIDs.remove(id) }
                }
            }
        )
    }

    private func refreshPublishers() {
        sortedPublishers = CatalogPublisherGroup.sorted(entries)
        refreshSearchResults()
    }

    private func refreshSearchResults() {
        matchingPublishers = CatalogPublisherGroup.matching(sortedPublishers, query: searchText)
        visibleRuleCounts.removeAll()
        guard isSearching else {
            searchExpandedPublisherIDs.removeAll()
            return
        }
        searchExpandedPublisherIDs = CatalogPublisherGroup.automaticallyExpandedIDs(in: matchingPublishers)
    }

    private func ruleBinding(_ entry: CatalogEntry) -> Binding<Bool> {
        Binding(
            get: { viewModel.isCatalogEntryEnabled(entry) },
            set: { viewModel.setCatalogEntry(entry, enabled: $0) }
        )
    }
}
