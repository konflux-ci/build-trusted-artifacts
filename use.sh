#!/bin/bash
# Restores a trusted artifact, content of the destination will be removed.
set -o errexit
set -o nounset
set -o pipefail

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
    destination="${artifact_pair/*=}"

    if [ "$(realpath "${destination}")" == "/" ]; then
      echo Not a valid destination: "${destination}", resolves to /
      exit 1
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
            rm -rf "${destination:?}"/*
        )
    fi

    mkdir -p "${destination}"

    tar -xpf "${archive}" -C "${destination}"

    echo Restored artifact to "${destination} (${digest_algorithm}:${digest})"
done
