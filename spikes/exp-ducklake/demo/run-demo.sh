#!/usr/bin/env bash
# run-demo.sh — run the DuckLake-on-MinIO demo with the local DuckDB CLI.
#
# DuckDB is the query runner. This script supplies connection env vars and pipes
# demo/lake.sql into `duckdb`. The lake's state lives in Postgres (catalog) and on
# the MinIO S3 bucket (Parquet) — not in any local file.
#
# Prereqs:
#   - duckdb CLI installed (>= the 2026 line that ships DuckLake 1.0; `duckdb --version`)
#   - envsubst (gettext): brew install gettext / apt-get install gettext-base
#   - a reachable Postgres (catalog) and a MinIO/S3 endpoint + bucket
# Defaults target the local k8s port-forwards described in the README; override any
# via the environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Catalog (Postgres) ---
export PG_HOST="${PG_HOST:-127.0.0.1}"
export PG_PORT="${PG_PORT:-5432}"
export PG_DB="${PG_DB:-ducklake}"
export PG_USER="${PG_USER:-ducklake}"
export PG_PASSWORD="${PG_PASSWORD:-ducklake}"

# --- Object storage (MinIO, S3-compatible) ---
# For MinIO the access key id / secret are the root user / password by default.
export S3_ENDPOINT="${S3_ENDPOINT:-127.0.0.1:9000}"
export S3_KEY_ID="${S3_KEY_ID:-minioadmin}"
export S3_SECRET="${S3_SECRET:-minioadmin123}"
export S3_USE_SSL="${S3_USE_SSL:-false}"
export S3_BUCKET="${S3_BUCKET:-ducklake}"

# --- Benchmark size ---
export ROW_COUNT="${ROW_COUNT:-2000000}"

for bin in duckdb envsubst; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: '$bin' not found on PATH." >&2
    [ "$bin" = duckdb ] && echo "  install: https://duckdb.org/docs/installation/" >&2
    [ "$bin" = envsubst ] && echo "  install: gettext (brew install gettext / apt-get install gettext-base)" >&2
    exit 1
  }
done

echo "duckdb: $(duckdb --version)"
echo "catalog: postgres ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
echo "data:    s3://${S3_BUCKET}/lake/  via  ${S3_ENDPOINT} (ssl=${S3_USE_SSL})"
echo "rows:    ${ROW_COUNT}"
echo

# DuckDB's ATTACH / CREATE SECRET take string LITERALS, so render the env vars into
# lake.sql with envsubst (restricted to our token list) BEFORE piping into an
# in-memory DuckDB. No local .db file is persisted; durable state -> Postgres + MinIO.
VARS='${PG_HOST} ${PG_PORT} ${PG_DB} ${PG_USER} ${PG_PASSWORD} ${S3_ENDPOINT} ${S3_KEY_ID} ${S3_SECRET} ${S3_USE_SSL} ${S3_BUCKET} ${ROW_COUNT}'
envsubst "$VARS" < "${SCRIPT_DIR}/lake.sql" | duckdb :memory:
