import Foundation
import IOKit

/// Emits whenever an Amazon USB device is attached or detached. MTP Kindles
/// never mount a volume, so `NSWorkspace` mount notifications don't fire for
/// them — this is their equivalent trigger for re-running device detection.
///
/// Events are coarse ("something changed") on purpose: the consumer just
/// re-runs `DeviceScanner.detect()`, which reads the current state.
nonisolated enum USBDeviceEvents {
    static func stream(vendorID: Int = MTPConnection.amazonVendorID) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = Box(continuation)
            let refcon = Unmanaged.passRetained(box).toOpaque()
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                Unmanaged<Box>.fromOpaque(refcon).release()
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "com.pdrbrnd.tomo.usb-events")
            IONotificationPortSetDispatchQueue(port, queue)

            let callback: IOServiceMatchingCallback = { refcon, iterator in
                drain(iterator)
                guard let refcon else { return }
                Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().continuation.yield()
            }

            var iterators: [io_iterator_t] = []
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                // Watch interfaces, not devices: the MTP interface is what
                // detection looks for, so its arrival means it's ready.
                // The vendor filter must go through IOPropertyMatch — a bare
                // top-level `idVendor` key never matches from user space.
                let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
                matching[kIOPropertyMatchKey] = ["idVendor": vendorID]
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(
                    port, type, matching, callback, refcon, &iterator)
                guard result == KERN_SUCCESS else { continue }
                // Notifications only arm once the existing matches are drained.
                drain(iterator)
                iterators.append(iterator)
            }

            let resources = Resources(port: port, iterators: iterators, refcon: refcon)
            continuation.onTermination = { _ in
                queue.async { resources.release() }
            }
        }
    }

    private final class Box: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    /// IOKit handles torn down on the notification queue when the stream ends.
    private final class Resources: @unchecked Sendable {
        let port: IONotificationPortRef
        let iterators: [io_iterator_t]
        let refcon: UnsafeMutableRawPointer

        init(port: IONotificationPortRef, iterators: [io_iterator_t], refcon: UnsafeMutableRawPointer) {
            self.port = port
            self.iterators = iterators
            self.refcon = refcon
        }

        func release() {
            iterators.forEach { IOObjectRelease($0) }
            IONotificationPortDestroy(port)
            Unmanaged<Box>.fromOpaque(refcon).release()
        }
    }
}

/// Releases every pending entry. File-level (not a static member) so the
/// IOKit callback can call it without capturing context — it's passed to C
/// as a function pointer.
private nonisolated func drain(_ iterator: io_iterator_t) {
    while case let object = IOIteratorNext(iterator), object != 0 {
        IOObjectRelease(object)
    }
}
