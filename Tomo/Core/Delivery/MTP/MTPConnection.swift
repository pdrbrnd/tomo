import Foundation
import IOKit
import IOUSBHost
import Synchronization

/// Errors at the MTP boundary. Surfaced to the user through
/// `BookDeviceError`, so messages say what to do, not what broke.
nonisolated enum MTPError: LocalizedError {
    case deviceNotFound
    /// Another process holds the USB interface — Calibre, Android File
    /// Transfer, OpenMTP. macOS gives the interface to one owner at a time.
    case deviceBusy
    case transport(String)
    case response(operation: UInt16, code: UInt16)
    case malformed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "The Kindle is no longer connected."
        case .deviceBusy:
            "Another app is using the Kindle. Quit Calibre, Android File Transfer, or OpenMTP and try again."
        case .transport(let detail):
            "USB transfer failed (\(detail)). Unplug the Kindle, plug it back in, and try again."
        case .response(let op, let code):
            String(format: "The Kindle refused the request (operation 0x%04X, response 0x%04X).", op, code)
        case .malformed(let detail):
            "The Kindle sent an unexpected reply (\(detail))."
        case .notFound(let path):
            "Couldn't find \(path) on the Kindle."
        }
    }
}

/// A connected MTP device as seen in the IORegistry — found without opening
/// it, so detection never contends with an in-flight transfer.
nonisolated struct MTPDeviceDescriptor: Sendable, Equatable {
    let serial: String
    let productName: String
}

