#!/bin/bash
# Restores a trusted artifact, content of the destination will be removed.
set -o errexit
set -o nounset
set -o pipefail

tar_opts=-xpf
if [[ ! -z "${DEBUG:-}" ]]; then
  tar_opts=-xvpf
  set -o xtrace
fi

supported_digest_algorithms=(sha256 sha384 sha512)

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

    if [ -f "${destination}/.skip-trusted-artifacts" ]; then
      echo WARN: found skip file in "${destination}"
      continue
    fi

    type="${uri/:*}"

    if [ "${type}" != "file" ]; then
        echo Unsupported archive type: "${type}"
        exit 1
    fi

    name="${uri#*:}"
    name="${name/:*}"

    archive="${store}/${name}".tar.gz

    if [ ! -f "${archive}" ]; then
        echo "Archive not produced: ${uri}"
        exit 1
    fi

    digest_algorithm=${uri/-*}
    digest_algorithm=${digest_algorithm/*:}
    supported=0
    case "${supported_digest_algorithms[@]}" in *"${digest_algorithm}"*) supported=1 ;; esac
    if [ $supported -eq 0 ]; then
        echo "Unsupported digest algorthm: ${digest_algorithm}"
        exit 1
    fi
    digest="${uri/*-}"

    echo "${digest} ${archive}" | "${digest_algorithm}sum" --check --quiet --strict

    if [ -d "${destination}" ]; then
        (
            shopt -s dotglob
            log "deleting everything in %s" "${destination}"
            rm -rf "${destination:?}"/*
        )
    fi

    mkdir -p "${destination}"

    log "destination: %s" "$(ls -lda "${destination}")"

    log "expanding archive %s to %s" "${archive}" "${destination}"

    tar "${tar_opts}" "${archive}" -C "${destination}"

    echo Restored artifact to "${destination} (${digest_algorithm}:${digest})"
done
