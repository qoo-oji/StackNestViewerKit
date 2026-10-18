import Foundation

/// 要求の鍵。同じ鍵の要求は 1 件にまとめる（書き戻しは通し番号で必ず別の件）。manifest は世代を持つ: 読み直し
/// （`refresh`・404 の後の確かめ）は世代を進めて新しい件を出し、それより前から飛んでいる件には乗らない
/// （前から飛んでいる件は、読み直しを決めた時点より古い StackNest の状態を答えうる）。読み直しでない読み出しは、
/// いまの世代の件に乗る。
enum RequestKey: Hashable, Sendable {
    case manifest(generation: UInt64)
    case page(index: Int, maxWidth: Int?)
    case cover(maxWidth: Int?)
    case progress(serial: UInt64, page: Int)

    var isProgress: Bool {
        if case .progress = self { return true }
        return false
    }
}

/// 2xx の応答。
struct FetchedResponse: Sendable {
    let data: Data
    let contentType: String?
    /// 応答を返した件の通し番号（`finish` が付ける）。manifest の新旧の順を決める。
    var serial: UInt64 = 0
}

/// `pages/{n}` の 404。顔（async・同期）が manifest を読み直して `.pageOutOfRange` などに振り分ける。外へは出さない。
struct PageNotFound: Error {}

/// 同期の顔の待つ人の受け皿（セマフォ）。
final class BlockingSlot: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<FetchedResponse, any Error>?

    func fulfil(_ result: Result<FetchedResponse, any Error>) {
        lock.withLock { self.result = result }
        semaphore.signal()
    }

    /// `deadline` までに結果が来たらそれを返す。来なければ nil。
    func waitForResult(until deadline: DispatchTime) -> Result<FetchedResponse, any Error>? {
        guard semaphore.wait(timeout: deadline) == .success else { return nil }
        return lock.withLock { result }
    }
}

/// 待つ人。再開はロックを外してから、再開の権利を取った側が 1 度だけ行う。
enum Waiter {
    case async(CheckedContinuation<FetchedResponse, any Error>)
    case blocking(BlockingSlot)
    /// 先読みの指示（結果を受け取る人はいない。取れたページはキャッシュに入る）。
    case prefetch

    var isPrefetchInstruction: Bool {
        if case .prefetch = self { return true }
        return false
    }

    func resume(with result: Result<FetchedResponse, any Error>) {
        switch self {
        case .async(let continuation): continuation.resume(with: result)
        case .blocking(let slot): slot.fulfil(result)
        case .prefetch: break
        }
    }
}

struct WaiterEntry {
    let waiter: Waiter
    let priority: StackNestRequestPriority
}

/// 取得中の 1 件。セッションのロックの中でだけ読み書きする。
final class Flight {
    let key: RequestKey
    let serial: UInt64
    var task: URLSessionDataTask?
    var waiters: [UInt64: WaiterEntry] = [:]
    /// 待つ人がいなくなって取り消した（まだ出していなければ出さない）。
    var isAbandoned = false

    init(key: RequestKey, serial: UInt64) {
        self.key = key
        self.serial = serial
    }

    var displayWaiterCount: Int { waiters.values.filter { $0.priority == .display }.count }

    /// 部品の先読みの枠を使っている件（先読みの指示だけが待ち、表示の要求が乗っていない）。
    var countsAsPrefetch: Bool {
        displayWaiterCount == 0 && waiters.values.contains { $0.waiter.isPrefetchInstruction }
    }

    var desiredPriority: Float { displayWaiterCount > 0 ? URLSessionTask.highPriority : URLSessionTask.lowPriority }

    /// 出す順の組（小さいほど先）: 0 = 書き戻し（小さく、遅れると読書位置が巻き戻って見える）、1 = 表示の要求が
    /// 乗っている件、2 = 先読みだけの件。同じ組の中は件を作った順（通し番号の順）。表示の要求が乗れば、その場で
    /// 1 の組へ上がる。
    var admissionRank: Int {
        if key.isProgress { return 0 }
        return displayWaiterCount > 0 ? 1 : 2
    }
}

/// 札（待つ人の ID）の状態。再開の権利はロックの中で 1 度だけ決まる。
enum TicketState {
    /// 札を出したが、まだ待つ人として加わっていない。
    case allocated
    /// 加わる前に抜けた（取り消し・時間切れ）。加わる側が見て、要求を出さずにこのエラーで再開する。
    case withdrawnEarly(any Error)
    /// 取得中の件に加わっている。
    case registered(RequestKey)
}

/// セッションの変わる状態（ロックの中でだけ触る）。
struct EngineState {
    var flights: [RequestKey: Flight] = [:]
    var tickets: [UInt64: TicketState] = [:]
    var nextTicket: UInt64 = 0
    var nextSerial: UInt64 = 0
    var cache: PageCache
    var knownPageCount: Int
    /// manifest を 1 度でも読んだか（範囲外の確かめ直しはセッションごとに 1 度だけ）。
    var hasConfirmedPageCount = false
    var manifest: StackNestBookManifest?
    /// manifest の件の世代（読み直しのたびに進む）。
    var manifestGeneration: UInt64 = 0
    /// 最後に反映した manifest の応答の件の通し番号（古い応答で新しい manifest を上書きしない）。
    var manifestSerial: UInt64 = 0
    var isClosed = false
    var permanentFailure: StackNestViewerError?
    /// まだ出していない先読み（指示の順）。
    var prefetchQueue: [RequestKey] = []
    /// 取得中の件に乗っている先読みの札。
    var prefetchTickets: [RequestKey: UInt64] = [:]
    /// まだ出していない件（作った順）。同時の数の枠が空くと、`admissionRank` の順に出す。
    var queuedFlights: [Flight] = []
    /// 枠を使っている件の通し番号。出した要求が終わる（delegate が完了を知らせる）まで枠を返さない
    /// （取り消した要求も、終わるまでは `URLSession` の接続を使っているため）。
    var runningSerials: Set<UInt64> = []
    /// 試験だけが置く。要求を出した直後に、ロックの外で呼ぶ。
    var launchHookForTesting: LaunchHook?
}

/// 試験の差し込み口: 出した件の鍵とタスク。
typealias LaunchHook = @Sendable (RequestKey, URLSessionTask) -> Void

/// ロックの中で決め、ロックの外で行うこと。
struct Effects {
    var resumes: [(Waiter, Result<FetchedResponse, any Error>)] = []
    var cancels: [URLSessionDataTask] = []
    var launches: [Flight] = []
}
