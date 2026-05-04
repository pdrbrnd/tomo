import Foundation

/// Maps BCP 47 language tags to Microsoft locale codes (LCIDs) for the
/// MOBI header `locale` field. Older Kindle firmwares read this for
/// language sorting / display when the EXTH 524 BCP 47 tag isn't set.
///
/// The full LCID table has hundreds of entries; we ship the ones we'll
/// realistically see in the user's library plus a reasonable fallback.
/// Unknown tags map to 0 (NEUTRAL) — Kindle accepts this without
/// complaint.
///
/// Reference: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-lcid/
nonisolated enum MicrosoftLocale {
    static func code(for bcp47: String) -> UInt32 {
        let tag = bcp47.lowercased()
        if let exact = byTag[tag] { return exact }
        let base = String(tag.split(separator: "-").first ?? "")
        return byTag[base] ?? 0
    }

    private static let byTag: [String: UInt32] = [
        "en": 0x0009,
        "en-us": 0x0409,
        "en-gb": 0x0809,
        "en-au": 0x0c09,
        "en-ca": 0x1009,
        "en-nz": 0x1409,
        "en-ie": 0x1809,
        "en-za": 0x1c09,
        "pt": 0x0016,
        "pt-br": 0x0416,
        "pt-pt": 0x0816,
        "es": 0x000a,
        "es-es": 0x040a,
        "es-mx": 0x080a,
        "es-ar": 0x2c0a,
        "fr": 0x000c,
        "fr-fr": 0x040c,
        "fr-ca": 0x0c0c,
        "fr-be": 0x080c,
        "fr-ch": 0x100c,
        "de": 0x0007,
        "de-de": 0x0407,
        "de-ch": 0x0807,
        "de-at": 0x0c07,
        "it": 0x0010,
        "it-it": 0x0410,
        "it-ch": 0x0810,
        "nl": 0x0013,
        "nl-nl": 0x0413,
        "nl-be": 0x0813,
        "ru": 0x0019,
        "ru-ru": 0x0419,
        "zh": 0x0004,
        "zh-cn": 0x0804,
        "zh-tw": 0x0404,
        "zh-hk": 0x0c04,
        "ja": 0x0011,
        "ja-jp": 0x0411,
        "ko": 0x0012,
        "ko-kr": 0x0412,
        "ar": 0x0001,
        "ar-sa": 0x0401,
        "he": 0x000d,
        "he-il": 0x040d,
        "tr": 0x001f,
        "tr-tr": 0x041f,
        "pl": 0x0015,
        "pl-pl": 0x0415,
        "sv": 0x001d,
        "sv-se": 0x041d,
        "da": 0x0006,
        "da-dk": 0x0406,
        "no": 0x0014,
        "nb": 0x0014,
        "nn": 0x0014,
        "nb-no": 0x0414,
        "nn-no": 0x0814,
        "fi": 0x000b,
        "fi-fi": 0x040b,
        "el": 0x0008,
        "el-gr": 0x0408,
        "cs": 0x0005,
        "cs-cz": 0x0405,
        "hu": 0x000e,
        "hu-hu": 0x040e,
        "ro": 0x0018,
        "ro-ro": 0x0418,
        "uk": 0x0022,
        "uk-ua": 0x0422,
    ]
}
