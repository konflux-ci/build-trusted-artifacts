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

tar_opts=-mczf
if [[ -v DEBUG ]]; then
  tar_opts=-mcvzf
  set -o xtrace
fi

# This ensures gzip does not add a modification time to the output. This helps in ensuring the
# archive digest is the same for the same content.
export GZIP=-n

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

if [[ -z "$store" ]]; then
    echo "--store cannot be empty when creating OCI artifacts"
    exit 1
fi

archive_dir="$(mktemp -d)"

artifacts=()

repo="$(echo -n $store | sed 's_/\(.*\):\(.*\)_/\1_g')"

for artifact_pair in "${artifact_pairs[@]}"; do
    result_path="${artifact_pair/=*}"
    path="${artifact_pair/*=}"
    artifact_name="$(basename ${result_path})"

    archive="${archive_dir}/${artifact_name}"

    # log "creating tar archive %s with files from %s" "${archive}" "${path}"

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
    echo -n "oci:${repo}@sha256:${digest}" > "${result_path}"

    artifacts+=("${artifact_name}")

    echo Prepared artifact from "${path} (sha256:${digest})"
done

if [[ -n  "${IMAGE_EXPIRES_AFTER:-}" ]]; then
    # If provided, oras requires the config file to be an existing file on disk. Using
    # a here file, i.e. <(...), does not work.
    config_file="$(mktemp)"
    echo -n '{
        "config": {
            "Labels": {
                "quay.expires-after": "'${IMAGE_EXPIRES_AFTER}'"
            }
        }
    }' | jq . > "${config_file}"

    config="${config_file}:application/vnd.oci.image.config.v1+json"
fi

pushd "${archive_dir}" > /dev/null
oras push --registry-config <(select-oci-auth.sh ${repo}) "${store}" --config="${config:-}" \
    "${artifacts[@]}"
popd > /dev/null

echo 'Artifacts created'