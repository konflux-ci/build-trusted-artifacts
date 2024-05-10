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

time_format=''
log() {
    :
}

if [[ -v DEBUG ]]; then
    iostat -d 1 &
    IOSTAT_PID=$!
    trap 'kill ${IOSTAT_PID}' EXIT
    time_format='User:\t\t%U\nSystem:\t\t%S\nElapsed:\t%E\nCPU:\t\t%P\nMax RS:\t\t%MKiB\nAVG Memory:\t%KKiB\nInputs:\t\t%I\nOutputs:\t%O\nWaits:\t\t%w\n'
    log() {
        # shellcheck disable=SC2059
        printf "DEBUG: %s\n" "$(printf "${@}")"
    }

    log "running as %s" "$(id)"
    export PS4='DEBUG $0.$LINENO: '
    set -o xtrace
fi

export -f log

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

case "${op}" in
    "create")
        TIME="${time_format}" time /usr/local/bin/create-archive --store "${store}" "${cmd[@]}"
        ;;
    "use")
        TIME="${time_format}" time /usr/local/bin/use-archive "${cmd[@]}"
        ;;
    *)
        echo "Unsupported operation: ${op}"
        exit 1
        ;;
esac
