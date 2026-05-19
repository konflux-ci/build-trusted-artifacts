#!/bin/bash
set -euo pipefail

TESTS_FAILED="false"
failure_num=0

## Test: custom CA_FILE must not break public registry access
echo "=== Test: CA_FILE does not break public registry TLS ==="

if ! oras manifest fetch quay.io/podman/hello:latest > /dev/null; then
  echo "SKIP: Cannot reach public registry (no network?)"
else
  echo "Baseline: public registry reachable without CA_FILE"

  # Dummy self-signed cert unrelated to any real CA
  cat > /tmp/ca.crt <<'CERT'
-----BEGIN CERTIFICATE-----
MIIBhjCCAS2gAwIBAgIUMWB/IxfT7E3bnpquuDJ+0m/yw7cwCgYIKoZIzj0EAwIw
GTEXMBUGA1UEAwwOdGVzdC1jdXN0b20tY2EwHhcNMjYwNTE5MTUzNjIxWhcNMzYw
NTE2MTUzNjIxWjAZMRcwFQYDVQQDDA50ZXN0LWN1c3RvbS1jYTBZMBMGByqGSM49
AgEGCCqGSM49AwEHA0IABE2Il62unn2rdiw72KGrR36mslwxYrs/tvkWbdH/ZT2Q
E9PY8OYqrl8ZL8hNv40/BFlb3EGEw/nhcLgfHU5JlumjUzBRMB0GA1UdDgQWBBSf
wwLj7t5SwsY78iVI/EHvmBLV8DAfBgNVHSMEGDAWgBSfwwLj7t5SwsY78iVI/EHv
mBLV8DAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIBLrf+bx0aPw
r3Dp2fXufwDiQimEk/4Gkicr/HYuPd+QAiAzAOxAZq89cA/I+yLSdNuaxXmbGXML
lt9KJxN0MqBcEw==
-----END CERTIFICATE-----
CERT

  export CA_FILE=/tmp/ca.crt
  # shellcheck source=/dev/null
  source /usr/local/bin/oras_opts.sh

  # Same public registry should still be reachable
  # shellcheck disable=SC2154 # oras_opts is set by oras_opts.sh
  if oras manifest fetch "${oras_opts[@]}" quay.io/podman/hello:latest > /dev/null; then
    echo "PASS: Public registry still reachable with CA_FILE set"
  else
    echo "FAIL: CA_FILE broke public registry TLS verification"
    TESTS_FAILED="true"
    failure_num=$((failure_num + 1))
  fi

  unset CA_FILE SSL_CERT_FILE
fi

if [ "$TESTS_FAILED" == "true" ]; then
  echo "$failure_num test(s) failed."
  exit 1
fi
echo "All tests passed."
