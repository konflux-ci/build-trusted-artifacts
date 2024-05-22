FROM scratch AS files

COPY centos9-stream.repo /etc/yum.repos.d/centos9-stream.repo
COPY RPM-GPG-KEY-centosofficial /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
COPY create-oci.sh /usr/local/bin/create-archive
COPY select-oci-auth.sh /usr/local/bin/select-oci-auth.sh
COPY use-oci.sh /usr/local/bin/use-archive
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY LICENSE /licenses/LICENSE

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

RUN microdnf update --assumeyes --nodocs --setopt=keepcache=0 && \
    microdnf install --assumeyes --nodocs --setopt=keepcache=0 tar gzip time jq && \
    useradd --non-unique --uid 0 --gid 0 --shell /bin/bash notroot

COPY download-oras.sh download-oras.sh
ARG ORAS_VERSION=1.2.0-rc.1

RUN ./download-oras.sh ${ORAS_VERSION} && \
    mkdir -p oras-install/ && \
    tar -zxf oras_${ORAS_VERSION}_*.tar.gz -C oras-install/ && \
    mv oras-install/oras /usr/local/bin/ && \
    rm -rf oras_${ORAS_VERSION}_*.tar.gz oras-install/ && \
    oras version

USER notroot

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
