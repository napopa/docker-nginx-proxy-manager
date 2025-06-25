# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a fork of the [jlesage/nginx-proxy-manager](https://hub.docker.com/r/jlesage/nginx-proxy-manager) Docker container that adds CrowdSec bouncer support. The project builds a Docker image that includes:

- Nginx Proxy Manager (web-based reverse proxy manager)
- OpenResty (enhanced Nginx)
- CrowdSec OpenResty Bouncer (security layer)
- Various utilities (bcrypt-tool, certbot)

The main difference from the upstream project is the integration of CrowdSec's OpenResty bouncer for enhanced security.

## Build System

### Docker Multi-Stage Build
The project uses a multi-stage Dockerfile with these build stages:
- `upx`: Builds UPX binary packer
- `npm`: Builds Nginx Proxy Manager frontend/backend
- `nginx`: Builds OpenResty with GeoIP2 module
- `bcrypt-tool`: Builds bcrypt utility
- `certbot`: Builds Let's Encrypt certificate tool
- `cs-openresty-bouncer`: Builds CrowdSec bouncer
- Final stage: Combines all components into runtime image

### Build Commands
```bash
# Build the Docker image locally (on amd64)
docker build -t napopa/nginx-proxy-manager .

# Build with specific version args
docker build --build-arg NGINX_PROXY_MANAGER_VERSION=2.12.3 \
             --build-arg CROWDSEC_OPENRESTY_BOUNCER_VERSION=1.0.5 \
             --build-arg OPENRESTY_VERSION=1.27.1.2 \
             -t napopa/nginx-proxy-manager .

# Note: No cross-compilation needed - build directly on amd64/Linux
```

### Component Build Scripts
Each component has its own build script in `src/`:
- `src/nginx-proxy-manager/build.sh` - Main application build
- `src/openresty/build.sh` - Nginx/OpenResty build  
- `src/bcrypt-tool/build.sh` - Password utility build
- `src/cs-openresty-bouncer/build.sh` - CrowdSec bouncer build

## Architecture

### Container Structure
- **Base**: jlesage/baseimage:alpine-3.16-v3.6.4
- **Runtime files**: `/rootfs/` contains all container overlay files
- **Application**: Installed to `/opt/nginx-proxy-manager/`
- **Configuration**: Persistent data in `/config` volume
- **Ports**: 8080 (HTTP), 4443 (HTTPS), 8181 (Web UI)

### Key Components
- **Frontend**: React-based web interface (built with yarn)
- **Backend**: Node.js API server with SQLite database
- **Nginx**: OpenResty with custom modules (GeoIP2, CrowdSec bouncer)
- **CrowdSec Integration**: Bouncer configuration in `/config/crowdsec/`

### Configuration Files
- `appdefs.yml` - Container metadata and documentation source
- `rootfs/defaults/production.json` - Default NPM configuration
- `rootfs/etc/nginx/` - Nginx configuration templates
- `rootfs/etc/cont-init.d/` - Container initialization scripts

## Development Workflow

### CI/CD Pipeline
GitHub Actions workflow (`.github/workflows/build-image.yml`):
- Triggers on push to any branch and tags
- Builds for linux/amd64 platform only (simplified for direct deployment)
- Pushes to both Docker Hub and GitHub Container Registry on tagged releases
- Updates Docker Hub description

### Testing Container
```bash
# Run the container for testing
docker run -d \
    --name=nginx-proxy-manager-test \
    -p 8181:8181 \
    -p 8080:8080 \
    -p 4443:4443 \
    -v ./config:/config:rw \
    napopa/nginx-proxy-manager

# Check logs
docker logs nginx-proxy-manager-test

# Shell access
docker exec -it nginx-proxy-manager-test sh
```

### CrowdSec Configuration
After first run, edit `/config/crowdsec/crowdsec-openresty-bouncer.conf`:
```bash
ENABLED=true
API_URL=http://<crowdsec-server>:8080
API_KEY=<api-key-from-cscli-bouncers-add>
```

## Key Differences from Upstream

1. **CrowdSec Integration**: Added OpenResty bouncer for security
2. **Build Process**: Additional build stage for CrowdSec bouncer
3. **Initialization**: Extra script `99_crowdsec-openresty-bouncer.sh`
4. **Configuration**: CrowdSec config files in persistent volume
5. **Branching**: Uses `crowdsec_rework` branch vs upstream `master`

## Version Information

- **Current NPM Version**: 2.12.3 (latest)
- **OpenResty Version**: 1.27.1.2 (latest)
- **CrowdSec Bouncer Version**: 1.0.5 (latest)
- **Base Image**: Alpine 3.18 (updated from 3.16)
- **Python Cryptography**: 43.0.0-py3.11 (updated from py3.10)

## Default Credentials

- **Username**: admin@example.com
- **Password**: changeme

Change these immediately after first login.

## Build Notes

- You don't need to cross compile!! I will compile on amd64 myself
- Do not rely on cross compiling the image locally for amd64
- You can try and build the image locally for arm64 and run it locally on arm64 to test changes, but never try to cross build

## Troubleshooting

- If you find building problems due to architecture, do not try to fix them and commit to the repos, since the image builds fine on amd64 which is its final target