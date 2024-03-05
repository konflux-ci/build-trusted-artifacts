FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

LABEL \
  description="RHTAP Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  io.k8s.description="RHTAP Trusted Artifacts implementation creates and restores archives of files maintaining their integrity." \
  summary="RHTAP Trusted Artifacts implementation" \
  io.k8s.display-name="RHTAP Trusted Artifacts implementation" \
  io.openshift.tags="rhtap build build-trusted-artifacts trusted-application-pipeline tekton pipeline security" \
  name="RHTAP Trusted Artifacts implementation" \
  com.redhat.component="build-trusted-artifacts"

COPY centos9-stream.repo /etc/yum.repos.d/centos9-stream.repo
COPY RPM-GPG-KEY-centosofficial /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

RUN microdnf update --assumeyes --nodocs --setopt=keepcache=0 && \
    microdnf install --assumeyes --nodocs --setopt=keepcache=0 tar gzip sysstat time && \
    groupadd --gid 1000 artifacts && \
    useradd --uid 1000 --gid 1000 --shell /bin/bash trusted

COPY create.sh /usr/local/bin/create-archive
COPY use.sh /usr/local/bin/use-archive
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY LICENSE /licenses/LICENSE

USER 1000

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
