#!/usr/bin/env bash
set -euo pipefail

case "$MACOS_MAJOR" in
    15|26|27) ;;
    *) echo "Select macOS 15, 26 or 27" >&2; exit 1 ;;
esac

profile="ci/macos$MACOS_MAJOR.json"
logs=.nerves/ci-logs
version=$(jq -er .macos.version "$profile")
build=$(jq -er .macos.build "$profile")
image_version=$(jq -er .image_version "$profile")
prerelease=$(jq -er '.prerelease | tostring' "$profile")
otp=$(jq -er .otp.version "$profile")
tag="$version-$build-v$image_version"
revision=$(jq -er .revision "$logs/result.json")

jq -e --slurpfile profile "$profile" --slurpfile inputs "$logs/inputs.json" \
    --slurpfile spec "$logs/base-spec.json" '
    .result == "passed" and .macos == $profile[0].macos and
    .image_version == $profile[0].image_version and
    ($inputs[0] | del(.tools)) == $profile[0] and
    $spec[0].format == 1 and $spec[0].macos == .macos and
    $spec[0].image_version == .image_version and $spec[0].source.type == "prebuilt"
' "$logs/result.json"

test "$(git rev-parse "$tag^{commit}")" = "$revision"
digest="sha256:$(shasum -a 256 "$logs/oci-manifest.json" | cut -d ' ' -f 1)"
reference="ghcr.io/cocoa-xu/nerves_system_macos@$digest"
test "$(jq -er .source.reference "$logs/base-spec.json")" = "$reference"

registry_config=$(mktemp)
trap 'rm -f "$registry_config"' EXIT
printf '{}\n' > "$registry_config"
test "$(oras resolve --registry-config "$registry_config" --ca-file "$NERVES_MACOS_CACERT" \
    "ghcr.io/cocoa-xu/nerves_system_macos:$tag")" = "$digest"

grep -Fx "Verified macOS $version ($build), admin, en_US, en-US, U.S." "$logs/published-guest.log" ||
    grep -Fx "Verified macOS $version ($build), admin, en_US, en-US, ABC" "$logs/published-guest.log"
grep -Fx 'Verified an application-free macOS base' "$logs/published-guest.log"
grep -Fx 'Guest shut down cleanly' "$logs/published-guest.log"

cat > "$logs/release-notes.md" <<EOF
Blank arm64 macOS base with SSH and Command Line Tools.

Account and password: \`admin\`. Language: English (United States). Keyboard: U.S./ABC.

\`\`\`sh
tart clone $reference macos-$MACOS_MAJOR
\`\`\`

Use the attached \`base-spec.json\` with \`mix nerves.macos.base prepare\`.
The Nerves system, native example and two cold boots passed with OTP $otp.
The published image was downloaded anonymously and passed an independent blank-base boot.
EOF

options=()
if [ "$prerelease" = true ]; then
    options+=(--prerelease --latest=false)
fi

gh release create "$tag" --repo cocoa-xu/nerves_system_macos --verify-tag \
    --title "macOS $version ($build), image $image_version" \
    --notes-file "$logs/release-notes.md" "${options[@]}" \
    "$logs/base-spec.json" "$logs/inputs.json" "$logs/result.json" "$logs/oci-manifest.json"
