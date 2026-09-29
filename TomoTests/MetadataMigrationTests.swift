import Foundation
import Testing

@testable import Tomo

@Suite("MetadataMigration")
struct MetadataMigrationTests {

    @Test func fillsSeriesFromEPUBAndBumpsVersion() {
        let book = makeLegacyBook(series: [])
        let migrated = MetadataMigration.migrated(book, from: .opf(makeOPF(series: [saga])))

        #expect(migrated.series == [saga])
        #expect(migrated.metadataVersion == Book.currentMetadataVersion)
        #expect(!MetadataMigration.needsMigration(migrated))
    }

    @Test func keepsSeriesAlreadySet() {
        let typed = BookSeries(name: "Typed By User", position: "1")
        let book = makeLegacyBook(series: [typed])
        let migrated = MetadataMigration.migrated(book, from: .opf(makeOPF(series: [saga])))

        #expect(migrated.series == [typed])
    }

    @Test func nothingToReadOnlyBumpsVersion() {
        let book = makeLegacyBook(series: [])
        let migrated = MetadataMigration.migrated(book, from: .none)

        #expect(migrated.series.isEmpty)
        #expect(migrated.metadataVersion == Book.currentMetadataVersion)
    }

    private let saga = BookSeries(name: "Saga", position: "3")

    private func makeLegacyBook(series: [BookSeries]) -> Book {
        Book(
            id: UUID(),
            title: "Title",
            authors: ["Author"],
            series: series,
            year: nil,
            locale: "en",
            coverPath: nil,
            dateAdded: Date(timeIntervalSince1970: 0),
            fileURL: URL(fileURLWithPath: "/library/Author/Title/author-title.epub"),
            metadataVersion: 1
        )
    }

    private func makeOPF(series: [BookSeries]) -> ParsedOPF {
        ParsedOPF(
            title: "Title",
            authors: ["Author"],
            series: series,
            version: "3.0",
            language: "en",
            date: nil,
            identifier: nil,
            manifest: [],
            spineHrefs: [],
            coverItem: nil,
            navItem: nil,
            ncxItem: nil
        )
    }
}
