package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/client"
	"github.com/docker/docker/pkg/archive"
	"github.com/docker/go-connections/nat"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

var containerClient *client.Client

const (
	containerImage    = "local-build-trusted-artifacts:acceptance"
	waitTimeout       = 1 * time.Minute
	environmentKey    = "env"
	logsKey           = "logs"
	networkName       = "trusted-artifacts-network"
	registryHost      = "trusted-artifacts-registry"
	artifactContainer = "trusted-artifacts"
	registryPort      = "5000"
	registryImage     = "docker.io/library/registry:2.8.3"
)

func init() {
	var err error
	containerClient, err = client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		panic(fmt.Sprintf("creating new client: %s", err))
	}
}

func runRegistry(ctx context.Context, binds []string, certs, key string) (string, error) {
	user, err := user.Current()
	if err != nil {
		return "", err
	}

	imageExists, err := imageExists(ctx, registryImage)
	if err != nil {
		return "", err
	}

	portMap := nat.PortMap{
		"5000/tcp": []nat.PortBinding{
			{
				HostIP:   "0.0.0.0",
				HostPort: "5000",
			},
		},
	}

	tempDir, err := os.MkdirTemp("", "registry-")
	if err != nil {
		return "", fmt.Errorf("setting up scenario: %w", err)
	}

	binds = append(binds, fmt.Sprintf("%s:/var/lib/registry:Z", tempDir))

	if !imageExists {
		// Pull the image
		reader, err := containerClient.ImagePull(ctx, registryImage, image.PullOptions{})
		if err != nil {
			panic(err)
		}
		defer reader.Close()
		io.Copy(os.Stdout, reader)
	}

	cont, err := containerClient.ContainerCreate(
		ctx,
		&container.Config{
			Hostname: registryHost,
			Env: []string{
				fmt.Sprintf("REGISTRY_HTTP_TLS_CERTIFICATE=%s", certs),
				fmt.Sprintf("REGISTRY_HTTP_TLS_KEY=%s", key),
			},
			Image: registryImage,
			User:  user.Uid,
			ExposedPorts: nat.PortSet{
				"5000/tcp": struct{}{},
			},
		},
		&container.HostConfig{
			Binds:        binds,
			PortBindings: portMap,
			NetworkMode:  container.NetworkMode(networkName),
			SecurityOpt:  []string{"label:disable"},
			Privileged:   true,
		},
		&network.NetworkingConfig{
			EndpointsConfig: map[string]*network.EndpointSettings{},
		},
		&ocispec.Platform{},
		registryHost,
	)

	if err != nil {
		return "", fmt.Errorf("creating container: %w", err)
	}

	if err := containerClient.ContainerStart(ctx, cont.ID, container.StartOptions{}); err != nil {
		return "", fmt.Errorf("starting container %s: %w", cont.ID, err)
	}

	return cont.ID, nil
}

func stopContainer(ctx context.Context, containerID string) error {
	return containerClient.ContainerRemove(ctx, containerID, container.RemoveOptions{Force: true})
}

func cleanupContainer(ctx context.Context, containerID string) error {
	containerJSON, err := containerClient.ContainerInspect(ctx, containerID)
	if err != nil {
		return fmt.Errorf("inspecting container: %w", err)
	}

	stopContainer(ctx, containerID)

	hostBinds := containerJSON.HostConfig.Binds
	// Remove bind mounts
	for _, bind := range hostBinds {
		hostPath, _, _ := strings.Cut(bind, ":")
		if err := os.RemoveAll(hostPath); err != nil {
			return fmt.Errorf("removing bind mount %s: %w", hostPath, err)
		}
	}

	return nil
}

