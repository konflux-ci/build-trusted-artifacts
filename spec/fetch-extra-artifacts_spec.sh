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

    It 'detects docker manifest lists as indexes'
        When call is_image_index "application/vnd.docker.distribution.manifest.list.v2+json"
        The status should be success
    End

    It 'detects docker container configs'
        When call is_container_image_config "application/vnd.docker.container.image.v1+json"
        The status should be success
    End
End

Describe 'path_allowed'
    gnu_realpath_missing() {
        ! realpath -m / >/dev/null 2>&1
    }
    Skip if "GNU realpath -m is required" gnu_realpath_missing

    setup() {
        SOURCE_ROOT="$(mktemp -d)/source"
        mkdir -p "${SOURCE_ROOT}"
    }

    cleanup() {
        rm -rf "$(dirname "${SOURCE_ROOT}")"
    }

    Before 'setup'
    After 'cleanup'

    It 'accepts a path under the source root'
        When call path_allowed "models/config.json"
        The output should eq "${SOURCE_ROOT}/models/config.json"
    End

    It 'rejects path traversal outside the source root'
        When call path_allowed "../etc/passwd"
        The status should be failure
        The error should include "Skipping path outside source root"
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

    It 'exits 0 when image-url is missing'
        When run command env FETCH_EXTRA_ARTIFACTS=true IMAGE_URL= IMAGE_DIGEST=sha256:x ./fetch-extra-artifacts.sh
        The status should be success
        The output should include "image-url/image-digest missing"
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
ref=""
out=""
for arg in "$@"; do
  [[ "$arg" == *@sha256:* ]] && ref="$arg"
done
digest="${ref##*@}"
if [[ "${1:-}" == "manifest" && "${2:-}" == "fetch" ]]; then
  if [[ -n "${digest}" && -f "${MOCK_BLOB_DIR}/manifest-${digest}" ]]; then
    cat "${MOCK_BLOB_DIR}/manifest-${digest}"
  else
    cat "${MOCK_MANIFEST}"
  fi
  exit 0
fi
if [[ "${1:-}" == "blob" && "${2:-}" == "fetch" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" ]]; then
      out="$2"
      shift 2
      continue
    fi
    shift
  done
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
        export ORAS_OPTS_FILE="${PWD}/oras_opts.sh"
        export SELECT_OCI_AUTH="${fake_bin}/select-oci-auth.sh"
        export SOURCE_ROOT="${source_root}"
        export MANIFEST_FILE="${manifest_file}"
        export FETCH_EXTRA_ARTIFACTS="true"
        export EXTRA_ARTIFACT_FILTER="${MODEL_FILTER}"
        export IMAGE_URL="fake.example/modelcar"
        export IMAGE_DIGEST="sha256:image"
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

    Describe 'no matching layers'
        extra_setup() {
            cat >"${MOCK_MANIFEST}" <<'EOF'
{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {"mediaType": "application/vnd.oci.image.config.v1+json"},
  "layers": [
    {
      "digest": "sha256:weights",
      "mediaType": "application/vnd.oci.image.layer.v1.tar",
      "annotations": {"org.opencontainers.image.title": "model.safetensors"}
    }
  ]
}
EOF
        }
        Before 'extra_setup'

        It 'reports when no titled layers match the filter'
            When run script ./fetch-extra-artifacts.sh
            The status should be success
            The output should include "No files matched EXTRA_ARTIFACT_FILTER"
            The file "${source_root}/model.safetensors" should not be exist
        End
    End

    Describe 'image index'
        extra_setup() {
            cat >"${MOCK_BLOB_DIR}/manifest-sha256:index" <<'EOF'
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {"digest": "sha256:arm", "platform": {"architecture": "arm64", "os": "linux"}},
    {"digest": "sha256:image", "platform": {"architecture": "amd64", "os": "linux"}}
  ]
}
EOF
            cp "${MOCK_MANIFEST}" "${MOCK_BLOB_DIR}/manifest-sha256:image"
            export IMAGE_DIGEST="sha256:index"
        }
        Before 'extra_setup'

        It 'resolves a multi-arch index then extracts titled layers'
            When run script ./fetch-extra-artifacts.sh
            The status should be success
            The output should include "Resolving image index to sha256:image"
            The output should include "Extracted models/config.json"
            The file "${source_root}/models/config.json" should be exist
        End
    End

    Describe 'empty image index'
        extra_setup() {
            cat >"${MOCK_MANIFEST}" <<'EOF'
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": []
}
EOF
        }
        Before 'extra_setup'

        It 'fails when an image index has no manifests'
            When run script ./fetch-extra-artifacts.sh
            The status should be failure
            The output should include "image index has no manifests to resolve"
        End
    End

    Describe 'oci artifact blobs'
        extra_setup() {
            printf '#!/bin/sh\necho hi\n' >"${MOCK_BLOB_DIR}/sha256:script"
            cat >"${MOCK_MANIFEST}" <<'EOF'
{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {"mediaType": "application/vnd.oci.empty.v1+json"},
  "layers": [
    {
      "digest": "sha256:script",
      "annotations": {"org.opencontainers.image.title": "run.sh"}
    },
    {
      "digest": "sha256:weights",
      "annotations": {"org.opencontainers.image.title": "model.safetensors"}
    },
    {
      "digest": "sha256:escape",
      "annotations": {"org.opencontainers.image.title": "../evil.sh"}
    }
  ]
}
EOF
        }
        Before 'extra_setup'

        It 'fetches matching blobs and skips traversal and non-matching titles'
            When run script ./fetch-extra-artifacts.sh
            The status should be success
            The output should include "Fetching blob sha256:script -> run.sh"
            The error should include "Skipping path outside source root"
            The file "${source_root}/run.sh" should be exist
            The file "${source_root}/model.safetensors" should not be exist
            The contents of file "${source_root}/run.sh" should include "echo hi"
        End
    End
End
