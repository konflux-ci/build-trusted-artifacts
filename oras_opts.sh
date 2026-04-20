#!/bin/bash

oras_opts=(${ORAS_OPTIONS:-})

# When a custom CA file is provided, set SSL_CERT_FILE to point to it.
# SSL_CERT_FILE is respected by Go's crypto/x509 (used by oras) and is ADDITIVE,
# meaning oras will automatically merge the custom CA with the system CA bundle.
# This ensures both public and self-hosted registries are trusted.
if [[ -v CA_FILE && -n "$CA_FILE" ]]; then
    if [[ -f "$CA_FILE" && -s "$CA_FILE" ]]; then
        export SSL_CERT_FILE="$CA_FILE"
        echo "Using custom CA certificate: $CA_FILE" >&2
    elif [[ -f "$CA_FILE" ]]; then
        echo "Warning: CA certificate file is empty: $CA_FILE" >&2
        echo "Falling back to system trust store" >&2
    else
        echo "Warning: CA certificate path provided but file not found: $CA_FILE" >&2
        echo "Falling back to system trust store" >&2
    fi
fi

if [[ ! -z "${DEBUG:-}" ]]; then
    oras_opts+=(--debug)
fi
