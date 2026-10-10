/// 部品の版。リリースの検査（`Scripts/release.sh`）が CHANGELOG とタグに突き合わせる。
///
/// The kit's version. The release check (`Scripts/release.sh`) matches it against the changelog and the tag.
public enum StackNestViewerKitInfo {
    /// semver の版（`X.Y.Z`）。 / The semantic version (`X.Y.Z`).
    public static let version = "0.1.0"
}
