package main

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/client"
	"github.com/docker/docker/pkg/archive"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

var containerClient *client.Client

const containerImage = "local.build-trusted-artifacts:acceptance"

const waitTimeout = 1 * time.Minute

func init() {
	var err error
	containerClient, err = client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		panic(fmt.Sprintf("creating new client: %s", err))
	}
}

func runContainer(ctx context.Context, cmd []string, binds []string) error {
	cont, err := containerClient.ContainerCreate(
		ctx,
		&container.Config{
			Image: containerImage,
			Tty:   true, // Prevent leading metadata characters in the container logs... weird
			Cmd:   cmd,
		},
		&container.HostConfig{
			Binds: binds,
		},
		&network.NetworkingConfig{},
		&ocispec.Platform{},
		"", // Let docker pick a name.
	)
	if err != nil {
		return fmt.Errorf("creating container: %w", err)
	}

	defer containerClient.ContainerRemove(ctx, cont.ID, container.RemoveOptions{Force: true})

	if err := containerClient.ContainerStart(ctx, cont.ID, container.StartOptions{}); err != nil {
		return fmt.Errorf("starting container %s: %w", cont.ID, err)
	}

	if err := waitForContainer(ctx, cont.ID); err != nil {
		return fmt.Errorf("waiting for container %s: %w", cont.ID, err)
	}

	return nil
}

func waitForContainer(ctx context.Context, contID string) error {
	ctxWait, cancel := context.WithTimeout(ctx, waitTimeout)
	defer cancel()

	waitC, errC := containerClient.ContainerWait(ctxWait, contID, container.WaitConditionNotRunning)
	select {
	case wait := <-waitC:
		if wait.Error != nil {
			return fmt.Errorf("wait error: %s", wait.Error)
		}
		if wait.StatusCode != 0 {
			logs := getContainerLogs(ctx, contID)
			return fmt.Errorf("unexpected status code %d, logs:\n%s", wait.StatusCode, logs)
		}
	case err := <-errC:
		if err != nil {
			return fmt.Errorf("waiting for container: %w", err)
		}
	}

	return nil
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
	opts := types.ImageBuildOptions{
		Dockerfile: "Containerfile",
		Tags:       []string{containerImage},
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
