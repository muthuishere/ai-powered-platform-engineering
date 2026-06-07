-- lake.sql — DuckDB as the query runner over a DuckLake lakehouse on MinIO.
--
-- DuckDB is the *engine*; it holds no state. State lives in two places:
--   1. Table METADATA  -> a SQL catalog DB (Postgres here). Snapshots, schema,
--                         and the list of every data file are ROWS you can SELECT.
--   2. Table DATA       -> Parquet files on S3-compatible object storage (MinIO).
--
-- That metadata-in-SQL split is the entire DuckLake thesis and the contrast with
-- Iceberg (which keeps metadata as a tree of JSON/manifest files on object storage).
--
-- This file is a TEMPLATE. DuckDB's ATTACH / CREATE SECRET take string LITERALS,
-- not expressions, so the ${PLACEHOLDER} tokens below are substituted by
-- run-demo.sh (envsubst) before the SQL reaches DuckDB. Tokens consumed:
--   ${PG_HOST} ${PG_PORT} ${PG_DB} ${PG_USER} ${PG_PASSWORD}
--   ${S3_ENDPOINT} ${S3_KEY_ID} ${S3_SECRET} ${S3_USE_SSL} ${S3_BUCKET}
--   ${ROW_COUNT}   (synthetic dataset size, e.g. 2000000)

-- 1. Extensions. ducklake needs httpfs (S3) and postgres (catalog). DuckLake hit
--    1.0 in April 2026; install/load them explicitly so the script self-documents.
INSTALL ducklake;
INSTALL httpfs;
INSTALL postgres;
LOAD ducklake;
LOAD httpfs;
LOAD postgres;

-- 2. S3 credentials for MinIO. URL_STYLE 'path' is REQUIRED for MinIO/Garage-style
--    endpoints (AWS defaults to vhost). USE_SSL is false for the in-cluster
--    plaintext endpoint; set it true behind TLS. For MinIO the access key id /
--    secret are the root user / password (or a scoped key in production).
CREATE OR REPLACE SECRET minio (
    TYPE      s3,
    KEY_ID    '${S3_KEY_ID}',
    SECRET    '${S3_SECRET}',
    ENDPOINT  '${S3_ENDPOINT}',
    URL_STYLE 'path',
    USE_SSL   ${S3_USE_SSL}
);

-- 3. Attach the lake. The string after 'ducklake:' is a standard libpq DSN pointing
--    at the Postgres CATALOG. DATA_PATH is where Parquet data lands on MinIO.
--    Metadata -> Postgres; data -> s3://bucket/lake/. That split *is* DuckLake.
ATTACH 'ducklake:postgres:host=${PG_HOST} port=${PG_PORT} dbname=${PG_DB} user=${PG_USER} password=${PG_PASSWORD}'
    AS lake (DATA_PATH 's3://${S3_BUCKET}/lake/');

USE lake;

-- 4. Schema. A wide-ish synthetic events table so scans/aggregations are non-trivial.
CREATE TABLE IF NOT EXISTS events (
    id         BIGINT,
    user_id    INTEGER,
    city       VARCHAR,
    amount     DECIMAL(10,2),
    event_ts   TIMESTAMP
);

-- 5. INGEST — bulk-insert a synthetic dataset and TIME it. This single committed
--    write becomes one DuckLake snapshot: a row insert in the Postgres catalog plus
--    Parquet objects written to MinIO. ${ROW_COUNT} rows generated from range().
SELECT '== ingest timing ==' AS step;
.timer on
INSERT INTO events
SELECT
    i                                         AS id,
    (i % 50000)::INTEGER                       AS user_id,
    ['chennai','bengaluru','mumbai','delhi','pune','hyderabad'][(i % 6) + 1] AS city,
    round((i % 1000) + (i % 7) * 0.5, 2)::DECIMAL(10,2) AS amount,
    TIMESTAMP '2026-01-01 00:00:00' + (INTERVAL 1 SECOND * (i % 5184000)) AS event_ts
FROM range(${ROW_COUNT}) t(i);
.timer off

-- A second, smaller write -> a SECOND snapshot. This is what we time-travel over.
INSERT INTO events
SELECT
    ${ROW_COUNT} + i                           AS id,
    (i % 50000)::INTEGER                        AS user_id,
    'late-arrival'                              AS city,
    99.99::DECIMAL(10,2)                        AS amount,
    TIMESTAMP '2026-06-01 00:00:00'             AS event_ts
FROM range(10000) t(i);

-- 6. SCAN throughput — full-table count, timed. rows_per_s is derived in run.sh
--    from this count and the .timer wall time printed for this statement.
SELECT '== full scan (count) ==' AS step;
.timer on
SELECT count(*) AS total_rows FROM events;
.timer off

-- 7. AGGREGATION query, repeated so run.sh can derive p50/p95 latency. Each line is
--    one timed query; run.sh parses the per-statement .timer lines.
SELECT '== aggregation queries (timed x10) ==' AS step;
.timer on
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
SELECT city, count(*) c, sum(amount) rev, avg(amount) a FROM events GROUP BY city ORDER BY rev DESC;
.timer off

-- 8. The headline contrast with Iceberg: snapshot history is a SQL TABLE you query,
--    not a tree of JSON manifest files you walk on object storage.
SELECT '== snapshots (from the SQL catalog) ==' AS step;
SELECT snapshot_id, snapshot_time, schema_version, changes
FROM ducklake_snapshots('lake')
ORDER BY snapshot_id;

-- 9. TIME TRAVEL by VERSION. With a fresh catalog the snapshot sequence is:
--      0 = catalog init, 1 = CREATE TABLE, 2 = first (big) INSERT, 3 = second INSERT.
--    Version 2 therefore sees ONLY the big insert (no 'late-arrival' rows). If you
--    re-run against a non-fresh catalog, read the real ids from step 8 above.
SELECT '== time travel: AT (VERSION => 2) ==' AS step;
SELECT count(*) AS rows_at_v2 FROM events AT (VERSION => 2);
SELECT count(*) AS late_rows_at_v2 FROM events AT (VERSION => 2) WHERE city = 'late-arrival';

-- 10. TIME TRAVEL by TIMESTAMP is independent of snapshot numbering — robust:
SELECT '== time travel: AT (TIMESTAMP => now) ==' AS step;
SELECT count(*) AS rows_now FROM events AT (TIMESTAMP => now());

-- 11. ON-DISK footprint — prove the data is really Parquet on MinIO (not hidden in
--     DuckDB), and emit the total bytes so run.sh can record on_disk_bytes.
SELECT '== data files on S3 (path + size) ==' AS step;
SELECT data_file_path, file_size_bytes
FROM ducklake_list_files('lake', 'events')
ORDER BY data_file_path;

SELECT '== ON_DISK_BYTES marker ==' AS step;
SELECT 'ON_DISK_BYTES=' || coalesce(sum(file_size_bytes), 0)::BIGINT AS marker
FROM ducklake_list_files('lake', 'events');

SELECT '== METADATA_IN_SQL marker ==' AS step;
-- The catalog itself is queryable SQL — count how many file-rows the SQL catalog
-- tracks. With Iceberg this would mean walking manifest files on object storage.
SELECT 'CATALOG_FILE_ROWS=' || count(*)::BIGINT AS marker
FROM ducklake_list_files('lake', 'events');

SELECT '== done ==' AS step;
