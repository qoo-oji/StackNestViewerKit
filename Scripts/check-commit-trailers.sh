#!/usr/bin/env bash
# 公開のコミットに Claude-Session: の行（会話の URL）を残さないための検査（このリポジトリの決まり。CONTRIBUTING.md）。
# 個人識別子の検査（check-private-identifiers.sh）とは別の、リポジトリの中に書いてよい固定の規則。行頭の
# `Claude-Session:`（大文字小文字・行頭の空白を問わない）と、書き方を変えた会話の URL（claude.ai の code/session_ で始まる道）を止める。
#
# 使い方:
#   check-commit-trailers.sh message <file>      コミットのメッセージのファイルを検査する（commit-msg フックが呼ぶ）
#   check-commit-trailers.sh pre-push            pre-push フックの標準入力（ref の組）を読み、push する新しいコミットの
#                                                メッセージを検査する
#   check-commit-trailers.sh range <rev>...      git log に渡す範囲（例: 0.1.0..HEAD）のメッセージを検査する
# 見つかったらコミットと行を出して終了コード 1。見つからなければ 0。
set -euo pipefail

ZERO="0000000000000000000000000000000000000000"
found=0

fail() { echo "commit-trailers: $*" >&2; exit 1; }

# 標準入力の行のうち、決まりに外れるものを「<印>: <行>」で出す（印はコミットの短い SHA か message）。
scan() {
    awk -v label="$1" '
        /^@@commit@@ /{label=$2; next}
        tolower($0) ~ /^[[:space:]]*claude-session:/ || tolower($0) ~ /claude[.]ai\/code\/session_/ {print label ": " $0}
    '
}

report() {
    if [ -n "$1" ]; then
        echo "$1" >&2
        echo "commit-trailers: a commit message carries a Claude-Session: line or a session URL (this repository allows only Co-Authored-By)" >&2
        found=1
    fi
}

check_range() {
    local log
    log="$(git log --format='@@commit@@ %h%n%B' "$@")" || fail "git log failed: $*"
    report "$(printf '%s\n' "$log" | scan "?")"
}

case "${1:-}" in
message)
    [ -n "${2:-}" ] && [ -r "$2" ] || fail "usage: $0 message <file>"
    report "$(scan message < "$2")"
    ;;
pre-push)
    while read -r local_ref local_sha remote_ref remote_sha; do
        [ "$local_sha" = "$ZERO" ] && continue          # ref の削除は検査しない
        if [ "$remote_sha" = "$ZERO" ]; then
            check_range "$local_sha" --not --remotes     # 新しい ref: どの remote にも無いコミット
        else
            check_range "$remote_sha..$local_sha"
        fi
    done
    ;;
range)
    shift
    [ "$#" -gt 0 ] || fail "usage: $0 range <rev>..."
    check_range "$@"
    ;;
*)
    fail "usage: $0 message <file> | pre-push | range <rev>..."
    ;;
esac

if [ "$found" -ne 0 ]; then
    echo "commit-trailers: refused. Remove the Claude-Session: line (keep only Co-Authored-By) and retry." >&2
    exit 1
fi
exit 0
