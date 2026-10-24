import Foundation

// Standalone and curl-script installers do not register with a system package manager.
// Keep their reviewed footprints and safe metadata readers in one unified scanner;
// never execute untrusted binaries during discovery.
struct DirectInstallScanner: Sendable {
    let homeDirectory: URL
    let systemBinaryDirectory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemBinaryDirectory: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    ) {
        self.homeDirectory = homeDirectory
        self.systemBinaryDirectory = systemBinaryDirectory
    }

    func scan(
        packageCandidates: [ApplicationCandidate],
        applicationCandidates: [ApplicationCandidate]
    ) -> DirectInstallSnapshot {
        let fileManager = FileManager.default
        var candidates: [ApplicationCandidate] = []
        var remnants: [DirectInstallRemnant] = []

        for recipe in Self.recipes {
            var seenResolvedPaths = Set<String>()
            for executable in recipe.executables(
                homeDirectory: homeDirectory,
                systemBinaryDirectory: systemBinaryDirectory
            ) {
                let resolved = executable.resolvingSymlinksInPath().standardizedFileURL

                // A broken symlink is evidence of a past installation, not a live product.
                // FileManager's executable check follows symlinks and rejects missing targets.
                let isPresent: Bool
                if recipe.requiresExecutable {
                    isPresent = fileManager.isExecutableFile(atPath: executable.path)
                        && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                } else {
                    isPresent = fileManager.fileExists(atPath: executable.path)
                        && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                }
                guard isPresent else {
                    if (try? fileManager.destinationOfSymbolicLink(atPath: executable.path)) != nil {
                        remnants.append(.init(name: recipe.name, path: executable.path))
                    }
                    continue
                }

                if let appBundleID = recipe.appBundleID,
                   applicationCandidates.contains(where: { $0.bundleIdentifier == appBundleID }) {
                    continue
                }

                if Self.isPackageManaged(resolvedPath: resolved.path, packageCandidates: packageCandidates)
                    || Self.isManagerOwnedPath(resolved.path)
                    || (recipe.id == "starship" && resolved.path.contains("/.cargo/bin/")) {
                    continue
                }
                guard seenResolvedPaths.insert(resolved.path).inserted else { continue }

                let version = recipe.version(from: resolved, homeDirectory: homeDirectory)
                candidates.append(ApplicationCandidate(
                    inventoryID: "direct-cli:\(recipe.id):\(executable.path)",
                    path: executable.path,
                    name: recipe.name,
                    bundleIdentifier: "direct-cli:\(recipe.id)",
                    displayVersion: version ?? String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    buildVersion: "",
                    teamIdentifier: nil,
                    parentManagerBundleIdentifier: nil,
                    isSystemApplication: false,
                    info: [
                        "DirectInstallSource": recipe.documentationURL,
                        "DirectInstallOwner": recipe.owner,
                        "DirectInstallMethod": recipe.installMethod
                    ],
                    kind: .commandLineTool
                ))
            }
        }

        return DirectInstallSnapshot(candidates: candidates, remnants: remnants)
    }

    private static func isPackageManaged(
        resolvedPath: String,
        packageCandidates: [ApplicationCandidate]
    ) -> Bool {
        packageCandidates.contains { candidate in
            guard let location = candidate.packageProvenance?.installLocation else { return false }
            let root = URL(fileURLWithPath: location).resolvingSymlinksInPath().standardizedFileURL.path
            return resolvedPath == root || resolvedPath.hasPrefix(root + "/")
        }
    }

    private static func isManagerOwnedPath(_ path: String) -> Bool {
        // If the package inventory was unavailable, still avoid claiming a
        // recognizable manager-owned symlink as a direct vendor installation.
        ["/Cellar/", "/Caskroom/", "/node_modules/", "/pipx/venvs/", "/uv/tools/", "/mise/installs/"]
            .contains(where: path.contains)
    }

    static let recipes: [DirectInstallRecipe] = [
        .init(id: "cua-driver", name: "Cua Driver", relativePath: ".local/bin/cua-driver",
              owner: "Cua Driver", documentationURL: "https://cua.ai/docs/how-to-guides/driver/install",
              appBundleID: "com.trycua.driver"),
        .init(id: "antigravity-cli", name: "Antigravity CLI", relativePath: ".local/bin/agy",
              owner: "Antigravity CLI", documentationURL: "https://antigravity.google/docs/cli/install/"),
        .init(id: "claude-code", name: "Claude Code", relativePath: ".local/bin/claude",
              owner: "Claude Code", documentationURL: "https://code.claude.com/docs/en/setup",
              versionDirectory: ".local/share/claude/versions"),
        .init(id: "uv", name: "uv", relativePath: ".local/bin/uv",
              owner: "uv", documentationURL: "https://docs.astral.sh/uv/getting-started/installation/",
              receiptJSONFile: ".config/uv/uv-receipt.json"),
        .init(id: "bun", name: "Bun", relativePath: ".bun/bin/bun",
              owner: "Bun", documentationURL: "https://bun.sh/docs/installation"),
        .init(id: "deno", name: "Deno", relativePath: ".deno/bin/deno",
              owner: "Deno", documentationURL: "https://docs.deno.com/runtime/getting_started/installation/"),
        .init(id: "rustup", name: "rustup", relativePath: ".cargo/bin/rustup",
              owner: "rustup", documentationURL: "https://rust-lang.org/tools/install/"),
        .init(id: "mise", name: "mise", relativePath: ".local/bin/mise",
              owner: "mise", documentationURL: "https://mise.jdx.dev/getting-started"),
        .init(id: "starship", name: "Starship", relativePath: ".local/bin/starship",
              owner: "Starship", documentationURL: "https://starship.rs/guide/",
              systemBinaryName: "starship"),
        .init(id: "nvm", name: "Node Version Manager (nvm)", relativePath: ".nvm/nvm.sh",
              owner: "nvm", documentationURL: "https://github.com/nvm-sh/nvm",
              versionJSONFile: ".nvm/package.json", requiresExecutable: false),
        .init(id: "pyenv", name: "pyenv", relativePath: ".pyenv/bin/pyenv",
              owner: "pyenv", documentationURL: "https://github.com/pyenv/pyenv"),
        .init(id: "sdkman", name: "SDKMAN!", relativePath: ".sdkman/bin/sdkman-init.sh",
              owner: "SDKMAN!", documentationURL: "https://sdkman.io/install",
              versionTextFile: ".sdkman/var/version", requiresExecutable: false),
        .init(id: "oh-my-zsh", name: "Oh My Zsh", relativePath: ".oh-my-zsh/oh-my-zsh.sh",
              owner: "Oh My Zsh", documentationURL: "https://ohmyz.sh/",
              requiresExecutable: false),
        .init(id: "volta", name: "Volta", relativePath: ".volta/bin/volta",
              owner: "Volta", documentationURL: "https://docs.volta.sh/guide/getting-started"),
        .init(id: "pnpm", name: "pnpm", relativePath: ".local/share/pnpm/pnpm",
              owner: "pnpm", documentationURL: "https://pnpm.io/installation"),
        .init(id: "flyctl", name: "Flyctl", relativePath: ".fly/bin/flyctl",
              owner: "Fly.io", documentationURL: "https://fly.io/docs/flyctl/install/"),
        .init(id: "atuin", name: "Atuin", relativePath: ".atuin/bin/atuin",
              owner: "Atuin", documentationURL: "https://docs.atuin.sh/guide/installation/"),
        .init(id: "proto", name: "proto", relativePath: ".proto/bin/proto",
              owner: "moonrepo", documentationURL: "https://moonrepo.dev/docs/proto/install"),
        .init(id: "pixi", name: "pixi", relativePath: ".pixi/bin/pixi",
              owner: "prefix.dev", documentationURL: "https://pixi.sh/latest/"),
        .init(id: "wasmtime", name: "Wasmtime", relativePath: ".wasmtime/bin/wasmtime",
              owner: "Bytecode Alliance", documentationURL: "https://wasmtime.dev/"),
        .init(id: "wasmer", name: "Wasmer", relativePath: ".wasmer/bin/wasmer",
              owner: "Wasmer", documentationURL: "https://wasmer.io/"),
        .init(id: "ghcup", name: "GHCup", relativePath: ".ghcup/bin/ghcup",
              owner: "Haskell", documentationURL: "https://www.haskell.org/ghcup/"),
        .init(id: "elan", name: "elan (Lean)", relativePath: ".elan/bin/elan",
              owner: "Lean Prover", documentationURL: "https://github.com/leanprover/elan"),
        .init(id: "turso", name: "Turso CLI", relativePath: ".turso/turso",
              owner: "Turso", documentationURL: "https://docs.turso.tech/cli/installation"),
        .init(id: "gcloud", name: "Google Cloud SDK", relativePath: "google-cloud-sdk/bin/gcloud",
              owner: "Google Cloud", documentationURL: "https://cloud.google.com/sdk/docs/install",
              versionTextFile: "google-cloud-sdk/VERSION")
    ]
}

