import AppKit
import Foundation
import Observation
import os

private nonisolated func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

private nonisolated func renamedToSlugIfChanged(_ book: Book) -> (book: Book, didRename: Bool) {
    let ext = book.fileURL.pathExtension.lowercased()
    let target = bookFileSlug(
        title: book.title,
        author: book.authors.first,
        year: book.year,
        ext: ext,
        id: book.id
    )
    guard target != book.fileURL.lastPathComponent else {
        return (book, false)
    }
    let folder = book.fileURL.deletingLastPathComponent()
    let newURL = folder.appending(component: target)
    let fm = FileManager.default
    if fm.fileExists(atPath: newURL.path(percentEncoded: false)) {
        libraryLogger.warning(
            "rename skipped, target exists: \(target, privacy: .public)")
        return (book, false)
    }
    do {
        try fm.moveItem(at: book.fileURL, to: newURL)
        var updated = book
        updated.fileURL = newURL
        libraryLogger.info(
            "renamed: \(book.fileURL.lastPathComponent, privacy: .public) -> \(target, privacy: .public)"
        )
        return (updated, true)
    } catch {
        libraryLogger.error(
            "rename failed: \(error.localizedDescription, privacy: .public)")
        return (book, false)
    }
}

/// Outcome of a folder relocate attempt.
///
/// - `noChange`: current folder is already canonical, nothing to do.
/// - `moved`: folder was relocated; carries the previous folder URL so the
///   caller can roll back if a downstream step fails.
/// - `collision`: target folder exists and isn't ours — refusing to merge.
///   Caller should surface this to the user and not persist the edit, so
///   on-disk layout and metadata stay in sync.
nonisolated enum FolderRelocateOutcome: Equatable {
    case noChange
    case moved(originalFolder: URL)
    case collision(target: URL)
}

nonisolated struct FolderRelocateResult {
    let book: Book
    let outcome: FolderRelocateOutcome
}

/// Moves `<library>/OldAuthor/OldTitle (year)/` to
/// `<library>/NewAuthor/NewTitle (year)/` when the book's title / first
/// author / year produce a different canonical folder. The entire folder
/// moves — file, sidecar, cover, anything else in it. The returned
/// `Book.fileURL` is rewritten to point into the new folder.
///
/// Returns a `FolderRelocateOutcome`:
///  - `.noChange` when the folder is already canonical, *or* when the
///    move attempt failed at the FileManager level (logged but
///    swallowed — the next save will retry).
///  - `.moved(originalFolder:)` on success; the original URL is the
///    caller's handle for rolling back if a later step (slug rename,
///    sidecar write, index update) fails.
///  - `.collision(target:)` when the target folder already exists. The
///    caller is expected to surface this to the user and *not* persist
///    the edit, so on-disk layout and metadata stay in sync.
///
/// Rollback is the caller's responsibility — this function only does the
/// forward move and reports what happened.
nonisolated func relocateBookFolderIfChanged(
    _ book: Book,
    libraryRoot: URL
) -> FolderRelocateResult {
    let currentFolder = book.fileURL.deletingLastPathComponent()
    let target = LibraryLayout.bookFolderURL(
        in: libraryRoot,
        title: book.title,
        firstAuthor: book.authors.first,
        year: book.year
    )

    // Path-string comparison, not URL equality. `URL` `==` is on string form,
    // and `deletingLastPathComponent` produces a directory URL with a trailing
    // slash while `appending(component:)` doesn't — so the same folder can
    // disagree with itself and the function falls through to the
    // fileExists branch, returning `.collision` against the very folder the
    // book already lives in. NFC-fold for accented author/title names so
    // "Brandão" stored as NFD doesn't disagree with NFC re-derivation.
    let currentPath =
        currentFolder.standardizedFileURL.path(percentEncoded: false)
        .precomposedStringWithCanonicalMapping
    let targetPath =
        target.standardizedFileURL.path(percentEncoded: false)
        .precomposedStringWithCanonicalMapping
    if currentPath == targetPath {
        return FolderRelocateResult(book: book, outcome: .noChange)
    }

    let fm = FileManager.default
    if fm.fileExists(atPath: target.path(percentEncoded: false)) {
        libraryLogger.warning(
            "folder relocate refused, target exists: \(target.path(percentEncoded: false), privacy: .public)"
        )
        return FolderRelocateResult(book: book, outcome: .collision(target: target))
    }

    do {
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: currentFolder, to: target)

        var updated = book
        updated.fileURL = target.appending(component: book.fileURL.lastPathComponent)

        libraryLogger.info(
            "relocated folder: \(currentFolder.lastPathComponent, privacy: .public) -> \(target.lastPathComponent, privacy: .public)"
        )
        return FolderRelocateResult(
            book: updated,
            outcome: .moved(originalFolder: currentFolder)
        )
    } catch {
        libraryLogger.error(
            "folder relocate failed: \(error.localizedDescription, privacy: .public)"
        )
        // Treat raw move failures as "no change" — we tried, it didn't
        // happen, the book is still at its original folder. We still let
        // the metadata persist; the next save will retry.
        return FolderRelocateResult(book: book, outcome: .noChange)
    }
}

