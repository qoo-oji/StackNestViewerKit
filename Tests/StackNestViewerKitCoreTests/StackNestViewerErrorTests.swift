import Foundation
import Testing

@testable import StackNestViewerKitCore

@Suite("エラーと既定の文言")
struct StackNestViewerErrorTests {
    @Test("表にあるすべてのコードに英日の文言があり、書式の数が揃っている")
    func everyCodeHasBothLanguages() {
        #expect(StackNestMessages.knownCodes.count == 14)
        for code in StackNestMessages.knownCodes {
            let entry = try! #require(StackNestMessages.table[code], "\(code.rawValue)")
            #expect(!entry.english.isEmpty && !entry.japanese.isEmpty, "\(code.rawValue)")
            for token in ["%@", "%lld"] {
                #expect(entry.english.components(separatedBy: token).count
                        == entry.japanese.components(separatedBy: token).count, "\(code.rawValue) \(token)")
            }
        }
    }

    @Test("英語はまっすぐなアポストロフィ、日本語の文言に「書庫」を使わない")
    func wordingFollowsTheGlossary() {
        for code in StackNestMessages.knownCodes {
            let entry = StackNestMessages.table[code]!
            #expect(!entry.english.contains("\u{2019}"), "\(code.rawValue)")
            #expect(!entry.japanese.contains("書庫"), "\(code.rawValue)")
        }
    }

    @Test("アプリの名前と状態コードが入る")
    func formatsArguments() {
        #expect(StackNestViewerError(.httpStatus, statusCode: 503).message(language: .english)
                == "StackNest returned an error (HTTP 503).")
        #expect(StackNestViewerError(.httpStatus, statusCode: 500).message(language: .japanese)
                == "StackNest がエラーを返しました（HTTP 500）。")
        #expect(StackNestViewerError(.unsupportedVersion, formatVersion: 2).message(language: .english, appName: "Example Viewer")
                == "This StackNest book reference uses a newer format. Update Example Viewer to open it.")
        #expect(StackNestViewerError(.hostNotAllowed).message(language: .japanese, appName: "Example Viewer")
                == "この本の接続先がこの Mac ではないため、Example Viewer は接続しません。StackNest から開き直してください。")
    }

    @Test("表に無いコードは「想定外の応答」の文言")
    func unknownCodeFallsBack() {
        let custom = StackNestViewerError(.init(rawValue: "somethingNew"))
        #expect(custom.message(language: .english)
                == "StackNest returned an unexpected response. Open the book from StackNest again.")
    }

    @Test("恒久的な失敗: 期限切れ・認証失敗・本が無い・ライブラリのロック・つないでよくないホスト")
    func permanentCodes() {
        for code in StackNestMessages.knownCodes {
            let permanent: Set<StackNestViewerError.Code> = [.expired, .unauthorized, .bookNotFound, .libraryLocked,
                                                             .hostNotAllowed]
            #expect(StackNestViewerError(code).isPermanent == permanent.contains(code), "\(code.rawValue)")
        }
    }

    @Test("知らせの種類: 期限切れと認証失敗は同じ・httpStatus は状態コードごとに別")
    func noticeKinds() {
        #expect(StackNestViewerError(.expired).noticeKind == StackNestViewerError(.unauthorized).noticeKind)
        #expect(StackNestViewerError(.libraryLocked).noticeKind != StackNestViewerError(.bookNotFound).noticeKind)
        #expect(StackNestViewerError(.httpStatus, statusCode: 500).noticeKind
                != StackNestViewerError(.httpStatus, statusCode: 503).noticeKind)
        #expect(StackNestViewerError(.httpStatus, statusCode: 500).noticeKind
                == StackNestViewerError(.httpStatus, statusCode: 500).noticeKind)
        #expect(StackNestViewerError(.pageOutOfRange, pageCount: 3).noticeKind
                == StackNestViewerError(.pageOutOfRange, pageCount: 9).noticeKind)
    }

    @Test("言語: ロケールから選ぶ（日本語以外は英語）")
    func languageFromLocale() {
        #expect(StackNestLanguage(locale: Locale(identifier: "ja_JP")) == .japanese)
        #expect(StackNestLanguage(locale: Locale(identifier: "ja")) == .japanese)
        #expect(StackNestLanguage(locale: Locale(identifier: "en_US")) == .english)
        #expect(StackNestLanguage(locale: Locale(identifier: "fr")) == .english)
    }

    @Test("文言は固定の表から作るので、鍵も book の資格情報も入らない（どのコード・どの言語でも）")
    func messagesNeverContainTheToken() {
        for code in StackNestMessages.knownCodes {
            for language in [StackNestLanguage.english, .japanese] {
                let error = StackNestViewerError(code, statusCode: 500, formatVersion: 2, pageCount: 3)
                for text in [error.message(language: language, appName: "Example Viewer"), String(describing: error)] {
                    #expect(!text.contains("Bearer"), "\(code.rawValue)")
                    #expect(!text.contains("token"), "\(code.rawValue)")
                    #expect(!text.contains("@"), "\(code.rawValue)")
                }
            }
        }
    }

    @Test("errorDescription は message() と同じ")
    func errorDescriptionMatchesMessage() {
        let error = StackNestViewerError(.cannotConnect)
        #expect(error.errorDescription == error.message())
    }

    @Test("すべてのコードの英日の文言が、仕様の表と一字一句同じ（app 名は Example Viewer・状態コードは 503 で描いた全文）")
    func everyMessageMatchesTheSpecTable() {
        let unexpected = (
            "StackNest returned an unexpected response. Open the book from StackNest again.",
            "StackNest から想定外の応答が返りました。StackNest から開き直してください。")
        let expiredLink = (
            "The link to this book has expired. Open the book from StackNest again.",
            "この本を開くための期限が切れました。StackNest から開き直してください。")
        let expected: [StackNestViewerError.Code: (en: String, ja: String)] = [
            .invalidReference: (
                "This file isn't a StackNest book reference, or it's damaged.",
                "このファイルは StackNest の本の参照ファイルではないか、壊れています。"),
            .unsupportedVersion: (
                "This StackNest book reference uses a newer format. Update Example Viewer to open it.",
                "この StackNest の参照ファイルは新しい形式です。開くには Example Viewer を更新してください。"),
            .expired: expiredLink,
            .unauthorized: expiredLink,
            .libraryLocked: (
                "Unlock the library in StackNest, then open the book from StackNest again.",
                "StackNest でライブラリを解錠し、StackNest から開き直してください。"),
            .bookNotFound: (
                "This book is no longer in StackNest. Open it from StackNest again.",
                "この本は StackNest にありません。StackNest から開き直してください。"),
            .pageOutOfRange: (
                "This page isn't in the book.",
                "このページは本にありません。"),
            .hostNotAllowed: (
                "This book's address isn't on this Mac, so Example Viewer won't connect to it. Open the book from StackNest again.",
                "この本の接続先がこの Mac ではないため、Example Viewer は接続しません。StackNest から開き直してください。"),
            .cannotConnect: (
                "StackNest isn't running, or its reading-position sync setting is off. Open the book from StackNest again.",
                "StackNest が起動していないか、読書位置の同期の設定がオフです。StackNest から開き直してください。"),
            .insecureConnectionBlocked: (
                "This book's address isn't on this Mac or your local network, so Example Viewer can't reach it. Open the book from StackNest again.",
                "この本の接続先は、この Mac やローカルネットワークの中にないため、Example Viewer から接続できません。StackNest から開き直してください。"),
            .remoteUnavailable: (
                "StackNest couldn't reach the remote library. Try again later.",
                "StackNest がリモートのライブラリに接続できませんでした。しばらくしてからもう一度お試しください。"),
            .responseTooLarge: unexpected,
            .invalidResponse: unexpected,
            .httpStatus: (
                "StackNest returned an error (HTTP 503).",
                "StackNest がエラーを返しました（HTTP 503）。"),
        ]
        #expect(Set(StackNestMessages.table.keys) == Set(StackNestMessages.knownCodes))
        #expect(Set(expected.keys) == Set(StackNestMessages.knownCodes))
        #expect(Set(StackNestMessages.knownCodes).count == StackNestMessages.knownCodes.count)
        for (code, texts) in expected {
            let error = StackNestViewerError(code, statusCode: 503, formatVersion: 2)
            #expect(error.message(language: .english, appName: "Example Viewer") == texts.en, "\(code.rawValue) en")
            #expect(error.message(language: .japanese, appName: "Example Viewer") == texts.ja, "\(code.rawValue) ja")
        }
        for language in [StackNestLanguage.english, .japanese] {
            #expect(StackNestViewerError(.expired).message(language: language, appName: "Example Viewer")
                    == StackNestViewerError(.unauthorized).message(language: language, appName: "Example Viewer"))
        }
    }
}
