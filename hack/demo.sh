#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

root="$(dirname "${BASH_SOURCE[0]}")/.."
repository="${REPOSITORY:-quay.io/zregvart_redhat}"

cluster_config="apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $PWD/storage
        containerPath: /storage
        selinuxRelabel: true
"

kind get clusters -q | grep -q trusted-artifacts || kind create cluster --name=trusted-artifacts --config <(echo "$cluster_config") || { echo 'ERROR: Unable to create a kind cluster'; exit 1; }

kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.50.3/release.yaml

# Create the test namespace
kubectl create namespace test --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=test
while ! kubectl get serviceaccount default 2> /dev/null
do
    sleep 1
done

kubectl -n tekton-pipelines wait deployment -l "app.kubernetes.io/part-of=tekton-pipelines" --for=condition=Available --timeout=3m

kubectl create secret generic docker-config --from-file=.dockerconfigjson="$HOME/.docker/config.json" --type=kubernetes.io/dockerconfigjson --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "docker-config"}], "secrets": [{"name": "docker-config"}]}'

id="$(cd "${root}" && podman build --quiet .)"

podman tag "$id" "${repository}/build-trusted-artifacts"
podman push "${repository}/build-trusted-artifacts"

(
  # shellcheck disable=SC2030
  export repository="${repository}"
  # shellcheck disable=SC2016
  kubectl kustomize --load-restrictor=LoadRestrictionsNone "${root}/hack" | envsubst '$repository' | kubectl apply -f -
)

echo 'apiVersion: v1
kind: PersistentVolume
metadata:
  name: storage-pv
spec:
  storageClassName: standard
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /storage
  persistentVolumeReclaimPolicy: Retain
' | kubectl apply -f -

echo 'apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-pvc
spec:
  volumeName: storage-pv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
' | kubectl apply -f -

#tkn task start git-clone --param url=https://github.com/enterprise-contract/golden-container.git --use-param-defaults --timeout 3m --showlog --workspace name=output,claimName=storage-pvc
#tkn task start buildah --param "IMAGE=${repository}/golden" -p "DOCKERFILE=Containerfile" --use-param-defaults --timeout 3m --showlog --workspace name=source,claimName=storage-pvc

# shellcheck disable=SC2031
echo "apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: demo
spec:
  tasks:
    - name: clone
      params:
        - name: url
          value: https://github.com/enterprise-contract/golden-container.git
      taskRef:
        name: git-clone
      workspaces:
        - name: output
          workspace: workspace
    - name: build
      params:
        - name: IMAGE
          value: ${repository}/golden
        - name: DOCKERFILE
          value: Containerfile
        - name: SOURCE_ARTIFACT
          value: \$(tasks.clone.results.SOURCE_ARTIFACT)=\$(workspaces.source.path)/source
      taskRef:
        name: buildah
      workspaces:
        - name: source
          workspace: workspace
  workspaces:
    - name: workspace
" | kubectl apply -f -

tkn pipeline start demo --pipeline-timeout 5m --showlog --workspace name=workspace,claimName=storage-pvc