struct DirectInstallSnapshot: Sendable {
    let candidates: [ApplicationCandidate]
    let remnants: [DirectInstallRemnant]
}

struct DirectInstallRemnant: Hashable, Sendable {
    let name: String
    let path: String
}

struct DirectInstallRecipe: Sendable {
    let id: String
    let name: String
    let relativePath: String
    let owner: String
    let documentationURL: String
    let appBundleID: String?
    let versionDirectory: String?
    let versionJSONFile: String?
    let versionTextFile: String?
    let receiptJSONFile: String?
    let systemBinaryName: String?
    let requiresExecutable: Bool
    let installMethod: String

    init(
        id: String,
        name: String,
        relativePath: String,
        owner: String,
        documentationURL: String,
        appBundleID: String? = nil,
        versionDirectory: String? = nil,
        versionJSONFile: String? = nil,
        versionTextFile: String? = nil,
        receiptJSONFile: String? = nil,
        systemBinaryName: String? = nil,
        requiresExecutable: Bool = true,
        installMethod: String = "curl / standalone script"
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.owner = owner
        self.documentationURL = documentationURL
        self.appBundleID = appBundleID
        self.versionDirectory = versionDirectory
        self.versionJSONFile = versionJSONFile
        self.versionTextFile = versionTextFile
        self.receiptJSONFile = receiptJSONFile
        self.systemBinaryName = systemBinaryName
        self.requiresExecutable = requiresExecutable
        self.installMethod = installMethod
    }

