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
rc=0
grep -v -E '^[[:space:]]*(#|$)' "$LIST" > "$PATTERNS" || rc=$?
[ "$rc" -le 1 ] || fail "could not read the marker list: $LIST (grep exit $rc; refusing)"   # 1 は「採る行が無い」だけ
[ -s "$PATTERNS" ] || fail "marker list is empty: $LIST"

# 検査語の照合（grep・git grep）は C ロケールと UTF-8 のロケールの両方で行い、どちらかで当たれば当たりとする。
#   - C ロケール: UTF-8 として読めないバイトを含む行も、バイトのまま照合できる（UTF-8 の grep はその行を黙って飛ばす）。
#   - UTF-8 のロケール: 「.」や [ ] の中の漢字・全角の空白、全角文字の大文字小文字の無視など、文字として扱う書き方の検査語が
#     当たる（C ではバイト単位になり当たらない）。
# どちらかの実行が失敗（終了コード 0・1 以外）したら止まる。UTF-8 のロケールが無いときも止まる（C だけで続けない）。
# 行を取り出す awk は C ロケールで動かす（UTF-8 だと、不正なバイトの行で終了コード 2 になる。その失敗は呼び出し側が止める）。
# STACKNEST_GUARD_UTF8_LOCALE は試験用（ロケールが無いときの停止を試すために別の名前を渡す）。名前の指定先が UTF-8 でなければ止まる。
UTF8_LOCALE="${STACKNEST_GUARD_UTF8_LOCALE:-en_US.UTF-8}"
available="$(locale -a)" || fail "could not list the locales (locale -a failed); refusing"
case "
$available
" in
*"
$UTF8_LOCALE
"*) ;;
*) fail "the UTF-8 locale $UTF8_LOCALE is not installed (refusing; matching would be bytes-only)" ;;
esac
[ "$(LC_ALL=$UTF8_LOCALE locale charmap)" = "UTF-8" ] || fail "locale $UTF8_LOCALE is not a UTF-8 locale (refusing)"

# 標準入力の文面を 2 つのロケールで grep する。引数は grep の引数。0 = 当たり（行を標準出力へ）、1 = 一致なし、2 = 失敗
both_grep() {
    local input clean out_c out_u rc_c=0 rc_u=0
    input="$(cat)" || return 2
    out_c="$(printf '%s\n' "$input" | LC_ALL=C grep "$@")" || rc_c=$?
    # UTF-8 の grep は、不正なバイトを含む行を黙って飛ばす。UTF-8 の実行には、不正な並びを落とした写し（改行は残るので
    # 行番号は同じ）を渡す。先に変数へ取る（iconv の失敗をパイプの中で隠さない）。不正なバイトの行の中の識別子は C の実行が拾う
    clean="$(printf '%s\n' "$input" | iconv -f UTF-8 -t UTF-8 -c)" || return 2
    out_u="$(printf '%s\n' "$clean" | LC_ALL="$UTF8_LOCALE" grep "$@")" || rc_u=$?
    { [ "$rc_c" -le 1 ] && [ "$rc_u" -le 1 ]; } || return 2
    [ -n "$out_c$out_u" ] || return 1
    { [ -z "$out_c" ] || printf '%s\n' "$out_c"; [ -z "$out_u" ] || printf '%s\n' "$out_u"; } | LC_ALL=C sort -u || return 2
    return 0
}

# git grep を 2 つのロケールで行う（引数は git grep の引数）。同じ約束: 0 = 当たり、1 = 一致なし、2 = 失敗
both_git_grep() {
    local out_c out_u rc_c=0 rc_u=0
    out_c="$(LC_ALL=C git "$@")" || rc_c=$?
    out_u="$(LC_ALL="$UTF8_LOCALE" git "$@")" || rc_u=$?
    { [ "$rc_c" -le 1 ] && [ "$rc_u" -le 1 ]; } || return 2
    [ -n "$out_c$out_u" ] || return 1
    { [ -z "$out_c" ] || printf '%s\n' "$out_c"; [ -z "$out_u" ] || printf '%s\n' "$out_u"; } | LC_ALL=C sort -u || return 2
    return 0
}

found=0

check_tree() {
    local rev="$1" rc=0 hits
    hits="$(both_git_grep -C "$ROOT" grep -I -n -E -f "$PATTERNS" "$rev" -- .)" || rc=$?
    case "$rc" in
    0) echo "$hits" >&2; echo "internal-markers: internal marker found in the files of $rev" >&2; found=1 ;;
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
        | LC_ALL=C awk '/^diff --git /{h=0; next} /^@@/{h=1; next} h && /^\+/{print substr($0, 2)}')" \
        || fail "awk failed on the outgoing patches"
    hits="$(printf '%s\n' "$added" | both_grep -E -f "$PATTERNS")" || rc=$?
    [ "$rc" -le 1 ] || fail "grep failed on the added lines (exit $rc)"   # 一致なし(1)と取り違えない
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "internal-markers: internal marker added by an outgoing commit (even if removed later)" >&2
        found=1
    fi
}

check_paths() {
    local names hits rc=0
    names="$(git -C "$ROOT" log --diff-merges=first-parent --format= --name-only -z --diff-filter=ACR "$@" | LC_ALL=C tr '\0' '\n')" \
        || fail "git log --name-only failed: $*"
    hits="$(printf '%s\n' "$names" | both_grep -E -f "$PATTERNS")" || rc=$?
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
    hits="$(printf '%s\n' "$log" | both_grep -n -E -f "$PATTERNS")" || rc=$?
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
    # 先に全部を読む（cat の失敗をパイプの中で「一致なし」に埋もれさせない）
    if [ "$#" -eq 0 ]; then text="$(cat)" || fail "could not read the text (stdin)"
    else
        # ファイルごとに読み、最後に改行を足す（末尾の改行の無いファイルの最後の行が次のファイルの先頭行と繋がらないように）
        text="$(for f in "$@"; do cat -- "$f" || exit 1; printf '\n'; done)" || fail "could not read the text"
    fi
    hits="$(printf '%s\n' "$text" | both_grep -n -E -f "$PATTERNS")" || rc=$?
    case "$rc" in
    0) echo "$hits" >&2; echo "internal-markers: internal marker found in the text" >&2; found=1 ;;
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
