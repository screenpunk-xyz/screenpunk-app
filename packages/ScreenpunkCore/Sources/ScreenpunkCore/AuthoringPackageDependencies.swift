import Foundation

/// Checks statically resolvable references after all retained/write files are materialized.
/// This deliberately supports a bounded static subset, not a browser parser or CSS escapes.
/// Runtime JavaScript references still require the host's missing-resource reporting.
public enum AuthoringPackageDependencies {
    private static let packageByteLimit = 204_800
    private static let workLimit = packageByteLimit * 32

    public static func validate(files: [AuthoringScreenFile]) throws {
        try validate(files: files, workLimit: workLimit, byteLimit: packageByteLimit)
    }

    /// Internal limits let small, ordinary fixtures exercise the same fail-closed guards.
    static func validate(files: [AuthoringScreenFile], workLimit: Int, byteLimit: Int = packageByteLimit) throws {
        try admit(files: files, byteLimit: byteLimit)
        var budget = Budget(remaining: workLimit)
        try budget.spend(0)
        let paths = Set(files.map(\.path))
        for file in files {
            let ext = (file.path as NSString).pathExtension.lowercased()
            if ext == "html" || ext == "svg" || ext == "css" {
                // Admission bounds this buffer before it or the path set is allocated.
                let bytes = Array(file.content.utf8)
                let directory = file.path.split(separator: "/").dropLast().map(String.init)
                let context = Context(paths: paths, directory: directory, directoryBytes: file.path.utf8.count)
                if ext == "css" { try css(bytes, start: 0, end: bytes.count, context: context, budget: &budget) }
                else { try markup(bytes, html: ext == "html", context: context, budget: &budget) }
            }
        }
    }

    /// Count the canonical JSON files array without first encoding/copying arbitrary input.
    /// Title/entry admission remains with AuthoringContract.validateScreen at its caller.
    private static func admit(files: [AuthoringScreenFile], byteLimit: Int) throws {
        guard files.count <= 20, (0...packageByteLimit).contains(byteLimit) else { throw invalid("The screen package is too large.") }
        var remaining = byteLimit
        func spend(_ count: Int) throws {
            guard count <= remaining else { throw invalid("The screen package is too large.") }
            remaining -= count
        }
        func string(_ value: String) throws {
            for byte in value.utf8 {
                switch byte {
                case 34, 92, 8, 9, 10, 12, 13: try spend(2)
                case 0...31: try spend(6)
                default: try spend(1)
                }
            }
        }
        try spend(2) // []
        for (index, file) in files.enumerated() {
            if index > 0 { try spend(1) }
            try spend(24) // {"path":"","content":""}
            try string(file.path); try string(file.content)
        }
    }