    func executables(homeDirectory: URL, systemBinaryDirectory: URL) -> [URL] {
        var paths = [homeDirectory.appendingPathComponent(relativePath)]
        if let systemBinaryName {
            paths.append(systemBinaryDirectory.appendingPathComponent(systemBinaryName))
        }
        return paths
    }

    func version(from resolved: URL, homeDirectory: URL) -> String? {
        if let versionDirectory {
            let root = homeDirectory.appendingPathComponent(versionDirectory).standardizedFileURL.path
            if resolved.path.hasPrefix(root + "/") {
                let value = resolved.lastPathComponent
                if value.first?.isNumber == true, value.contains(".") {
                    return value
                }
            }
        }
        if let versionJSONFile {
            let url = homeDirectory.appendingPathComponent(versionJSONFile)
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = obj["version"] as? String,
               Self.isValidVersionString(version) {
                return version
            }
        }
        if let receiptJSONFile {
            let url = homeDirectory.appendingPathComponent(receiptJSONFile)
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = (obj["version"] as? String) ?? (obj["app_version"] as? String),
               Self.isValidVersionString(version) {
                return version
            }
        }
        if let versionTextFile {
            let url = homeDirectory.appendingPathComponent(versionTextFile)
            if let text = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               Self.isValidVersionString(text) {
                return text
            }
        }
        return nil
    }

    private static func isValidVersionString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48,
              trimmed.first?.isNumber == true, trimmed.contains(".") else { return false }
        return !trimmed.contains("\n") && !trimmed.contains("/")
    }
}
