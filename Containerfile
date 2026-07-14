FROM scratch AS files

COPY create-oci.sh /usr/local/bin/create-archive
COPY select-oci-auth.sh /usr/local/bin/select-oci-auth.sh
COPY use-oci.sh /usr/local/bin/use-archive
COPY oras_opts.sh /usr/local/bin/oras_opts.sh
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY LICENSE /licenses/LICENSE

FROM quay.io/konflux-ci/buildah-task:latest@sha256:4c470b5a153c4acd14bf4f8731b5e36c61d7faafe09c2bf376bb81ce84aa5709 AS buildah-task-image

FROM quay.io/konflux-ci/oras:latest@sha256:6b8e8b368bdaad521629300a6d945734a15207fa5070a0396d42b377cf6c61fb as oras

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest@sha256:463cae32c6f6f5594b11a5c22de275016bd8545ce58a6373388e8b24f13fc15c

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

# TODO: Obviously, don't do this...
ADD https://www.ivarch.com/programs/binaries/pv-1.10.5-1.el9.x86_64.rpm /tmp
RUN rpm -ivh /tmp/pv-1.10.5-1.el9.x86_64.rpm && pv --version && rm /tmp/pv-1.10.5-1.el9.x86_64.rpm

RUN oras version

USER notroot

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
