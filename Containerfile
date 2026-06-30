FROM scratch AS files

COPY create-oci.sh /usr/local/bin/create-archive
COPY select-oci-auth.sh /usr/local/bin/select-oci-auth.sh
COPY use-oci.sh /usr/local/bin/use-archive
COPY oras_opts.sh /usr/local/bin/oras_opts.sh
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY LICENSE /licenses/LICENSE

FROM quay.io/konflux-ci/buildah-task:latest@sha256:4c470b5a153c4acd14bf4f8731b5e36c61d7faafe09c2bf376bb81ce84aa5709 AS buildah-task-image

FROM quay.io/konflux-ci/oras:latest@sha256:c4fb02d6c1caa722360e0317002d5dfc2fce8a465bb3a3fdd62a3d1608105cbc as oras

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest@sha256:c5478a52c410e71c53839923c83a1480199a1e74ce5736fe3e3a5578dc399102

LABEL \
  description="RHTAP Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  io.k8s.description="RHTAP Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  summary="RHTAP Trusted Artifacts implementation" \
  io.k8s.display-name="RHTAP Trusted Artifacts implementation" \
  io.openshift.tags="rhtap build build-trusted-artifacts trusted-application-pipeline tekton pipeline security" \
  name="RHTAP Trusted Artifacts implementation" \
  com.redhat.component="build-trusted-artifacts"

COPY --from=files / /
COPY --from=oras /usr/bin/oras /usr/local/bin/oras
COPY --from=buildah-task-image /usr/bin/retry /usr/local/bin/

RUN microdnf update --assumeyes --nodocs --setopt=keepcache=0 && \
    microdnf install --assumeyes --nodocs --setopt=keepcache=0 tar gzip time jq findutils && \
    useradd --non-unique --uid 0 --gid 0 --shell /bin/bash notroot

RUN oras version

USER notroot

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
