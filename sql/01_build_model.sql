-- =============================================================================
--  01_build_model.sql   |   TWO REAL SENSOR FEEDS  ->  ANALYTICAL MODEL
-- =============================================================================
--  TELEMETRY FEED   Azure Predictive Maintenance -- 876,100 hourly readings from
--                   100 machines over a full year (2015), with the real
--                   maintenance record: 761 failures, 3,919 error events and
--                   3,286 component replacements.
--                   Parameters: voltage, rotation, pressure, vibration.
--
--  PROCESS FEED     AI4I 2020 (UCI) -- 10,000 process runs with air and process
--                   TEMPERATURE, rotational speed, torque and tool wear, plus
--                   five labelled failure modes (TWF/HDF/PWF/OSF/RNF).
--
--  Together the two feeds cover all four monitored parameter families:
--    temperature (AI4I) · load/current proxy (AI4I torque) ·
--    vibration (Azure) · runtime/wear (Azure age + AI4I tool wear)
--
--  They are NOT joined -- different machines, different plants. They are two
--  marts answering the same question from different instrumentation.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Raw landing
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW raw_telemetry AS SELECT * FROM read_csv_auto('data/raw/PdM_telemetry.csv', header=true);
CREATE OR REPLACE VIEW raw_errors    AS SELECT * FROM read_csv_auto('data/raw/PdM_errors.csv',    header=true);
CREATE OR REPLACE VIEW raw_failures  AS SELECT * FROM read_csv_auto('data/raw/PdM_failures.csv',  header=true);
CREATE OR REPLACE VIEW raw_maint     AS SELECT * FROM read_csv_auto('data/raw/PdM_maint.csv',     header=true);
CREATE OR REPLACE VIEW raw_machines  AS SELECT * FROM read_csv_auto('data/raw/PdM_machines.csv',  header=true);
CREATE OR REPLACE VIEW raw_ai4i      AS SELECT * FROM read_csv_auto('data/raw/ai4i2020.csv',      header=true);

-- -----------------------------------------------------------------------------
-- 1. DIM_MACHINE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_machine AS
SELECT machineID          AS machine_id,
       model              AS machine_model,
       age                AS age_years,
       CASE WHEN age >= 15 THEN 'Old (15y+)'
            WHEN age >=  8 THEN 'Mid-life (8-15y)'
            ELSE 'New (<8y)' END AS age_band
FROM raw_machines;

-- -----------------------------------------------------------------------------
-- 2. FCT_TELEMETRY  -- hourly readings, one row per machine-hour
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_telemetry AS
SELECT CAST(datetime AS TIMESTAMP)          AS reading_ts,
       CAST(datetime AS DATE)               AS reading_date,
       machineID                            AS machine_id,
       volt                                 AS voltage,
       rotate                               AS rotation_rpm,
       pressure                             AS pressure,
       vibration                            AS vibration,
       EXTRACT(hour  FROM CAST(datetime AS TIMESTAMP)) AS hour_of_day,
       strftime(CAST(datetime AS DATE), '%Y-%m')       AS year_month
FROM raw_telemetry;

-- -----------------------------------------------------------------------------
-- 3. EVENT FACTS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_failure AS
SELECT CAST(datetime AS TIMESTAMP) AS failure_ts,
       CAST(datetime AS DATE)      AS failure_date,
       machineID                   AS machine_id,
       failure                     AS component,
       strftime(CAST(datetime AS DATE), '%Y-%m') AS year_month
FROM raw_failures;

CREATE OR REPLACE TABLE fct_error AS
SELECT CAST(datetime AS TIMESTAMP) AS error_ts,
       CAST(datetime AS DATE)      AS error_date,
       machineID                   AS machine_id,
       errorID                     AS error_code,
       strftime(CAST(datetime AS DATE), '%Y-%m') AS year_month
FROM raw_errors;

-- A maintenance record is a component replacement. It is either PLANNED
-- (preventive) or UNPLANNED (a repair following a failure). The source does not
-- label which, so it is derived: a replacement within 6 hours of a failure of
-- the same component on the same machine is an unplanned repair.
-- That single classification is what makes planned-vs-reactive ratio -- the
-- headline maintenance KPI -- computable at all.
CREATE OR REPLACE TABLE fct_maintenance AS
SELECT m.maint_ts, m.maint_date, m.machine_id, m.component,
       CASE WHEN f.machine_id IS NOT NULL THEN 'Unplanned (post-failure)'
            ELSE 'Planned (preventive)' END AS maintenance_type,
       strftime(m.maint_date, '%Y-%m') AS year_month
FROM (
    SELECT CAST(datetime AS TIMESTAMP) AS maint_ts,
           CAST(datetime AS DATE)      AS maint_date,
           machineID                   AS machine_id,
           comp                        AS component
    FROM raw_maint
) m
LEFT JOIN fct_failure f
       ON f.machine_id = m.machine_id
      AND f.component  = m.component
      AND m.maint_ts BETWEEN f.failure_ts - INTERVAL 6 HOUR
                         AND f.failure_ts + INTERVAL 6 HOUR;

