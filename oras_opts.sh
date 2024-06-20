#!/bin/bash

oras_opts=(${ORAS_OPTIONS:-})

if [[ -v CA_FILE ]]; then
    oras_opts+=(--ca-file=${CA_FILE})
fi

if [[ -v DEBUG ]]; then
    oras_opts+=(--debug)
fi
