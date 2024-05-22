#!/bin/bash
set -o verbose
set -eu
set -o pipefail
# Function to determine the system architecture
get_architecture() {
    case $(uname -m) in
        x86_64)
            echo "amd64"
            ;;
        i386 | i686)
            echo "i386"
            ;;
        aarch64)
            echo "arm64"
            ;;
        ppc64le)
            echo "ppc64le"
            ;;
        s390x)
            echo "s390x"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

ARCH=$(get_architecture)

curl -LO "https://github.com/oras-project/oras/releases/download/v${1}/oras_${1}_linux_$ARCH.tar.gz"
