#!/bin/bash
# Restores a trusted artifact, content of the destination will be removed.
#
# The --store parameter is ignored. It is kept to maintain compatibility with other storage types.
#
# Positional parametes are artifact pairs. These are strings. Each contains two parts separated by
# an equal sign (=). The left portion refers to the uri of where the artifact can be fetch from.
# This must be prefixed with "oci:" to indicate that it is indeed meant to be processed by this
# script. The right side specifies where the artifact will be extracted to. For example,
# oci:registry/org/repo:latest@sha256:123=/home/user/Downloads/artifact means the artifact will be
# fetched from registry/org/repo and extract to the /home/user/Downloads/artifact directory.
#
set -o errexit
set -o nounset
set -o pipefail

tar_opts=-zxpf
if [[ -v DEBUG ]]; then
  tar_opts=-zxvpf
  set -o xtrace
fi

# contains name=path artifact pairs
artifact_pairs=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --store)
        store="$2"
        shift
        shift
        ;;
    -*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      artifact_pairs+=("$1")
      shift
      ;;
  esac
done

for artifact_pair in "${artifact_pairs[@]}"; do
    uri="${artifact_pair/=*}"
    destination="$(realpath "${artifact_pair/*=}")"

    if [ -z "${uri}" ]; then
        echo WARN: artifact URI not provided, "(given: ${artifact_pair})"
        continue
    fi

    if [ -z "${destination}" ]; then
        echo WARN: destination not provided, "(given: ${artifact_pair})"
        continue
    fi

    if [ "${destination}" == "/" ]; then
      echo Not a valid destination: "${destination}", resolves to /
      exit 1
    fi

    mkdir -p "${destination}"

    type="${uri/:*}"

    if [ "${type}" != "oci" ]; then
        echo Unsupported archive type: "${type}"
        exit 1
    fi

    name="${uri#*:}"

    oras blob fetch --registry-config <(select-oci-auth.sh ${name}) \
        "${name}" --output - | tar -C "${destination}" "${tar_opts}" -

    echo "Restored artifact ${name} to ${destination}"
done
