# Info.plist とサンドボックス / Info.plist and Sandbox

対応の宣言・参照ファイルの型・127.0.0.1 への平文の HTTP・外への接続の許可。

The support declaration, the reference file type, plain HTTP to 127.0.0.1 and the outgoing network entitlement.

## 対応の宣言 / Declaring Support

StackNest は、ビューアの `Info.plist` にこの宣言があるときだけ参照ファイルを渡す。読める版を整数で並べる。

StackNest hands reference files only to viewers that declare support. List the versions the viewer reads.

```xml
<key>StackNestViewerSupport</key>
<dict>
  <key>referenceFormatVersions</key>
  <array><integer>1</integer></array>
</dict>
```

宣言した版を部品が読めないと、StackNest がその版で書いたときに開けない。ビューアの試験に自己点検を 1 つ置く。

If the kit can't read a declared version, files StackNest writes in it won't open. Add one self-check to the viewer's tests.

```swift
import Foundation
import StackNestViewerKit

/// ビューアの試験から呼ぶ（Swift Testing なら `#expect(declarationProblems().isEmpty)`）。
/// Call from the viewer's tests (with Swift Testing: `#expect(declarationProblems().isEmpty)`).
func declarationProblems() -> [StackNestViewerSupport.Issue] {
    StackNestViewerSupport.verify(infoDictionary: Bundle.main.infoDictionary ?? [:])
}
```

## 参照ファイルの型 / The Reference File Type

`UTImportedTypeDeclarations` で `app.shelfsmith.stacknest.book-reference`（`public.json` に準拠・拡張子
`stacknestbook`）を取り込み、`CFBundleDocumentTypes` で書類として受け付ける（`application(_:open:)` に届く）。
StackNest は `open -a` でアプリを名指しするので、順位は `Alternate` で足りる。

Import `app.shelfsmith.stacknest.book-reference` (conforms to `public.json`, extension `stacknestbook`) and accept
it as a document type. StackNest names the app when it opens the file, so the `Alternate` rank is enough.

```xml
<key>UTImportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>app.shelfsmith.stacknest.book-reference</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeDescription</key><string>StackNest Book Reference</string>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>stacknestbook</string></array></dict>
  </dict>
</array>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>StackNest Book Reference</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>app.shelfsmith.stacknest.book-reference</string></array>
  </dict>
</array>
```

## 通信の許可 / Network Access

StackNest は 127.0.0.1 で平文の HTTP を話す。App Transport Security でローカルの通信を許し、サンドボックスの
アプリには外への接続（client）の権限を付ける。任意の宛先への平文の HTTP（`NSAllowsArbitraryLoads`）は要らない。

StackNest speaks plain HTTP on 127.0.0.1. Allow local networking in App Transport Security, and give a sandboxed app
the outgoing (client) network entitlement. Arbitrary loads aren't needed.

```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsLocalNetworking</key><true/></dict>
```

Xcode のビルド設定では `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`（エンタイトルメント
`com.apple.security.network.client`）。部品は既定で `127.0.0.1` と `::1` にしかつながない（<doc:Security>）。

In Xcode build settings, set `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` (the
`com.apple.security.network.client` entitlement). The kit connects only to `127.0.0.1` and `::1` by default.
