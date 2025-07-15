FROM scratch AS files

COPY centos9-stream.repo /etc/yum.repos.d/centos9-stream.repo
COPY RPM-GPG-KEY-centosofficial /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
COPY create-oci.sh /usr/local/bin/create-archive
COPY select-oci-auth.sh /usr/local/bin/select-oci-auth.sh
COPY use-oci.sh /usr/local/bin/use-archive
COPY oras_opts.sh /usr/local/bin/oras_opts.sh
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY LICENSE /licenses/LICENSE

FROM quay.io/konflux-ci/buildah-task:latest@sha256:c8d667a4efa2f05e73e2ac36b55928633d78857589165bd919d2628812d7ffcb AS buildah-task-image
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest as oras
ARG ORAS_VERSION=1.2.0
ARG TARGETARCH
ADD https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${TARGETARCH}.tar.gz /tmp
RUN microdnf install --assumeyes tar gzip && tar -x -C /tmp -f /tmp/oras_${ORAS_VERSION}_linux_${TARGETARCH}.tar.gz

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

LABEL \
  description="RHTAP Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  io.k8s.description="RHTAP Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  summary="RHTAP Trusted Artifacts implementation" \
  io.k8s.display-name="RHTAP Trusted Artifacts implementation" \
  io.openshift.tags="rhtap build build-trusted-artifacts trusted-application-pipeline tekton pipeline security" \
  name="RHTAP Trusted Artifacts implementation" \
  com.redhat.component="build-trusted-artifacts"

COPY --from=files / /
COPY --chown=0:0 --from=oras /tmp/oras /usr/local/bin/oras
COPY --from=buildah-task-image /usr/bin/retry /usr/local/bin/

RUN microdnf update --assumeyes --nodocs --setopt=keepcache=0 && \
    microdnf install --assumeyes --nodocs --setopt=keepcache=0 tar gzip time jq findutils && \
    useradd --non-unique --uid 0 --gid 0 --shell /bin/bash notroot

RUN oras version

USER notroot

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
