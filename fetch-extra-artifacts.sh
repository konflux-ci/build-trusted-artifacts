#!/bin/bash
# Fetch files matching EXTRA_ARTIFACT_FILTER from IMAGE_URL@IMAGE_DIGEST into SOURCE_ROOT.
#
# Used by sast-snyk-check-oci-ta (and similar) when FETCH_EXTRA_ARTIFACTS=true.
# Supports OCI artifacts (raw titled blobs) and container images with titled
# layers (e.g. ModelCar/olot), extracting matching tar layers without unpacking
# the full image.
#
# Source this file to unit-test helpers.
set -o errexit
set -o nounset
set -o pipefail

SOURCE_ROOT="${SOURCE_ROOT:-/var/workdir/source}"
MANIFEST_FILE="${MANIFEST_FILE:-/tmp/manifest.json}"
SELECT_OCI_AUTH="${SELECT_OCI_AUTH:-/usr/local/bin/select-oci-auth.sh}"
ORAS_OPTS_FILE="${ORAS_OPTS_FILE:-/usr/local/bin/oras_opts.sh}"

is_image_index() {
  local media_type="$1"
  [[ "${media_type}" == "application/vnd.oci.image.index.v1+json" ]] ||
    [[ "${media_type}" == "application/vnd.docker.distribution.manifest.list.v2+json" ]]
}

is_container_image_config() {
  local config_media_type="$1"
  [[ "${config_media_type}" == "application/vnd.oci.image.config.v1+json" ]] ||
    [[ "${config_media_type}" == "application/vnd.docker.container.image.v1+json" ]]
}

