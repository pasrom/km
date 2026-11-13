# The image every role session of the agent layer runs in (e2e/README-agents.md). After Claude Code's
# reference devcontainer: Node with Claude Code, git, gh, jq, python3 and uv, and a firewall the entrypoint
# sets up before it drops to the session user (init-firewall.sh). Claude Code's updater and nonessential
# traffic are off here, for every container. Every version is pinned; build once:
#   docker build -t km-e2e-agent:1 e2e/container
FROM node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee

ARG CLAUDE_CODE_VERSION=2.1.325
ARG GH_VERSION=2.103.3
ARG GH_SHA256_ARM64=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
ARG GH_SHA256_AMD64=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG UV_VERSION=0.13.7
ARG UV_SHA256_ARM64=71279f8d3c67241e807b9d8db872d1bf541579fb9f08b7d1eb1682196d1e57dc
ARG UV_SHA256_AMD64=c5221ff41b7892bfc223543883600125f6a47fe845093e0f5bdff4f359196d83
# km's own pin (skills/km/bin/km): the uv cache below holds it, so km starts without a package index
ARG PYYAML_VERSION=6.0.3

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less procps python3 python3-yaml \
      iptables ipset iproute2 dnsutils util-linux \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN set -eu; arch="$(dpkg --print-architecture)"; \
    case "$arch" in arm64) gh_sum=$GH_SHA256_ARM64; uv_arch=aarch64; uv_sum=$UV_SHA256_ARM64;; \
                    amd64) gh_sum=$GH_SHA256_AMD64; uv_arch=x86_64; uv_sum=$UV_SHA256_AMD64;; \
                    *) echo "unsupported architecture $arch" >&2; exit 1;; esac; \
    cd /tmp; \
    curl -fsSLo gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz"; \
    echo "$gh_sum  gh.tgz" | sha256sum -c -; \
    tar -xzf gh.tgz; install -D -m 0755 "gh_${GH_VERSION}_linux_${arch}/bin/gh" /opt/gh/bin/gh; \
    curl -fsSLo uv.tgz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_arch}-unknown-linux-gnu.tar.gz"; \
    echo "$uv_sum  uv.tgz" | sha256sum -c -; \
    tar -xzf uv.tgz; install -m 0755 "uv-${uv_arch}-unknown-linux-gnu/uv" "uv-${uv_arch}-unknown-linux-gnu/uvx" /usr/local/bin/; \
    rm -rf /tmp/*

# gh is off the PATH: a session reaches it only through its role's wrapper (`uv run`, which starts km, puts
# its own folder, /usr/local/bin, first on the PATH, so a gh there would bypass the wrapper)
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force

# the session user is `node` (uid 1000); its uv cache holds km's PyYAML for the system Python
USER node
RUN uv run --quiet --no-config --no-project --python '>=3.11' --with "pyyaml==${PYYAML_VERSION}" python -c 'import yaml'
USER root

COPY init-firewall.sh entrypoint.sh /usr/local/sbin/
RUN chmod 0755 /usr/local/sbin/init-firewall.sh /usr/local/sbin/entrypoint.sh \
    && mkdir -p /work/inputs /opt/km-e2e/net /etc/claude-code && chown -R node:node /work

LABEL km-e2e.claude-code="${CLAUDE_CODE_VERSION}"
ENV DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never
WORKDIR /work
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
