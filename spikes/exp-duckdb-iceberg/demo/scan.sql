-- scan.sql — DuckDB as the query runner over an Apache Iceberg table.
--
-- DuckDB holds NO state. The table was created by create_table.py (pyiceberg). All
-- durable state is on S3: Parquet data + the Iceberg metadata tree (metadata.json +
-- manifest lists + manifest files). DuckDB just reads it.
--
-- We point iceberg_scan straight at the CURRENT root metadata.json that pyiceberg
-- reported (ICEBERG_METADATA_LOCATION). This sidesteps DuckDB's filename "version
-- guessing" entirely — pyiceberg uses random metadata filenames, so guessing is
-- unreliable; an explicit metadata path is the robust read.
--
-- This file is a TEMPLATE. DuckDB's CREATE SECRET / iceberg_scan take string
-- LITERALS, not expressions, so the ${...} tokens are substituted by run.sh
-- (envsubst) before the SQL reaches DuckDB. Tokens consumed:
--   ${S3_ENDPOINT_HOSTPORT} ${S3_ACCESS_KEY} ${S3_SECRET_KEY} ${S3_USE_SSL}
--   ${METADATA_LOCATION} ${SNAPSHOT_FIRST}

-- 1. Extensions. httpfs gives S3; iceberg gives the Iceberg reader.
INSTALL httpfs;
INSTALL iceberg;
LOAD httpfs;
LOAD iceberg;

-- 2. S3 credentials for MinIO. URL_STYLE 'path' is required for MinIO/Garage-style
--    endpoints (AWS defaults to vhost). ENDPOINT is host:port WITHOUT a scheme.
CREATE OR REPLACE SECRET minio (
    TYPE      s3,
    KEY_ID    '${S3_ACCESS_KEY}',
    SECRET    '${S3_SECRET_KEY}',
    ENDPOINT  '${S3_ENDPOINT_HOSTPORT}',
    URL_STYLE 'path',
    USE_SSL   ${S3_USE_SSL}
);

-- 3. Snapshot history straight from the Iceberg metadata. THIS is the headline
--    contrast with DuckLake: with Iceberg the history is read by walking metadata
--    JSON + manifest files on object storage, not by SELECTing a SQL catalog table.
SELECT '== snapshots (read from Iceberg metadata on S3) ==' AS step;
SELECT sequence_number, snapshot_id, timestamp_ms
FROM iceberg_snapshots('${METADATA_LOCATION}')
ORDER BY sequence_number;

-- 4. Iceberg metadata / manifest view — the file-level map of the table.
SELECT '== iceberg_metadata (manifest entries) ==' AS step;
SELECT status, content, file_path, record_count
FROM iceberg_metadata('${METADATA_LOCATION}')
ORDER BY file_path
LIMIT 10;

-- 5. Full scan of the latest snapshot. Should see all rows across both appends.
SELECT '== current state (latest snapshot) ==' AS step;
SELECT city, count(*) AS trips, round(sum(fare), 2) AS revenue
FROM iceberg_scan('${METADATA_LOCATION}')
GROUP BY city ORDER BY revenue DESC;

-- 6. Row count of the whole table (the scan-throughput query run hot by run.sh).
SELECT '== total rows ==' AS step;
SELECT count(*) AS total_rows FROM iceberg_scan('${METADATA_LOCATION}');

-- 7. TIME TRAVEL — read an EARLIER snapshot by id (the first append only). With two
--    appends, the first snapshot holds half the rows; the second append is invisible
--    from here. snapshot_from_id pins the read to that older metadata state.
SELECT '== time travel: AT snapshot_from_id (first append only) ==' AS step;
SELECT count(*) AS rows_at_first_snapshot
FROM iceberg_scan('${METADATA_LOCATION}', snapshot_from_id = ${SNAPSHOT_FIRST});
