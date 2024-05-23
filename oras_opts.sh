#!/bin/bash

oras_opts=()

if [[ -v CA_FILE ]]; then
    oras_opts+=(--ca-file=${CA_FILE})
fi


