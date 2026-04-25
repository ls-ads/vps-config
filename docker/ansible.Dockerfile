# Ansible runner image. Built on demand by the `./ansible` wrapper.
# Pins the Ansible version + collections so every workstation + CI job
# runs the same tool matrix. No local Python or Ansible install needed —
# Docker is the only host-side dependency.

FROM python:3.14-slim

ARG ANSIBLE_VERSION=9.5.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      gnupg \
      openssh-client \
      rsync \
      sshpass \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      "ansible==${ANSIBLE_VERSION}" \
      "ansible-lint" \
      "cryptography" \
      "docker" \
      "jmespath" \
      "netaddr" \
      "passlib" \
      "requests"

# Install Galaxy collections at build time so we're not downloading on
# every run. Docker's layer cache will only invalidate this step when
# requirements.yml actually changes.
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p /opt/galaxy \
    && rm /tmp/requirements.yml

ENV ANSIBLE_COLLECTIONS_PATH=/opt/galaxy

WORKDIR /workspace
