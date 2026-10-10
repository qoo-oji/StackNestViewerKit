# 版 / Versions

部品の版（semver）と参照ファイルの版（整数）は別の軸。

The kit's version (semver) and the reference file's version (an integer) are separate.

## 参照ファイルの版 / Reference File Versions

部品 0.1.x が読み書きできるのは版 1（``StackNestFormat/supportedVersions``）。ビューアは読める版を `Info.plist` に
宣言し、StackNest は宣言と自分の書ける版の共通の最大で書く。部品は実行時に交渉せず、読めない版は
`unsupportedVersion`。

Kit 0.1.x reads and writes version 1. The viewer declares the versions it reads in `Info.plist`, and StackNest writes the highest
version both support. The kit doesn't negotiate at run time; unreadable versions fail with `unsupportedVersion`.

```swift
import StackNestViewerKit

let writable = StackNestViewerSupport.chooseVersion(declared: [1, 2], writable: StackNestFormat.supportedVersions)
```

## 部品の版 / Kit Versions

0.x の間は、壊す変更は minor を上げる（ホストは次の minor までに固定する）。読める参照ファイルの版を足すのは minor、
落とすのは major。名乗りの `kit=` で、StackNest の記録から部品の版が分かる。

While the kit is 0.x, breaking changes bump the minor version, so pin to the next minor. Adding a readable reference
version is a minor change; dropping one is a major change. The `kit=` parameter of the identification header tells
StackNest which kit version a viewer uses.

Public enums (`StackNestReadingDirection`, `StackNestLanguage`, `StackNestRequestPriority`,
`StackNestViewerSupport.Issue`, and the Testing target's `Route` and `Response`) may gain cases in a 0.x minor
version, so switch with a `default` case.

公開の enum は、0.x の minor でケースが増えることがある。`switch` には `default` を書く。

```swift
import StackNestViewerKit

let identification = StackNestViewerIdentification.forMainBundle(format: 1)
let header = identification.headerValue  // 例: com.example.viewer/1.80; format=1; kit=0.1.0
```
