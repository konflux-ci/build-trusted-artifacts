#!/bin/bash
# Creates specified trusted artifacts
set -o errexit
set -o nounset
set -o pipefail

tar_opts=-czf
if [[ ! -z "${DEBUG:-}" ]]; then
  tar_opts=-cvzf
  set -o xtrace
fi

# contains {result path}={artifact source path} pairs
artifact_pairs=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --store)
        store="$2"
        shift
        shift
        ;;
        --results)
        result_path="$2"
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
    result_path="${artifact_pair/=*}"
    path="${artifact_pair/*=}"

    if [ -f "${path}/.skip-trusted-artifacts" ]; then
      echo WARN: found skip file in "${path}"
      continue
    fi

    archive="$(mktemp).tar.gz"

    log "creating tar archive %s with files from %s" "${archive}" "${path}"

    if [ ! -r "${path}" ]; then
        # non-existent paths result in empty archives
        tar "${tar_opts}" "${archive}" --files-from /dev/null
    elif [ -d "${path}" ]; then
        # archive the whole directory
        tar "${tar_opts}" "${archive}" -C "${path}" .
    else
        # archive a single file
        tar "${tar_opts}" "${archive}" -C "${path%/*}" "${path##*/}"
    fi

    sha256sum_output="$(sha256sum "${archive}")"
    digest="${sha256sum_output/ */}"
    artifact="${store}/sha256-${digest}.tar.gz"
    mv "${archive}" "${artifact}"
    echo -n "file:sha256-${digest}" > "${result_path}"

    echo Created artifact from "${path} (sha256:${digest})"
done
