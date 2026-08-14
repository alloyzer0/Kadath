#!/bin/sh
set -eu
export LC_ALL=C

package_root=$1
archive_path=$2
archive_root=kadath-linux-x86_64
files='README.txt
SHA256SUMS
behavior-tools/kadath-behavior-tool
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

test -f "$package_root/SHA256SUMS"
if find "$package_root" -path "$package_root/dist" -prune -o ! -type d ! -type f -print -quit | grep -q .; then
    echo 'Linux Runtime package contains a non-regular entry' >&2
    exit 1
fi
if find "$package_root" -path "$package_root/dist" -prune -o -type f -links +1 -print -quit | grep -q .; then
    echo 'Linux Runtime package cannot contain hardlinks' >&2
    exit 1
fi
(cd "$package_root" && sha256sum -c SHA256SUMS)

stage=$(mktemp -d)
tar_path=$(mktemp)
temporary_archive="$archive_path.tmp.$$"
cleanup() {
    rm -rf "$stage"
    rm -f "$tar_path" "$temporary_archive"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$stage/$archive_root"
printf '%s\n' "$files" | while IFS= read -r path; do
    test -f "$package_root/$path"
    case "$path" in
        /*|../*|*/../*|*/..) exit 1 ;;
    esac
    mkdir -p "$stage/$archive_root/$(dirname "$path")"
    cp -- "$package_root/$path" "$stage/$archive_root/$path"
done
chmod 755 "$stage/$archive_root/bin/kadath"
chmod 755 "$stage/$archive_root/behavior-tools/kadath-behavior-tool"
find "$stage/$archive_root" -type f \
    ! -path "$stage/$archive_root/bin/kadath" \
    ! -path "$stage/$archive_root/behavior-tools/kadath-behavior-tool" \
    -exec chmod 644 {} +
find "$stage/$archive_root" -type d -exec chmod 755 {} +

tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=ustar -C "$stage" -cf "$tar_path" "$archive_root"
mkdir -p "$(dirname "$archive_path")"
gzip -n -9 -c "$tar_path" > "$temporary_archive"
mv "$temporary_archive" "$archive_path"
trap - EXIT HUP INT TERM
cleanup
