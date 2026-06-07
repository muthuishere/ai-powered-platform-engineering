-- bench.sql — DuckDB as a query runner over pure Parquet on MinIO (S3).
--
-- DuckDB is the *engine*; it holds no state. The dataset is a single Parquet
-- file on an S3-compatible bucket (MinIO). Kill this pod, start another, point it
-- at the same bucket, and it reads the same data. No DuckLake, no Iceberg, no
-- catalog DB — just Parquet files you own and a disposable engine over them.
--
-- This file is a TEMPLATE. DuckDB's CREATE SECRET takes string LITERALS, not
-- expressions, so we don't read env vars inside SQL. The @TOKEN@ markers below are
-- substituted (by run.sh locally, or by the Job's init container in-cluster) before
-- the SQL reaches DuckDB. Tokens consumed:
--   @S3_ENDPOINT@ @S3_KEY_ID@ @S3_SECRET@ @S3_USE_SSL@ @S3_BUCKET@ @ROW_COUNT@
--
-- .timer on makes the CLI print "Run Time (s): real <seconds> ..." after every
-- statement. run.sh scrapes those lines, paired with the BENCH_TAG markers below,
-- to fill results.json. We never hardcode a number; every metric comes from a
-- printed Run Time or an object-store size query.

.timer on

-- 1. Extensions. httpfs gives us s3://; parquet is built in but we LOAD it to be
--    explicit and self-documenting.
INSTALL httpfs;
INSTALL parquet;
LOAD httpfs;
LOAD parquet;

-- 2. S3 credentials for MinIO. URL_STYLE 'path' is REQUIRED for MinIO/Garage-style
--    endpoints (AWS defaults to vhost-style); USE_SSL is false for the in-cluster
--    plaintext demo endpoint. Set USE_SSL true behind TLS.
CREATE OR REPLACE SECRET minio (
    TYPE      s3,
    KEY_ID    '@S3_KEY_ID@',
    SECRET    '@S3_SECRET@',
    ENDPOINT  '@S3_ENDPOINT@',
    URL_STYLE 'path',
    USE_SSL   @S3_USE_SSL@
);

-- 3. INGEST. Generate a synthetic dataset with range() and write it straight to
--    Parquet on S3 in one COPY. range(N) yields a single bigint column `range`;
--    we derive a few typed columns off it so the file isn't a single-column toy:
--      id     monotonically increasing bigint
--      city   low-cardinality string  (compresses very well -> dictionary)
--      amount double                   (poor compression -> realistic mix)
--      ts     timestamp spread across a day
--    ZSTD + a sane row-group size is the normal analytics default.
SELECT '@@BENCH_TAG ingest@@' AS step;
COPY (
    SELECT
        range                                              AS id,
        ['chennai','bengaluru','mumbai','delhi','pune'][
            (range % 5) + 1]                               AS city,
        (range * 2654435761 % 100000) / 100.0             AS amount,
        TIMESTAMP '2026-06-01 00:00:00'
            + INTERVAL (range % 86400) SECOND             AS ts
    FROM range(@ROW_COUNT@)
)
TO 's3://@S3_BUCKET@/data.parquet'
    (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 1000000);

-- 4. ON-DISK SIZE. Pure Parquet size on the object store, read back from the file
--    footer metadata. parquet_file_metadata exposes the total compressed/uncompressed
--    byte sizes — no MinIO admin call needed. run.sh scrapes the printed values.
SELECT '@@BENCH_TAG filesize@@' AS step;
SELECT
    sum(total_compressed_size)   AS parquet_compressed_bytes,
    sum(total_uncompressed_size) AS parquet_uncompressed_bytes
FROM parquet_metadata('s3://@S3_BUCKET@/data.parquet');

-- 5. SCAN THROUGHPUT. A full-table count forces DuckDB to read every row group.
--    rows / Run Time = scan rows/s. Tagged so run.sh can pair count <-> time.
SELECT '@@BENCH_TAG scan@@' AS step;
SELECT count(*) AS rows_scanned
FROM read_parquet('s3://@S3_BUCKET@/data.parquet');

-- 6. QUERY LATENCY. A realistic group-by aggregation, run several times so run.sh
--    can compute p50/p95 from the repeated Run Time samples. Each repetition is
--    tagged identically; the scraper collects every "query" Run Time after this
--    marker. (DuckDB does not cache result sets between statements, and httpfs
--    range-reads the same object, so each run is a fresh scan+aggregate.)
SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

SELECT '@@BENCH_TAG query@@' AS step;
SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
FROM read_parquet('s3://@S3_BUCKET@/data.parquet')
GROUP BY city ORDER BY n DESC;

-- 7. Echo the row count we generated so run.sh can compute scan rows/s without
--    re-deriving it. (count(*) above also prints it, but this is the contract value.)
SELECT '@@BENCH_TAG rowcount@@' AS step;
SELECT @ROW_COUNT@ AS generated_rows;

SELECT '@@BENCH_TAG done@@' AS step;
