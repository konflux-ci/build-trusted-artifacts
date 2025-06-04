#!/bin/bash
# Creates specified trusted artifacts in an OCI repository
#
# The --store parameter is an image reference used to specify the repository, e.g.
# registry.local/org/repo. If the image reference contains a tag, it is ignored.
#
# The --results parameter is unused. It is left here for compatibility with non-oci support.
#
# Positional parametes are artifact pairs. These are strings. Each contains two parts separated by
# an equal sign (=). The left portion refers to the name of the artifact while the right side
# specifies the files to be included in the artifact. The left portion is a filepath that specifies
# where the metadata about the created artifact will be written to. The right side denotes the file
# to be included in the artifact. If the file is a directory, the directory is includes recursively.
# For example, /home/user/artifact=/home/user/src means the artifact will be created with the
# contents of the /home/user/src. Information about this artifact will be written to
# /home/user/artifact.
#
set -o errexit
set -o nounset
set -o pipefail

# using `-n` ensures gzip does not add a modification time to the output. This
# helps in ensuring the archive digest is the same for the same content.
tar_opts=(--create --use-compress-program='gzip -n' --file)
if [[ ! -z "${DEBUG:-}" ]]; then
  tar_opts=(--verbose "${tar_opts[@]}")
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

if [[ -z "${store:-}" ]]; then
    echo "--store cannot be empty when creating OCI artifacts"
    exit 1
fi

archive_dir="$(mktemp -d)"

artifacts=()

repo="$(echo -n $store | sed 's_/\(.*\):\(.*\)_/\1_g')"

tmp_workdir=$(mktemp -d --tmpdir create-oci.sh.XXXXXX)
trap 'rm -rf $tmp_workdir' EXIT

for artifact_pair in "${artifact_pairs[@]}"; do
    result_path="${artifact_pair/=*}"
    path="${artifact_pair/*=}"

    if [ -f "${path}/.skip-trusted-artifacts" ]; then
      echo WARN: found skip file in "${path}"
      continue
    fi

    artifact_name="$(basename ${result_path})"

    archive="${archive_dir}/${artifact_name}"

    # log "creating tar archive %s with files from %s" "${archive}" "${path}"

    if [ ! -r "${path}" ]; then
        # non-existent paths result in empty archives
        tar "${tar_opts[@]}" "${archive}" --files-from /dev/null
    elif [ -d "${path}" ]; then
        # archive the whole directory
        tar "${tar_opts[@]}" "${archive}" --directory="${path}" .
    else
        # archive a single file
        tar "${tar_opts[@]}" "${archive}" --directory="${path%/*}" "${path##*/}"
    fi

    sha256sum_output="$(sha256sum "${archive}")"
    digest="${sha256sum_output/ */}"
    echo -n "oci:${repo}@sha256:${digest}" > "${result_path}"

    artifacts+=("${artifact_name}")

    echo Prepared artifact from "${path} (sha256:${digest})"
done

if [ ${#artifacts[@]} != 0 ]; then
    # read in any oras options
    source oras_opts.sh

    if [[ -n  "${IMAGE_EXPIRES_AFTER:-}" ]]; then
        oras_opts+=("--annotation=quay.expires-after=${IMAGE_EXPIRES_AFTER}")
    fi

    authfile=$(mktemp --tmpdir="$tmp_workdir" "auth-XXXXXX.json")
    select-oci-auth.sh "$repo" > "$authfile"

    pushd "${archive_dir}" > /dev/null
    retry oras push "${oras_opts[@]}" --registry-config "$authfile" "${store}" "${artifacts[@]}"
    popd > /dev/null

    echo 'Artifacts created'
fi
