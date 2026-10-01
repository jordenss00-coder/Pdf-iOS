import Compression
import Foundation

/// Bağımlılıksız ZIP yazıcı (DEFLATE; UTF-8 dosya adları). DOCX/XLSX/PPTX paketleri ve toplu paylaşım için.
enum Zip {
    static func archive(_ files: [URL], to destination: URL) throws {
        var entries: [(String, Data)] = []
        var used = Set<String>()
        for file in files {
            var name = file.lastPathComponent
            var counter = 2
            while used.contains(name.lowercased()) {
                let ext = file.pathExtension
                name = "\(stem(file.lastPathComponent))_\(counter)" + (ext.isEmpty ? "" : ".\(ext)")
                counter += 1
            }
            used.insert(name.lowercased())
            entries.append((name, try Data(contentsOf: file)))
        }
        try make(entries).write(to: destination)
    }

    static func make(_ entries: [(String, Data)]) -> Data {
        var output = Data()
        var central = Data()
        let (time, date) = dosStamp(Date())
        for (name, data) in entries {
            let nameData = Data(name.utf8)
            let crc = CRC32.checksum(data)
            var method: UInt16 = 0
            var payload = data
            if let deflated = deflate(data), deflated.count < data.count {
                method = 8
                payload = deflated
            }
            let offset = UInt32(output.count)
            output.append(le32(0x0403_4b50))
            output.append(le16(20))
            output.append(le16(0x0800))
            output.append(le16(method))
            output.append(le16(time))
            output.append(le16(date))
            output.append(le32(crc))
            output.append(le32(UInt32(payload.count)))
            output.append(le32(UInt32(data.count)))
            output.append(le16(UInt16(nameData.count)))
            output.append(le16(0))
            output.append(nameData)
            output.append(payload)

            central.append(le32(0x0201_4b50))
            central.append(le16(20))
            central.append(le16(20))
            central.append(le16(0x0800))
            central.append(le16(method))
            central.append(le16(time))
            central.append(le16(date))
            central.append(le32(crc))
            central.append(le32(UInt32(payload.count)))
            central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameData.count)))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(0))
            central.append(le32(offset))
            central.append(nameData)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4b50))
        output.append(le16(0))
        output.append(le16(0))
        output.append(le16(UInt16(entries.count)))
        output.append(le16(UInt16(entries.count)))
        output.append(le32(UInt32(central.count)))
        output.append(le32(centralOffset))
        output.append(le16(0))
        return output
    }

    /// Ham DEFLATE (RFC 1951); ZIP yöntemi 8.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var buffer = Data(count: capacity)
        let written = buffer.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let input = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity, input, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return buffer.prefix(written)
    }

    private static func dosStamp(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
