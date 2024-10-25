FROM registry.access.redhat.com/ubi9/ubi-minimal:latest as oras
ARG ORAS_VERSION=1.2.0
ARG TARGETARCH
ADD https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${TARGETARCH}.tar.gz /tmp
RUN microdnf install --assumeyes tar gzip && tar -x -C /tmp -f /tmp/oras_${ORAS_VERSION}_linux_${TARGETARCH}.tar.gz

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest as parent

LABEL \
  description="Konflux Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  io.k8s.description="Konflux Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  summary="Konflux Trusted Artifacts implementation" \
  io.k8s.display-name="Konflux Trusted Artifacts implementation" \
  io.openshift.tags="konflux build build-trusted-artifacts trusted-application-pipeline tekton pipeline security" \
  name="Konflux Trusted Artifacts implementation" \
  com.redhat.component="build-trusted-artifacts"

COPY --chown=0:0 --from=oras /tmp/oras /usr/local/bin/oras

RUN microdnf update --assumeyes --nodocs --setopt=keepcache=0 && \
    microdnf install --assumeyes --nodocs --setopt=keepcache=0 tar gzip time jq findutils && \
    useradd --non-unique --uid 0 --gid 0 --shell /bin/bash notroot

RUN oras version

USER notroot

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]

# These files are more likely to change when developing and debugging
# so copy them at a later step to reuse the cached earlier layers
FROM scratch AS files

COPY centos9-stream.repo /etc/yum.repos.d/centos9-stream.repo
COPY RPM-GPG-KEY-centosofficial /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
COPY create-oci.sh /usr/local/bin/create-archive
COPY select-oci-auth.sh /usr/local/bin/select-oci-auth.sh
COPY use-oci.sh /usr/local/bin/use-archive
COPY oras_opts.sh /usr/local/bin/oras_opts.sh
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY LICENSE /licenses/LICENSE

FROM parent
COPY --from=files / /
