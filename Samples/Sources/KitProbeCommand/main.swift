import Foundation
import KitProbe
import StackNestViewerKit

// stacknest-kit-probe <参照ファイル> [--no-progress] [--allow-host <ホスト>]...
// manifest → 開くページ → progress を部品のセッションで試し、結果を JSON で出す（鍵は出さない）。
// --no-progress: 書き戻さない（実物の StackNest に向けるときに使う。読書位置の記録を動かさない）。
// 成功なら終了コード 0、失敗なら 1。

let usage = "usage: stacknest-kit-probe <reference.stacknestbook> [--no-progress] [--allow-host <host>]...\n"
var arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first, !path.hasPrefix("-") else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
arguments.removeFirst()
var extraHosts: Set<String> = []
var postsProgress = true
while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--no-progress":
        postsProgress = false
    case "--allow-host" where !arguments.isEmpty:
        extraHosts.insert(arguments.removeFirst())
    default:
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
}
var configuration = StackNestBookSession.Configuration()
if !extraHosts.isEmpty { configuration.allowedHosts = .loopback(plus: extraHosts) }
let result = await KitProbe.run(referenceFile: URL(fileURLWithPath: path), configuration: configuration,
                                postsProgress: postsProgress)
FileHandle.standardOutput.write(try KitProbe.json(result) + Data("\n".utf8))
exit(result.failure == nil ? 0 : 1)
