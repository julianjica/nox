import AppKit
import PDFKit

// `nox file.pdf [--page N] [--forward LINE TEXFILE]` from a terminal hands the request to
// the running nox app (or starts it). LaunchServices starts the app itself with `--gui`.

let bundleID = "com.jujimenez.nox"
var arguments = Array(CommandLine.arguments.dropFirst())

/// Makes file arguments absolute, since the app doesn't share the terminal's directory.
func absolutePaths(_ args: [String]) -> [String] {
    let cwd = FileManager.default.currentDirectoryPath
    var result: [String] = [], i = 0
    let valueCounts = ["--page": 1, "--forward": 2, "--keys": 1, "--search": 1, "--state": 1, "--note": 1, "--pdf-note": 1, "--type": 1, "--close-note": 1, "--click-note": 1, "--right-click-note": 1, "--menu": 1, "--snapshot": 1, "--pick": 1]
    while i < args.count {
        let arg = args[i]
        if let n = valueCounts[arg] {
            result.append(arg)
            for j in 1...n where i + j < args.count {
                var value = args[i + j]
                if (arg == "--forward" && j == 2) || arg == "--state" || arg == "--snapshot" {
                    value = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
                }
                result.append(value)
            }
            i += n + 1
            continue
        }
        result.append(URL(fileURLWithPath: NSString(string: arg).expandingTildeInPath,
                           relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path)
        i += 1
    }
    return result
}

if arguments == ["--help"] || arguments == ["-h"] {
    print("""
    usage: nox [file.pdf] [--page N] [--forward LINE TEXFILE]
      --page N               open at page N
      --forward LINE TEX     SyncTeX: show where LINE of TEX ends up in the PDF
    nox --export file.pdf [--write]
                             highlights and notes as Markdown (--write: into file.notes.md)
    nox --self-test          check that this build works
    In the viewer, press ? (or Cmd-/) for this list:

    """ + Keymap.plainText)
    exit(0)
}

// `nox --export file.pdf [--write]`: the PDF's highlights and notes as Markdown
// (printed, or written into file.notes.md with --write). No window needed.
if arguments.first == "--export", arguments.count >= 2 {
    let pdf = URL(fileURLWithPath: absolutePaths([arguments[1]])[0])
    guard let document = PDFDocument(url: pdf) else {
        FileHandle.standardError.write(Data("nox: cannot open \(pdf.path)\n".utf8)); exit(1)
    }
    if arguments.contains("--write") {
        do {
            let count = try NotesExport.write(document, pdf: pdf)
            print("\(count) highlights/notes → \(NotesExport.notesURL(for: pdf).path)")
        } catch { FileHandle.standardError.write(Data("nox: \(error.localizedDescription)\n".utf8)); exit(1) }
    } else {
        print(NotesExport.markdown(document, pdf: pdf).text, terminator: "")
    }
    exit(0)
}

if arguments == ["--self-test"] {
    exit(SelfTest.run())
}

if arguments.first == "--render-test" {
    let saved = Theme.recolor
    let status = renderTest(Array(arguments.dropFirst()))
    Theme.recolor = saved
    exit(status)
}

if arguments.first == "--gui" || arguments.isEmpty && Bundle.main.bundleIdentifier == bundleID
    && ProcessInfo.processInfo.environment["TERM"] == nil {
    // Started by LaunchServices: run the app.
    if arguments.first == "--gui" { arguments.removeFirst() }
    let app = NSApplication.shared
    let delegate = AppDelegate(arguments: arguments)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    // Started from a terminal: pass the request on.
    let args = absolutePaths(arguments)
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != getpid() }
    if !running.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.commandNotification, object: nil, userInfo: ["args": args], deliverImmediately: true)
        running.first?.activate()
    } else {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", Bundle.main.bundleURL.path, "--args", "--gui"] + args
        try? open.run()
        open.waitUntilExit()
    }
}
