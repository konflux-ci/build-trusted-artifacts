#!/bin/bash

oras_opts=(${ORAS_OPTIONS:-})

# Only set --ca-file if CA_FILE is non-empty AND file exists and is not empty
# This avoids overriding system trust store and prevents "file not found" errors
if [[ -v CA_FILE && -n "$CA_FILE" ]]; then
    if [[ -f "$CA_FILE" && -s "$CA_FILE" ]]; then
        oras_opts+=(--ca-file=${CA_FILE})
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
