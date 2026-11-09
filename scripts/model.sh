#!/bin/sh
set -eu

repo=$1
revision=$2
destination=$3
shift 3

[ "$(cat "$destination/.revision" 2>/dev/null)" = "$revision" ] && exit 0

partial="$destination.partial"
rm -rf "$partial"
mkdir -p "$partial"

curl -fsSL "https://huggingface.co/api/models/$repo/tree/$revision?recursive=true" -o "$partial/.tree.json"
jq -r --args '
    [.[] | select(.type == "file")] as $files
    | $ARGS.positional[] as $wanted
    | [$files[] | select(.path == $wanted or (.path | startswith($wanted + "/")))]
    | if length == 0 then error("\($wanted) is not in the repository") else .[] end
    | [.path, (if .lfs then "sha256" else "blob" end), (.lfs.oid // .oid)]
    | @tsv' "$@" < "$partial/.tree.json" > "$partial/.files"

while IFS="$(printf '\t')" read -r path kind expected; do
    mkdir -p "$partial/$(dirname "$path")"
    echo "$path"
    curl -fL --progress-bar "https://huggingface.co/$repo/resolve/$revision/$path" -o "$partial/$path"
    case $kind in
        sha256) actual=$(shasum -a 256 "$partial/$path" | cut -d ' ' -f 1) ;;
        blob) actual=$(git hash-object "$partial/$path") ;;
    esac
    if [ "$actual" != "$expected" ]; then
        echo "$path: expected $kind $expected, got $actual" >&2
        exit 1
    fi
done < "$partial/.files"

rm "$partial/.tree.json" "$partial/.files"
echo "$revision" > "$partial/.revision"
rm -rf "$destination"
mv "$partial" "$destination"
echo "model: $destination"
