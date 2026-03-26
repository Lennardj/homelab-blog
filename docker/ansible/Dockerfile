FROM python:3.12.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    openssh-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ansible==13.5.0

# Make sure /bin/bash exists (it does in slim, but just being explicit)
SHELL ["/bin/sh", "-lc"]
# ENTRYPOINT ["/work/scripts/wait.sh"]