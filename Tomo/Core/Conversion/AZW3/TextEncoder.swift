import Foundation

/// Slices a combined-text byte stream into `TextRecord`s of at most
/// 4096 bytes each, attaching the appropriate trailing-bytes payload
/// to each. Direct port of leotaku/mobi's `textToRecords`.
///
/// Input must be the UTF-8 encoded concatenation of HTML + CSS flows,
/// in the order the FDST record will declare. `chapters` describes
/// where each chapter starts and ends in that byte stream; the
/// trailing-bytes payload uses it to emit chapter-strand hints per
/// record.
nonisolated func textToRecords(
    text: Data,
    chapters: [ChapterInfo]
) -> [TextRecord] {
    let provider = TrailProvider(chapters: chapters)

    var recordCount = text.count / TextRecord.maxSize
    if text.count % TextRecord.maxSize != 0 { recordCount += 1 }

    var records: [TextRecord] = []
    records.reserveCapacity(recordCount)
    for i in 0..<recordCount {
        let from = i * TextRecord.maxSize
        let to = min(from + TextRecord.maxSize, text.count)
        let slice = text.subdata(in: from..<to)
        var trail = provider.get(from: from, to: to)
        // Multibyte overlap only matters when there's a next record
        // to spill into. The last record's last bytes either complete
        // a sequence or terminate the document.
        if to < text.count {
            trail.multibyte = multibyteOverlap(in: slice)
        }
        records.append(TextRecord(text: slice, trail: trail))
    }
    return records
}