    /// Optional SDK manifest is authoritative when supplied. Check declarations against the completed package.
    public static func validateManifest(files: [AuthoringScreenFile]) throws {
        try admit(files: files, byteLimit: packageByteLimit)
        guard let source = files.first(where: { $0.path == "manifest.json" }) else { return }
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: Data(source.content.utf8))
        // Bound untrusted integers before the shared manifest validator sums them.
        guard manifest.files.count <= 20, manifest.files.allSatisfy({ $0.bytes >= 0 && $0.bytes <= 204_800 }),
              Set(files.map(\.path)).count == files.count else { throw AuthoringStoreError.invalid("The manifest contains invalid asset counts or sizes.") }
        try PackageValidator.validate(manifest)
        guard manifest.entrypoint == "index.html" else { throw AuthoringStoreError.invalid("The manifest entrypoint differs from the screen entry.") }
        let package = Dictionary(uniqueKeysWithValues: files.filter { $0.path != "manifest.json" }.map { ($0.path, Data($0.content.utf8)) })
        guard Set(manifest.files.map(\.path)) == Set(package.keys) else { throw AuthoringStoreError.invalid("The manifest must declare every package asset exactly once.") }
        for declaration in manifest.files {
            guard let bytes = package[declaration.path], declaration.bytes == bytes.count,
                  declaration.sha256 == AuthoringContract.contentDigest(bytes) else { throw AuthoringStoreError.invalid("A declared manifest asset has a different raw-byte size or digest.") }
        }
    }

    private struct Budget {
        var remaining: Int
        mutating func spend(_ count: Int = 1) throws {
            guard count >= 0, remaining >= count else { throw invalid("Package dependency parsing exceeded its work limit.") }
            remaining -= count
        }
    }
    private struct Context {
        let paths: Set<String>
        let directory: [String]
        let directoryBytes: Int
    }
    private static func invalid(_ message: String = "The screen contains malformed or unsupported dependency syntax.") -> AuthoringStoreError { .invalid(message) }
    private static func space(_ b: UInt8) -> Bool { b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }
    private static func alpha(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
    private static func digit(_ b: UInt8) -> Bool { (48...57).contains(b) }
    private static func folded(_ b: UInt8) -> UInt8 { (65...90).contains(b) ? b + 32 : b }
    private static func nameByte(_ b: UInt8) -> Bool { alpha(b) || digit(b) || b == 45 || b == 58 || b == 95 }
    private static func identifier(_ b: UInt8) -> Bool { alpha(b) || digit(b) || b == 45 || b == 95 || b >= 128 }
    /// All comparisons have fixed ASCII tokens; no suffix lowercasing or substring searching.
    private static func has(_ bytes: [UInt8], _ index: Int, _ end: Int, _ token: StaticString, insensitive: Bool = false) -> Bool {
        token.withUTF8Buffer { wanted in
            guard index <= end, wanted.count <= end - index else { return false }
            for offset in wanted.indices {
                let actual = bytes[index + offset]
                if (insensitive ? folded(actual) : actual) != wanted[offset] { return false }
            }
            return true
        }
    }
    private static func equals(_ bytes: [UInt8], _ range: Range<Int>, _ token: StaticString) -> Bool {
        range.count == token.utf8CodeUnitCount && has(bytes, range.lowerBound, range.upperBound, token, insensitive: true)
    }
    private static func skipSpace(_ bytes: [UInt8], _ index: inout Int, _ end: Int, budget: inout Budget) throws {
        while index < end, space(bytes[index]) { try budget.spend(); index += 1 }
    }
    private static func delimited(_ bytes: [UInt8], _ index: inout Int, _ end: Int, close: StaticString, budget: inout Budget) throws {
        while index < end {
            try budget.spend()
            if has(bytes, index, end, close) { index += close.utf8CodeUnitCount; return }
            index += 1
        }
        throw invalid()
    }
    private static func markup(_ bytes: [UInt8], html: Bool, context: Context, budget: inout Budget) throws {
        var i = 0
        while i < bytes.count {
            try budget.spend()
            guard bytes[i] == 60 else { i += 1; continue }
            if has(bytes, i, bytes.count, "<!--") { i += 4; try delimited(bytes, &i, bytes.count, close: "-->", budget: &budget); continue }
            if has(bytes, i, bytes.count, "<![CDATA[") { i += 9; try delimited(bytes, &i, bytes.count, close: "]]>", budget: &budget); continue }
            if has(bytes, i, bytes.count, "<!doctype", insensitive: true), i + 9 < bytes.count, space(bytes[i + 9]) {
                i += 9
                try declaration(bytes, &i, budget: &budget); continue
            }
            if has(bytes, i, bytes.count, "<?xml", insensitive: true), i + 5 < bytes.count, space(bytes[i + 5]) {
                i += 5; try delimited(bytes, &i, bytes.count, close: "?>", budget: &budget); continue
            }
            if i + 1 < bytes.count, bytes[i + 1] == 33 || bytes[i + 1] == 63 { throw invalid() }
            var cursor = i + 1
            let closing = cursor < bytes.count && bytes[cursor] == 47
            if closing { cursor += 1 }
            guard cursor < bytes.count, alpha(bytes[cursor]) else { i += 1; continue }
            let start = cursor
            while cursor < bytes.count, nameByte(bytes[cursor]) { try budget.spend(); cursor += 1 }
            let name = start..<cursor
            guard cursor < bytes.count, space(bytes[cursor]) || bytes[cursor] == 47 || bytes[cursor] == 62 else { throw invalid() }
            if closing {
                try skipSpace(bytes, &cursor, bytes.count, budget: &budget)
                guard cursor < bytes.count, bytes[cursor] == 62 else { throw invalid() }
                i = cursor + 1; continue
            }
            if equals(bytes, name, "base") { throw invalid("Package HTML cannot change its base URL.") }
            let selfClosing = try attributes(bytes, &cursor, context: context, budget: &budget)
            i = cursor
            let rawText = equals(bytes, name, "script") || equals(bytes, name, "style")
            // In HTML a trailing slash does not close script/style. Reject that
            // unsupported spelling rather than skipping a browser-visible body.
            // XML/SVG documents legitimately permit empty self-closed elements.
            if html && selfClosing && rawText { throw invalid("Self-closing HTML script/style elements are unsupported.") }
            if !selfClosing && rawText {
                let bodyStart = i
                let isStyle = equals(bytes, name, "style")
                let bodyEnd = try rawBodyEnd(bytes, &i, style: isStyle, budget: &budget)
                if isStyle { try css(bytes, start: bodyStart, end: bodyEnd, context: context, budget: &budget) }
            }
        }
    }
    private static func declaration(_ bytes: [UInt8], _ i: inout Int, budget: inout Budget) throws {
        // Simple HTML doctypes only; DTD/internal subsets can introduce unhandled entities.
        var quote: UInt8?
        while i < bytes.count {
            try budget.spend(); let byte = bytes[i]; i += 1
            if let q = quote { if byte == q { quote = nil }; continue }
            if byte == 34 || byte == 39 { quote = byte }
            else if byte == 91 || byte == 60 { throw invalid() }
            else if byte == 62 { return }
        }
        throw invalid()
    }
    private static func attributes(_ bytes: [UInt8], _ i: inout Int, context: Context, budget: inout Budget) throws -> Bool {
        while i < bytes.count {
            try skipSpace(bytes, &i, bytes.count, budget: &budget)
            guard i < bytes.count else { throw invalid() }
            if bytes[i] == 62 { i += 1; return false }
            if has(bytes, i, bytes.count, "/>") { i += 2; return true }
            let start = i
            while i < bytes.count, !space(bytes[i]), bytes[i] != 61, bytes[i] != 62, bytes[i] != 47 {
                guard bytes[i] != 34, bytes[i] != 39, bytes[i] != 60, bytes[i] != 0 else { throw invalid() }
                try budget.spend(); i += 1
            }
            guard i > start else { throw invalid() }
            let name = start..<i
            try skipSpace(bytes, &i, bytes.count, budget: &budget)
            guard i < bytes.count else { throw invalid() }
            if bytes[i] != 61 { continue } // Boolean attribute.
            i += 1; try skipSpace(bytes, &i, bytes.count, budget: &budget)
            guard i < bytes.count else { throw invalid() }
            let value: Range<Int>
            if bytes[i] == 34 || bytes[i] == 39 {
                let quote = bytes[i]; i += 1; let valueStart = i
                while i < bytes.count, bytes[i] != quote { try budget.spend(); i += 1 }
                guard i < bytes.count else { throw invalid() }
                value = valueStart..<i; i += 1
                guard i == bytes.count || space(bytes[i]) || bytes[i] == 62 || bytes[i] == 47 else { throw invalid() }
            } else {
                let valueStart = i
                while i < bytes.count, !space(bytes[i]), bytes[i] != 62 {
                    guard ![UInt8(34),39,60,61,96,0].contains(bytes[i]) else { throw invalid() }
                    try budget.spend(); i += 1
                }
                guard i > valueStart else { throw invalid() }
                value = valueStart..<i
            }
            if equals(bytes, name, "src") || equals(bytes, name, "href") || equals(bytes, name, "xlink:href") || equals(bytes, name, "poster") || equals(bytes, name, "data") {
                try reference(try entities(bytes, value, budget: &budget), context: context, budget: &budget)
            } else if equals(bytes, name, "srcset") {
                try srcset(try entities(bytes, value, budget: &budget), context: context, budget: &budget)
            } else if equals(bytes, name, "style") || equals(bytes, name, "fill") || equals(bytes, name, "stroke") || equals(bytes, name, "filter") || equals(bytes, name, "mask") || equals(bytes, name, "clip-path") || equals(bytes, name, "marker-start") || equals(bytes, name, "marker-mid") || equals(bytes, name, "marker-end") {
                let decoded = try entities(bytes, value, budget: &budget)
                try css(decoded, start: 0, end: decoded.count, context: context, budget: &budget)
            }
        }
        throw invalid()
    }
    private static func rawBodyEnd(_ bytes: [UInt8], _ i: inout Int, style: Bool, budget: inout Budget) throws -> Int {
        while i < bytes.count {
            try budget.spend()
            let length = style ? 7 : 8
            if has(bytes, i, bytes.count, style ? "</style" : "</script", insensitive: true), i + length < bytes.count,
               space(bytes[i + length]) || bytes[i + length] == 62 {
                let end = i; i += length
                try skipSpace(bytes, &i, bytes.count, budget: &budget)
                guard i < bytes.count, bytes[i] == 62 else { throw invalid() }
                i += 1; return end
            }
            i += 1
        }
        throw invalid()
    }
    private static func cssSpace(_ bytes: [UInt8], _ i: inout Int, _ end: Int, budget: inout Budget) throws {
        while i < end {
            if space(bytes[i]) { try budget.spend(); i += 1 }
            else if has(bytes, i, end, "/*") { i += 2; try delimited(bytes, &i, end, close: "*/", budget: &budget) }
            else { return }
        }
    }
    private static func cssString(_ bytes: [UInt8], _ i: inout Int, _ end: Int, allowEscape: Bool, budget: inout Budget) throws -> Range<Int> {
        let quote = bytes[i]; i += 1; let start = i
        while i < end {
            try budget.spend()
            if bytes[i] == quote { let result = start..<i; i += 1; return result }
            if bytes[i] == 92 {
                guard allowEscape, i + 1 < end else { throw invalid("CSS escapes in dependency URLs are unsupported.") }
                try budget.spend(); i += 2; continue
            }
            guard bytes[i] != 10, bytes[i] != 13, bytes[i] != 12 else { throw invalid() }
            i += 1
        }
        throw invalid()
    }
    private static func css(_ bytes: [UInt8], start: Int, end: Int, context: Context, budget: inout Budget) throws {
        var i = start
        while i < end {
            try budget.spend()
            if has(bytes, i, end, "/*") { i += 2; try delimited(bytes, &i, end, close: "*/", budget: &budget); continue }
            if bytes[i] == 34 || bytes[i] == 39 { _ = try cssString(bytes, &i, end, allowEscape: true, budget: &budget); continue }
            guard bytes[i] != 92 else { throw invalid("Escaped CSS identifiers are unsupported for static dependency validation.") }
            if has(bytes, i, end, "@import", insensitive: true), i + 7 == end || !identifier(bytes[i + 7]) {
                i += 7; try cssSpace(bytes, &i, end, budget: &budget)
                guard i < end else { throw invalid() }
                if bytes[i] == 34 || bytes[i] == 39 {
                    let value = try cssString(bytes, &i, end, allowEscape: false, budget: &budget)
                    try reference(Array(bytes[value]), context: context, budget: &budget); continue
                }
                guard has(bytes, i, end, "url(", insensitive: true) else { throw invalid() }
            }
            if has(bytes, i, end, "url(", insensitive: true), i == start || !identifier(bytes[i - 1]) {
                i += 4; try cssSpace(bytes, &i, end, budget: &budget)
                guard i < end else { throw invalid() }
                let value: Range<Int>
                if bytes[i] == 34 || bytes[i] == 39 { value = try cssString(bytes, &i, end, allowEscape: false, budget: &budget) }
                else {
                    let valueStart = i
                    while i < end, bytes[i] != 41, !space(bytes[i]) {
                        guard ![UInt8(34),39,40,92,0].contains(bytes[i]), !has(bytes, i, end, "/*") else { throw invalid() }
                        try budget.spend(); i += 1
                    }
                    value = valueStart..<i
                }
                try cssSpace(bytes, &i, end, budget: &budget)
                guard i < end, bytes[i] == 41 else { throw invalid() }
                i += 1; try reference(Array(bytes[value]), context: context, budget: &budget); continue
            }
            i += 1
        }
    }
    private static func srcset(_ bytes: [UInt8], context: Context, budget: inout Budget) throws {
        var i = 0
        while i < bytes.count {
            while i < bytes.count, space(bytes[i]) || bytes[i] == 44 { try budget.spend(); i += 1 }
            if i == bytes.count { return }
            let start = i; let data = has(bytes, i, bytes.count, "data:", insensitive: true)
            while i < bytes.count, !space(bytes[i]), data || bytes[i] != 44 { try budget.spend(); i += 1 }
            let end = i
            try reference(Array(bytes[start..<end]), context: context, budget: &budget)
            // Commas inside a data URL belong to the URL; a final comma closes a
            // descriptor-free candidate. Otherwise parse descriptors up to the comma.
            if end > start, bytes[end - 1] == 44 { continue }
            if i < bytes.count, bytes[i] == 44 { i += 1; continue }
            var descriptorSeen = false
            while i < bytes.count, bytes[i] != 44 {
                try skipSpace(bytes, &i, bytes.count, budget: &budget)
                if i == bytes.count || bytes[i] == 44 { break }
                let descriptorStart = i
                while i < bytes.count, !space(bytes[i]), bytes[i] != 44 { try budget.spend(); i += 1 }
                guard !descriptorSeen, validDescriptor(bytes, descriptorStart..<i) else { throw invalid("Unsupported srcset descriptor syntax.") }
                descriptorSeen = true
            }
            if i < bytes.count { i += 1 }
        }
    }
    private static func validDescriptor(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        guard range.count >= 2 else { return false }
        let suffix = bytes[range.upperBound - 1]
        guard suffix == 119 || suffix == 120 else { return false } // width or density
        var dot = false, digits = false, nonzero = false
        for index in range.dropLast() {
            let byte = bytes[index]
            if digit(byte) { digits = true; nonzero = nonzero || byte != 48 }
            else if byte == 46 && suffix == 120 && !dot { dot = true }
            else { return false }
        }
        return digits && (suffix == 120 || nonzero)
    }
    private static func hex(_ byte: UInt8) -> UInt32? {
        if digit(byte) { return UInt32(byte - 48) }
        let b = folded(byte); return (97...102).contains(b) ? UInt32(b - 87) : nil
    }
    /// Supported amp/numeric entities are decoded once, while advancing the input.
    private static func entities(_ bytes: [UInt8], _ range: Range<Int>, budget: inout Budget) throws -> [UInt8] {
        var output: [UInt8] = []; output.reserveCapacity(range.count)
        var i = range.lowerBound
        while i < range.upperBound {
            try budget.spend()
            if has(bytes, i, range.upperBound, "&amp;") { output.append(38); i += 5; continue }
            if has(bytes, i, range.upperBound, "&#") {
                i += 2; var radix: UInt32 = 10
                if i < range.upperBound, folded(bytes[i]) == 120 { radix = 16; i += 1 }
                let start = i; var number: UInt32 = 0
                while i < range.upperBound, let n = hex(bytes[i]), n < radix {
                    try budget.spend()
                    guard number <= (0x10ffff - n) / radix else { throw invalid("Invalid dependency entity.") }
                    number = number * radix + n; i += 1
                }
                guard i > start, let scalar = UnicodeScalar(number) else { throw invalid("Invalid dependency entity.") }
                if i < range.upperBound, bytes[i] == 59 { i += 1 }
                output.append(contentsOf: String(scalar).utf8); continue
            }
            output.append(bytes[i]); i += 1
        }
        return output
    }
    private static func reference(_ bytes: [UInt8], context: Context, budget: inout Budget) throws {
        try budget.spend(bytes.count)
        let raw = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Array(raw.utf8)
        if value.isEmpty || value[0] == 35 { return }
        let package = has(value, 0, value.count, "screenpunk://package/", insensitive: true)
        var start = 0
        if package { start = 21 }
        else {
            if has(value, 0, value.count, "//") { return }
            if alpha(value[0]) {
                var end = 1
                while end < value.count, alpha(value[end]) || digit(value[end]) || value[end] == 43 || value[end] == 45 || value[end] == 46 { try budget.spend(); end += 1 }
                if end < value.count, value[end] == 58 { return }
            }
        }
        var end = start
        while end < value.count, value[end] != 63, value[end] != 35 { try budget.spend(); end += 1 }
        var decoded: [UInt8] = []; decoded.reserveCapacity(end - start)
        var i = start
        while i < end {
            try budget.spend(); var byte = value[i]; i += 1
            if byte == 37 {
                guard i + 1 < end, let high = hex(value[i]), let low = hex(value[i + 1]) else { throw invalid("The screen contains an unsafe package dependency.") }
                byte = UInt8(high * 16 + low); i += 2
            }
            guard byte != 92, byte != 0, byte != 58, byte != 37 else { throw invalid("The screen contains an unsafe package dependency.") }
            decoded.append(byte)
        }
        guard let path = String(bytes: decoded, encoding: .utf8) else { throw invalid("The screen contains an unsafe package dependency.") }
        let rooted = package || decoded.first == 47
        try budget.spend(rooted ? 0 : context.directoryBytes + context.directory.count)
        var components = rooted ? [] : context.directory
        for part in path.split(separator: "/") {
            try budget.spend(part.utf8.count + 1)
            if part == "." { continue }
            if part == ".." { guard !components.isEmpty else { throw invalid("A package dependency escapes the screen.") }; components.removeLast() }
            else { components.append(String(part)) }
        }
        guard !components.isEmpty else { throw invalid("A package dependency does not name a file.") }
        // Account for joining/hashing before allocating or looking up the resolved path.
        for part in components { try budget.spend(part.utf8.count + 1) }
        let resolved = components.joined(separator: "/")
        guard context.paths.contains(resolved) else { throw invalid("The screen references a missing package file: \(resolved).") }
    }
}
