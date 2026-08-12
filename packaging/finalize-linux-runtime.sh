#!/bin/sh
set -eu
export LC_ALL=C

package_root=$1
output=$2
expected='README.txt
bin/assets/audio/lost.audio.wav
bin/assets/audio/won.audio.wav
bin/assets/renderer2d/goal.texture
bin/assets/renderer2d/test.texture
bin/assets/scenes/preview.scene
bin/assets/scenes/preview.scene.json
bin/assets/scripts/patrol.luau
bin/assets/scripts/preview.script
bin/assets/scripts/preview.script.json
bin/kadath'

test -d "$package_root"
if find "$package_root" -path "$package_root/dist" -prune -o -type l -print -quit | grep -q .; then
    echo 'Linux Runtime package cannot contain symlinks' >&2
    exit 1
fi
if find "$package_root" -path "$package_root/dist" -prune -o ! -type d ! -type f -print -quit | grep -q .; then
    echo 'Linux Runtime package contains a non-regular entry' >&2
    exit 1
fi
if find "$package_root" -path "$package_root/dist" -prune -o -type f -links +1 -print -quit | grep -q .; then
    echo 'Linux Runtime package cannot contain hardlinks' >&2
    exit 1
fi
actual=$(find "$package_root" -path "$package_root/dist" -prune -o -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort)
test "$actual" = "$expected"

temporary="$output.tmp.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
(
    cd "$package_root"
    printf '%s\n' "$expected" | while IFS= read -r path; do
        sha256sum -- "$path"
    done
) > "$temporary"
mv "$temporary" "$output"
trap - EXIT HUP INT TERM