resolve_index_child_digest() {
  local manifest_file="$1"
  jq -r '
    (.manifests // []) as $m
    | ($m | map(select(.platform.architecture == "amd64" and ((.platform.os // "linux") == "linux"))) | .[0].digest)
      // ($m | map(select((.platform.os // "linux") == "linux")) | .[0].digest)
      // ($m[0].digest)
      // empty
  ' "${manifest_file}"
}

matches_filter() {
  local match_path="$1"
  local title="$2"
  local filter="$3"
  printf '%s\n' "${match_path}" | grep -Eq "${filter}" && return 0
  printf '%s\n' "${title}" | grep -Eq "${filter}" && return 0
  return 1
}

path_allowed() {
  local rel_path="$1"
  local resolved_dest
  resolved_dest="$(realpath -m "${SOURCE_ROOT}/${rel_path}")"
  if [[ ! "${resolved_dest}" == "${SOURCE_ROOT}"/* ]]; then
    echo "WARN: Skipping path outside source root: ${rel_path}" >&2
    return 1
  fi
  printf '%s\n' "${resolved_dest}"
}

extract_tarball() {
  local blob="$1"
  local dest="$2"
  local media_type="$3"
  if [[ "${media_type}" == *gzip* ]] || [[ "${media_type}" == *tar+gzip* ]]; then
    tar -xzf "${blob}" -C "${dest}"
  else
    tar -xf "${blob}" -C "${dest}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${FETCH_EXTRA_ARTIFACTS:-}" != "true" ]]; then
    exit 0
  fi

  if [[ -z "${IMAGE_URL:-}" || -z "${IMAGE_DIGEST:-}" ]]; then
    echo "INFO: image-url/image-digest missing, cannot fetch extra artifacts"
    exit 0
  fi

  declare -a oras_opts=()
  if [[ -f "${ORAS_OPTS_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ORAS_OPTS_FILE}"
  fi

  IMAGE_REF="${IMAGE_URL}@${IMAGE_DIGEST}"
  echo "INFO: Fetching extra artifacts from OCI reference ${IMAGE_REF}"

  authfile="$(mktemp)"
  cleanup_paths=("${authfile}")
  cleanup() {
    rm -rf "${cleanup_paths[@]}"
  }
  trap cleanup EXIT
  "${SELECT_OCI_AUTH}" "${IMAGE_URL}" >"${authfile}"

  # shellcheck disable=SC2086 # empty-array expansion under set -u
  retry oras manifest fetch ${oras_opts[@]+"${oras_opts[@]}"} --registry-config "${authfile}" "${IMAGE_REF}" >"${MANIFEST_FILE}"

  # Multi-arch index (e.g. modelcar build-image-index) → one platform manifest.
  media_type="$(jq -r '.mediaType // ""' "${MANIFEST_FILE}")"
  if is_image_index "${media_type}"; then
    child_digest="$(resolve_index_child_digest "${MANIFEST_FILE}")"
    if [[ -z "${child_digest}" || "${child_digest}" == "null" ]]; then
      echo "ERROR: image index has no manifests to resolve"
      exit 1
    fi
    echo "INFO: Resolving image index to ${child_digest}"
    # shellcheck disable=SC2086 # empty-array expansion under set -u
    retry oras manifest fetch ${oras_opts[@]+"${oras_opts[@]}"} --registry-config "${authfile}" "${IMAGE_URL}@${child_digest}" >"${MANIFEST_FILE}"
  fi

  config_media_type="$(jq -r '.config.mediaType // ""' "${MANIFEST_FILE}")"
  is_container_image=false
  if is_container_image_config "${config_media_type}"; then
    is_container_image=true
    echo "INFO: Reference is a container image (${config_media_type}); extracting titled layers matching EXTRA_ARTIFACT_FILTER"
  fi

  mkdir -p "${SOURCE_ROOT}"
  fetched_count=0

  if [[ "${is_container_image}" == "true" ]]; then
    # ModelCar/olot (and similar) store one file per titled tar layer. Fetch only
    # matching layers — skip base-image layers (no title) and huge weight blobs.
    while IFS=$'\t' read -r digest media_type title inlayer_path; do
      [[ -n "${title}" ]] || continue
      match_path="${inlayer_path:-${title}}"
      match_path="${match_path#/}"
      if ! matches_filter "${match_path}" "${title}" "${EXTRA_ARTIFACT_FILTER}"; then
        continue
      fi

      tmp_blob="$(mktemp)"
      tmp_dir="$(mktemp -d)"
      cleanup_paths+=("${tmp_blob}" "${tmp_dir}")
      echo "INFO: Fetching layer ${digest} (${title}) for extraction"
      # shellcheck disable=SC2086 # empty-array expansion under set -u
      retry oras blob fetch ${oras_opts[@]+"${oras_opts[@]}"} --registry-config "${authfile}" "${IMAGE_URL}@${digest}" --output "${tmp_blob}"

      # olot model files are uncompressed tar; modelcard layers are tar+gzip.
      extract_tarball "${tmp_blob}" "${tmp_dir}" "${media_type}"

      while IFS= read -r -d '' extracted; do
        rel_path="${extracted#"${tmp_dir}"/}"
        rel_path="${rel_path#./}"
        [[ -n "${rel_path}" ]] || continue
        if ! dest_path="$(path_allowed "${rel_path}")"; then
          continue
        fi
        mkdir -p "$(dirname "${dest_path}")"
        cp -a "${extracted}" "${dest_path}"
        echo "INFO: Extracted ${rel_path}"
        fetched_count=$((fetched_count + 1))
      done < <(find "${tmp_dir}" -type f -print0)

      rm -rf "${tmp_blob}" "${tmp_dir}"
    done < <(jq -r '
      (.layers // [])[]
      | [
          .digest,
          (.mediaType // ""),
          (.annotations["org.opencontainers.image.title"] // ""),
          (.annotations["olot.layer.content.inlayerpath"] // "")
        ]
      | @tsv
    ' "${MANIFEST_FILE}")
  else
    while IFS=$'\t' read -r digest rel_path; do
      [[ -n "${rel_path}" ]] || continue
      if ! printf '%s\n' "${rel_path}" | grep -Eq "${EXTRA_ARTIFACT_FILTER}"; then
        continue
      fi

      if ! dest_path="$(path_allowed "${rel_path}")"; then
        continue
      fi

      mkdir -p "$(dirname "${dest_path}")"
      echo "INFO: Fetching blob ${digest} -> ${rel_path}"
      # shellcheck disable=SC2086 # empty-array expansion under set -u
      retry oras blob fetch ${oras_opts[@]+"${oras_opts[@]}"} --registry-config "${authfile}" "${IMAGE_URL}@${digest}" --output "${dest_path}"
      fetched_count=$((fetched_count + 1))
    done < <(jq -r '(.layers // [])[] | [.digest, (.annotations["org.opencontainers.image.title"] // "")] | @tsv' "${MANIFEST_FILE}")
  fi

  if [[ "${fetched_count}" -eq 0 ]]; then
    echo "INFO: No files matched EXTRA_ARTIFACT_FILTER"
  else
    echo "INFO: Fetched ${fetched_count} extra artifact file(s) alongside SOURCE_ARTIFACT"
  fi
fi
