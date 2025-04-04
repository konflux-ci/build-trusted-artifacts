#!/bin/bash
# Retry a command a few times if it fails
# https://github.com/konflux-ci/build-trusted-artifacts/tree/main/retry.sh

retry() {
  status=-1
  max_try=12
  wait_sec=2

  for run in $(seq 1 $max_try); do
    status=0
    echo "Executing (attempt $run):  $" "${@}" >&2
    "$@"
    status=$?
    if [ "$status" -eq 0 ]; then
      break
    fi
    sleep $wait_sec
  done
  if [ "$status" -ne 0 ]; then
    echo "Failed after ${max_try} tries with status ${status}" >&2
    exit "$status"
  fi
}

retry "$@"
