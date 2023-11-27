# Trusted artifacts

A trusted artifact a way to pass files between two Tekton Tasks without those
files being clandestinely modified. This is done by tracking the digest of
archived files.
A Tekton Task creating a trusted artifact for later use needs to add a step
like:

```yaml
- name: create-trusted-artifact
    image: (image built from this repository)
    args:
        - create
        - <name>=<directory/file>
```

For name, it is convinient to use the TaskRun name: `$(context.taskRun.name)`.

Example:
```yaml
- name: create-trusted-artifact
    image: (image built from this repository)
    args:
        - create
        - source=/workspace/source
```

More than one trusted artifact can be created from that single step by appending
to the `args` list.

The `create` operation (as used above), will generate a result, an array
containing an entry for each of the artifacts created in specified order. The
value of the result entry is used to restore the artifact with the `use`
operation. For example, by adding a step:

```yaml
- name: use-trusted-artifact
    image: (image built from this repository)
    args:
        - use
        - <result entry>=<destination>
```

Since the resulting entry cannot be, in vast majority of cases, predetermined,
referencing the result from the step performing the `create` operation is most
common way of using the `use` operation.

Example:
```yaml
- name: use-trusted-artifact
    image: (image built from this repository)
    args:
        - use
        - $(tasks.clone.results.ARTIFACT[0])=$(workspaces.source.path)/src
```

In that example the first entry of the resulting `ARTIFACT` array of the `clone`
task is restored to the `source` workspace to the subdirectory `src`.

# Running the demo

First make sure that the access information to a image repository is already
present in the `$HOME/.docker/config.json` file. That is `docker login` was used
to populate it. Set the environment variable `REPOSITORY` to the image
repository used, e.g.:

```shell
export REPOSITORY=quay.io/username
```

The `hack/demo.sh` will push to `$REPOSITORY/build-trusted-artifacts` and
`$REPOSITORY/golden`.

The demo script patches the `git-clone` and `buildah` Task definitions form
https://github.com/redhat-appstudio/build-definitions/ and expects that
repository to be cloned in `../build-definitions` directory.

With that setup, the `hack/demo.sh`, will spin up a kind cluster, setup
PersistantVolume and PersistantVolumenClaim backed by the `storage` local
directory; install Tekton Pipelines and run a Pipeline with `git-clone` and
`buildah-tasks`.

Have a look in the `hack/kustomization.yaml` to see how the Tasks ware modified
so that they use trusted artifacts.
