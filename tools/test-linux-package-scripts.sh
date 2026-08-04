#!/bin/sh
set -eu

package_root=$1
finalizer=$2
archiver=$3
package_verifier=$4
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT HUP INT TERM

cp -a "$package_root" "$workspace/package"
rm -rf "$workspace/package/dist"
sh "$finalizer" "$workspace/package" "$workspace/manifest"
cmp "$workspace/package/SHA256SUMS" "$workspace/manifest"
sh "$archiver" "$workspace/package" "$workspace/first.tar.gz" >/dev/null
sh "$archiver" "$workspace/package" "$workspace/second.tar.gz" >/dev/null
cmp "$workspace/first.tar.gz" "$workspace/second.tar.gz"
mkdir "$workspace/extracted"
tar -xzf "$workspace/first.tar.gz" -C "$workspace/extracted"
archived_package="$workspace/extracted/kadath-linux-x86_64"
(cd "$archived_package" && sha256sum -c SHA256SUMS) >/dev/null
test -f "$archived_package/bin/assets/scenes/preview.scene.json"
test -f "$archived_package/bin/assets/scripts/preview.script.json"

touch "$workspace/package/unexpected.txt"
if sh "$finalizer" "$workspace/package" "$workspace/unexpected-manifest" >/dev/null 2>&1; then
    echo 'Finalizer accepted an unexpected file' >&2
    exit 1
fi
rm "$workspace/package/unexpected.txt"

ln -s README.txt "$workspace/package/linked-readme"
if sh "$finalizer" "$workspace/package" "$workspace/symlink-manifest" >/dev/null 2>&1; then
    echo 'Finalizer accepted a symlink' >&2
    exit 1
fi
rm "$workspace/package/linked-readme"

ln "$workspace/package/README.txt" "$workspace/package/hardlinked-readme"
if sh "$finalizer" "$workspace/package" "$workspace/hardlink-manifest" >/dev/null 2>&1; then
    echo 'Finalizer accepted a hardlink' >&2
    exit 1
fi
rm "$workspace/package/hardlinked-readme"

printf 'tamper' >> "$workspace/package/README.txt"
if sh "$archiver" "$workspace/package" "$workspace/tampered.tar.gz" >/dev/null 2>&1; then
    echo 'Archiver accepted a manifest mismatch' >&2
    exit 1
fi

printf 'unsafe' > "$workspace/unsafe-entry"
tar -czf "$workspace/unsafe.tar.gz" --transform='s|^unsafe-entry$|../escape|' -C "$workspace" unsafe-entry
if sh "$package_verifier" "$workspace/unsafe.tar.gz" /bin/false /bin/false Unsafe "$workspace/unsafe-evidence" >/dev/null 2>&1; then
    echo 'Package verifier accepted archive traversal' >&2
    exit 1
fi

mkdir "$workspace/outside-root"
tar -xzf "$workspace/first.tar.gz" -C "$workspace/outside-root"
printf 'unexpected' > "$workspace/outside-root/unexpected.txt"
tar -czf "$workspace/outside-root.tar.gz" -C "$workspace/outside-root" kadath-linux-x86_64 unexpected.txt
if sh "$package_verifier" "$workspace/outside-root.tar.gz" /bin/false /bin/false OutsideRoot "$workspace/outside-root-evidence" >/dev/null 2>&1; then
    echo 'Package verifier accepted an entry outside the fixed archive root' >&2
    exit 1
fi

printf 'linux_package_reproducible_archive=ok\n'
printf 'linux_package_archive_manifest=ok\n'
printf 'linux_package_json_templates_archived=ok\n'
printf 'linux_package_unexpected_file_rejected=ok\n'
printf 'linux_package_symlink_rejected=ok\n'
printf 'linux_package_hardlink_rejected=ok\n'
printf 'linux_package_manifest_tamper_rejected=ok\n'
printf 'linux_package_archive_traversal_rejected=ok\n'
printf 'linux_package_outside_root_rejected=ok\n'
