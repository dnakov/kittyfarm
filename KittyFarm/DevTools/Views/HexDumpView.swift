import SwiftUI

struct HexDumpView: View {
    let data: Data
    var byteLimit: Int? = 4096

    private var slicedData: Data {
        if let byteLimit, data.count > byteLimit {
            return data.prefix(byteLimit)
        }
        return data
    }

    private var isTruncated: Bool {
        guard let byteLimit else { return false }
        return data.count > byteLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isTruncated, let byteLimit {
                Text("Showing first \(byteLimit) of \(data.count) bytes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(Self.format(slicedData))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func format(_ data: Data) -> String {
        let bytesPerRow = 16
        var lines: [String] = []
        var offset = 0

        for rowStart in stride(from: 0, to: data.count, by: bytesPerRow) {
            let rowEnd = min(rowStart + bytesPerRow, data.count)
            let row = data[rowStart..<rowEnd]

            var hexParts: [String] = []
            var ascii = ""
            for byte in row {
                hexParts.append(String(format: "%02x", byte))
                if byte >= 0x20 && byte < 0x7F {
                    ascii.append(Character(UnicodeScalar(byte)))
                } else {
                    ascii.append(".")
                }
            }

            while hexParts.count < bytesPerRow {
                hexParts.append("  ")
            }

            let hex = hexParts.enumerated().map { idx, part in
                idx == 7 ? "\(part) " : part
            }.joined(separator: " ")

            lines.append(String(format: "%08x  %@  |%@|", offset, hex, ascii))
            offset += bytesPerRow
        }

        return lines.joined(separator: "\n")
    }
}
