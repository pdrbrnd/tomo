#if DEBUG

    import Foundation

    /// Debug-only stand-in for a real BookDevice. Lets the device tile UI be
    /// exercised without an actual e-reader plugged in. All file ops are
    /// no-ops with brief delays so transitions read naturally.
    nonisolated struct MockDevice: BookDevice {
        let id = "mock-kindle"
        let displayName = "Kindle"
        let volumeURL = URL(fileURLWithPath: "/tmp/MockKindle")
        let compatibilityWarning: String? = nil
        let supportedFormats: Set<String> = ["epub", "azw3", "mobi"]

        /// Pretend the device already has these — useful to test the
        /// on-device check badge and dim states for cards in the grid.
        let mockFilenames: Set<String>

        init(mockFilenames: Set<String> = []) {
            self.mockFilenames = mockFilenames
        }

        func filenames() -> Set<String> { mockFilenames }

        func copy(_ book: Book) async throws {
            try? await Task.sleep(for: .milliseconds(350))
        }

        func remove(_ book: Book) async throws {
            try? await Task.sleep(for: .milliseconds(150))
        }

        func eject() async throws {}
    }

#endif
