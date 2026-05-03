import Foundation
import ZIPFoundation
import os

struct EPUBMetadata: Sendable {
    let title: String
    let authors: [String]
    let language: String?
    let year: Int?
    let coverImage: CoverImage?

    struct CoverImage: Sendable {
        let data: Data
        let pathExtension: String
    }
}

enum EPUBMetadataError: LocalizedError {
    case cannotOpenArchive
    case missingContainer
    case missingOPFPath
    case missingOPF
    case missingTitle
    case malformedXML

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: "Could not open the EPUB archive."
        case .missingContainer: "EPUB is missing META-INF/container.xml."
        case .missingOPFPath: "EPUB container.xml does not point to an OPF file."
        case .missingOPF: "EPUB OPF file is missing."
        case .missingTitle: "EPUB does not declare a title."
        case .malformedXML: "EPUB metadata XML is malformed."
        }
    }
}

extension EPUBMetadata {
    nonisolated static func read(from url: URL) throws -> EPUBMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBMetadataError.cannotOpenArchive
        }

        let containerXML = try extract(from: archive, at: "META-INF/container.xml", whenMissing: .missingContainer)
        let opfPath = try parseOPFPath(containerXML)
        let opfXML = try extract(from: archive, at: opfPath, whenMissing: .missingOPF)
        let opf = try parseOPF(opfXML)
        let cover = readCover(from: archive, opfPath: opfPath, coverHref: opf.coverHref)

        return EPUBMetadata(
            title: opf.title,
            authors: opf.authors,
            language: opf.language,
            year: opf.year,
            coverImage: cover
        )
    }
}

private nonisolated func extract(from archive: Archive, at path: String, whenMissing: EPUBMetadataError) throws -> Data {
    guard let entry = archive[path] else { throw whenMissing }
    var data = Data()
    _ = try archive.extract(entry) { data.append($0) }
    return data
}

private nonisolated func parseOPFPath(_ xml: Data) throws -> String {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBMetadataError.malformedXML
    }
    let nodes = (try? doc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path")) ?? []
    guard let path = nodes.first?.stringValue, !path.isEmpty else {
        throw EPUBMetadataError.missingOPFPath
    }
    return path
}

private struct OPFData {
    let title: String
    let authors: [String]
    let language: String?
    let year: Int?
    let coverHref: String?
}

private nonisolated func parseOPF(_ xml: Data) throws -> OPFData {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBMetadataError.malformedXML
    }

    func first(_ xpath: String) -> String? {
        let nodes = (try? doc.nodes(forXPath: xpath)) ?? []
        return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func all(_ xpath: String) -> [String] {
        let nodes = (try? doc.nodes(forXPath: xpath)) ?? []
        return nodes
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    guard let title = first("//*[local-name()='title']"), !title.isEmpty else {
        throw EPUBMetadataError.missingTitle
    }

    let authors = all("//*[local-name()='creator']")
    let language = first("//*[local-name()='language']")
    let year = all("//*[local-name()='date']")
        .compactMap { Int($0.prefix(4)) }
        .first

    let coverHref: String? = {
        // EPUB 3: <item properties="cover-image" .../>
        if let href = first("//*[local-name()='item' and contains(@properties, 'cover-image')]/@href"),
           !href.isEmpty {
            return href
        }
        // EPUB 2: <meta name="cover" content="ID"/> + matching item
        guard let id = first("//*[local-name()='meta' and @name='cover']/@content"), !id.isEmpty else {
            return nil
        }
        return first("//*[local-name()='item' and @id='\(id)']/@href")
    }()

    return OPFData(title: title, authors: authors, language: language, year: year, coverHref: coverHref)
}

private nonisolated func readCover(from archive: Archive, opfPath: String, coverHref: String?) -> EPUBMetadata.CoverImage? {
    guard let coverHref else { return nil }
    let opfDir = (opfPath as NSString).deletingLastPathComponent
    let coverPath = opfDir.isEmpty ? coverHref : "\(opfDir)/\(coverHref)"
    guard let entry = archive[coverPath] else {
        metadataLogger.error("cover entry not found at path: \(coverPath, privacy: .public)")
        return nil
    }
    var data = Data()
    do {
        _ = try archive.extract(entry) { data.append($0) }
    } catch {
        metadataLogger.error("cover extract failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }
    return EPUBMetadata.CoverImage(
        data: data,
        pathExtension: (coverHref as NSString).pathExtension
    )
}
