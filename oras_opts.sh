#!/bin/bash

oras_opts=(${ORAS_OPTIONS:-})

if [[ -v CA_FILE && -n "$CA_FILE" ]]; then
  if [[ -f "$CA_FILE" && -s "$CA_FILE" ]]; then
    system_bundle=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    if [ -w "$system_bundle" ]; then
      cat "$CA_FILE" >> "$system_bundle"
      echo "Appended custom CA to system trust bundle" >&2
    else
      oras_opts+=(--ca-file=${CA_FILE})
      echo "Using custom CA certificate (fallback): $CA_FILE" >&2
    fi
  elif [[ -f "$CA_FILE" ]]; then
    echo "Warning: CA certificate file is empty: $CA_FILE" >&2
  else
    echo "Warning: CA certificate path provided but file not found: $CA_FILE" >&2
  fi
fi

if [[ ! -z "${DEBUG:-}" ]]; then
    oras_opts+=(--debug)
fi
