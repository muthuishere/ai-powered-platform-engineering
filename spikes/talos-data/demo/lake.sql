-- lake.sql — DuckDB as the query runner over a DuckLake lakehouse.
--
-- DuckDB is the *engine*; it holds no state. State lives in two places:
--   1. Table METADATA  -> a SQL catalog DB (Postgres here).
--   2. Table DATA       -> Parquet files on S3-compatible object storage (Garage).
--
-- Nothing about a table is "owned" by this process. Point any other DuckLake
-- client at the same Postgres + bucket and it sees the same tables/snapshots.
--
-- This file is a TEMPLATE. DuckDB's ATTACH / CREATE SECRET take string LITERALS,
-- not expressions, so we don't try to read env vars inside SQL. Instead the
-- ${PLACEHOLDER} tokens below are substituted by run-demo.sh (envsubst) before the
-- SQL reaches DuckDB. Tokens consumed:
--   ${PG_HOST} ${PG_PORT} ${PG_DB} ${PG_USER} ${PG_PASSWORD}
--   ${S3_ENDPOINT} ${S3_KEY_ID} ${S3_SECRET} ${S3_USE_SSL} ${S3_BUCKET}

-- 1. Extensions. ducklake pulls in httpfs (S3) and postgres (catalog) as needed,
--    but we install them explicitly so the script is self-documenting.
INSTALL ducklake;
INSTALL httpfs;
INSTALL postgres;
LOAD ducklake;
LOAD httpfs;
LOAD postgres;

-- 2. S3 credentials for the Garage object store. URL_STYLE 'path' is required for
--    Garage/MinIO-style endpoints (AWS defaults to vhost). USE_SSL is false for the
--    in-cluster plaintext demo endpoint; set it to true behind TLS.
CREATE OR REPLACE SECRET garage (
    TYPE      s3,
    KEY_ID    '${S3_KEY_ID}',
    SECRET    '${S3_SECRET}',
    ENDPOINT  '${S3_ENDPOINT}',
    URL_STYLE 'path',
    USE_SSL   ${S3_USE_SSL}
);

-- 3. Attach the lake. The string after 'ducklake:' is a standard libpq DSN pointing
--    at the Postgres CATALOG. DATA_PATH is where Parquet data lands.
--    Metadata -> Postgres; data -> s3://bucket/lake/. That split *is* DuckLake.
ATTACH 'ducklake:postgres:host=${PG_HOST} port=${PG_PORT} dbname=${PG_DB} user=${PG_USER} password=${PG_PASSWORD}'
    AS lake (DATA_PATH 's3://${S3_BUCKET}/lake/');

USE lake;

-- 4. Create a table and write some rows. Each committed write is a new SNAPSHOT
--    recorded as rows in the Postgres catalog; the data goes to Parquet on S3.
CREATE TABLE IF NOT EXISTS trips (
    id        INTEGER,
    city      VARCHAR,
    fare      DECIMAL(8,2),
    booked_at TIMESTAMP
);

INSERT INTO trips VALUES
    (1, 'chennai',   240.50, TIMESTAMP '2026-06-01 09:15:00'),
    (2, 'bengaluru', 310.00, TIMESTAMP '2026-06-01 09:40:00'),
    (3, 'chennai',   180.75, TIMESTAMP '2026-06-01 10:05:00');

-- A second, separate write -> a second snapshot. This is what we time-travel over.
INSERT INTO trips VALUES
    (4, 'mumbai',    420.00, TIMESTAMP '2026-06-02 08:00:00');

-- 5. Normal query (latest state). Should return 4 rows total.
SELECT '== current state ==' AS step;
SELECT city, count(*) AS trips, sum(fare) AS revenue
FROM trips GROUP BY city ORDER BY revenue DESC;

-- 6. Show the snapshot history straight out of the SQL catalog. This is the
--    headline contrast with Iceberg: history is a SQL table you can query, not a
--    tree of JSON manifest files you have to walk on object storage.
SELECT '== snapshots (from the SQL catalog) ==' AS step;
SELECT snapshot_id, snapshot_time, schema_version, changes
FROM ducklake_snapshots('lake')
ORDER BY snapshot_id;

-- 7. Time travel by VERSION. DuckLake numbers snapshots from 0 (the ATTACH that
--    initialised the catalog). With a fresh catalog the sequence here is:
--      0 = catalog init, 1 = CREATE TABLE, 2 = first INSERT, 3 = second INSERT.
--    So version 2 sees 3 rows; the mumbai trip (version 3) is invisible. If you
--    re-run against a non-fresh catalog, read the actual IDs from step 6 above.
SELECT '== time travel: AT (VERSION => 2) ==' AS step;
SELECT count(*) AS rows_at_v2 FROM trips AT (VERSION => 2);

-- 8. Time travel by TIMESTAMP is independent of snapshot numbering — robust:
SELECT '== time travel: AT (TIMESTAMP => ...) ==' AS step;
SELECT count(*) AS rows_before_jun2
FROM trips AT (TIMESTAMP => TIMESTAMP '2026-06-01 23:59:59');

-- 9. Prove the data is really Parquet on S3 (not hidden in DuckDB):
SELECT '== data files on S3 (path + size) ==' AS step;
SELECT data_file, data_file_size_bytes
FROM ducklake_list_files('lake', 'trips')
ORDER BY data_file;

SELECT '== done ==' AS step;
