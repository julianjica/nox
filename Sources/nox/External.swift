import Foundation

/// Runs a command and returns its standard output (nil if it couldn't start).
@discardableResult
func run(_ executable: String, _ arguments: [String], wait: Bool = true) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    guard wait else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Forward and inverse search through the `synctex` command from TeX Live.
enum SyncTeX {
    static let synctex = "/Library/TeX/texbin/synctex"
    static let nvim = "/opt/homebrew/bin/nvim"

    /// First value of `key:` in synctex output, e.g. "Page:3".
    private static func field(_ key: String, in output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix(key + ":") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    /// Location in the PDF for a line of a .tex file: 1-based page and top-left coordinates.
    static func forward(line: Int, tex: String, pdf: String) -> (page: Int, x: Double, y: Double)? {
        guard let out = run(synctex, ["view", "-i", "\(line):0:\(tex)", "-o", pdf]),
              let page = field("Page", in: out).flatMap({ Int($0) }),
              let x = field("x", in: out).flatMap({ Double($0) }),
              let y = field("y", in: out).flatMap({ Double($0) })
        else { return nil }
        return (page, x, y)
    }

    /// Source file and line for a point on a 1-based page (top-left coordinates).
    static func inverse(page: Int, x: Double, y: Double, pdf: String) -> (file: String, line: Int)? {
        guard let out = run(synctex, ["edit", "-o", "\(page):\(x):\(y):\(pdf)"]),
              let file = field("Input", in: out),
              let line = field("Line", in: out).flatMap({ Int($0) })
        else { return nil }
        return (file, max(line, 1))
    }

    /// Jump Neovim to the source line (VimTeX finds the running Neovim).
    static func openInEditor(file: String, line: Int) {
        run(nvim, ["--headless", "-c", "VimtexInverseSearch \(line) '\(file)'"], wait: false)
    }
}

/// The Sioyek notes bridge scripts, shared with nox.
enum Notes {
    static let script = NSString(string: "~/.config/sioyek/scripts/pdfnotes.sh").expandingTildeInPath

    static func quote(pdf: String, pageIndex: Int, text: String) {
        run("/bin/sh", [script, "quote", pdf, String(pageIndex), text], wait: false)
    }

    static func open(pdf: String) {
        run("/bin/sh", [script, "notes", pdf], wait: false)
    }
}
