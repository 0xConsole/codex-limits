import Foundation

enum Terminal {
    static func fail(_ message: String, status: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("codex-limits: \(message)\n".utf8))
        exit(status)
    }

    /// Opens `url` in the default browser. Callers also print it, in case nothing opens.
    static func openInBrowser(_ url: URL) {
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        #elseif os(Windows)
        process.executableURL = URL(fileURLWithPath: #"C:\Windows\explorer.exe"#)
        process.arguments = [url.absoluteString]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url.absoluteString]
        #endif
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Pads each column to its widest cell.
    static func table(_ rows: [[String]]) -> String {
        guard let columnCount = rows.map(\.count).max() else { return "" }
        let widths = (0..<columnCount).map { column in
            rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return rows.map { row in
            let line = row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
            return String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        .joined(separator: "\n")
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
