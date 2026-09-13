#!/usr/bin/env bash
set -euo pipefail

token=${GH_TOKEN:?}
unset GH_TOKEN
credentials=$(mktemp -d "$LAYOUT/.oras-auth.XXXXXX")
trap 'rm -rf "$credentials"' EXIT

printf '%s' "$token" | oras login ghcr.io --username "$GITHUB_ACTOR" \
    --password-stdin --registry-config "$credentials/config.json" \
    --ca-file "$NERVES_MACOS_CACERT"
unset token

oras cp --from-oci-layout "$LAYOUT:image" "$REFERENCE" \
    --to-registry-config "$credentials/config.json" \
    --to-ca-file "$NERVES_MACOS_CACERT" --concurrency 2 --no-tty
