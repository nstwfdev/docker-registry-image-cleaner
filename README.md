# Docker & GHCR Image Cleaner

A utility for automatically deleting old Docker images by prefix and age from Docker Hub and GitHub Container Registry (
GHCR).

---

## Contents

* [ Features ](#features)
* [Quick Start](#quick-start)

* [ 1. Using the `clean.sh` Script Locally ](#1-using-the-cleansh-script-locally)
* [2. Running via Docker](#2-running-via-docker)
* [GitHub Action: `nstwf/docker-registry-cleaner`](#github-action-nstwfdocker-registry-cleaner)

* [ Usage in Workflow ](#usage-in-workflow)
* [Action Inputs](#action-inputs)
* [Help](#help)
* [Support](#support)

---

## Features

* Clean up Docker Hub and GHCR images from a single script
* Filter by tag prefix (`IMAGE_PREFIX`)
* Filter by image age in days (`MAX_AGE_DAYS`)
* Easy to run locally or inside Docker
* GitHub Action support

---

## Quick Start

### 1. Using the `clean.sh` Script Locally

You need `bash`, `jq`, `curl`, and GNU `date` available.

```bash
DOCKERHUB_REPO="username/repo" \
DOCKERHUB_USERNAME="user" \
DOCKERHUB_PASSWORD="pass" \
IMAGE_PREFIX="myapp-" \
MAX_AGE_DAYS=7 \
./clean.sh
```

---

### 2. Running via Docker

Pull the image from Docker Hub:

  ```bash
  docker pull nstwf/docker-registry-image-cleaner:latest
  ```

Run it with environment variables:

  ```bash
  docker run --rm \
  -e DOCKERHUB_REPO="username/repo" \
  -e DOCKERHUB_USERNAME="user" \
  -e DOCKERHUB_PASSWORD="pass" \
  -e GHCR_REPO="ghcr.io/org/repo" \
  -e GHCR_TOKEN="ghp_..." \
  -e IMAGE_PREFIX="myapp-" \
  -e MAX_AGE_DAYS="7" \
  nstwf/docker-registry-image-cleaner:latest
  ```

---

## GitHub Action: `nstwf/docker-registry-cleaner`

Run the registry cleaner using the official Docker image inside your workflows without rebuilding the container.

### Usage in Workflow

```yaml
jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - name: Run Registry Cleaner
        uses: nstwfdev/docker-registry-image-cleaner@v1
        with:
          dockerhub_repo: "username/repo"
          dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub_password: ${{ secrets.DOCKERHUB_PASSWORD }}
          ghcr_repo: "ghcr.io/org/repo"
          ghcr_token: ${{ secrets.GHCR_TOKEN }}
          image_prefix: "myapp-"
          max_age_days: 7
  ```

### Action Inputs

| Input                | Description                                                | Required |
|----------------------|------------------------------------------------------------|----------|
| `dockerhub_repo`     | Docker Hub repository (e.g. `username/repo`)               | no       |
| `dockerhub_username` | Docker Hub username                                        | no\*     |
| `dockerhub_password` | Docker Hub password                                        | no\*     |
| `ghcr_repo`          | GitHub Container Registry repo (e.g. `ghcr.io/org/repo`)   | no       |
| `ghcr_token`         | GitHub token with `delete:packages` permission             | no\*     |
| `image_prefix`       | (Optional) Only delete tags starting with this prefix      | no       |
| `max_age_days`       | (Optional) Only delete tags older than this number of days | no       |

*\* Required if corresponding repository input is set.*

---

## Help

You can view the built-in help by running the container with `--help` or `-h`:

  ```bash
  docker run --rm nstwf/docker-registry-image-cleaner:latest --help
  ```

This will display usage instructions and environment variable details from inside the container.