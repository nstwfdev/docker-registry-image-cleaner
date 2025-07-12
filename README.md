# Docker & GHCR Image Cleaner

A utility for automatically deleting old Docker images by prefix and age from Docker Hub and GitHub Container Registry (
GHCR).

---

## Features

* Clean up Docker Hub and GHCR images from a single script
* Filter by tag prefix (`IMAGE_PREFIX`)
* Filter by image age in days (`MAX_AGE_DAYS`)
* Easy to run locally or inside Docker

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

## Environment Variables

| Variable             | Description                                                | Required for       |
|----------------------|------------------------------------------------------------|--------------------|
| `DOCKERHUB_REPO`     | Docker Hub repository (e.g. `username/repo`)               | Docker Hub cleanup |
| `DOCKERHUB_USERNAME` | Docker Hub username                                        | Docker Hub cleanup |
| `DOCKERHUB_PASSWORD` | Docker Hub password                                        | Docker Hub cleanup |
| `GHCR_REPO`          | GHCR repository (e.g. `ghcr.io/org/repo`)                  | GHCR cleanup       |
| `GHCR_TOKEN`         | GitHub token with `delete:packages` permission             | GHCR cleanup       |
| `IMAGE_PREFIX`       | (Optional) Only delete tags starting with this prefix      | Both               |
| `MAX_AGE_DAYS`       | (Optional) Only delete tags older than this number of days | Both               |

---

## Help

You can view the built-in help by running the container with `--help` or `-h`:

```bash
docker run --rm nstwf/docker-registry-image-cleaner:latest --help
```

This will display usage instructions and environment variable details from inside the container.

---

Feel free to ask if you want help with publishing images or integrating with CI/CD!
