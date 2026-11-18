#!/usr/bin/env bash
set -euo pipefail

repo=$1
tag=$2
build=$3
directory=$4
: "${GH_TOKEN:?The publisher requires a GitHub token with contents write access}"
[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]]
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$build" =~ ^[1-9][0-9]{0,9}$ && "$build" -le 2100000000 ]]

apk="mianban-android-${tag#v}-$build.apk"
cd "$directory"
sha256sum --check "$apk.sha256"
digest="sha256:$(sha256sum "$apk" | cut -d' ' -f1)"

repository=$(gh api "repos/$repo")
[[ "$(jq -r '.private' <<< "$repository")" == 'false' ]]
releases=$(gh api --paginate --slurp "repos/$repo/releases?per_page=100")
existing=$(jq -c --arg tag "$tag" 'flatten | map(select(.tag_name == $tag)) | first // empty' <<< "$releases")
if [[ -n "$existing" && "$(jq -r '.draft' <<< "$existing")" == 'false' ]]; then
  if jq -e --arg apk "$apk" --arg digest "$digest" \
    '.prerelease == false and any(.assets[]; .name == $apk and .digest == $digest)' <<< "$existing" >/dev/null; then
    echo "$tag is already published with the same APK"
    exit 0
  fi
  echo "$tag is already published with different assets" >&2
  exit 1
fi

highest_build=$(jq -r '[flatten[] | select(.draft == false and .prerelease == false) | .assets[].name
  | capture("^mianban-android-[0-9]+\\.[0-9]+\\.[0-9]+-(?<build>[0-9]+)\\.apk$") | .build | tonumber] | max // 0' <<< "$releases")
if (( build <= highest_build )); then
  echo "Build number must be greater than $highest_build" >&2
  exit 1
fi

if [[ -z "$existing" ]]; then
  gh release create "$tag" "$apk" "$apk.sha256" --repo "$repo" --verify-tag \
    --draft --title "眠伴 Android ${tag#v}" --notes "眠伴 Android ${tag#v} 正式签名安装包。"
else
  gh release upload "$tag" "$apk" "$apk.sha256" --repo "$repo" --clobber
fi

draft=$(gh api --paginate --slurp "repos/$repo/releases?per_page=100" |
  jq -ec --arg tag "$tag" 'flatten | map(select(.tag_name == $tag and .draft)) | first')
if ! jq -e --arg apk "$apk" --arg digest "$digest" \
  '[.assets[] | select(.name | test("^mianban-android-.*\\.apk$"))] | length == 1 and .[0].name == $apk and .[0].digest == $digest and .[0].state == "uploaded"' \
  <<< "$draft" >/dev/null; then
  echo 'The GitHub release APK failed verification' >&2
  exit 1
fi
gh release edit "$tag" --repo "$repo" --draft=false --prerelease=false --latest
