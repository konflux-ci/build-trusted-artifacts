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
        export AUTHFILE="$(mktemp --tmpdir build-trusted-artifacts.XXX)"
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

    Before 'setup'
    After 'cleanup'

    Describe 'matches'
        Parameters
            'quay.io' "$quayio_secret"
            'quay.io/spam' "$quayio_spam_secret"
            'quay.io/spam/bacon' "$quayio_spam_secret"
            'quay.io/spam/bacon/eggs/ham/sausage' "$quayio_spam_secret"
            'quay.io:443' "$quayio_443_secret"
            'quay.io:443/spam' "$quayio_443_spam_secret"
            'quay.io:443/spam/bacon' "$quayio_443_spam_secret"
            'quay.io:5000' "$quayio_5000_secret"
            'quay.io:5000/spam' "$quayio_5000_spam_secret"
            'quay.io:5000/spam/bacon' "$quayio_5000_spam_secret"
        End

        It "$1"
            When run script ./select-oci-auth.sh $1
            The output should include $2
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
            When run script ./select-oci-auth.sh $1
            The output should eq '{"auths": {}}'
            The error should include "Token not found"
        End
    End

End

It 'missing parameter'
    When run script ./select-oci-auth.sh
    The error should eq "Specify the image reference to match"
    The status should be failure
End

Describe 'missing-auth-file'
    setup() {
        export AUTHFILE="$(mktemp --tmpdir build-trusted-artifacts.XXX)"
    }

    cleanup() {
        rm -f "${AUTHFILE}"
    }

    Before 'setup'
    After 'cleanup'

    It 'returns empty auth when no tokens match'
        When run script ./select-oci-auth.sh "dummy"
        The output should eq '{"auths": {}}'
        The error should include "Token not found"
    End
End
