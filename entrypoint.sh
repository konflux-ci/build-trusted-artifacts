#!/bin/bash
# Determines the storage location and delegates to the implementation of the
# operation.
#
# Two operations are supported currently:
#  * `create`` - to create a trusted artifact, will put a directory or files into a
#    trusted artifact with a given name.
#  * `use``    - to use a trusted artifact, will restore content of a trusted
#    artifact identified via its name to a provided directory
#
# Invoking the `create` operation will store the specified directory or file in
# a trusted archive and will generate the uri of the artifact with the digest.
# For example `create source=/workspace/source` will generate a result of
# `file:source@sha256:abcd...`.
# The result of the `create` operation needs to be provided to the `use`
# operation.
#
# The storage location of trusted artifacts can be specified with the `--store`
# parameter.
#
# Examples:
#     # to create the trusted artifact named "source" from the content of
#     # "/workspace/source/checkout"
#     create source=/workspace/source/checkout
#
#     # to restore the trusted artifact named "source" to the directory
#     #"/workspace/build/source"
#     use file:source@sha256:abc...=/workspace/build/source
#
set -o errexit
set -o nounset
set -o pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <create|use> [args...]"
    exit 1
fi

op=$1
cmd=("${@:2}")

store=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --store)
        store="$2"
        shift
        shift
        ;;
        *)
        shift
        ;;
    esac
done

# The `--store`` was not provided, use first available workspace.
if [ -z "${store}" ]; then
    workspaces=(/workspace/*)
    for w in "${workspaces[@]}"; do
        if [ -d "${w}" ]; then
            store="${w}"
            break
        fi
    done
fi

if [ ! -d "${store}" ]; then
    echo "Unable to use artifact store: ${store}"
    exit 1
fi

case "${op}" in
    "create")
        /usr/local/bin/create-archive --store "${store}" "${cmd[@]}"
        ;;
    "use")
        /usr/local/bin/use-archive --store "${store}" "${cmd[@]}"
        ;;
    *)
        echo "Unsupported operation: ${op}"
        exit 1
        ;;
esac
