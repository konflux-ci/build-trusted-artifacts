#!/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

eval "$(shellspec - -c) exit 1"

Include ./fetch-extra-artifacts.sh

MODEL_FILTER='(^|/)(Dockerfile|Containerfile|[^/]+\.(json|jinja|py|rb|pl|js|mjs|cjs|ts|ps1|sh|bash|zsh|ksh|md|yaml|yml|txt|model))$'

Describe 'fetch-extra-artifacts.sh helpers'
    It 'matches models/config.json against EXTRA_ARTIFACT_FILTER'
        When call matches_filter "models/config.json" "config.json" "${MODEL_FILTER}"
        The status should be success
    End

    It 'matches title config.json against EXTRA_ARTIFACT_FILTER'
        When call matches_filter "config.json" "config.json" "${MODEL_FILTER}"
        The status should be success
    End

    It 'does not match safetensors weights'
        When call matches_filter "model.safetensors" "model.safetensors" "${MODEL_FILTER}"
        The status should be failure
    End

    It 'detects oci image config'
        When call is_container_image_config "application/vnd.oci.image.config.v1+json"
        The status should be success
    End

    It 'detects oci image index'
        When call is_image_index "application/vnd.oci.image.index.v1+json"
        The status should be success
    End

    It 'does not treat an image manifest as an index'
        When call is_image_index "application/vnd.oci.image.manifest.v1+json"
        The status should be failure
    End
End

Describe 'resolve_index_child_digest'
    setup() {
        index_dir="$(mktemp -d)"
        cat >"${index_dir}/index.json" <<'EOF'
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {"digest": "sha256:arm", "platform": {"architecture": "arm64", "os": "linux"}},
    {"digest": "sha256:amd", "platform": {"architecture": "amd64", "os": "linux"}}
  ]
}
EOF
        cat >"${index_dir}/linux-only.json" <<'EOF'
{
  "manifests": [
    {"digest": "sha256:arm", "platform": {"architecture": "arm64", "os": "linux"}}
  ]
}
EOF
    }

    cleanup() {
        rm -rf "${index_dir}"
    }

    Before 'setup'
    After 'cleanup'

    It 'prefers linux/amd64'
        When call resolve_index_child_digest "${index_dir}/index.json"
        The output should eq "sha256:amd"
    End

    It 'falls back to the first linux digest'
        When call resolve_index_child_digest "${index_dir}/linux-only.json"
        The output should eq "sha256:arm"
    End
End

Describe 'extract_tarball'
    setup() {
        workdir="$(mktemp -d)"
        mkdir -p "${workdir}/layer/models"
        printf '{"ok":true}\n' >"${workdir}/layer/models/config.json"
        tar -cf "${workdir}/layer.tar" -C "${workdir}/layer" models/config.json
        tar -czf "${workdir}/layer.tar.gz" -C "${workdir}/layer" models/config.json
        extract_dir="$(mktemp -d)"
        gz_dir="$(mktemp -d)"
    }

    cleanup() {
        rm -rf "${workdir}" "${extract_dir}" "${gz_dir}"
    }

    Before 'setup'
    After 'cleanup'

    It 'extracts an uncompressed olot-style tar layer'
        When call extract_tarball "${workdir}/layer.tar" "${extract_dir}" "application/vnd.oci.image.layer.v1.tar"
        The status should be success
        The file "${extract_dir}/models/config.json" should be exist
        The contents of file "${extract_dir}/models/config.json" should include '{"ok":true}'
    End

    It 'extracts a gzip tar layer'
        When call extract_tarball "${workdir}/layer.tar.gz" "${gz_dir}" "application/vnd.oci.image.layer.v1.tar+gzip"
        The status should be success
        The file "${gz_dir}/models/config.json" should be exist
    End
End

Describe 'FETCH_EXTRA_ARTIFACTS default-off'
    It 'exits 0 when FETCH_EXTRA_ARTIFACTS is not true'
        When run command env FETCH_EXTRA_ARTIFACTS=false IMAGE_URL=x IMAGE_DIGEST=y ./fetch-extra-artifacts.sh
        The status should be success
        The output should eq ""
    End
