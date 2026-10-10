#!/bin/sh
# リリースの前の検査（Scripts/release-check.py）。タグの作成・push はしない。
# 使い方: Scripts/release.sh X.Y.Z [--remote <remote>]
set -eu
exec python3 -B "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/release-check.py" "$@"
