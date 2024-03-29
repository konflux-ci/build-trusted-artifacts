#!/bin/bash
# Selects the expected token from ~/.docker/config.json given an image reference.
#
# The format of ~/.docker/config.json is not well defined. Some clients allow the specification of
# repository specific tokens, e.g. buildah and kubernetes, while others only allow registry specific
# tokens, e.g. oras. This script serves as an adapter to allow repository specific tokens for
# clients that do not support it.
#
# If the provided image reference contains a tag or a digest, those are ignored.
#
# Usage:
# select-oci-auth.sh <repository>
#
# Example:
# select-oci-auth.sh quay.io/lucarval/spam
#
set -o errexit
set -o nounset
set -o pipefail

original_ref="$1"

# Remove digest from image reference
ref="${original_ref/@*}"

# Remove tag from image reference while making sure optional registry port is taken into account
ref="$(echo -n $ref | sed 's_/\(.*\):\(.*\)_/\1_g')"

registry="${ref/\/*}"

while true; do
    token=$(< ~/.docker/config.json jq -c '.auths["'$ref'"]')
    if [[ "$token" != "null" ]]; then
        >&2 echo "Using token for $ref"
        echo -n '{"auths": {"'$registry'": '$token'}}' | jq -c .
        exit 0
    fi

    if [[ "$ref" != *"/"* ]]; then
        break
    fi

    ref="${ref%*/*}"
done

>&2 echo "Token not found for $original_ref"

echo -n '{"auths": {}}'
