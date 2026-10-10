#!/usr/bin/env bash
# 内部の印（内部の作業の番号・計画の文書の名前・ホームのパス・会話の URL など）を公開の場に出さないための検査。
# 語彙は Scripts/internal-markers.txt（リポジトリの中に書いてよい固定の規則。個人識別子の一覧とは別）。
# 形は check-private-identifiers.sh と同じ（送るコミットのファイル全体・足した行・ファイル名・メッセージ）。
#
# 使い方:
#   check-internal-markers.sh pre-push          pre-push フックの標準入力（ref の組）を読んで検査する
#   check-internal-markers.sh tree <rev>        <rev> のファイル全体を検査する（手作業の点検はこれを使う）
#   check-internal-markers.sh range <rev>...    範囲のコミットで足した行・ファイル名・メッセージを検査する
#   check-internal-markers.sh text [file...]    ファイル（無ければ標準入力）の文面を検査する
# 見つかったら該当箇所を出して終了コード 1。見つからなければ 0。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="$ROOT/Scripts/internal-markers.txt"
ZERO="0000000000000000000000000000000000000000"

fail() { echo "internal-markers: $*" >&2; exit 1; }

[ -r "$LIST" ] || fail "marker list not found: $LIST"
PATTERNS="$(mktemp -t internal-markers)"
trap 'rm -f "$PATTERNS"' EXIT
grep -v -E '^[[:space:]]*(#|$)' "$LIST" > "$PATTERNS" || true
[ -s "$PATTERNS" ] || fail "marker list is empty: $LIST"

found=0

check_tree() {
    local rev="$1" rc=0
    git -C "$ROOT" grep -I -n -E -f "$PATTERNS" "$rev" -- . >&2 || rc=$?
    case "$rc" in
    0) echo "internal-markers: internal marker found in the files of $rev" >&2; found=1 ;;
    1) ;;
    *) fail "git grep failed on $rev (exit $rc)" ;;
    esac
}

check_patches() {
    local patch hits
    patch="$(git -C "$ROOT" log -p --diff-merges=first-parent --no-color --no-ext-diff --format='commit %h' "$@")" \
        || fail "git log -p failed: $*"
    hits="$(printf '%s\n' "$patch" \
        | awk '/^diff --git /{h=0; next} /^@@/{h=1; next} h && /^\+/{print substr($0, 2)}' \
        | grep -E -f "$PATTERNS" || true)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "internal-markers: internal marker added by an outgoing commit (even if removed later)" >&2
        found=1
    fi
}

check_paths() {
    local names hits
    names="$(git -C "$ROOT" log --diff-merges=first-parent --format= --name-only -z --diff-filter=ACR "$@" | tr '\0' '\n')" \
        || fail "git log --name-only failed: $*"
    hits="$(printf '%s\n' "$names" | grep -E -f "$PATTERNS" || true)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "internal-markers: internal marker in a file name added by an outgoing commit" >&2
        found=1
    fi
}

check_messages() {
    local log hits
    log="$(git -C "$ROOT" log --format='%B' "$@")" || fail "git log failed: $*"
    hits="$(printf '%s\n' "$log" | grep -n -E -f "$PATTERNS" || true)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "internal-markers: internal marker found in commit messages" >&2
        found=1
    fi
}

check_range() {
    check_messages "$@"
    check_patches "$@"
    check_paths "$@"
}

case "${1:-}" in
pre-push)
    while read -r local_ref local_sha remote_ref remote_sha; do
        [ "$local_sha" = "$ZERO" ] && continue
        check_tree "$local_sha"
        if [ "$remote_sha" = "$ZERO" ]; then
            check_range "$local_sha" --not --remotes
        else
            check_range "$remote_sha..$local_sha"
        fi
    done
    ;;
tree)
    [ -n "${2:-}" ] || fail "usage: $0 tree <rev>"
    check_tree "$2"
    ;;
range)
    shift
    [ "$#" -gt 0 ] || fail "usage: $0 range <rev>..."
    check_range "$@"
    ;;
text)
    shift
    rc=0
    if [ "$#" -eq 0 ]; then
        grep -n -E -f "$PATTERNS" >&2 || rc=$?
    else
        grep -n -E -f "$PATTERNS" "$@" >&2 || rc=$?
    fi
    case "$rc" in
    0) echo "internal-markers: internal marker found in the text" >&2; found=1 ;;
    1) ;;
    *) fail "could not read the text (grep exit $rc)" ;;
    esac
    ;;
*)
    fail "usage: $0 pre-push | tree <rev> | range <rev>... | text [file...]"
    ;;
esac

if [ "$found" -ne 0 ]; then
    echo "internal-markers: refused. Rewrite the lines above without internal markers and retry." >&2
    exit 1
fi
exit 0
