import Foundation

/// セッションのエンジン（1 本の道）。ロックの中では帳簿だけを付け、再開・取り消し・要求の開始はロックの外で行う。
extension StackNestBookSession {
    // MARK: - 札

    func allocateTicketLocked() -> UInt64 {
        state.nextTicket += 1
        state.tickets[state.nextTicket] = .allocated
        return state.nextTicket
    }

    /// manifest の鍵。`fresh` なら世代を進める（呼んだ後に始めた件の答えだけを使う）。そうでなければ、いまの世代
    /// （飛んでいる件があれば乗る）。
    func manifestKey(fresh: Bool) -> RequestKey {
        lock.withLock {
            if fresh { state.manifestGeneration += 1 }
            return .manifest(generation: state.manifestGeneration)
        }
    }

    // MARK: - 1 本の道

    /// すべての要求が通る入口。札が加わる前に抜けていれば（取り消し・時間切れ）、要求を出さずにそのエラーで再開する。
    func perform(_ key: RequestKey, priority: StackNestRequestPriority, ticket: UInt64, waiter: Waiter) {
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            if case .withdrawnEarly(let error)? = state.tickets[ticket] {
                state.tickets[ticket] = nil
                effects.resumes.append((waiter, .failure(error)))
                return
            }
            admitLocked(key, priority: priority, ticket: ticket, waiter: waiter, now: now, effects: &effects)
            // 表示の要求が先読みの件に乗ると、その件は先読みの枠を使わなくなる（次の先読みを始められる）。
            startQueuedPrefetchesLocked(now: now, effects: &effects)
        }
        apply(effects)
    }

    /// 帳簿付け（ロックの中）: 事前の検査 → キャッシュ → 取得中の件に乗る／新しい件を作る。
    func admitLocked(_ key: RequestKey, priority: StackNestRequestPriority, ticket: UInt64, waiter: Waiter,
                     now: Date, effects: inout Effects)
    {
        if let failure = preflightFailureLocked(for: key, now: now) {
            state.tickets[ticket] = nil
            effects.resumes.append((waiter, .failure(failure)))
            return
        }
        if let cached = state.cache.value(for: key) {
            state.tickets[ticket] = nil
            effects.resumes.append((waiter, .success(cached)))
            return
        }
        let flight: Flight
        if let existing = state.flights[key] {
            flight = existing
        } else {
            state.nextSerial += 1
            flight = Flight(key: key, serial: state.nextSerial)
            state.flights[key] = flight
            effects.launches.append(flight)
        }
        flight.waiters[ticket] = WaiterEntry(waiter: waiter, priority: priority)
        state.tickets[ticket] = .registered(key)
        if waiter.isPrefetchInstruction { state.prefetchTickets[key] = ticket }
        // 表示の要求が乗ったら優先度を上げる（プロパティの書き込みだけで、こちらへは呼び戻さない）。
        flight.task?.priority = flight.desiredPriority
    }

    /// 要求を出す前の検査。閉じた後のページ・manifest・表紙は取り消し、つないでよいホストでなければ
    /// `.hostNotAllowed`、期限を過ぎていれば `.expired`（読む途中にも切れるので毎回見る）。
    func preflightFailureLocked(for key: RequestKey, now: Date) -> (any Error)? {
        if state.isClosed, !key.isProgress { return CancellationError() }
        guard configuration.allowedHosts.allows(reference.bookURL) else {
            return StackNestViewerError(.hostNotAllowed)
        }
        guard !reference.isExpired(at: now) else { return StackNestViewerError(.expired) }
        return nil
    }

    // MARK: - 先読み

    /// 部品の先読みの枠を使っている件の数。
    func activePrefetchCountLocked() -> Int {
        state.flights.values.filter(\.countsAsPrefetch).count
    }

    /// 枠が空いていれば、指示の順に先読みを始める。
    func startQueuedPrefetchesLocked(now: Date, effects: inout Effects) {
        let limit = max(configuration.maxConcurrentPrefetches, 0)
        while activePrefetchCountLocked() < limit, !state.prefetchQueue.isEmpty {
            guard !state.isClosed, state.permanentFailure == nil else {
                state.prefetchQueue.removeAll()
                return
            }
            let key = state.prefetchQueue.removeFirst()
            if state.flights[key] != nil || state.cache.contains(key) { continue }
            let ticket = allocateTicketLocked()
            admitLocked(key, priority: .prefetch, ticket: ticket, waiter: .prefetch, now: now, effects: &effects)
        }
    }

    // MARK: - 抜ける

    /// 待つ人を抜ける（取り消し・時間切れ）。再開の権利を取れたら、その待つ人を返す（呼び出し側が `error` で再開する）。
    /// まだ加わっていない札には「加わる前に抜けた」印と `error` を残す（加わる側が見て、要求を出さずにそれで再開する）。
    func withdraw(_ ticket: UInt64, because error: any Error = CancellationError()) -> Waiter? {
        let now = configuration.now()
        var effects = Effects()
        let waiter: Waiter? = lock.withLock {
            switch state.tickets[ticket] {
            case nil, .withdrawnEarly?:
                return nil
            case .allocated?:
                state.tickets[ticket] = .withdrawnEarly(error)
                return nil
            case .registered?:
                let removed = removeWaiterLocked(ticket, effects: &effects)
                startQueuedPrefetchesLocked(now: now, effects: &effects)
                return removed
            }
        }
        apply(effects)
        return waiter
    }

    /// 札の待つ人を件から外す。待つ人がいなくなった件は取り消す（先読みの取り中に表示が乗っていれば、
    /// 先読みが抜けても件は続く）。
    func removeWaiterLocked(_ ticket: UInt64, effects: inout Effects) -> Waiter? {
        guard case .registered(let key)? = state.tickets[ticket] else { return nil }
        state.tickets[ticket] = nil
        if state.prefetchTickets[key] == ticket { state.prefetchTickets[key] = nil }
        guard let flight = state.flights[key], let entry = flight.waiters.removeValue(forKey: ticket) else {
            return nil
        }
        if flight.waiters.isEmpty {
            flight.isAbandoned = true
            state.flights[key] = nil
            if let task = flight.task { effects.cancels.append(task) }
        } else {
            flight.task?.priority = flight.desiredPriority
        }
        return entry.waiter
    }

    // MARK: - 要求を出す・受ける

    /// 新しい件の要求を組み立てて出す。出す前に待つ人がいなくなっていたら出さない。
    func launch(_ flight: Flight) {
        guard let request = makeRequest(for: flight.key) else {
            finish(flight.key, serial: flight.serial, with: .failure(StackNestViewerError(.invalidReference)))
            return
        }
        let task = urlSession.dataTask(with: request)
        let key = flight.key
        let serial = flight.serial
        delegate.register(
            ResponseSink(limit: configuration.maxResponseBytes) { [weak self] outcome in
                self?.finish(key, serial: serial, with: Self.classify(outcome, for: key))
            }, for: task)
        let started: Bool = lock.withLock {
            guard !flight.isAbandoned else { return false }
            flight.task = task
            task.priority = flight.desiredPriority
            return true
        }
        if started {
            task.resume()
        } else {
            delegate.unregister(task)
            task.cancel()
        }
    }

    /// 件の結果を待つ人すべてに渡す。ページはキャッシュへ、恒久的な失敗は記録して先読みを止める。
    func finish(_ key: RequestKey, serial: UInt64, with result: Result<FetchedResponse, any Error>) {
        let now = configuration.now()
        var effects = Effects()
        lock.withLock {
            guard let flight = state.flights[key], flight.serial == serial else { return }
            state.flights[key] = nil
            // Tag the response with its flight's serial so a late recorder can tell old from new.
            var result = result
            if case .success(var response) = result {
                response.serial = flight.serial
                result = .success(response)
            }
            for (ticket, entry) in flight.waiters {
                state.tickets[ticket] = nil
                if state.prefetchTickets[key] == ticket { state.prefetchTickets[key] = nil }
                effects.resumes.append((entry.waiter, result))
            }
            switch result {
            case .success(let response):
                if case .page = key, !state.isClosed { state.cache.store(response, for: key) }
            case .failure(let error):
                if let failure = error as? StackNestViewerError, failure.isPermanent {
                    state.permanentFailure = failure
                    state.prefetchQueue.removeAll()
                }
            }
            startQueuedPrefetchesLocked(now: now, effects: &effects)
        }
        apply(effects)
    }

    /// ロックの外で行う: 取り消し → 再開 → 新しい件の開始。
    func apply(_ effects: Effects) {
        for task in effects.cancels { task.cancel() }
        for (waiter, result) in effects.resumes { waiter.resume(with: result) }
        for flight in effects.launches { launch(flight) }
    }

    /// 要求の組み立て（ここ 1 か所）。URL は `book` の後ろへ文字列で足す（IPv6 の区域 ID `%25en0` を組み直さない）。
    func makeRequest(for key: RequestKey) -> URLRequest? {
        let suffix: String
        switch key {
        case .manifest: suffix = "manifest"
        case .page(let index, let width): suffix = "pages/\(index)" + Self.widthQuery(width)
        case .cover(let width): suffix = "cover" + Self.widthQuery(width)
        case .progress: suffix = "progress"
        }
        var base = reference.bookURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + suffix) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.requestTimeout.timeInterval
        request.setValue("Bearer \(reference.token)", forHTTPHeaderField: "Authorization")
        request.setValue(viewerHeader, forHTTPHeaderField: StackNestViewerIdentification.headerName)
        if case .progress(_, let page) = key {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"page\":\(page)}".utf8)
        }
        return request
    }

    static func widthQuery(_ width: Int?) -> String {
        width.map { "?maxw=\($0)" } ?? ""
    }

    /// 応答の振り分け。401 → `.unauthorized`／403＋`X-Library-Locked: 1` → `.libraryLocked`／ほかの 403 →
    /// `.unauthorized`／ページの 404 → 顔で振り分け／表紙の 404 → `.httpStatus`（本はあるが表紙が無いことがある。恒久にしない）／ほかの 404 → `.bookNotFound`／502 → `.remoteUnavailable`／
    /// ほかの 3xx・4xx・5xx → `.httpStatus`。
    static func classify(_ outcome: ResponseSink.Outcome, for key: RequestKey) -> Result<FetchedResponse, any Error> {
        // 上限を超えて自分で打ち切ったときは、その取り消しの失敗ではなく「応答が大きすぎる」。
        if outcome.exceededLimit { return .failure(StackNestViewerError(.responseTooLarge)) }
        if let error = outcome.error { return .failure(transportError(error)) }
        guard let status = outcome.statusCode else { return .failure(StackNestViewerError(.invalidResponse)) }
        switch status {
        case 200..<300:
            return .success(FetchedResponse(data: outcome.data, contentType: outcome.contentType))
        case 401:
            return .failure(StackNestViewerError(.unauthorized))
        case 403:
            return .failure(StackNestViewerError(outcome.libraryLocked ? .libraryLocked : .unauthorized))
        case 404:
            if case .page = key { return .failure(PageNotFound()) }
            // A missing cover image also answers 404 while the book exists, so it is not a permanent failure.
            if case .cover = key { return .failure(StackNestViewerError(.httpStatus, statusCode: 404)) }
            return .failure(StackNestViewerError(.bookNotFound))
        case 502:
            return .failure(StackNestViewerError(.remoteUnavailable))
        default:
            return .failure(StackNestViewerError(.httpStatus, statusCode: status))
        }
    }

    /// 通信の失敗の振り分け。取り消し → `CancellationError`、ATS → `.insecureConnectionBlocked`、ほか → `.cannotConnect`。
    static func transportError(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return StackNestViewerError(.cannotConnect) }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .appTransportSecurityRequiresSecureConnection: return StackNestViewerError(.insecureConnectionBlocked)
        default: return StackNestViewerError(.cannotConnect)
        }
    }

    // MARK: - 試験のための読み取り

    var knownPageCountForTesting: Int { lock.withLock { state.knownPageCount } }
    var inFlightKeysForTesting: Set<RequestKey> { lock.withLock { Set(state.flights.keys) } }
    func waiterCountForTesting(_ key: RequestKey) -> Int { lock.withLock { state.flights[key]?.waiters.count ?? 0 } }
    func taskPriorityForTesting(_ key: RequestKey) -> Float? { lock.withLock { state.flights[key]?.task?.priority } }
    var cachedKeysForTesting: [RequestKey] { lock.withLock { state.cache.keys } }
    var ticketCountForTesting: Int { lock.withLock { state.tickets.count } }
    var urlSessionConfigurationForTesting: URLSessionConfiguration { urlSession.configuration }
    var delegateForTesting: AnyObject { delegate }
}
