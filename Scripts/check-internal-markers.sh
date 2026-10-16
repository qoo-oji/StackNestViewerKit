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

# 検査はすべて C ロケールで動かす。UTF-8 のロケールだと、UTF-8 として読めないバイトの行で macOS の awk が
# 途中で止まり（終了コード 0 のことがある）、それより後の行を見ないまま「一致なし」になる。
export LC_ALL=C

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
    local patch added hits rc=0
    patch="$(git -C "$ROOT" log -p --diff-merges=first-parent --no-color --no-ext-diff --format='commit %h' "$@")" \
        || fail "git log -p failed: $*"
    # awk と grep を 1 本のパイプにすると awk の失敗が grep の「一致なし(1)」に隠れるので、段を分ける
    added="$(printf '%s\n' "$patch" \
        | awk '/^diff --git /{h=0; next} /^@@/{h=1; next} h && /^\+/{print substr($0, 2)}')" \
        || fail "awk failed on the outgoing patches"
    hits="$(printf '%s\n' "$added" | grep -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the added lines (exit $rc)"   # 一致なし(1)と取り違えない
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "internal-markers: internal marker added by an outgoing commit (even if removed later)" >&2
        found=1
    fi
}

check_paths() {
    local names hits rc=0
    names="$(git -C "$ROOT" log --diff-merges=first-parent --format= --name-only -z --diff-filter=ACR "$@" | tr '\0' '\n')" \
        || fail "git log --name-only failed: $*"
    hits="$(printf '%s\n' "$names" | grep -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the file names (exit $rc)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "internal-markers: internal marker in a file name added by an outgoing commit" >&2
        found=1
    fi
}

check_messages() {
    local log hits rc=0
    log="$(git -C "$ROOT" log --format='%B' "$@")" || fail "git log failed: $*"
    hits="$(printf '%s\n' "$log" | grep -n -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the commit messages (exit $rc)"
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
    # 省略可の第 2 引数: push 先の remote の名前（pre-push フックの $1）。新しい ref では、その remote の追跡 ref に無い
    # コミットだけを新しいものとして見る（別の remote にあるだけのコミットを見逃さない）。
    remote="${2:-}"
    while read -r local_ref local_sha remote_ref remote_sha; do
        [ "$local_sha" = "$ZERO" ] && continue
        check_tree "$local_sha"
        if [ "$remote_sha" = "$ZERO" ]; then
            if [ -z "$remote" ]; then NOT=(--not --remotes)
            elif git -C "$ROOT" remote | grep -Fxq -- "$remote"; then NOT=(--not "--remotes=$remote")
            else NOT=(); fi                              # URL への push: 追跡 ref が無いので履歴をすべて見る
            check_range "$local_sha" ${NOT[@]+"${NOT[@]}"}
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
