#!/bin/bash
# Restores a trusted artifact, content of the destination will be removed.
#
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
if [[ ! -z "${DEBUG:-}" ]]; then
  tar_opts=-zxvpf
  set -o xtrace
fi

# contains name=path artifact pairs
artifact_pairs=()

while [[ $# -gt 0 ]]; do
  case $1 in
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

# read in any oras options
source oras_opts.sh

tmp_workdir=$(mktemp -d --tmpdir use-oci.sh.XXXXXX)
trap 'rm -rf $tmp_workdir' EXIT

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

    if [ -f "${destination}/.skip-trusted-artifacts" ]; then
      echo WARN: found skip file in "${destination}"
      continue
    fi

    mkdir -p "${destination}"

    type="${uri/:*}"

    if [ "${type}" != "oci" ]; then
        echo Unsupported archive type: "${type}"
        exit 1
    fi

    name="${uri#*:}"

    authfile=$(mktemp --tmpdir="$tmp_workdir" "auth-XXXXXX.json")
    select-oci-auth.sh "$name" > "$authfile"

    retry.sh oras blob fetch "${oras_opts[@]}" --registry-config "$authfile" \
        "${name}" --output - | tar -C "${destination}" "${tar_opts}" -

    echo "Restored artifact ${name} to ${destination}"
done
