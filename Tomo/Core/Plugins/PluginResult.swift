import Foundation

/// One label / value pair the inspector will render below the canonical
/// metadata rows. Plugins decide what to surface (publisher, ISBN, subjects,
/// etc.) and the inspector mirrors them in order.
struct PluginField: Hashable, Sendable {
    let key: String
    let value: String
}

/// Mirrors the JS plugin's result shape. Plugins return JS objects with these
/// fields; we lift them into Swift here. `id` is whatever the plugin uses to
/// uniquely identify the result on its own side — opaque to us.
struct PluginResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let authors: [String]
    let year: Int?
    let language: String
    let format: String
    let sizeBytes: Int?
    let coverURL: URL?
    let detailURL: URL?
    /// Ordered list of additional inspector rows. The plugin's order is
    /// preserved as-is (it knows what's most relevant). Empty is fine.
    let metadata: [PluginField]

    init(
        id: String,
        title: String,
        authors: [String],
        year: Int?,
        language: String,
        format: String,
        sizeBytes: Int?,
        coverURL: URL? = nil,
        detailURL: URL? = nil,
        metadata: [PluginField] = []
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.language = language
        self.format = format
        self.sizeBytes = sizeBytes
        self.coverURL = coverURL
        self.detailURL = detailURL
        self.metadata = metadata
    }

    /// Lifts a JS-side dictionary into a `PluginResult`. Returns nil if the
    /// dictionary lacks an id+title — minimum viable result.
    static func from(jsValue dict: [String: Any]) -> PluginResult? {
        guard
            let id = dict["id"] as? String,
            let title = dict["title"] as? String,
            !id.isEmpty, !title.isEmpty
        else { return nil }

        let authors: [String] = (dict["authors"] as? [String]) ?? []
        let year = dict["year"] as? Int
        let language = (dict["language"] as? String) ?? ""
        let format = ((dict["format"] as? String) ?? "epub").lowercased()
        let sizeBytes = dict["sizeBytes"] as? Int
        let coverURL = (dict["coverURL"] as? String).flatMap(URL.init(string:))
        let detailURL = (dict["detailURL"] as? String).flatMap(URL.init(string:))
        // Plugin contract: metadata is an array of `{ key, value }` objects.
        // Order is preserved. Entries missing either field are skipped.
        let metadata: [PluginField] = ((dict["metadata"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let key = entry["key"] as? String,
                let value = entry["value"] as? String,
                !key.isEmpty, !value.isEmpty
            else { return nil }
            return PluginField(key: key, value: value)
        }

        return PluginResult(
            id: id,
            title: title,
            authors: authors,
            year: year,
            language: language,
            format: format,
            sizeBytes: sizeBytes,
            coverURL: coverURL,
            detailURL: detailURL,
            metadata: metadata
        )
    }

    /// Serialises back to the dict shape the plugin expects when it receives
    /// a result back via `download(result)`.
    func toJSDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "authors": authors,
            "language": language,
            "format": format,
            "metadata": metadata.map { ["key": $0.key, "value": $0.value] },
        ]
        if let year { dict["year"] = year }
        if let sizeBytes { dict["sizeBytes"] = sizeBytes }
        if let coverURL { dict["coverURL"] = coverURL.absoluteString }
        if let detailURL { dict["detailURL"] = detailURL.absoluteString }
        return dict
    }

    /// Returns a copy with `coverURL` replaced. Used by the app-side cover
    /// enricher to fill in covers the plugin didn't supply, without
    /// requiring plugins to know about iTunes / Open Library themselves.
    func with(coverURL newURL: URL?) -> PluginResult {
        PluginResult(
            id: id,
            title: title,
            authors: authors,
            year: year,
            language: language,
            format: format,
            sizeBytes: sizeBytes,
            coverURL: newURL,
            detailURL: detailURL,
            metadata: metadata)
    }
}

/// Query passed to a plugin's `search()`.
///
/// `text` is the free-text portion (whatever the user typed that wasn't a
/// `field:value` token). The other fields are parsed structured constraints
/// that the user can express via the search syntax — see `QueryParser`.
/// Plugins consume what they understand and ignore the rest.
struct PluginQuery: Sendable {
    let text: String
    let title: String?
    let author: String?
    let language: String?
    let isbn: String?
    let format: String?
    let year: Int?
    let publisher: String?

    init(
        text: String,
        title: String? = nil,
        author: String? = nil,
        language: String? = nil,
        isbn: String? = nil,
        format: String? = nil,
        year: Int? = nil,
        publisher: String? = nil
    ) {
        self.text = text
        self.title = title
        self.author = author
        self.language = language
        self.isbn = isbn
        self.format = format
        self.year = year
        self.publisher = publisher
    }

    /// True when every structured field is empty AND `text` is empty.
    /// Callers use this to skip a no-op plugin call.
    var isEmpty: Bool {
        text.isEmpty
            && title == nil && author == nil && language == nil
            && isbn == nil && format == nil && year == nil
            && publisher == nil
    }

    func toJSDictionary() -> [String: Any] {
        var dict: [String: Any] = ["text": text]
        if let title { dict["title"] = title }
        if let author { dict["author"] = author }
        if let language { dict["language"] = language }
        if let isbn { dict["isbn"] = isbn }
        if let format { dict["format"] = format }
        if let year { dict["year"] = year }
        if let publisher { dict["publisher"] = publisher }
        return dict
    }
}

enum PluginError: Error, LocalizedError {
    case loadFailed(String)
    case missingExport(String)
    case runtime(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): return "Plugin load failed: \(m)"
        case .missingExport(let m): return "Plugin missing required export: \(m)"
        case .runtime(let m): return "Plugin runtime error: \(m)"
        case .invalidResponse: return "Plugin returned invalid response shape"
        }
    }
}