-- -----------------------------------------------------------------------------
-- 4. FCT_MACHINE_DAILY -- daily rollup (100 machines x 365 days = 36,500 rows)
--    This is the grain Power BI and Excel consume: 876k hourly rows would make
--    the model slow for no analytical gain, and every KPI in this project is
--    daily or coarser.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_machine_daily AS
WITH tel AS (
    SELECT machine_id, reading_date, year_month,
           COUNT(*)                          AS readings,
           ROUND(AVG(voltage),3)             AS avg_voltage,
           ROUND(MAX(voltage),3)             AS max_voltage,
           ROUND(STDDEV_SAMP(voltage),3)     AS sd_voltage,
           ROUND(AVG(rotation_rpm),3)        AS avg_rotation,
           ROUND(MIN(rotation_rpm),3)        AS min_rotation,
           ROUND(STDDEV_SAMP(rotation_rpm),3)AS sd_rotation,
           ROUND(AVG(pressure),3)            AS avg_pressure,
           ROUND(MAX(pressure),3)            AS max_pressure,
           ROUND(STDDEV_SAMP(pressure),3)    AS sd_pressure,
           ROUND(AVG(vibration),3)           AS avg_vibration,
           ROUND(MAX(vibration),3)           AS max_vibration,
           ROUND(STDDEV_SAMP(vibration),3)   AS sd_vibration
    FROM fct_telemetry GROUP BY 1,2,3
),
err AS (SELECT machine_id, error_date AS d, COUNT(*) AS error_count FROM fct_error GROUP BY 1,2),
fal AS (SELECT machine_id, failure_date AS d, COUNT(*) AS failure_count FROM fct_failure GROUP BY 1,2),
mnt AS (SELECT machine_id, maint_date AS d,
               COUNT(*) AS maint_count,
               SUM(CASE WHEN maintenance_type LIKE 'Unplanned%' THEN 1 ELSE 0 END) AS unplanned_maint
        FROM fct_maintenance GROUP BY 1,2)
SELECT t.*, dm.machine_model, dm.age_years, dm.age_band,
       COALESCE(e.error_count,0)     AS error_count,
       COALESCE(f.failure_count,0)   AS failure_count,
       COALESCE(m.maint_count,0)     AS maint_count,
       COALESCE(m.unplanned_maint,0) AS unplanned_maint_count
FROM tel t
JOIN dim_machine dm ON dm.machine_id = t.machine_id
LEFT JOIN err e ON e.machine_id = t.machine_id AND e.d = t.reading_date
LEFT JOIN fal f ON f.machine_id = t.machine_id AND f.d = t.reading_date
LEFT JOIN mnt m ON m.machine_id = t.machine_id AND m.d = t.reading_date;

-- -----------------------------------------------------------------------------
-- 5. FCT_PROCESS_RUN -- the AI4I process feed (temperature + torque + tool wear)
--    Temperatures are converted Kelvin -> Celsius; nobody reads a shop-floor
--    dashboard in Kelvin.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_process_run AS
SELECT
    UDI                                                      AS run_id,
    "Product ID"                                             AS product_id,
    Type                                                     AS quality_variant,
    ROUND("Air temperature [K]"     - 273.15, 2)             AS air_temp_c,
    ROUND("Process temperature [K]" - 273.15, 2)             AS process_temp_c,
    ROUND("Process temperature [K]" - "Air temperature [K]", 2) AS temp_delta_k,
    "Rotational speed [rpm]"                                 AS rotational_speed_rpm,
    "Torque [Nm]"                                            AS torque_nm,
    "Tool wear [min]"                                        AS tool_wear_min,
    -- Mechanical power = torque x angular velocity. The strongest single
    -- predictor of power failure (PWF) in this dataset, and it is not a column
    -- in the source -- it has to be derived.
    ROUND("Torque [Nm]" * "Rotational speed [rpm]" * 2 * PI() / 60.0, 1) AS power_w,
    "Machine failure"                                        AS is_failure,
    TWF AS twf_tool_wear, HDF AS hdf_heat_dissipation, PWF AS pwf_power,
    OSF AS osf_overstrain, RNF AS rnf_random,
    CASE WHEN TWF=1 THEN 'Tool Wear Failure'
         WHEN HDF=1 THEN 'Heat Dissipation Failure'
         WHEN PWF=1 THEN 'Power Failure'
         WHEN OSF=1 THEN 'Overstrain Failure'
         WHEN RNF=1 THEN 'Random Failure'
         WHEN "Machine failure"=1 THEN 'Unclassified Failure'
         ELSE 'No Failure' END                               AS failure_mode
FROM raw_ai4i;

-- -----------------------------------------------------------------------------
-- Build receipt
-- -----------------------------------------------------------------------------
SELECT 'dim_machine' AS table_name, COUNT(*) AS row_count FROM dim_machine
UNION ALL SELECT 'fct_telemetry',     COUNT(*) FROM fct_telemetry
UNION ALL SELECT 'fct_machine_daily', COUNT(*) FROM fct_machine_daily
UNION ALL SELECT 'fct_error',         COUNT(*) FROM fct_error
UNION ALL SELECT 'fct_failure',       COUNT(*) FROM fct_failure
UNION ALL SELECT 'fct_maintenance',   COUNT(*) FROM fct_maintenance
UNION ALL SELECT 'fct_process_run',   COUNT(*) FROM fct_process_run
ORDER BY 1;
