#!/bin/bash
# Creates specified trusted artifacts in an OCI repository
#
# The --store parameter is an image reference used to specify the repository, e.g.
# registry.local/org/repo. If the image reference contains a tag, it is ignored.
#
# The --attach parameter is used to specify to use oras attach instead of oras push.
#
# The --oci-type-scope parameter is used to further define a scope for mediaType and artifactType
# properties when attaching artifacts.
#
# The --no-tar parameter skips tarring steps. Since a single artifact needs to be uploaded,
# this only supports single (or missing) files
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
if [[ -v DEBUG ]]; then
  tar_opts=(--verbose "${tar_opts[@]}")
  set -o xtrace
fi

# contains {result path}={artifact source path} pairs
artifact_pairs=()
attach=""
no_tar=""
oci_type_scope=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --store)
        store="$2"
        shift
        shift
        ;;
        --oci-type-scope)
        oci_type_scope="$2"
        shift
        shift
        ;;
        --attach)
        attach="true"
        shift
        ;;
        --no-tar)
        no_tar="true"
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

# Trim off digests and tags
repo="$(echo -n $store | cut -d@ -f1 | cut -d: -f1)"

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

    if [ -z "${no_tar}" ]; then
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
    else
        artifact_name="$(basename ${path})"
        archive="${archive_dir}/${artifact_name}"
        if [ ! -r "${path}" ]; then
            # non-existent paths result in empty files
            touch "${archive}"
        elif [ -d "${path}" ]; then
            # directories cannot be uploaded without being tarred
            echo WARN: Directories need to be tarred. Do not use the option "--no-tar"
            continue
        else
            # archive a single file
            cp ${path} ${archive}
        fi
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

if [ ${#artifacts[@]} != 0 ]; then
    # read in any oras options
    source oras_opts.sh

    pushd "${archive_dir}" > /dev/null
    if [ -z "${attach}" ]; then
        oras push "${oras_opts[@]}" --registry-config <(select-oci-auth.sh ${repo}) "${store}" --config="${config:-}" \
            "${artifacts[@]}"
    else
        oci_artifact_type="application/vnd.konflux-ci.trusted-artifact"
        if [ -n "${oci_type_scope}" ]; then
            oci_artifact_type="${oci_artifact_type}.${oci_type_scope}"
        fi
        attached_artifacts=()
        for artifact in "${artifacts[@]}"; do
            file_base="${artifact%.*}"
            file_extension="${artifact##*.}"
            media_type_descriptor="${file_base}"
            if [[ "${file_base}" != "${file_extension}" ]]; then
                media_type_descriptor="${media_type_descriptor}+${file_extension}"
            fi
            echo "registering artifact:"
            echo "${artifact}:${oci_artifact_type}.${media_type_descriptor}"
            attached_artifacts+=("${artifact}:${oci_artifact_type}.${media_type_descriptor}")
        done
        oras attach "${oras_opts[@]}" --no-tty --registry-config <(select-oci-auth.sh ${repo}) --artifact-type "${oci_artifact_type}" \
            --distribution-spec v1.1-referrers-api "${store}" "${attached_artifacts[@]}"
        oras attach "${oras_opts[@]}" --no-tty --registry-config <(select-oci-auth.sh ${repo}) --artifact-type "${oci_artifact_type}" \
            --distribution-spec v1.1-referrers-tag "${store}" "${attached_artifacts[@]}"
    fi
    popd > /dev/null

    echo 'Artifacts created'
fi
