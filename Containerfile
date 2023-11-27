FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install --assumeyes --nodocs --setopt=keepcache=0 tar gzip

COPY create.sh /usr/local/bin/create-archive
COPY use.sh /usr/local/bin/use-archive
COPY entrypoint.sh /usr/local/bin/entrypoint

ENTRYPOINT [ "/usr/local/bin/entrypoint" ]
