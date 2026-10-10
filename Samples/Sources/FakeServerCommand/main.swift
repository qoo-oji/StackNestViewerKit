import FakeStackNestServer
import Foundation

// stacknest-fake-server --folder <画像のフォルダ> --reference-out <書き出す .stacknestbook>
//                       [--record-out <記録の .json>] [--port <番号>] [--token <鍵>]
//                       [--redirect <道>=<URL>]... [--delay <道>=<秒>]...
// 127.0.0.1 で待ち受け、参照ファイルを書き出す。止めるまで動く（Ctrl-C）。記録（鍵は入らない）は要求のたびに
// --record-out へ書き直す。

let usage = """
    usage: stacknest-fake-server --folder <dir> --reference-out <file.stacknestbook> [--record-out <file.json>]
                                 [--port <n>] [--token <token>] [--redirect <path>=<url>]... [--delay <path>=<seconds>]...
    """

/// 標準出力へ 1 行（ファイルへ向けても、すぐ書き出す）。
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("stacknest-fake-server: \(message)\n\(usage)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var folder: URL?
var referenceOut: URL?
var recordOut: URL?
var port: UInt16 = 0
var token: String?
var redirects: [String: String] = [:]
var delays: [String: TimeInterval] = [:]

func pair(_ value: String) -> (String, String) {
    guard let equals = value.firstIndex(of: "=") else { fail("expected <path>=<value>: \(value)") }
    return (String(value[..<equals]), String(value[value.index(after: equals)...]))
}

while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard !arguments.isEmpty else { fail("missing value for \(flag)") }
    let value = arguments.removeFirst()
    switch flag {
    case "--folder": folder = URL(fileURLWithPath: value, isDirectory: true)
    case "--reference-out": referenceOut = URL(fileURLWithPath: value)
    case "--record-out": recordOut = URL(fileURLWithPath: value)
    case "--port": port = UInt16(value) ?? 0
    case "--token": token = value
    case "--redirect":
        let (path, url) = pair(value)
        redirects[path] = url
    case "--delay":
        let (path, seconds) = pair(value)
        delays[path] = TimeInterval(seconds) ?? 0
    default: fail("unknown option \(flag)")
    }
}

guard let folder, let referenceOut else { fail("--folder and --reference-out are required") }
let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
guard !files.isEmpty else { fail("no images in \(folder.path)") }

var options = FakeStackNestServer.Options(pages: files.compactMap { try? Data(contentsOf: $0) })
options.contentType = files[0].pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
if let token { options.token = token }
options.redirects = redirects
options.delays = delays
let server = FakeStackNestServer(options: options)
if let recordOut {
    server.onEveryRecord { _ in try? server.recordsJSON().write(to: recordOut) }
}
do {
    let bound = try server.start(port: port)
    let reference = try server.reference(title: folder.lastPathComponent).encodedJSON()
    say("stacknest-fake-server: listening on http://127.0.0.1:\(bound) with \(options.pages.count) pages")
    say("stacknest-fake-server: wrote \(referenceOut.path)")
    // 参照ファイルは最後に書く（ファイルができたら、上の 2 行は出ている＝待つ側が読める）。
    try reference.write(to: referenceOut)
} catch {
    fail("could not start: \(error)")
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stopSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        server.stop()
        if let recordOut { try? server.recordsJSON().write(to: recordOut) }
        exit(0)
    }
    source.resume()
    return source
}
withExtendedLifetime(stopSources) { dispatchMain() }