/// One MTP session over raw USB (`IOUSBHost`). Apple's ImageCaptureCore
/// only claims class-6 "Still Image" interfaces; Kindles from 2024 on expose
/// a vendor-specific (class 255) interface named "MTP", so we speak the
/// protocol ourselves.
///
/// Usage is always `MTPConnection.withSession(serial:) { conn in … }`: open,
/// do the work, close. Sessions are short-lived on purpose — no lifecycle to
/// manage across plug/unplug, and nothing is held open when the user pulls
/// the cable. A process-wide lock serialises sessions because the USB
/// interface is exclusive.
///
/// All calls block; run them off the main actor.
nonisolated final class MTPConnection {
    static let amazonVendorID = 0x1949

    private static let sessionLock = Mutex(())

    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let maxPacketSize: Int
    private var transactionID: UInt32 = 0
    /// Bytes read past the end of the previous container. Devices end each
    /// container with a short packet, so this is normally empty.
    private var pending = Data()

    private static let commandTimeout: TimeInterval = 10
    /// Generous: after a large SendObject the Kindle can take a while to
    /// flush before it sends the response.
    private static let responseTimeout: TimeInterval = 120
    private static let readChunk = 256 * 1024
    private static let writeChunk = 1024 * 1024

    // MARK: - Discovery

    /// Amazon devices exposing an MTP interface whose product string says
    /// "Kindle" (Fire tablets share the vendor ID but aren't e-readers).
    static func connectedKindles() -> [MTPDeviceDescriptor] {
        var results: [MTPDeviceDescriptor] = []
        forEachMTPInterface { service in
            guard
                let product = parentProperty(service, "kUSBProductString") as? String,
                product.localizedCaseInsensitiveContains("kindle"),
                let serial = parentProperty(service, "kUSBSerialNumberString") as? String
            else { return false }
            results.append(MTPDeviceDescriptor(serial: serial, productName: product))
            return false
        }
        return results
    }

    /// Opens a session on the Kindle with this USB serial, runs `body`, and
    /// closes it again — on success and on throw.
    static func withSession<T>(
        serial: String, _ body: (MTPConnection) throws(MTPError) -> T
    ) throws(MTPError) -> T {
        try sessionLock.withLock { _ throws(MTPError) in
            var found: io_service_t = 0
            forEachMTPInterface { service in
                guard parentProperty(service, "kUSBSerialNumberString") as? String == serial
                else { return false }
                IOObjectRetain(service)
                found = service
                return true
            }
            guard found != 0 else { throw .deviceNotFound }
            defer { IOObjectRelease(found) }

            let connection = try MTPConnection(service: found)
            defer { connection.interface.destroy() }
            try connection.openSession()
            defer { _ = try? connection.transact(.closeSession) }
            return try body(connection)
        }
    }

    /// "Eject" for MTP: sends SET_CONFIGURATION 0, which unconfigures the
    /// device. The Kindle treats that as the host letting go — it leaves the
    /// "connected to computer" screen and stays usable on the cable — and
    /// macOS doesn't reconfigure it until it's unplugged and replugged.
    /// Takes the session lock so it can't cut an in-flight transfer short.
    static func unconfigure(serial: String) throws(MTPError) {
        try sessionLock.withLock { _ throws(MTPError) in
            let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            matching[kIOPropertyMatchKey] = [
                "idVendor": amazonVendorID, "kUSBSerialNumberString": serial,
            ]
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { throw .deviceNotFound }
            defer { IOObjectRelease(service) }
            do {
                let device = try IOUSBHostDevice(
                    __ioService: service, options: [], queue: nil, interestHandler: nil)
                defer { device.destroy() }
                try device.__configure(withValue: 0, matchInterfaces: false)
            } catch {
                if (error as NSError).code == Int(Int32(bitPattern: 0xE000_02C5)) { throw .deviceBusy }
                throw .transport(error.localizedDescription)
            }
        }
    }

    /// Calls `visit` for each vendor-specific USB interface named "MTP" on an
    /// Amazon device until it returns true.
    private static func forEachMTPInterface(_ visit: (io_service_t) -> Bool) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
                == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = property(service, "kUSBString") as? String
            let interfaceClass = property(service, "bInterfaceClass") as? Int
            let vendor = parentProperty(service, "idVendor") as? Int
            guard vendor == amazonVendorID, interfaceClass == 255, name == "MTP" else { continue }
            if visit(service) { return }
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func parentProperty(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    // MARK: - Transport

    private init(service: io_service_t) throws(MTPError) {
        do {
            interface = try IOUSBHostInterface(
                __ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            // kIOReturnExclusiveAccess: someone else has the interface open.
            if (error as NSError).code == Int(Int32(bitPattern: 0xE000_02C5)) { throw .deviceBusy }
            throw .transport(error.localizedDescription)
        }

        var inPipe: IOUSBHostPipe?
        var outPipe: IOUSBHostPipe?
        var packetSize = 512
        var cursor = UnsafeRawPointer(interface.interfaceDescriptor)
            .assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(
            interface.configurationDescriptor, interface.interfaceDescriptor, cursor)
        {
            cursor = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            guard IOUSBGetEndpointType(endpoint) == 2 else { continue }  // bulk only
            let address = Int(IOUSBGetEndpointAddress(endpoint))
            guard let pipe = try? interface.copyPipe(withAddress: address) else { continue }
            if IOUSBGetEndpointDirection(endpoint) == 1 {
                inPipe = pipe
            } else {
                outPipe = pipe
                packetSize = Int(UInt16(littleEndian: endpoint.pointee.wMaxPacketSize) & 0x7FF)
            }
        }
        guard let inPipe, let outPipe else {
            interface.destroy()
            throw .transport("no bulk endpoints")
        }
        bulkIn = inPipe
        bulkOut = outPipe
        maxPacketSize = max(packetSize, 1)
    }

    private func write(_ data: Data, timeout: TimeInterval = commandTimeout) throws(MTPError) {
        var sent = 0
        do {
            try bulkOut.__sendIORequest(
                with: NSMutableData(data: data), bytesTransferred: &sent, completionTimeout: timeout)
        } catch {
            throw .transport(error.localizedDescription)
        }
    }

    /// Reads one whole container (header + body) from the bulk-in pipe.
    private func readContainer(timeout: TimeInterval) throws(MTPError) -> Data {
        var buffer = pending
        pending = Data()
        var expected: Int?
        while expected.map({ buffer.count < $0 }) ?? true {
            if expected == nil, buffer.count >= 4 {
                let length = Int(try PTP.parseHeader(buffer.prefix(PTP.headerSize).padded(to: 12)).length)
                guard length >= PTP.headerSize else { throw .malformed("container length \(length)") }
                expected = length
                continue
            }
            let chunk = NSMutableData(length: Self.readChunk)!
            var got = 0
            do {
                try bulkIn.__sendIORequest(
                    with: chunk, bytesTransferred: &got, completionTimeout: timeout)
            } catch {
                throw .transport(error.localizedDescription)
            }
            // A zero-length packet terminating the previous transfer — skip.
            buffer.append(Data(bytes: chunk.bytes, count: got))
        }
        let length = expected!
        if buffer.count > length { pending = buffer.suffix(from: buffer.startIndex + length) }
        return Data(buffer.prefix(length))
    }

    private func nextTransactionID() -> UInt32 {
        transactionID &+= 1
        return transactionID
    }

    private func openSession() throws(MTPError) {
        // Session-less operations use transaction ID 0.
        try write(PTP.command(.openSession, transactionID: 0, params: [1]))
        let response = try readContainer(timeout: Self.commandTimeout)
        let code = try PTP.parseHeader(response).code
        // A previous session left open by an aborted transfer is fine to reuse.
        guard code == PTP.Response.ok || code == PTP.Response.sessionAlreadyOpen else {
            throw .response(operation: PTP.Operation.openSession.rawValue, code: code)
        }
    }

    /// One command → optional data-in → response round trip. Returns the
    /// incoming data payload (empty if none) and the response params.
    @discardableResult
    private func transact(
        _ op: PTP.Operation, _ params: [UInt32] = [], send payload: Data? = nil
    ) throws(MTPError) -> (data: Data, params: [UInt32]) {
        let tid = nextTransactionID()
        try write(PTP.command(op, transactionID: tid, params: params))
        if let payload {
            try sendDataPhase(op, tid: tid, length: payload.count) { offset, count in
                payload.subdata(in: offset..<offset + count)
            }
        }
        return try readResponse(op)
    }

    @discardableResult
    private func readResponse(_ op: PTP.Operation, timeout: TimeInterval = commandTimeout)
        throws(MTPError) -> (data: Data, params: [UInt32])
    {
        var incoming = Data()
        while true {
            let container = try readContainer(timeout: timeout)
            let header = try PTP.parseHeader(container)
            switch PTP.ContainerType(rawValue: header.type) {
            case .data:
                incoming = container.dropFirst(PTP.headerSize)
            case .response:
                guard header.code == PTP.Response.ok else {
                    throw .response(operation: op.rawValue, code: header.code)
                }
                return (Data(incoming), PTP.responseParams(container))
            default:
                throw .malformed("container type \(header.type)")
            }
        }
    }

    /// Streams a data container of `length` bytes, pulling the payload in
    /// chunks from `chunk(offset, count)`.
    private func sendDataPhase(
        _ op: PTP.Operation, tid: UInt32, length: Int,
        chunk: (_ offset: Int, _ count: Int) throws(MTPError) -> Data
    ) throws(MTPError) {
        var outgoing = PTP.dataHeader(op, transactionID: tid, payloadLength: length)
        var offset = 0
        repeat {
            let count = min(Self.writeChunk - outgoing.count, length - offset)
            outgoing.append(try chunk(offset, count))
            offset += count
            try write(outgoing, timeout: Self.responseTimeout)
            outgoing = Data()
        } while offset < length
        // A transfer that ends exactly on a packet boundary needs a
        // zero-length packet so the device knows it's complete.
        if (PTP.headerSize + length) % maxPacketSize == 0 {
            var sent = 0
            do {
                try bulkOut.__sendIORequest(
                    with: nil, bytesTransferred: &sent, completionTimeout: Self.commandTimeout)
            } catch {
                throw .transport(error.localizedDescription)
            }
        }
    }

    // MARK: - Operations

    func storageIDs() throws(MTPError) -> [UInt32] {
        try PTP.parseUInt32Array(transact(.getStorageIDs).data)
    }

    struct Object {
        let handle: UInt32
        let info: PTP.ObjectInfo
    }

    func children(storage: UInt32, parent: UInt32) throws(MTPError) -> [Object] {
        let handles = try PTP.parseUInt32Array(
            transact(.getObjectHandles, [storage, 0, parent]).data)
        return try handles.map { handle throws(MTPError) in
            Object(handle: handle, info: try PTP.decodeObjectInfo(transact(.getObjectInfo, [handle]).data))
        }
    }

    func child(named name: String, storage: UInt32, parent: UInt32) throws(MTPError) -> Object? {
        try children(storage: storage, parent: parent).first { $0.info.filename == name }
    }

    /// Resolves a `/`-separated path of folder names from `parent`.
    func folder(at path: String, storage: UInt32, from parent: UInt32 = PTP.rootParent)
        throws(MTPError) -> UInt32
    {
        var current = parent
        for name in path.split(separator: "/").map(String.init) {
            guard let next = try child(named: name, storage: storage, parent: current),
                next.info.isFolder
            else { throw .notFound(path) }
            current = next.handle
        }
        return current
    }

    func getObject(_ handle: UInt32) throws(MTPError) -> Data {
        try transact(.getObject, [handle]).data
    }

    func delete(_ handle: UInt32) throws(MTPError) {
        try transact(.deleteObject, [handle])
    }

    /// Uploads `fileURL` into `parent` as `name`, replacing any existing
    /// object of that name — MTP has no overwrite, so a re-send would
    /// otherwise leave two files with the same name.
    func upload(_ fileURL: URL, as name: String, storage: UInt32, parent: UInt32) throws(MTPError) {
        let handle: FileHandle
        let size: Int
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw .transport("couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        guard size <= Int(UInt32.max) else { throw .transport("file larger than 4 GB") }

        try upload(name: name, size: size, storage: storage, parent: parent) { _, count throws(MTPError) in
            do {
                guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                    throw MTPError.transport("short read from \(fileURL.lastPathComponent)")
                }
                return bytes
            } catch let error as MTPError {
                throw error
            } catch {
                throw .transport(error.localizedDescription)
            }
        }
    }

    func upload(_ data: Data, as name: String, storage: UInt32, parent: UInt32) throws(MTPError) {
        try upload(name: name, size: data.count, storage: storage, parent: parent) { offset, count in
            data.subdata(in: offset..<offset + count)
        }
    }

    private func upload(
        name: String, size: Int, storage: UInt32, parent: UInt32,
        chunk: (_ offset: Int, _ count: Int) throws(MTPError) -> Data
    ) throws(MTPError) {
        if let existing = try child(named: name, storage: storage, parent: parent) {
            try delete(existing.handle)
        }
        let info = PTP.ObjectInfo(
            storageID: storage, format: PTP.ObjectFormat.undefined, size: UInt32(size),
            parent: parent, filename: name, modified: nil)
        try transact(.sendObjectInfo, [storage, parent], send: PTP.encodeObjectInfo(info))

        let tid = nextTransactionID()
        try write(PTP.command(.sendObject, transactionID: tid))
        try sendDataPhase(.sendObject, tid: tid, length: size, chunk: chunk)
        try readResponse(.sendObject, timeout: Self.responseTimeout)
    }
}

extension Data {
    /// Zero-pads to `length` so a partial header can be parsed for its
    /// length field before the rest arrives.
    fileprivate nonisolated func padded(to length: Int) -> Data {
        count >= length ? self : self + Data(count: length - count)
    }
}
