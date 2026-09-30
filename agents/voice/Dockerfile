FROM python:3.13-bookworm

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Install dependencies first for caching
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Bake the turn-detector / VAD model weights into the image. Without this the
# first worker start downloads them from HuggingFace, which is slow and fails
# closed if the host has no outbound access to it.
RUN uv run --no-dev python -m livekit.agents download-files

# Copy application code
COPY agent.py tools.py ui_bridge.py vision.py background.py \
     call_config.py chuk_proxy.py delegation.py ./


# Run the agent
CMD ["uv", "run", "--no-dev", "agent.py", "start"]