/// Walks up from `start` deleting empty directories, never crossing or
/// touching `libraryRoot`. After a folder relocate the old author folder
/// is often left empty — this cleanup keeps the library tidy without
/// requiring a separate housekeeping pass.
private nonisolated func pruneEmptyAncestors(from start: URL, stoppingAt libraryRoot: URL) {
    let fm = FileManager.default
    let root = libraryRoot.standardizedFileURL
    var current = start.standardizedFileURL
    while current != root, current.pathComponents.count > root.pathComponents.count {
        let path = current.path(percentEncoded: false)
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        // `.DS_Store` doesn't count as content — macOS sprinkles it freely
        // and it shouldn't keep an otherwise-empty folder alive.
        let meaningful = contents.filter { $0 != ".DS_Store" }
        guard meaningful.isEmpty else { return }
        do {
            try fm.removeItem(at: current)
        } catch {
            libraryLogger.error(
                "empty-folder prune failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        current = current.deletingLastPathComponent().standardizedFileURL
    }
}

/// Drives the device tile's morphing UI for the send-to-device flow.
/// Distinct from the drag-active scale-up: this only covers the post-drop
/// progress + success/failure stretch.
enum DeviceSendState: Equatable {
    case idle
    case sending(completed: Int, total: Int)
    case success(count: Int)
    case error(String)
}

@Observable
final class AppState {
    var libraryFolder: URL? {
        didSet { LibraryFolder.save(libraryFolder) }
    }
    private(set) var index: BookIndex?
    private(set) var importer: LibraryImporter?

    /// Every bundled language profile, regardless of user enable/disable state.
    /// Use this for the manual locale picker — manual selection is unconstrained
    /// by what the user has chosen to auto-detect. Empty until `bootstrap()`
    /// finishes loading the bundled JSONs off-main.
    private(set) var allProfiles: [LanguageProfile] = []

    /// IDs of profiles the user has switched off in Settings. Persisted in
    /// UserDefaults via `DisabledProfilesStore`.
    private(set) var disabledProfileIDs: Set<String> = []

    /// Profiles eligible for auto-classification on import. Disabled profiles
    /// are filtered out; they never appear in classifier output.
    var enabledProfiles: [LanguageProfile] {
        allProfiles.filter { !disabledProfileIDs.contains($0.id) }
    }

    /// Per-profile enable toggle from Settings. Persisted.
    func setProfile(_ profileID: String, enabled: Bool) {
        if enabled { disabledProfileIDs.remove(profileID) } else { disabledProfileIDs.insert(profileID) }
        DisabledProfilesStore.save(disabledProfileIDs)
    }

    var books: [Book] = [] {
        didSet { recomputeCounts() }
    }
    var collections: [Collection] = []
    private(set) var device: (any BookDevice)?
    private(set) var deviceFilenames: Set<String> = []

    /// Number of books in each collection. Cached from `books`; cheaper than
    /// recomputing in every `LibrarySidebar` body evaluation.
    private(set) var collectionCounts: [UUID: Int] = [:]

    /// Number of books per locale tag. Same caching rationale as above.
    private(set) var languageCounts: [String: Int] = [:]

    /// Number of books per author name (verbatim — no normalisation). One
    /// book counts once per distinct author it credits.
    private(set) var authorCounts: [String: Int] = [:]

    private func recomputeCounts() {
        var coll: [UUID: Int] = [:]
        for book in books {
            for cid in book.collectionIDs {
                coll[cid, default: 0] += 1
            }
        }
        collectionCounts = coll

        // Aggregate by base BCP 47 code so the sidebar shows "Portuguese"
        // (summing pt, pt-PT, pt-BR) rather than each variant as a separate
        // row. Variant precision is still expressible via the search bar's
        // `language:pt-PT` syntax — sidebar is for navigation, search is
        // for filtering. `und` and empty tags are dropped: they're not a
        // navigable language.
        var lang: [String: Int] = [:]
        for book in books {
            guard let base = Self.baseLanguageCode(book.locale) else { continue }
            lang[base, default: 0] += 1
        }
        languageCounts = lang

        var auth: [String: Int] = [:]
        for book in books {
            // Split comma-joined entries so multi-author strings ("A, B, C")
            // surface as separate sidebar rows. Same set-dedupe so the same
            // name twice in one book counts once. Misclassifies "Wilde, Oscar"
            // as two rows — treated as broken metadata to fix in BookInspector.
            let unique = Set(book.authors.flatMap(Self.splitAuthors))
            for author in unique {
                auth[author, default: 0] += 1
            }
        }
        authorCounts = auth
    }

    /// Splits a raw author field on commas and trims. Empties drop out.
    /// Shared with `LibraryView`'s author filter so what the sidebar shows
    /// is what clicking it actually matches.
    static func splitAuthors(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Strips a BCP 47 tag down to its base language subtag. Returns nil
    /// for empty / "und" so unclassified books don't pollute the sidebar.
    private static func baseLanguageCode(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "und" { return nil }
        let base = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return base.isEmpty ? nil : base
    }

    /// Number of items currently being dragged inside the app. Zero when
    /// nothing is being dragged. The device tile reads this to scale up
    /// when *any* in-app drag is active, drawing attention as a drop target.
    var inAppDragCount: Int = 0

    /// State of the most recent send-to-device operation. Drives the device
    /// tile's morphing UI (idle → sending → success/error). Cleared back to
    /// idle after a brief display.
    var deviceSendState: DeviceSendState = .idle

    /// Currently visible toast, or nil when nothing is shown. Replaced on
    /// every `showToast` call (no stacking). Auto-dismissed by a task; the
    /// task is cancelled when superseded by a new toast.
    var currentToast: Toast?

    /// Live state of the current batch import, or nil when none is running /
    /// dismissed. Drives `ImportProgressSheet`.
    var importSession: ImportSession?

    /// The running batch-import task, held so `cancelImport` can stop it.
    private var importTask: Task<Void, Never>?

    /// User-loaded JS plugins used as search sources. All `.js` files in the
    /// plugins directory; replaced wholesale on reload. Empty until
    /// `reloadPluginSource()` runs (via `bootstrap()` or a user-triggered reload).
    private(set) var pluginSources: [PluginSource] = []

    /// IDs of plugins currently enabled for search. Persisted in
    /// `UserDefaults` under `enabledPluginIDs`. First-run default: all
    /// loaded plugins are enabled.
    private(set) var enabledPluginIDs: Set<String> = []

    /// Plugins currently enabled for search.
    var enabledPlugins: [PluginSource] {
        pluginSources.filter { enabledPluginIDs.contains($0.id) }
    }

    /// Looks up a loaded plugin by ID. Used to route a `PluginResult`'s
    /// download call back to the plugin that produced it.
    func plugin(withID id: String) -> PluginSource? {
        pluginSources.first(where: { $0.id == id })
    }

    private static let enabledPluginIDsKey = "enabledPluginIDs"
    private static let didInitPluginEnableStateKey = "didInitPluginEnableState"

    /// True while a plugin search is in flight (post-debounce, awaiting
    /// the plugin's `search()` Promise). Drives the trailing-icon spinner
    /// and the "searching…" empty state.
    var pluginSearchInFlight: Bool = false

    private(set) var cachedRegistries: [URL: CachedRegistry] = [:]
    var pluginRegistryRefreshInFlight: Bool = false
    private(set) var pluginUpdatesAvailable: Set<String> = []
    var hasPluginUpdates: Bool { !pluginUpdatesAvailable.isEmpty }
    /// Plugin IDs whose available update the user has already seen — set when
    /// the user opens the sources popover. The session-level badge dot
    /// (`hasUnacknowledgedPluginUpdates`) only shows for updates *not* in
    /// this set, so popping the popover once dismisses the dot until a
    /// genuinely new update lands. `pluginUpdatesAvailable` itself stays
    /// truthful (the Settings view still surfaces the count).
    private(set) var pluginUpdatesBadgeAcknowledged: Set<String> = []
    var hasUnacknowledgedPluginUpdates: Bool {
        !pluginUpdatesAvailable.subtracting(pluginUpdatesBadgeAcknowledged).isEmpty
    }
    func acknowledgePluginUpdatesBadge() {
        pluginUpdatesBadgeAcknowledged = pluginUpdatesAvailable
    }
    func updateAllAvailablePlugins() async {
        // Refresh first: the cached registry entry's sha can be stale while
        // the entry's `url` (which always points at `main`) serves the live
        // bytes. Downloading without a refresh hits a guaranteed sha
        // mismatch in `fetchPluginJS`.
        await refreshAllRegistries()
        for id in pluginUpdatesAvailable {
            guard let target = latestRegistryEntry(forID: id) else { continue }
            await updatePluginFromRegistry(target.entry, from: target.registryURL)
        }
    }

    /// Apply the latest available update for a single plugin. Refresh-first
    /// for the same reason as `updateAllAvailablePlugins` — the registry
    /// entry passed in by the caller may have been resolved from a stale
    /// cache.
    func applyPluginUpdate(id: String) async {
        await refreshAllRegistries()
        guard let target = latestRegistryEntry(forID: id) else {
            showToast(.error("No registry entry found for \(id)."))
            return
        }
        await updatePluginFromRegistry(target.entry, from: target.registryURL)
    }
    var allRegistryURLs: [URL] { PluginRegistryStore.allRegistryURLs() }
    var userAddedRegistryURLs: [URL] { PluginRegistryStore.userAddedRegistryURLs() }
    var defaultRegistryURL: URL { PluginRegistryStore.defaultRegistryURL }

    /// `SettingsSection.rawValue` to land on after `openWindow(settingsWindowID)`.
    /// Cleared by `SettingsRoot` once applied.
    var pendingSettingsSection: String?

    // Imperative AppKit handle for the library window, so "Add to Library" can
    // bring it forward. Not observed — plumbing, not view state.
    @ObservationIgnored weak var libraryWindow: NSWindow?

    /// Brings the library window to the front. Used when the user explicitly
    /// wants it — e.g. "Add to Library" from the reader.
    func showLibraryWindow() {
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    private nonisolated(unsafe) var mountTask: Task<Void, Never>?
    private nonisolated(unsafe) var unmountTask: Task<Void, Never>?
    private var sendStateResetTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

    init() {
        self.libraryFolder = LibraryFolder.load()
        self.disabledProfileIDs = DisabledProfilesStore.load()
        if let stored = UserDefaults.standard.array(forKey: Self.enabledPluginIDsKey) as? [String] {
            self.enabledPluginIDs = Set(stored)
        }
        startVolumeMonitoring()
    }

    /// Heavy startup work, kept out of `init()` so MainActor stays unblocked
    /// during the first SwiftUI render. Invoked from `LibraryView.task` so the
    /// window draws empty-state UI immediately and fills in as each step lands.
    ///
    /// Background: Sentry app-hang reports (TOMO-MACOS-2) sampled main mid-way
    /// through the first SwiftUI update pass. The cumulative cost of doing
    /// profile loading, device scanning, plugin JS reads, and JSContext parsing
    /// inside `init()` pushed startup past the 2 s threshold on slower hosts.
    func bootstrap() async {
        self.allProfiles = await Task.detached { LanguageProfileStore.loadBundled() }.value

        let detected = await Task.detached { DeviceScanner.detect() }.value
        self.device = detected
        if let detected {
            self.deviceFilenames = await Task.detached { detected.filenames() }.value
        } else {
            self.deviceFilenames = []
        }
        if let kindle = detected as? Kindle {
            Task.detached { await KindleSync.run(volumeURL: kindle.volumeURL) }
        }

        await reloadPluginSource()
        // Cached registry data only — Principle 5 forbids touching the
        // network without explicit user action. Refresh happens via the
        // "Check for updates" button in Plugins settings.
        loadCachedRegistryState()
    }

    private func persistEnabledPluginIDs() {
        UserDefaults.standard.set(Array(enabledPluginIDs), forKey: Self.enabledPluginIDsKey)
    }

    /// Per-plugin enable toggle from the sources popover. Persisted.
    func setPluginEnabled(_ pluginID: String, enabled: Bool) {
        if enabled { enabledPluginIDs.insert(pluginID) } else { enabledPluginIDs.remove(pluginID) }
        persistEnabledPluginIDs()
    }

    /// Re-runs plugin loading off-main: reads JS source files in a detached
    /// task, then constructs `PluginSource` instances on MainActor (where
    /// `JSContext` must live). Call after the user adds or removes a plugin
    /// file in the plugins directory, or from `bootstrap()`.
    ///
    /// One broken plugin doesn't prevent others from loading; the first
    /// error surfaces as a toast. Also applies the first-run "enable
    /// everything" default exactly once via a UserDefaults flag.
    ///
    /// Note: replacing `pluginSources` doesn't actively cancel in-flight
    /// `fetch` Tasks owned by prior `PluginHost`s. Those Tasks hop back to
    /// MainActor and call `resolve`/`reject` on JSValues whose contexts
    /// have been replaced — harmless (the resolved value is discarded by
    /// an abandoned Promise) but worth knowing. Productionisation should
    /// track in-flight tasks per host and cancel on reload.
    func reloadPluginSource() async {
        let read = await Task.detached { PluginDirectory.readAllPluginSources() }.value
        let result = PluginDirectory.loadAllPlugins(from: read.sources)
        self.pluginSources = result.plugins
        // Drop enabled IDs whose plugin file is gone so the set stays
        // tight to actually-loaded plugins.
        let loadedIDs = Set(result.plugins.map(\.id))
        if !enabledPluginIDs.isSubset(of: loadedIDs) {
            enabledPluginIDs.formIntersection(loadedIDs)
            persistEnabledPluginIDs()
        }
        // First-run for the per-plugin toggle: enable everything that loaded
        // so the user gets working search out of the box without a tour.
        if !UserDefaults.standard.bool(forKey: Self.didInitPluginEnableStateKey) {
            self.enabledPluginIDs = Set(pluginSources.map(\.id))
            persistEnabledPluginIDs()
            UserDefaults.standard.set(true, forKey: Self.didInitPluginEnableStateKey)
        }
        recomputePluginUpdateAvailable()
        pluginLogger.info("loaded \(result.plugins.count, privacy: .public) plugin(s)")
        if let err = read.firstError ?? result.firstError {
            showToast(.error("Plugin failed to load: \(err.localizedDescription)"))
        }
    }

    func installPlugin(from sourceURL: URL) async {
        guard let dir = PluginDirectory.directoryURL() else {
            showToast(.error("Couldn't locate plugins directory."))
            return
        }
        let destURL = dir.appending(path: sourceURL.lastPathComponent)
        let priorIDs = Set(pluginSources.map(\.id))
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }.value
            // Reload picks up the new file; reconcile (inside reload) writes
            // the install record keyed on the loaded plugin's actual id —
            // which can differ from the filename when the manifest declares
            // its own. Find what's new by set-difference.
            await reloadPluginSource()
            if let installed = pluginSources.first(where: { !priorIDs.contains($0.id) }) {
                if !enabledPluginIDs.contains(installed.id) {
                    setPluginEnabled(installed.id, enabled: true)
                }
                showToast(.info("Plugin installed."))
            }
        } catch {
            pluginLogger.error("install plugin failed: \(error.localizedDescription, privacy: .public)")
            showToast(.error("Couldn't install plugin: \(error.localizedDescription)"))
        }
    }

    // MARK: - Plugin registries

    /// Reads cached registry snapshots off disk into memory. Pure I/O on
    /// the app-support cache directory; no network. Called once at bootstrap
    /// so Plugins settings can render without waiting.
    func loadCachedRegistryState() {
        var cached: [URL: CachedRegistry] = [:]
        for url in PluginRegistryStore.allRegistryURLs() {
            if let c = PluginRegistryStore.cachedRegistry(at: url) {
                cached[url] = c
            }
        }
        self.cachedRegistries = cached
        recomputePluginUpdateAvailable()
    }

    /// An update is available when a registry has an entry for this plugin's
    /// id, the host satisfies its `minAppVersion`, and its `sha256` differs
    /// from what's installed. Sha is the change signal — there's no separate
    /// "installed version" to track.
    private func recomputePluginUpdateAvailable() {
        var updates: Set<String> = []
        for plugin in pluginSources {
            for cached in cachedRegistries.values {
                guard let entry = cached.registry.plugins.first(where: { $0.id == plugin.id })
                else { continue }
                guard isCompatible(entry: entry) else { continue }
                if entry.sha256.caseInsensitiveCompare(plugin.sha256) != .orderedSame {
                    updates.insert(plugin.id)
                }
            }
        }
        self.pluginUpdatesAvailable = updates
    }

    /// Finds the registry entry whose `id` and `sha256` match the installed
    /// plugin — that's the canonical "where did this come from" lookup,
    /// used to label rows and route Update clicks. Nil for manually-installed
    /// plugins or plugins whose source registry isn't currently cached.
    func registryOrigin(for plugin: PluginSource) -> (entry: PluginRegistryEntry, registryURL: URL)? {
        for (registryURL, cached) in cachedRegistries {
            if let entry = cached.registry.plugins.first(where: {
                $0.id == plugin.id
                    && $0.sha256.caseInsensitiveCompare(plugin.sha256) == .orderedSame
            }) {
                return (entry, registryURL)
            }
        }
        return nil
    }

    /// Latest registry entry for this id across all cached registries (newest
    /// version wins), regardless of sha. Used by the Update button to find
    /// what to fetch.
    func latestRegistryEntry(forID id: String) -> (entry: PluginRegistryEntry, registryURL: URL)? {
        var best: (PluginRegistryEntry, URL)?
        for (registryURL, cached) in cachedRegistries {
            guard let entry = cached.registry.plugins.first(where: { $0.id == id })
            else { continue }
            if let current = best {
                if PluginVersion.updateAvailable(installed: current.0.version, available: entry.version) {
                    best = (entry, registryURL)
                }
            } else {
                best = (entry, registryURL)
            }
        }
        return best
    }

    func isCompatible(entry: PluginRegistryEntry) -> Bool {
        guard let minRequired = entry.minAppVersion, !minRequired.isEmpty else { return true }
        return SemVerCompare.compare(AppVersion.current, minRequired) != .orderedAscending
    }

    /// Partial refresh is more useful than none — errors are surfaced but
    /// don't halt the loop.
    func refreshAllRegistries() async {
        guard !pluginRegistryRefreshInFlight else { return }
        pluginRegistryRefreshInFlight = true
        defer { pluginRegistryRefreshInFlight = false }

        let urls = PluginRegistryStore.allRegistryURLs()
        var firstError: Error?
        for url in urls {
            do {
                let cached = try await PluginRegistryStore.fetchRegistry(at: url)
                cachedRegistries[url] = cached
            } catch {
                pluginLogger.error(
                    "registry fetch failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if firstError == nil { firstError = error }
            }
        }
        recomputePluginUpdateAvailable()
        if let firstError {
            showToast(.error("Couldn't refresh registries: \(firstError.localizedDescription)"))
        }
    }

    func installPluginFromRegistry(_ entry: PluginRegistryEntry, from registryURL: URL) async {
        await fetchAndWrite(entry: entry, replace: false)
    }

    func updatePluginFromRegistry(_ entry: PluginRegistryEntry, from registryURL: URL) async {
        await fetchAndWrite(entry: entry, replace: true)
    }

    private func fetchAndWrite(entry: PluginRegistryEntry, replace: Bool) async {
        guard isCompatible(entry: entry) else {
            showToast(
                .error(
                    "\(entry.name) needs Tomo \(entry.minAppVersion ?? "?")+ — you have \(AppVersion.current)."
                ))
            return
        }
        do {
            let bytes = try await PluginRegistryStore.fetchPluginJS(entry)
            _ = try await Task.detached {
                try PluginDirectory.writePluginFile(id: entry.id, bytes: bytes, replace: replace)
            }.value
            await reloadPluginSource()
            if let installed = plugin(withID: entry.id), !enabledPluginIDs.contains(installed.id) {
                setPluginEnabled(installed.id, enabled: true)
            }
            showToast(.info(replace ? "Updated \(entry.name)." : "Installed \(entry.name)."))
        } catch {
            pluginLogger.error(
                "registry \(replace ? "update" : "install") failed for \(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            showToast(.error("Couldn't \(replace ? "update" : "install") \(entry.name): \(error.localizedDescription)"))
        }
    }

    func removeInstalledPlugin(id: String) async {
        do {
            try await Task.detached {
                try PluginDirectory.deletePluginFile(id: id)
            }.value
            await reloadPluginSource()
        } catch {
            pluginLogger.error(
                "remove plugin failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            showToast(.error("Couldn't remove plugin: \(error.localizedDescription)"))
        }
    }

    /// Fetches once to validate the JSON shape before persisting.
    func addUserRegistry(_ url: URL) async {
        guard !PluginRegistryStore.allRegistryURLs().contains(url) else {
            showToast(.error("Registry already added."))
            return
        }
        do {
            let cached = try await PluginRegistryStore.fetchRegistry(at: url)
            var current = PluginRegistryStore.userAddedRegistryURLs()
            current.append(url)
            PluginRegistryStore.setUserAddedRegistryURLs(current)
            cachedRegistries[url] = cached
            recomputePluginUpdateAvailable()
            showToast(.info("Added \(cached.registry.name)."))
        } catch {
            pluginLogger.error(
                "add registry failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            showToast(.error("Couldn't add registry: \(error.localizedDescription)"))
        }
    }

    func removeUserRegistry(_ url: URL) {
        guard url != PluginRegistryStore.defaultRegistryURL else { return }
        var current = PluginRegistryStore.userAddedRegistryURLs()
        guard let idx = current.firstIndex(of: url) else { return }
        current.remove(at: idx)
        PluginRegistryStore.setUserAddedRegistryURLs(current)
        cachedRegistries.removeValue(forKey: url)
        PluginRegistryStore.removeCachedRegistry(at: url)
        recomputePluginUpdateAvailable()
    }

    /// Replaces any current toast with `toast` and schedules its auto-dismiss.
    /// The previous dismiss task is cancelled so the new toast lives its full
    /// duration, even if it arrives before the old one would have expired.
    func showToast(_ toast: Toast) {
        toastDismissTask?.cancel()
        currentToast = toast
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: toast.dismissAfter)
            guard !Task.isCancelled else { return }
            // Only clear if this toast is still the active one.
            if self?.currentToast?.id == toast.id {
                self?.currentToast = nil
            }
        }
    }

    nonisolated deinit {
        mountTask?.cancel()
        unmountTask?.cancel()
    }

    func sendToDevice(book: Book) async {
        await sendBooksToDevice([book])
    }

    /// Sequentially copies books to the connected device, driving
    /// `deviceSendState` so the tile can morph through sending → success/error.
    /// Books that the device can't accept are filtered out before sending.
    func sendBooksToDevice(_ books: [Book]) async {
        guard let device else {
            deliveryLogger.error("send to device: no device connected")
            return
        }
        let toSend = books.filter { device.canAccept($0) }
        guard !toSend.isEmpty else { return }

        sendStateResetTask?.cancel()
        deviceSendState = .sending(completed: 0, total: toSend.count)

        var successes = 0
        var lastError: Error?
        for (index, book) in toSend.enumerated() {
            do {
                try await device.copy(book)
                successes += 1
                deliveryLogger.info(
                    "copied to \(device.displayName, privacy: .public): \(book.title, privacy: .public)")
                deviceSendState = .sending(completed: index + 1, total: toSend.count)
            } catch {
                lastError = error
                deliveryLogger.error("device copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        deviceFilenames = await Task.detached { device.filenames() }.value

        if let lastError, successes == 0 {
            deviceSendState = .error(lastError.localizedDescription)
        } else {
            deviceSendState = .success(count: successes)
        }

        sendStateResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.deviceSendState = .idle
        }
    }

    /// Bulk trash. Each delete runs independently; failures are logged
    /// (in `deleteBook`) but don't halt the loop. Partial-success is
    /// surfaced through the on-disk truth (loadBooks reflects what's left).
    func deleteBooks(_ books: [Book]) async {
        for book in books {
            await deleteBook(book)
        }
    }

    func removeFromDevice(book: Book) async {
        guard let device else { return }
        do {
            try await device.remove(book)
            deliveryLogger.info(
                "removed from \(device.displayName, privacy: .public): \(book.title, privacy: .public)")
            deviceFilenames = await Task.detached { device.filenames() }.value
        } catch {
            deliveryLogger.error("device remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bulk-removes files from the device by relative path. Used by the
    /// device contents sheet, which mixes library books (matched by
    /// filename) and orphans (paths with no library match) — both flow
    /// through the same path. Each failure is logged but doesn't halt
    /// the loop. Refreshes `deviceFilenames` at the end so the chip
    /// reflects the new on-device count.
    func removeFilesFromDevice(_ relativePaths: [String]) async {
        guard let device, !relativePaths.isEmpty else { return }
        for path in relativePaths {
            do {
                try await device.removeFile(at: path)
                deliveryLogger.info(
                    "removed from \(device.displayName, privacy: .public): \(path, privacy: .public)")
            } catch {
                deliveryLogger.error(
                    "device remove failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        deviceFilenames = await Task.detached { device.filenames() }.value
    }

    func ejectDevice() async {
        guard let device else { return }
        do {
            try await device.eject()
            deliveryLogger.info("ejected device: \(device.displayName, privacy: .public)")
            // The unmount notification clears `device` and `deviceFilenames`.
        } catch {
            deliveryLogger.error("eject failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startVolumeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        mountTask = Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSWorkspace.didMountNotification) {
                await self?.refreshDeviceState()
            }
        }
        unmountTask = Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSWorkspace.didUnmountNotification) {
                await self?.refreshDeviceState()
            }
        }
    }

    /// Detection and enumeration run detached, same as `bootstrap()`:
    /// `DeviceScanner.detect()` stats every entry in /Volumes (a stale
    /// network mount can block that for seconds) and `filenames()` walks
    /// the device's documents folder over USB. Both fire on *every*
    /// mount/unmount notification — not just e-readers — so keeping them
    /// off main is what prevents app-hang reports when any volume comes
    /// and goes.
    private func refreshDeviceState() async {
        let detected = await Task.detached { DeviceScanner.detect() }.value
        device = detected
        if let detected {
            deviceFilenames = await Task.detached { detected.filenames() }.value
        } else {
            deviceFilenames = []
        }
        if let kindle = detected as? Kindle {
            Task.detached { await KindleSync.run(volumeURL: kindle.volumeURL) }
        }
    }

    func loadBooks() async {
        await openIndexIfNeeded()
        guard let index else { return }
        do {
            async let booksTask = index.all()
            async let collectionsTask = index.collections()
            self.books = try await booksTask
            self.collections = try await collectionsTask
        } catch {
            libraryLogger.error("load books failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Maps `Book.collectionIDs` to the collection *names* — what the sidecar
    /// stores. Sorted for stable serialisation.
    private func collectionNames(for ids: Set<UUID>) -> [String] {
        collections
            .filter { ids.contains($0.id) }
            .map(\.name)
            .sorted()
    }

    /// Imports a file into the library and returns the resulting `Book`.
    /// Returns nil on failure and surfaces a toast to the user. Callers
    /// that don't need the imported book can ignore the return value —
    /// the standard refresh still happens.
    ///
    /// `collection` is the optional collection to add the new book to right
    /// after import — used by the source-download flow to honour the active
    /// sidebar collection ("downloads will add to <collection>"). Manual
    /// imports leave it nil and the book lands at the library root.
    @discardableResult
    func importBook(
        from url: URL, collection: UUID? = nil
    ) async -> Book? {
        await openIndexIfNeeded()
        guard let importer else {
            libraryLogger.error("import called without index/importer")
            showToast(.error("Library isn't ready yet."))
            return nil
        }
        guard let libraryFolder else {
            libraryLogger.error("import called without library folder")
            showToast(.error("Choose a library folder before importing."))
            return nil
        }
        do {
            let imported = try await importer.importBook(
                from: url, into: libraryFolder, profiles: enabledProfiles)
            await loadBooks()
            if let collection {
                // Resolve the up-to-date Book (loadBooks may have replaced
                // the imported instance with a sidecar-driven copy) and
                // add it to the collection. addBook re-loads on its own,
                // so a second loadBooks call here would be redundant.
                if let resolved = books.first(where: { $0.id == imported.id }) {
                    await addBook(resolved, to: collection)
                }
            }
            return imported
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showToast(.error("\(url.lastPathComponent): \(message)"))
            libraryLogger.error("import failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Batch import: copy many files into the library in one O(n) pass with a
    /// live progress sheet, deduping against the library and within the batch.
    /// Fire-and-forget — sets up `importSession` + `importTask` and returns so
    /// the drop handler can complete synchronously.
    func importBooks(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Supersede any session still on screen.
        importTask?.cancel()
        let session = ImportSession(urls: urls)
        importSession = session
        importTask = Task { [weak self] in
            await self?.runImport(session)
        }
    }

    private func runImport(_ session: ImportSession) async {
        await openIndexIfNeeded()
        guard let libraryFolder, let index else {
            for i in session.rows.indices {
                session.rows[i].status = .failed("Library isn't ready.")
            }
            session.isRunning = false
            if importSession === session { importTask = nil }
            return
        }

        let profiles = enabledProfiles
        let claims = FingerprintClaims(
            Dictionary(
                books.map {
                    (
                        bookFingerprint(title: $0.title, firstAuthor: $0.authors.first),
                        ImportMatch(title: $0.title, author: $0.authors.first)
                    )
                },
                uniquingKeysWith: { _, latest in latest }))
        let urls = session.rows.map(\.url)
        // Process in chunks so a huge batch doesn't swamp the cooperative pool;
        // the heavy work is disk + EPUB parsing, so a handful in flight is plenty.
        // Each chunk runs concurrently; session updates happen on the main actor
        // between chunks (the task-group closure is nonisolated and can't touch
        // `session`). Per-chunk progress is plenty granular for the UI.
        let cap = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)

        var imported: [Book] = []
        var idx = 0
        while idx < urls.count {
            if Task.isCancelled {
                for i in idx..<urls.count where session.rows[i].status == .pending {
                    session.rows[i].status = .failed("Cancelled")
                }
                break
            }

            let base = idx
            let chunk = Array(urls[base..<min(base + cap, urls.count)])
            for j in chunk.indices { session.rows[base + j].status = .importing }

            let outcomes: [(Int, ImportOutcome)] = await withTaskGroup(
                of: (Int, ImportOutcome).self
            ) { group in
                for (j, url) in chunk.enumerated() {
                    group.addTask {
                        let outcome = await LibraryImporter.prepareImport(
                            from: url,
                            into: libraryFolder,
                            profiles: profiles,
                            claims: claims,
                            allowDuplicate: false
                        )
                        return (base + j, outcome)
                    }
                }
                var results: [(Int, ImportOutcome)] = []
                for await result in group { results.append(result) }
                return results
            }

            for (rowIdx, outcome) in outcomes {
                switch outcome {
                case .imported(let book):
                    imported.append(book)
                    session.rows[rowIdx].status = .imported
                case .alreadyInLibrary:
                    session.rows[rowIdx].status = .alreadyInLibrary
                case .possibleDuplicate(_, let matched):
                    session.rows[rowIdx].status = .possibleDuplicate(
                        matchedLabel: importMatchLabel(matched))
                case .failed(_, let message):
                    session.rows[rowIdx].status = .failed(message)
                }
            }

            idx += chunk.count
        }

        // One bulk index write + one reload for the whole batch. Sidecars are
        // already on disk, so an index-write failure is recoverable via the
        // next disk sync — we still surface it.
        if !imported.isEmpty {
            do {
                try await index.addBooks(imported)
            } catch {
                libraryLogger.error(
                    "batch index write failed: \(error.localizedDescription, privacy: .public)")
                showToast(.error("Imported to disk, but the library index didn't update."))
            }
            await loadBooks()
        }

        session.isRunning = false
        if importSession === session { importTask = nil }
    }

    /// Cancels the running batch. Files already imported stay; pending ones are
    /// marked cancelled.
    func cancelImport() {
        importTask?.cancel()
    }

    /// Closes the import sheet (does not undo anything).
    func dismissImportSession() {
        importSession = nil
    }

    /// Re-attempts a single failed row, or force-imports a duplicate row.
    /// Bypasses dedup (claims: nil) so a deliberate retry always proceeds if
    /// disk allows. Indexes immediately and reloads.
    func retryImportRow(_ rowID: ImportSession.Row.ID) {
        guard let session = importSession,
            // Per-row actions are only valid once the batch has settled —
            // retrying mid-run would race the batch-end index write + reload.
            !session.isRunning,
            let idx = session.rows.firstIndex(where: { $0.id == rowID })
        else { return }
        let url = session.rows[idx].url
        Task { [weak self] in
            guard let self else { return }
            await openIndexIfNeeded()
            guard let libraryFolder, let index else { return }
            session.rows[idx].status = .importing
            let outcome = await LibraryImporter.prepareImport(
                from: url,
                into: libraryFolder,
                profiles: enabledProfiles,
                claims: nil,
                allowDuplicate: true
            )
            switch outcome {
            case .imported(let book):
                do {
                    try await index.add(book)
                    session.rows[idx].status = .imported
                    await loadBooks()
                } catch {
                    session.rows[idx].status = .failed("Couldn't update the library index.")
                }
            case .alreadyInLibrary:
                session.rows[idx].status = .alreadyInLibrary
            case .possibleDuplicate(_, let matched):
                session.rows[idx].status = .possibleDuplicate(
                    matchedLabel: importMatchLabel(matched))
            case .failed(_, let message):
                session.rows[idx].status = .failed(message)
            }
        }
    }

    /// Human-readable explanation of a fingerprint match, shown under a
    /// possible-duplicate row. No "already in your library" suffix — the match
    /// may be an earlier file in the same batch, not yet in the library.
    private func importMatchLabel(_ match: ImportMatch) -> String {
        if let author = match.author, !author.isEmpty {
            return "Matches “\(match.title)” by \(author)"
        }
        return "Matches “\(match.title)”"
    }

    func updateBook(_ book: Book) async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("update: no index")
            return
        }

        // Two-step disk relocate, in order: folder (Author/Title (Year)/)
        // then file slug (author-title-year.ext). Folder first so the slug
        // rename happens inside the new folder and we don't have to undo a
        // file move across folder boundaries on failure.
        let relocated: FolderRelocateResult
        if let libraryFolder {
            relocated = await Task.detached {
                relocateBookFolderIfChanged(book, libraryRoot: libraryFolder)
            }.value
        } else {
            relocated = FolderRelocateResult(book: book, outcome: .noChange)
        }

        // Bail out on collision without persisting. Library-on-disk-is-truth
        // means the sidecar / index can't claim a layout we couldn't apply.
        if case .collision(let target) = relocated.outcome {
            let label =
                target.deletingLastPathComponent().lastPathComponent
                + "/" + target.lastPathComponent
            showToast(
                .error(
                    "Another book already lives at \(label). Rename it (or this one) before saving."
                ))
            return
        }

        let originalFolder: URL? = {
            if case .moved(let folder) = relocated.outcome { return folder }
            return nil
        }()
        let renamed = await Task.detached { renamedToSlugIfChanged(relocated.book) }.value
        let bookForSidecar = renamed.book
        let bookFolder = bookForSidecar.fileURL.deletingLastPathComponent()
        let names = collectionNames(for: bookForSidecar.collectionIDs)
        do {
            try await Task.detached {
                try MetadataSidecar.write(bookForSidecar, collectionNames: names, to: bookFolder)
            }.value
            try await index.update(bookForSidecar)

            // Success — old author folder is often empty after a relocate.
            // Prune it (and any further-empty ancestors) up to the library
            // root. Cleanup is best-effort: a failure here doesn't roll back
            // the edit.
            if let libraryFolder, let originalFolder {
                let oldAuthorFolder = originalFolder.deletingLastPathComponent()
                await Task.detached {
                    pruneEmptyAncestors(from: oldAuthorFolder, stoppingAt: libraryFolder)
                }.value
            }

            await loadBooks()
            libraryLogger.info("updated: \(bookForSidecar.title, privacy: .public)")
        } catch {
            // Sidecar / index write failed after disk moves — undo them in
            // reverse so the on-disk layout still resolves through the old
            // sidecar's stored fileName.
            if renamed.didRename {
                try? await Task.detached {
                    try FileManager.default.moveItem(
                        at: bookForSidecar.fileURL,
                        to: relocated.book.fileURL
                    )
                }.value
            }
            if let originalFolder {
                let currentFolder = relocated.book.fileURL.deletingLastPathComponent()
                try? await Task.detached {
                    try FileManager.default.moveItem(at: currentFolder, to: originalFolder)
                }.value
            }
            libraryLogger.error("update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(named name: String) async -> Collection? {
        await openIndexIfNeeded()
        guard let index else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let collection = try await index.createCollection(named: trimmed)
            await persistCollectionsToDisk()
            await loadBooks()
            libraryLogger.info("created collection: \(trimmed, privacy: .public)")
            return collection
        } catch {
            libraryLogger.error(
                "create collection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func renameCollection(id: UUID, to newName: String) async {
        await openIndexIfNeeded()
        guard let index else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await index.renameCollection(id: id, to: trimmed)
            await persistCollectionsToDisk()
            // Sidecars store the old name; re-write each affected book so the
            // on-disk truth follows the rename.
            let affectedBooks = books.filter { $0.collectionIDs.contains(id) }
            for book in affectedBooks {
                await rewriteSidecar(for: book, newCollectionIDs: book.collectionIDs)
            }
            await loadBooks()
        } catch {
            libraryLogger.error(
                "rename collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteCollection(id: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        // Books that lose membership need their sidecars rewritten.
        let affectedBooks = books.filter { $0.collectionIDs.contains(id) }
        do {
            try await index.deleteCollection(id: id)
            await persistCollectionsToDisk()
            for book in affectedBooks {
                var remaining = book.collectionIDs
                remaining.remove(id)
                await rewriteSidecar(for: book, newCollectionIDs: remaining)
            }
            await loadBooks()
        } catch {
            libraryLogger.error(
                "delete collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Snapshots the index's current collection definitions to
    /// `<library>/.tomo/collections.json`. Called after any mutation that
    /// changes the collection set (create / rename / delete) and at the end
    /// of a disk sync to capture sidecar-driven auto-creations.
    private func persistCollectionsToDisk() async {
        guard let libraryFolder, let index else { return }
        do {
            let collections = try await index.collections()
            try await Task.detached { [libraryFolder] in
                try CollectionsFile.write(collections, in: libraryFolder)
            }.value
        } catch {
            libraryLogger.error(
                "persist collections.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func addBook(_ book: Book, to collectionID: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        guard !book.collectionIDs.contains(collectionID) else { return }
        do {
            try await index.addBook(book.id, to: collectionID)
            var newIDs = book.collectionIDs
            newIDs.insert(collectionID)
            await rewriteSidecar(for: book, newCollectionIDs: newIDs)
            await loadBooks()
        } catch {
            libraryLogger.error(
                "add to collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeBook(_ book: Book, from collectionID: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        guard book.collectionIDs.contains(collectionID) else { return }
        do {
            try await index.removeBook(book.id, from: collectionID)
            var newIDs = book.collectionIDs
            newIDs.remove(collectionID)
            await rewriteSidecar(for: book, newCollectionIDs: newIDs)
            await loadBooks()
        } catch {
            libraryLogger.error(
                "remove from collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-writes a book's sidecar with an updated collection-membership set.
    /// Membership is mirrored to disk so a rebuild from sidecars reconstructs
    /// the same groupings.
    private func rewriteSidecar(for book: Book, newCollectionIDs: Set<UUID>) async {
        let bookFolder = book.fileURL.deletingLastPathComponent()
        let names = collectionNames(for: newCollectionIDs)
        let bookForSidecar = book
        do {
            try await Task.detached {
                try MetadataSidecar.write(bookForSidecar, collectionNames: names, to: bookFolder)
            }.value
        } catch {
            libraryLogger.error("sidecar rewrite failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setCover(for book: Book, fromFile url: URL) async {
        let ext = url.pathExtension.lowercased().isEmpty ? "jpg" : url.pathExtension.lowercased()
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            await writeCover(data, ext: ext, for: book)
        } catch {
            libraryLogger.error("cover read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setCover(for book: Book, image: NSImage) async {
        guard let data = pngData(from: image) else {
            libraryLogger.error("cover encode to PNG failed")
            return
        }
        await writeCover(data, ext: "png", for: book)
    }

    /// Direct write path for cover bytes we already hold (e.g. JPEG fetched
    /// from Open Library / Google Books). Skips the NSImage→PNG round-trip
    /// — both because it preserves the source's quality and because
    /// `NSImage(data:)` from a JPEG often surfaces no `tiffRepresentation`
    /// until forced, which makes `pngData` silently nil.
    func setCover(for book: Book, fromData data: Data, ext: String) async {
        let normalised = ext.lowercased().isEmpty ? "jpg" : ext.lowercased()
        await writeCover(data, ext: normalised, for: book)
    }

    func removeCover(for book: Book) async {
        // The user's explicit "remove cover" — we do delete the file. The
        // implicit "replace cover" path (`writeCover`) keeps the old one
        // around since picking a new cover is a softer signal of intent.
        if let coverURL = book.coverURL {
            try? await Task.detached {
                try FileManager.default.removeItem(at: coverURL)
            }.value
        }
        var updated = book
        updated.coverPath = nil
        await persistCoverChange(updated)
    }

    private func writeCover(_ data: Data, ext: String, for book: Book) async {
        let bookFolder = book.fileURL.deletingLastPathComponent()
        // Unique-per-save filename. Same path + same name = identical `URL`,
        // and SwiftUI's view diffing then skips re-evaluating any
        // `LocalCoverImage` body — so the cached `@State image` would stay
        // even though the bytes on disk just changed. A unique URL per save
        // is the natural change-signal that propagates through the parent
        // view tree without bespoke notifications.
        let suffix = String(UUID().uuidString.prefix(6).lowercased())
        let newFileName = "cover-\(suffix).\(ext)"
        let newURL = bookFolder.appending(component: newFileName)

        do {
            try await Task.detached {
                try data.write(to: newURL, options: .atomic)
            }.value
        } catch {
            libraryLogger.error("cover write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Old cover file is left on disk on purpose: covers don't affect
        // identity, the user might want to revert via Finder, and the
        // unique-suffix naming means no collisions accumulate within the
        // active session.
        var updated = book
        updated.coverPath = newFileName
        await persistCoverChange(updated)
    }

    /// Persists a cover-only change (new `coverPath`) to the sidecar + index
    /// without going through `updateBook`'s folder-relocate / slug-rename
    /// pipeline. The cover lives inside the book's folder; changing it
    /// doesn't move or rename the book on disk, so the heavy machinery is
    /// both unnecessary and a source of bugs — it has previously refused
    /// cover changes with phantom folder-collision errors when the
    /// canonical-folder URL disagreed with the current-folder URL by string
    /// representation alone. Sidecar is canonical per Principle 1; index
    /// update follows but failures only desync the cache (next bootstrap
    /// rebuilds from sidecars).
    private func persistCoverChange(_ book: Book) async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("cover persist: no index")
            return
        }
        let bookFolder = book.fileURL.deletingLastPathComponent()
        let names = collectionNames(for: book.collectionIDs)
        do {
            try await Task.detached {
                try MetadataSidecar.write(book, collectionNames: names, to: bookFolder)
            }.value
        } catch {
            libraryLogger.error(
                "cover sidecar write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            try await index.update(book)
        } catch {
            libraryLogger.error(
                "cover index update failed: \(error.localizedDescription, privacy: .public)")
        }
        await loadBooks()
    }

    func deleteBook(_ book: Book) async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("delete: no index")
            return
        }
        let bookFolder = book.fileURL.deletingLastPathComponent()
        let authorFolder = bookFolder.deletingLastPathComponent()
        let libFolder = libraryFolder
        do {
            try await Task.detached {
                try FileManager.default.trashItem(at: bookFolder, resultingItemURL: nil)
                // Best-effort cleanup of now-empty author folder. Never trash the
                // library folder itself, even if it's empty.
                if let libFolder,
                    authorFolder.standardizedFileURL != libFolder.standardizedFileURL,
                    LibraryFolder.isEmpty(authorFolder)
                {
                    do {
                        try FileManager.default.trashItem(at: authorFolder, resultingItemURL: nil)
                    } catch {
                        libraryLogger.warning(
                            "author folder cleanup failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }.value
            try await index.delete(book)
            await loadBooks()
            libraryLogger.info("trashed: \(book.title, privacy: .public)")
        } catch {
            libraryLogger.error("delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reconciles the index with the on-disk library: adds sidecars not yet
    /// indexed, removes index rows whose folders are gone, resolves collection
    /// memberships from sidecars. Idempotent and additive — safe to call on
    /// every appear and every library-folder change.
    ///
    /// This is how the disk-truth principle is enforced at runtime. The index
    /// is disposable; the library is the source of truth. A second machine
    /// pointed at the same iCloud folder, a fresh install, a deleted DB —
    /// they all rebuild themselves through here without user action.
    func syncWithDisk() async {
        await openIndexIfNeeded()
        guard let index else { return }
        guard let libraryFolder else {
            // No folder set: just refresh the UI from whatever's in the index.
            // The grid placeholder ("Open Settings…") handles the empty case.
            await loadBooks()
            return
        }
        do {
            // 1. One-time migration: if no collections.json exists yet but the
            //    DB has collections (carried forward from before this change),
            //    dump them to disk so we don't lose UUIDs / sortOrder. Runs
            //    only on first sync after upgrade.
            let didMigrate = try await migrateLegacyCollectionsIfNeeded(
                in: libraryFolder, index: index)

            // 2. Read collection definitions from disk and seed the index
            //    (wipes previous library's collections — fixes the
            //    ghost-collection bug on library-folder change). nil =
            //    fresh library with no JSON yet.
            let onDiskCollections =
                try await Task.detached { [libraryFolder] in
                    try CollectionsFile.read(in: libraryFolder)
                }.value
            try await index.seedCollections(onDiskCollections ?? [])

            // 3. Walk the library folder, read sidecars. Detached: this is
            //    one read + JSON decode per book, and doing it on main was
            //    enough to trip the app-hang threshold on large libraries.
            let folders = try await LibraryFolder.bookFolders(in: libraryFolder)
            let sidecars = await Task.detached {
                var sidecars: [LoadedSidecar] = []
                for folder in folders {
                    do {
                        sidecars.append(try MetadataSidecar.read(from: folder))
                    } catch {
                        libraryLogger.error(
                            "sync: skipped \(folder.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                return sidecars
            }.value
            try Task.checkCancellation()
            let onDisk = Set(sidecars.map(\.book.id))
            let inIndex = try await index.allIDs()
            let toAdd = onDisk.subtracting(inIndex)
            let orphans = inIndex.subtracting(onDisk)

            for id in orphans {
                try Task.checkCancellation()
                try await index.delete(id: id)
            }

            // 4. Re-attach memberships for ALL sidecars (not just new ones),
            //    since we just wiped book_collections in step 2.
            for sidecar in sidecars {
                try Task.checkCancellation()
                if toAdd.contains(sidecar.book.id) {
                    try await index.add(sidecar.book)
                }
                for name in sidecar.collectionNames {
                    // getOrCreate so a sidecar referencing a not-yet-on-disk
                    // collection still resolves. New collections are picked
                    // up in the persist step below.
                    let collection = try await index.getOrCreateCollection(named: name)
                    try await index.addBook(sidecar.book.id, to: collection.id)
                }
            }

            // 5. If a sidecar auto-created a collection in step 4, it's now
            //    in the DB but not on disk. Snapshot the DB to JSON so disk
            //    catches up. Skipped when migration already wrote the file.
            if !didMigrate {
                await persistCollectionsToDisk()
            }

            libraryLogger.info(
                "sync: \(sidecars.count) on disk, +\(toAdd.count) -\(orphans.count)")
            await loadBooks()
            await migrateBookFilenames()
        } catch is CancellationError {
            libraryLogger.info("sync cancelled")
        } catch {
            libraryLogger.error("sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-time per-book migration: books imported before the slug-filename
    /// change live on disk as `book.epub` / `book.pdf`. Rename them in place
    /// so they carry a unique, identity-bearing name that Kindle (and other
    /// downstream consumers that key off filename) won't collide on.
    /// Failures are logged and skipped — the book stays at its legacy name
    /// and gets retried on the next sync. After the first successful run,
    /// the cheap `hasPrefix` filter makes this a no-op.
    private func migrateBookFilenames() async {
        let legacy = books.filter { $0.fileURL.lastPathComponent.hasPrefix("book.") }
        guard !legacy.isEmpty, let index else { return }
        var migrated = 0
        for book in legacy {
            let renamed = await Task.detached { renamedToSlugIfChanged(book) }.value
            guard renamed.didRename else { continue }
            let bookForPersist = renamed.book
            let bookFolder = bookForPersist.fileURL.deletingLastPathComponent()
            let names = collectionNames(for: bookForPersist.collectionIDs)
            do {
                try await Task.detached {
                    try MetadataSidecar.write(
                        bookForPersist, collectionNames: names, to: bookFolder)
                }.value
                try await index.update(bookForPersist)
                migrated += 1
            } catch {
                // Sidecar / index write failed after a successful rename —
                // roll the rename back so the on-disk state stays consistent.
                try? await Task.detached {
                    try FileManager.default.moveItem(
                        at: bookForPersist.fileURL, to: book.fileURL)
                }.value
                libraryLogger.error(
                    "filename migration failed for \(book.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if migrated > 0 {
            libraryLogger.info(
                "filename migration: renamed \(migrated, privacy: .public) book(s)")
            await loadBooks()
        }
    }

    private static let didMigrateLegacyCollectionsKey = "didMigrateLegacyCollections"

    /// One-time migration: pre-v1, collection definitions only existed in the
    /// SQLite index. Post-v1 they live in `<library>/.tomo/collections.json`.
    /// On the very first sync after upgrade, dump the index's collections to
    /// the current library's JSON so UUIDs / sortOrder survive. Gated by a
    /// `UserDefaults` flag so it can't fire again — critical, otherwise
    /// switching to a fresh library folder would re-migrate the *previous*
    /// library's stale DB rows into the new folder's JSON. Returns true if
    /// the file was written.
    private func migrateLegacyCollectionsIfNeeded(
        in libraryFolder: URL, index: BookIndex
    ) async throws -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.didMigrateLegacyCollectionsKey) else {
            return false
        }
        defer { UserDefaults.standard.set(true, forKey: Self.didMigrateLegacyCollectionsKey) }
        let exists = await Task.detached { [libraryFolder] in
            CollectionsFile.exists(in: libraryFolder)
        }.value
        guard !exists else { return false }
        let dbCollections = try await index.collections()
        guard !dbCollections.isEmpty else { return false }
        try await Task.detached { [libraryFolder] in
            try CollectionsFile.write(dbCollections, in: libraryFolder)
        }.value
        libraryLogger.info(
            "migrated \(dbCollections.count, privacy: .public) collection(s) → collections.json")
        return true
    }

    private func openIndexIfNeeded() async {
        guard index == nil else { return }
        do {
            let opened = try await Task.detached { try BookIndex() }.value
            self.index = opened
            self.importer = LibraryImporter(index: opened)
        } catch {
            indexLogger.error("failed to open index: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
        /// Toggles a `MockDevice` so the device tile UI can be exercised
        /// without an e-reader plugged in. Wired to the Debug menu in
        /// `TomoApp`. The mock pretends a few books are already on the
        /// device too, so the on-device check badge / dim states render.
        func toggleFakeDevice() {
            if device is MockDevice {
                device = nil
                deviceFilenames = []
                deviceSendState = .idle
            } else {
                // Pretend the first ~half of the library is already on the
                // device so card states (check badge + dimmed missing) read
                // visibly differently.
                let half = books.prefix(books.count / 2)
                let pretendOnDevice = Set(half.map { fatSafeFilename($0.fileURL.lastPathComponent) })
                let mock = MockDevice(mockFilenames: pretendOnDevice)
                device = mock
                deviceFilenames = pretendOnDevice
            }
        }

        /// Cycles the device send state through its non-idle visuals so the
        /// device tile's morph (sending → success → error) can be inspected
        /// without actually copying files.
        func cycleFakeSendState() {
            switch deviceSendState {
            case .idle:
                deviceSendState = .sending(completed: 1, total: 3)
            case .sending(let completed, let total) where completed < total:
                deviceSendState = .sending(completed: completed + 1, total: total)
            case .sending:
                deviceSendState = .success(count: 3)
            case .success:
                deviceSendState = .error("Test error")
            case .error:
                deviceSendState = .idle
            }
        }
    #endif
}
