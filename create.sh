#!/bin/bash
# Creates specified trusted artifacts
set -o errexit
set -o nounset
set -o pipefail

# contains name=path artifact pairs
artifact_pairs=()

result_path=/tekton/results/ARTIFACT

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

results=()
for artifact_pair in "${artifact_pairs[@]}"; do
    name="${artifact_pair/=*}"
    dir="${artifact_pair/*=}"

    archive="${store}/${name}".tar.gz

    if [ -d "${dir}" ]; then
        # archive the whole directory
        tar -czf "${archive}" -C "${dir}" .
    else
        # archive a single file
        tar -czf "${archive}" -C "${dir%/*}" "${dir##*/}"
    fi

    sha256sum_output="$(sha256sum "${archive}")"
    results+=("file:${name}@sha256:${sha256sum_output/ */}")

    echo Created artifact "${name}" from "${dir}"
done

printf -v r '"%s",' "${results[@]}"

echo "[${r%,}]" > "${result_path}"