End

Describe 'mocked oras titled-layer extract'
    gnu_realpath_missing() {
        ! realpath -m / >/dev/null 2>&1
    }
    Skip if "GNU realpath -m is required" gnu_realpath_missing

    setup() {
        workdir="$(mktemp -d)"
        mkdir -p "${workdir}/layer/models"
        printf '{"ok":true}\n' >"${workdir}/layer/models/config.json"
        tar -cf "${workdir}/layer.tar" -C "${workdir}/layer" models/config.json

        fake_bin="$(mktemp -d)"
        blob_dir="$(mktemp -d)"
        digest="sha256:layer1"
        cp "${workdir}/layer.tar" "${blob_dir}/${digest}"

        cat >"${fake_bin}/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "manifest" && "${2:-}" == "fetch" ]]; then
  cat "${MOCK_MANIFEST}"
  exit 0
fi
if [[ "${1:-}" == "blob" && "${2:-}" == "fetch" ]]; then
  out=""
  ref=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" ]]; then
      out="$2"
      shift 2
      continue
    fi
    if [[ "$1" == *@sha256:* ]]; then
      ref="$1"
    fi
    shift
  done
  digest="${ref##*@}"
  cp "${MOCK_BLOB_DIR}/${digest}" "${out}"
  exit 0
fi
echo "unexpected oras args: $*" >&2
exit 1
EOF
        cat >"${fake_bin}/select-oci-auth.sh" <<'EOF'
#!/usr/bin/env bash
echo '{}'
EOF
        cat >"${fake_bin}/retry" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
        chmod +x "${fake_bin}/oras" "${fake_bin}/select-oci-auth.sh" "${fake_bin}/retry"

        source_root="$(mktemp -d)/source"
        mkdir -p "${source_root}"
        manifest_file="$(mktemp)"
        mock_manifest="$(mktemp)"
        cat >"${mock_manifest}" <<EOF
{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {"mediaType": "application/vnd.oci.image.config.v1+json"},
  "layers": [
    {
      "digest": "${digest}",
      "mediaType": "application/vnd.oci.image.layer.v1.tar",
      "annotations": {
        "org.opencontainers.image.title": "config.json",
        "olot.layer.content.inlayerpath": "/models/config.json"
      }
    },
    {
      "digest": "sha256:weights",
      "mediaType": "application/vnd.oci.image.layer.v1.tar",
      "annotations": {
        "org.opencontainers.image.title": "model.safetensors"
      }
    },
    {
      "digest": "sha256:base",
      "mediaType": "application/vnd.oci.image.layer.v1.tar"
    }
  ]
}
EOF
        export PATH="${fake_bin}:${PATH}"
        export MOCK_MANIFEST="${mock_manifest}"
        export MOCK_BLOB_DIR="${blob_dir}"
        export ORAS_OPTS_FILE="/no-such-oras-opts"
        export SELECT_OCI_AUTH="${fake_bin}/select-oci-auth.sh"
        export SOURCE_ROOT="${source_root}"
        export MANIFEST_FILE="${manifest_file}"
        export FETCH_EXTRA_ARTIFACTS="true"
        export EXTRA_ARTIFACT_FILTER="${MODEL_FILTER}"
        export IMAGE_URL="fake.example/modelcar"
        export IMAGE_DIGEST="sha256:index"
    }

    cleanup() {
        rm -rf "${workdir}" "${fake_bin}" "${blob_dir}" "$(dirname "${source_root}")" "${manifest_file}" "${mock_manifest}"
    }

    Before 'setup'
    After 'cleanup'

    It 'extracts matching titled layers and skips weights'
        When run script ./fetch-extra-artifacts.sh
        The status should be success
        The output should include "Extracted models/config.json"
        The file "${source_root}/models/config.json" should be exist
        The file "${source_root}/model.safetensors" should not be exist
        The contents of file "${source_root}/models/config.json" should include '{"ok":true}'
    End
End
