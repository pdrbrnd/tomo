import Foundation
import Testing

@testable import Tomo

@Suite("DisabledProfilesStore")
struct DisabledProfilesStoreTests {

    /// Round-trip persistence: what you save is what you read back, regardless
    /// of insertion order. Uses a fresh in-memory `UserDefaults` so we don't
    /// touch the real app's preferences plist.
    @Test func roundTripPersistsAcrossLoads() {
        let defaults = makeDefaults()
        DisabledProfilesStore.save(["en-GB", "en-US"], to: defaults)
        #expect(DisabledProfilesStore.load(from: defaults) == ["en-GB", "en-US"])
    }

    @Test func emptyStateLoadsAsEmptySet() {
        let defaults = makeDefaults()
        #expect(DisabledProfilesStore.load(from: defaults).isEmpty)
    }

    @Test func savingReplacesPreviousSet() {
        // Disable two, then re-enable one — the persisted set should be
        // exactly the latest write, not a union with prior state.
        let defaults = makeDefaults()
        DisabledProfilesStore.save(["en-GB", "en-US"], to: defaults)
        DisabledProfilesStore.save(["en-GB"], to: defaults)
        #expect(DisabledProfilesStore.load(from: defaults) == ["en-GB"])
    }

    /// Filtering a profile list by the disabled set excludes only what the
    /// user has switched off. This is the contract every classifier caller
    /// relies on — disabled profiles never reach the scorer.
    @Test func filteringExcludesDisabledProfiles() {
        let defaults = makeDefaults()
        DisabledProfilesStore.save(["en-GB"], to: defaults)
        let disabled = DisabledProfilesStore.load(from: defaults)
        let all: [String] = ["pt-PT", "pt-BR", "en-US", "en-GB"]
        let enabled = all.filter { !disabled.contains($0) }
        #expect(enabled == ["pt-PT", "pt-BR", "en-US"])
    }

    /// Each test gets a fresh `UserDefaults` keyed by a UUID-suffixed suite
    /// so concurrent runs don't bleed state into each other.
    private func makeDefaults() -> UserDefaults {
        let suite = "tomo.tests.disabled-profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
