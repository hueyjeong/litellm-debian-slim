# Base image for building (Debian Slim)
ARG LITELLM_BUILD_IMAGE=python:3.13-slim

# Runtime image (Debian Slim)
ARG LITELLM_RUNTIME_IMAGE=python:3.13-slim

# --- Builder stage ---
FROM $LITELLM_BUILD_IMAGE AS builder

# Set the working directory to /app
WORKDIR /app

USER root

# Install build dependencies
# Alpine: apk add ... gcc python3-dev openssl-dev
# Debian: apt-get ... build-essential python3-dev libssl-dev
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip>=24.3.1 && \
    pip install build

# Copy the current directory contents into the container at /app
COPY . .

# Fix line endings for shell scripts in builder stage
RUN sed -i 's/\r$//' docker/build_admin_ui.sh docker/install_auto_router.sh

# Build Admin UI
RUN chmod +x docker/build_admin_ui.sh && ./docker/build_admin_ui.sh

# Build the package
RUN rm -rf dist/* && python -m build

# There should be only one wheel file now, assume the build only creates one
RUN ls -1 dist/*.whl | head -1

# Install the package
RUN pip install dist/*.whl

# install dependencies as wheels
RUN pip wheel --no-cache-dir --wheel-dir=/wheels/ -r requirements.txt

# ensure pyjwt is used, not jwt
RUN pip uninstall jwt -y || true
RUN pip uninstall PyJWT -y || true
RUN pip install PyJWT==2.9.0 --no-cache-dir

# Runtime stage
FROM $LITELLM_RUNTIME_IMAGE AS runtime

# Ensure runtime stage runs as root
USER root

# Install runtime dependencies
# Alpine: apk add ... openssl tzdata nodejs npm
# Debian: apt-get ... openssl ca-certificates tzdata nodejs npm
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    openssl \
    ca-certificates \
    tzdata \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip to fix CVE-2025-8869
RUN pip install --upgrade pip>=24.3.1

WORKDIR /app
# Copy the current directory contents into the container at /app
COPY . .
RUN ls -la /app

# Copy the built wheel from the builder stage to the runtime stage; assumes only one wheel file is present
COPY --from=builder /app/dist/*.whl .
COPY --from=builder /wheels/ /wheels/

# Install the built wheel using pip; again using a wildcard if it's the only file
RUN pip install *.whl /wheels/* --no-index --find-links=/wheels/ && rm -f *.whl && rm -rf /wheels

# Remove test files and keys from dependencies
# Debian's path is /usr/local/lib/python3.13/site-packages, so scope is adjusted to /usr/local/lib
RUN find /usr/local/lib -type f -path "*/tornado/test/*" -delete && \
    find /usr/local/lib -type d -path "*/tornado/test" -delete

# Fix line endings for shell scripts in runtime stage
RUN sed -i 's/\r$//' docker/install_auto_router.sh docker/entrypoint.sh docker/prod_entrypoint.sh

# Install semantic_router and aurelio-sdk using script
RUN chmod +x docker/install_auto_router.sh && ./docker/install_auto_router.sh

# Generate prisma client
RUN prisma generate
RUN chmod +x docker/entrypoint.sh
RUN chmod +x docker/prod_entrypoint.sh

EXPOSE 4000/tcp

RUN apt-get update && \
    apt-get install -y --no-install-recommends supervisor && \
    rm -rf /var/lib/apt/lists/*

COPY docker/supervisord.conf /etc/supervisord.conf

ENTRYPOINT ["docker/prod_entrypoint.sh"]

# Append "--detailed_debug" to the end of CMD to view detailed debug logs
CMD ["--port", "4000"]
