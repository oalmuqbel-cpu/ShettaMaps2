import Foundation
import Compression

/// قارئ ZIP صغير عبر الدليل المركزي (يدعم التخزين بلا ضغط والضغط Deflate)، يكفي لملفات KMZ.
enum ZipReader {
    enum ZipError: LocalizedError {
        case notZip, unsupported, corrupt
        var errorDescription: String? {
            switch self {
            case .notZip: return "الملف ليس أرشيف ZIP صالحًا."
            case .unsupported: return "طريقة ضغط غير مدعومة في الملف."
            case .corrupt: return "الملف تالف."
            }
        }
    }

    struct Entry: Equatable {
        var name: String
        var method: Int
        var compressedSize: Int
        var size: Int
        var localOffset: Int
    }

    static func entries(_ data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { throw ZipError.notZip }
        // نهاية الدليل المركزي (قد يتبعها تعليق حتى ٦٤ ك.ب)
        var eocd = -1
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 65_535)
        while i >= floor { if u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10), cdOffset = u32(eocd + 16)
        var out: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw ZipError.corrupt }
            let method = u16(p + 10), csize = u32(p + 20), size = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nlen <= b.count else { throw ZipError.corrupt }
            let name = String(bytes: b[(p + 46)..<(p + 46 + nlen)], encoding: .utf8)
                ?? String(bytes: b[(p + 46)..<(p + 46 + nlen)], encoding: .isoLatin1) ?? ""
            out.append(Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: local))
            p += 46 + nlen + elen + clen
        }
        return out
    }

    static func read(_ e: Entry, from data: Data) throws -> Data {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        guard e.localOffset + 30 <= b.count, u16(e.localOffset) | u16(e.localOffset + 2) << 16 == 0x04034b50 else { throw ZipError.corrupt }
        let start = e.localOffset + 30 + u16(e.localOffset + 26) + u16(e.localOffset + 28)
        guard start + e.compressedSize <= b.count else { throw ZipError.corrupt }
        let raw = Array(b[start..<(start + e.compressedSize)])
        switch e.method {
        case 0: return Data(raw)
        case 8:
            guard e.size > 0 else { return Data() }
            guard e.size < 200_000_000 else { throw ZipError.unsupported }
            var out = [UInt8](repeating: 0, count: e.size)
            let n = raw.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard n == e.size else { throw ZipError.corrupt }
            return Data(out)
        default: throw ZipError.unsupported
        }
    }
}