func runContainer(ctx context.Context, cmd, binds []string, cert string) (context.Context, error) {
	var env []string
	if e, ok := ctx.Value(environmentKey).([]string); ok {
		env = e
	}
	env = append(env, fmt.Sprintf("CA_FILE=%s", cert))

	user, err := user.Current()
	if err != nil {
		return ctx, err
	}

	cont, err := containerClient.ContainerCreate(
		ctx,
		&container.Config{
			Image: containerImage,
			Tty:   true, // Prevent leading metadata characters in the container logs... weird
			Cmd:   cmd,
			Env:   env,
			User:  user.Uid,
		},
		&container.HostConfig{
			Binds:       binds,
			NetworkMode: container.NetworkMode(networkName),
		},
		&network.NetworkingConfig{},
		&ocispec.Platform{},
		artifactContainer,
	)
	if err != nil {
		return ctx, fmt.Errorf("creating container: %w", err)
	}

	defer containerClient.ContainerRemove(ctx, cont.ID, container.RemoveOptions{Force: true})

	if err := containerClient.ContainerStart(ctx, cont.ID, container.StartOptions{}); err != nil {
		return ctx, fmt.Errorf("starting container %s: %w", cont.ID, err)
	}

	if ctx, err = waitForContainer(ctx, cont.ID); err != nil {
		return ctx, fmt.Errorf("waiting for container %s: %w", cont.ID, err)
	}

	return ctx, nil
}

func waitForContainer(ctx context.Context, contID string) (context.Context, error) {
	ctxWait, cancel := context.WithTimeout(ctx, waitTimeout)
	defer cancel()

	waitC, errC := containerClient.ContainerWait(ctxWait, contID, container.WaitConditionNotRunning)
	select {
	case wait := <-waitC:
		if wait.Error != nil {
			return ctx, fmt.Errorf("wait error: %s", wait.Error)
		}
		logs := getContainerLogs(ctx, contID)
		ctx = context.WithValue(ctx, logsKey, logs)

		if wait.StatusCode != 0 {
			return ctx, fmt.Errorf("unexpected status code %d, logs:\n%s", wait.StatusCode, logs)
		}
	case err := <-errC:
		if err != nil {
			return ctx, fmt.Errorf("waiting for container: %w", err)
		}
	}

	return ctx, nil
}

func getContainerLogs(ctx context.Context, contID string) string {
	opts := container.LogsOptions{ShowStdout: true, ShowStderr: true}
	logReader, err := containerClient.ContainerLogs(ctx, contID, opts)
	if err != nil {
		return fmt.Sprintf("cannot get logs for container %s: %s", contID, err)
	}
	logs, err := io.ReadAll(logReader)
	if err != nil {
		return fmt.Sprintf("cannot read logs for container %s: %s", contID, err)
	}
	return string(logs)
}

func buildContainerImage(ctx context.Context) error {
	targetArch := runtime.GOARCH
	opts := types.ImageBuildOptions{
		Dockerfile: "Containerfile",
		Tags:       []string{containerImage},
		BuildArgs: map[string]*string{
			"TARGETARCH": &targetArch,
		},
	}

	buildContextPath, err := filepath.Abs("..")
	if err != nil {
		return fmt.Errorf("resolving build context path: %w", err)
	}
	buildContext, err := archive.TarWithOptions(buildContextPath, &archive.TarOptions{})
	if err != nil {
		return fmt.Errorf("creating build context archive: %w", err)
	}
	buildResponse, err := containerClient.ImageBuild(ctx, buildContext, opts)
	if err != nil {
		return fmt.Errorf("building image: %w", err)
	}
	// Reading the response is how we wait for the build to be complete. We don't really care about
	// the actual response.
	if _, err := io.ReadAll(buildResponse.Body); err != nil {
		return fmt.Errorf("reading build response: %w", err)
	}
	defer buildResponse.Body.Close()

	return nil
}

func networkExists(ctx context.Context, name string) (bool, error) {
	filters := filters.NewArgs()
	filters.Add("name", name)

	networks, err := containerClient.NetworkList(ctx, types.NetworkListOptions{
		Filters: filters,
	})
	if err != nil {
		return false, err
	}

	for _, network := range networks {
		if network.Name == name {
			return true, nil
		}
	}

	return false, nil
}

func createNetwork(ctx context.Context) error {
	exists, err := networkExists(ctx, networkName)
	if err != nil {
		return err
	}

	if !exists {
		netConfig := types.NetworkCreate{
			CheckDuplicate: true,
			Driver:         "bridge",
			Scope:          "local",
		}

		// Create the network
		if _, err := containerClient.NetworkCreate(ctx, networkName, netConfig); err != nil {
			return err
		}
	}
	return nil
}

func imageExists(ctx context.Context, imageName string) (bool, error) {
	images, err := containerClient.ImageList(ctx, types.ImageListOptions{})
	if err != nil {
		return false, err
	}

	for _, image := range images {
		for _, tag := range image.RepoTags {
			if tag == imageName {
				return true, nil
			}
		}
	}

	return false, nil
}
