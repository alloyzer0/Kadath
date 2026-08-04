#!/bin/sh
set -eu
export LC_ALL=C

archive_path=$1
window_verifier=$2
platform_test=$3
profile=$4
evidence_base=$5
archive_root=kadath-linux-x86_64
expected='README.txt
SHA256SUMS
bin/assets/audio/lost.audio.wav
bin/assets/audio/won.audio.wav
bin/assets/renderer2d/goal.texture
bin/assets/renderer2d/test.texture
bin/assets/scenes/preview.scene
bin/assets/scenes/preview.scene.json
bin/assets/scripts/preview.script
bin/assets/scripts/preview.script.json
bin/kadath'
expected_archive_entries='kadath-linux-x86_64/
kadath-linux-x86_64/README.txt
kadath-linux-x86_64/SHA256SUMS
kadath-linux-x86_64/bin/
kadath-linux-x86_64/bin/assets/
kadath-linux-x86_64/bin/assets/audio/
kadath-linux-x86_64/bin/assets/audio/lost.audio.wav
kadath-linux-x86_64/bin/assets/audio/won.audio.wav
kadath-linux-x86_64/bin/assets/renderer2d/
kadath-linux-x86_64/bin/assets/renderer2d/goal.texture
kadath-linux-x86_64/bin/assets/renderer2d/test.texture
kadath-linux-x86_64/bin/assets/scenes/
kadath-linux-x86_64/bin/assets/scenes/preview.scene
kadath-linux-x86_64/bin/assets/scenes/preview.scene.json
kadath-linux-x86_64/bin/assets/scripts/
kadath-linux-x86_64/bin/assets/scripts/preview.script
kadath-linux-x86_64/bin/assets/scripts/preview.script.json
kadath-linux-x86_64/bin/kadath'

test -f "$archive_path"
mkdir -p "$evidence_base"
evidence_root="$evidence_base/$profile-$$-$(date +%s)"
mkdir "$evidence_root"
extract_root=$(mktemp -d /tmp/kadath-linux-package-verify.XXXXXX)
trap 'rm -rf "$extract_root"' EXIT HUP INT TERM

tar -tzf "$archive_path" > "$evidence_root/archive-entries.txt"
if grep -E '(^/|(^|/)\.\.(/|$))' "$evidence_root/archive-entries.txt"; then
    echo 'Archive contains an unsafe path' >&2
    exit 1
fi
actual_archive_entries=$(cat "$evidence_root/archive-entries.txt")
if test "$actual_archive_entries" != "$expected_archive_entries"; then
    echo 'Archive entries do not match the fixed Linux Runtime allowlist' >&2
    exit 1
fi
tar -xzf "$archive_path" -C "$extract_root" --no-same-owner --no-same-permissions
package_root="$extract_root/$archive_root"
test -d "$package_root/bin"
if find "$package_root" ! -type d ! -type f -print -quit | grep -q .; then
    echo 'Extracted package contains a non-regular entry' >&2
    exit 1
fi
if find "$package_root" -type f -links +1 -print -quit | grep -q .; then
    echo 'Extracted package contains a hardlink' >&2
    exit 1
fi
actual=$(find "$package_root" -type f -printf '%P\n' | LC_ALL=C sort)
test "$actual" = "$expected"
(cd "$package_root" && sha256sum -c SHA256SUMS) > "$evidence_root/manifest-check.txt"

readelf -d "$package_root/bin/kadath" > "$evidence_root/readelf-dynamic.txt"
if grep -E '\((RPATH|RUNPATH)\)' "$evidence_root/readelf-dynamic.txt"; then
    echo 'Packaged Runtime contains RPATH/RUNPATH' >&2
    exit 1
fi
grep -F 'Shared library: [libxcb.so.1]' "$evidence_root/readelf-dynamic.txt" >/dev/null
grep -F 'Shared library: [libvulkan.so.1]' "$evidence_root/readelf-dynamic.txt" >/dev/null
grep -F 'Shared library: [libasound.so.2]' "$evidence_root/readelf-dynamic.txt" >/dev/null

sha256sum "$archive_path" > "$evidence_root/archive.sha256"
cp "$package_root/SHA256SUMS" "$evidence_root/SHA256SUMS"
"$window_verifier" "$platform_test" "$package_root/bin/kadath" "$profile-Package" "$package_root/bin" \
    > "$evidence_root/window-verifier.stdout.log" \
    2> "$evidence_root/window-verifier.stderr.log"
grep -F 'asset_mode=package_root' "$evidence_root/window-verifier.stdout.log" >/dev/null
grep -F 'linux_two_frame_evidence=ok' "$evidence_root/window-verifier.stdout.log" >/dev/null
grep -F 'linux_audio_backend=alsa' "$evidence_root/window-verifier.stdout.log" >/dev/null
grep -F 'linux_audio_lost_cue=ok' "$evidence_root/window-verifier.stdout.log" >/dev/null
grep -F 'linux_audio_won_cue=ok' "$evidence_root/window-verifier.stdout.log" >/dev/null
grep -F 'linux_close_exit=0' "$evidence_root/window-verifier.stdout.log" >/dev/null

"$window_verifier" "$platform_test" "$package_root/bin/kadath" "$profile-AudioFallback" "$package_root/bin" expect-silent-audio \
    > "$evidence_root/audio-fallback.stdout.log" \
    2> "$evidence_root/audio-fallback.stderr.log"
grep -F 'asset_mode=package_root' "$evidence_root/audio-fallback.stdout.log" >/dev/null
grep -F 'linux_audio_fallback=silent' "$evidence_root/audio-fallback.stdout.log" >/dev/null
grep -F 'linux_close_exit=0' "$evidence_root/audio-fallback.stdout.log" >/dev/null

printf 'linux_package_archive=ok\n'
printf 'linux_package_manifest=ok\n'
printf 'linux_package_elf_dependencies=ok\n'
printf 'linux_package_clean_extract=ok\n'
printf 'linux_package_runtime_pixels=ok\n'
printf 'linux_package_audio_feedback=ok\n'
printf 'linux_package_audio_fallback=ok\n'
printf 'linux_package_shutdown=ok\n'
printf 'evidence_root=%s\n' "$evidence_root"
