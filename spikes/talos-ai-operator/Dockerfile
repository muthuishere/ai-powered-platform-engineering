# syntax=docker/dockerfile:1.7
#
# Talos AI Operator — the fat, air-tight image (book Ch9).
#
#   JDK 22 (FFM) + Spring Boot agent jar (mochallama embedded)
#   + python3 + kubectl + talosctl
#   + the read-only platform-sre scripts at /opt/platform-sre/scripts
#   + the GGUF model BAKED IN at /models (downloaded at BUILD time => runtime offline)
#
# Multi-GB on purpose: that is the "all embedded / no network at runtime" trade.
# Build:  task build   (or: docker build --build-arg MODEL_URL=... -t talos-ai-operator:dev .)

# ---------------------------------------------------------------------------
# Stage 1 — build the Spring Boot fat jar (mochallama pulled from Maven Central)
# ---------------------------------------------------------------------------
FROM eclipse-temurin:22-jdk AS build
WORKDIR /src
# Wrapper + build files first for layer caching.
COPY gradlew settings.gradle build.gradle ./
COPY gradle ./gradle
RUN chmod +x gradlew && ./gradlew --no-daemon dependencies > /dev/null 2>&1 || true
COPY src ./src
RUN ./gradlew --no-daemon clean bootJar -x test \
    && cp build/libs/*-0*.jar /app.jar \
    && test -f /app.jar

# ---------------------------------------------------------------------------
# Stage 2 — fetch the GGUF at BUILD time so the runtime is air-gapped.
# Default: Qwen2.5-3B-Instruct q4_k_m (tool-capable, CPU-runnable). Swap via
# build args for real hardware (e.g. a bigger Qwen3 / Phi-4 GGUF).
# ---------------------------------------------------------------------------
FROM debian:12-slim AS model
ARG MODEL_FILENAME=qwen2.5-3b-instruct-q4_k_m.gguf
ARG MODEL_URL=https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /models \
    && echo "Baking model ${MODEL_FILENAME} from ${MODEL_URL}" \
    && curl -fL --retry 3 -o "/models/${MODEL_FILENAME}" "${MODEL_URL}" \
    && test -s "/models/${MODEL_FILENAME}"

# ---------------------------------------------------------------------------
# Stage 3 — the air-tight runtime image
# ---------------------------------------------------------------------------
FROM eclipse-temurin:22-jre AS runtime
ARG MODEL_FILENAME=qwen2.5-3b-instruct-q4_k_m.gguf
ARG KUBECTL_VERSION=v1.31.0
ARG TALOSCTL_VERSION=v1.8.0
ARG TARGETARCH=amd64

ENV MODEL_FILENAME=${MODEL_FILENAME} \
    JAVA_TOOL_OPTIONS="" \
    LANG=C.UTF-8

# python3 (the @Tool methods exec the read-only scripts) + the CLIs they use.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-yaml ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# kubectl + talosctl (read-only get/list/watch from inside the cluster).
RUN curl -fL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fL -o /usr/local/bin/talosctl \
        "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/talosctl

# Read-only platform-sre capabilities (reused as-is).
COPY scripts/ /opt/platform-sre/scripts/

# The Spring Boot agent (mochallama embedded) + the baked-in model.
COPY --from=build  /app.jar     /app/app.jar
COPY --from=model  /models      /models

# Non-root.
RUN useradd -r -u 10001 -d /app operator \
    && chown -R operator:operator /app /models /opt/platform-sre
USER operator

WORKDIR /app
EXPOSE 8080

# --enable-native-access=ALL-UNNAMED is REQUIRED for mochallama's FFM bridge;
# the incubator Vector API speeds up CPU inference.
ENTRYPOINT ["java", \
    "--enable-native-access=ALL-UNNAMED", \
    "--add-modules=jdk.incubator.vector", \
    "-jar", "/app/app.jar"]
