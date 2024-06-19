#!/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

eval "$(shellspec - -c) exit 1"

random_secret() {
    printf "spam:$(echo $RANDOM | md5sum | head -c 10)" | base64 -w0
}

# Generate these instead of hard-coding values to avoid scanners flagging them as leaked secrets.
quayio_secret="$(random_secret)"
quayio_spam_secret="$(random_secret)"
quayio_443_secret="$(random_secret)"
quayio_443_spam_secret="$(random_secret)"
quayio_5000_secret="$(random_secret)"
quayio_5000_spam_secret="$(random_secret)"

Describe 'select-oci-auth.sh'
    setup() {
        AUTHFILE="$(mktemp --tmpdir build-trusted-artifacts.XXX)"
        echo '{"auths":{
            "quay.io":{"auth":"'$quayio_secret'"},
            "quay.io/spam":{"auth":"'$quayio_spam_secret'"},
            "quay.io:443":{"auth":"'$quayio_443_secret'"},
            "quay.io:443/spam":{"auth":"'$quayio_443_spam_secret'"},
            "quay.io:5000":{"auth":"'$quayio_5000_secret'"},
            "quay.io:5000/spam":{"auth":"'$quayio_5000_spam_secret'"}
        }}' > "${AUTHFILE}"
    }

    cleanup() {
        rm -f "${AUTHFILE}"
    }

    selectauth_token() {
        ref="${1}"
        key="${2}"
        AUTHFILE="${AUTHFILE}" ./select-oci-auth.sh "${ref}" | jq -r '.auths["'$key'"].auth'
    }

    selectauth() {
        ref="${1}"
        AUTHFILE="${AUTHFILE}" ./select-oci-auth.sh "${ref}"
    }

    Before 'setup'
    After 'cleanup'

    Describe 'matches'
        Parameters
            'quay.io' quay.io "$quayio_secret"
            'quay.io/spam' quay.io "$quayio_spam_secret"
            'quay.io/spam/bacon' quay.io "$quayio_spam_secret"
            'quay.io/spam/bacon/eggs/ham/sausage' quay.io "$quayio_spam_secret"
            'quay.io:443' quay.io:443 "$quayio_443_secret"
            'quay.io:443/spam' quay.io:443 "$quayio_443_spam_secret"
            'quay.io:443/spam/bacon' quay.io:443 "$quayio_443_spam_secret"
            'quay.io:5000' quay.io:5000 "$quayio_5000_secret"
            'quay.io:5000/spam' quay.io:5000 "$quayio_5000_spam_secret"
            'quay.io:5000/spam/bacon' quay.io:5000 "$quayio_5000_spam_secret"
        End

        It "$1"
            When call selectauth_token $1 $2
            The output should eq $3
            The error should include "Using token for"
        End
    End

    Describe 'does not match'
        Parameters
            'quay.local'
            'quay.local/spam'
            'quay.local/spam/bacon'
            'quay.io:8080'
            'quay.io:8080/spam'
            'quay.io:8080/spam/bacon'
        End

        It "$1"
            When call selectauth $1
            The output should eq '{"auths": {}}'
            The error should include "Token not found"
        End
    End

End


It 'missing parameter'
    When call ./select-oci-auth.sh
    The error should eq "Specify the image reference to match"
    The status should be failure
End
