import AppKit
import Foundation
import os

nonisolated let deliveryLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "delivery")

/// A connected e-reader. Implementations live alongside this file
/// (`Kindle.swift`, eventually `Kobo.swift`, etc). The library/UI never
/// depends on a specific device — it just talks to this protocol.
nonisolated protocol BookDevice: Sendable {
  /// Stable identifier for change detection (volume path is fine).
  var id: String { get }

  /// User-facing display name ("Kindle", "Kobo Clara", etc).
  var displayName: String { get }

  /// Mounted volume URL — used by `eject` and for the user to see in the UI.
  var volumeURL: URL { get }

  /// Optional warning surfaced in the UI when the device can't actually
  /// receive books (e.g. firmware too old for EPUB). Non-nil = warn.
  var compatibilityWarning: String? { get }

  /// File extensions (lowercase, no dot) the device's home-screen indexer
  /// will actually recognise. A book whose extension isn't in this set will
  /// be silently ignored by the device even if copied successfully — so we
  /// refuse the copy upfront rather than mislead the user. This is distinct
  /// from what the device's renderer can theoretically read; Kindle's
  /// renderer reads EPUB on FW 5.16+ but its scanner doesn't index them.
  var supportedFormats: Set<String> { get }

  /// Filenames currently on the device, in whatever destination folder
  /// the device uses. Used to detect "already on device".
  func filenames() -> Set<String>

  /// What this book's filename will be on the device after sanitisation.
  /// Kept consistent across copy/remove/match.
  func deviceFilename(for book: Book) -> String

  /// Copies a book to the device's destination folder. fsync after write.
  func copy(_ book: Book) async throws

  /// Removes a book file from the device.
  func remove(_ book: Book) async throws

  /// Programmatic eject. macOS handles the underlying unmount.
  func eject() async throws
}

extension BookDevice {
  /// True if this device will end up with an indexable copy of the
  /// book — either by direct copy (the book's format is already in
  /// `supportedFormats`) or via conversion (a registered converter
  /// can produce one of the device's native formats from this
  /// book's format). Conversion runs lazily inside `copy` when the
  /// user actually drops the book, so accepting here only commits
  /// to a *path*, not the work itself.
  nonisolated func canAccept(_ book: Book) -> Bool {
    deliveryRoute(for: book) != nil
  }

  /// What this book's filename will be on the device after sanitisation
  /// AND any conversion the device will run. Kept consistent across
  /// copy / remove / "is this on device" so post-conversion books
  /// (e.g. an EPUB that lands as `<stem>.azw3`) match correctly.
  nonisolated func deviceFilename(for book: Book) -> String {
    let stem = book.fileURL.deletingPathExtension().lastPathComponent
    switch deliveryRoute(for: book) {
    case .passthrough:
      return fatSafeFilename(book.fileURL.lastPathComponent)
    case .convert(let target):
      return fatSafeFilename(stem + "." + target.rawValue)
    case .none:
      // canAccept would have rejected; fall back to the original
      // name so callers get a sensible string instead of a crash.
      return fatSafeFilename(book.fileURL.lastPathComponent)
    }
  }

  /// Internal helper. Returns the route the device will take for
  /// this book — either pass-through copy or conversion to a
  /// specific format — or nil if neither applies. `canAccept` and
  /// `deviceFilename` and `Kindle.copy` all flow from this so the
  /// three views stay in lockstep.
  nonisolated func deliveryRoute(for book: Book) -> DeliveryRoute? {
    let sourceExt = book.fileURL.pathExtension.lowercased()
    if supportedFormats.contains(sourceExt) {
      return .passthrough
    }
    guard let sourceFormat = FileFormat(rawValue: sourceExt) else {
      return nil
    }
    for supported in supportedFormats {
      guard let target = FileFormat(rawValue: supported) else { continue }
      if ConversionRegistry.default
        .converter(from: sourceFormat, to: target) != nil
      {
        return .convert(to: target)
      }
    }
    return nil
  }
}

/// How a device will deliver a book — direct copy or via conversion.
nonisolated enum DeliveryRoute: Sendable, Equatable {
  case passthrough
  case convert(to: FileFormat)
}

/// Errors any device implementation can throw at the device boundary.
enum BookDeviceError: LocalizedError {
  case alreadyOnDevice
  case copyFailed(underlying: Error)
  case removeFailed(underlying: Error)
  case ejectFailed(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .alreadyOnDevice: "This book is already on the device."
    case .copyFailed(let e): "Couldn't copy to the device: \(e.localizedDescription)"
    case .removeFailed(let e): "Couldn't remove from the device: \(e.localizedDescription)"
    case .ejectFailed(let e): "Couldn't eject the device: \(e.localizedDescription)"
    }
  }
}

/// Scans `/Volumes` and instantiates the appropriate device driver. New
/// device types are added by appending an init attempt below.
nonisolated enum DeviceScanner {
  static func detect() -> (any BookDevice)? {
    let fm = FileManager.default
    let volumes = URL(fileURLWithPath: "/Volumes")
    guard
      let entries = try? fm.contentsOfDirectory(
        at: volumes,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    for url in entries {
      if let kindle = Kindle(volumeURL: url) { return kindle }
      // Future: if let kobo = Kobo(volumeURL: url) { return kobo }
    }
    return nil
  }
}

/// Shared FAT32-safe filename normalisation. Most e-readers expose FAT/exFAT
/// volumes, so any driver that copies files should use this to avoid
/// macOS-legal-but-FAT-illegal filenames silently failing.
nonisolated func fatSafeFilename(_ name: String) -> String {
  let illegal = CharacterSet(charactersIn: "<>:\"/\\|?*")
  var cleaned = name.components(separatedBy: illegal).joined(separator: "_")
  cleaned = cleaned.unicodeScalars
    .map { $0.value < 0x20 ? "_" : String($0) }
    .joined()
  if cleaned.count > 200 {
    let ext = (cleaned as NSString).pathExtension
    let stem = (cleaned as NSString).deletingPathExtension
    let trimmedStem = String(stem.prefix(200 - ext.count - 1))
    cleaned = ext.isEmpty ? trimmedStem : "\(trimmedStem).\(ext)"
  }
  return cleaned
}

/// Eject helper used by all USB mass-storage device drivers.
nonisolated func ejectVolume(_ url: URL) async throws {
  do {
    try await Task.detached {
      try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }.value
  } catch {
    throw BookDeviceError.ejectFailed(underlying: error)
  }
}
