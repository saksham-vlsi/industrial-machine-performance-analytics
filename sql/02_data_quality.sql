-- =============================================================================
--  02_data_quality.sql   |   DATA QUALITY GATE  (both sensor feeds)
-- =============================================================================
--  Sensor data fails quietly. A stuck transmitter reports a perfectly plausible
--  constant; a dropped hour leaves no trace. These rules look for exactly that
--  before any reliability number is published.
-- =============================================================================

CREATE OR REPLACE TABLE dq_report AS
WITH checks AS (

    -- ---- Coverage / completeness --------------------------------------------
    SELECT 'CMP-01' AS rule_id,'INFO' AS severity,'Telemetry readings ingested' AS rule_name,
           COUNT(*) AS row_count FROM fct_telemetry
    UNION ALL SELECT 'CMP-02','INFO','Machines instrumented',COUNT(*) FROM dim_machine
    UNION ALL SELECT 'CMP-03','INFO','Failure events',COUNT(*) FROM fct_failure
    UNION ALL SELECT 'CMP-04','INFO','Error events',COUNT(*) FROM fct_error
    UNION ALL SELECT 'CMP-05','INFO','Maintenance events',COUNT(*) FROM fct_maintenance
    UNION ALL SELECT 'CMP-06','INFO','Process runs (AI4I feed)',COUNT(*) FROM fct_process_run

    -- Expected 100 machines x 8,761 hourly readings. A shortfall is a dropout.
    UNION ALL SELECT 'CMP-07','BLOCK','Machines with an incomplete hourly series',
           COUNT(*) FROM (
             SELECT machine_id FROM fct_telemetry GROUP BY 1
             HAVING COUNT(*) <> (SELECT MAX(c) FROM (SELECT COUNT(*) c FROM fct_telemetry GROUP BY machine_id)))

    UNION ALL SELECT 'CMP-08','BLOCK','Duplicate machine-hour readings',
           COUNT(*) FROM (SELECT machine_id, reading_ts FROM fct_telemetry
                          GROUP BY 1,2 HAVING COUNT(*) > 1)

    -- ---- Referential integrity ------------------------------------------------
    UNION ALL SELECT 'REF-01','BLOCK','Telemetry for an unknown machine',COUNT(*)
           FROM fct_telemetry t LEFT JOIN dim_machine m USING(machine_id) WHERE m.machine_id IS NULL
    UNION ALL SELECT 'REF-02','BLOCK','Failure logged against an unknown machine',COUNT(*)
           FROM fct_failure f LEFT JOIN dim_machine m USING(machine_id) WHERE m.machine_id IS NULL
    UNION ALL SELECT 'REF-03','WARN','Machines with zero failures in the window',COUNT(*)
           FROM dim_machine m LEFT JOIN (SELECT DISTINCT machine_id FROM fct_failure) f
             USING(machine_id) WHERE f.machine_id IS NULL

    -- ---- Sensor plausibility ---------------------------------------------------
    UNION ALL SELECT 'SEN-01','BLOCK','Null sensor value on the critical path',COUNT(*)
           FROM fct_telemetry WHERE voltage IS NULL OR rotation_rpm IS NULL
                                 OR pressure IS NULL OR vibration IS NULL
    UNION ALL SELECT 'SEN-02','BLOCK','Non-positive sensor reading (physically impossible)',COUNT(*)
           FROM fct_telemetry WHERE voltage <= 0 OR rotation_rpm <= 0
                                 OR pressure <= 0 OR vibration <= 0

    -- A stuck transmitter: zero variance across a whole day is not real data.
    UNION ALL SELECT 'SEN-03','WARN','Machine-days with zero sensor variance (stuck transmitter)',COUNT(*)
           FROM fct_machine_daily
           WHERE sd_voltage = 0 OR sd_rotation = 0 OR sd_pressure = 0 OR sd_vibration = 0

    UNION ALL SELECT 'SEN-04','WARN','Readings beyond 5 sigma from the fleet mean',COUNT(*)
           FROM fct_telemetry t CROSS JOIN
                (SELECT AVG(vibration) mu, STDDEV_SAMP(vibration) sd FROM fct_telemetry) s
           WHERE ABS(t.vibration - s.mu) > 5 * s.sd

    -- ---- Event logic -----------------------------------------------------------
    UNION ALL SELECT 'EVT-01','WARN','Failures with no component replacement within 6h',COUNT(*)
           FROM fct_failure f LEFT JOIN fct_maintenance m
             ON m.machine_id = f.machine_id AND m.component = f.component
            AND m.maint_ts BETWEEN f.failure_ts - INTERVAL 6 HOUR AND f.failure_ts + INTERVAL 6 HOUR
           WHERE m.machine_id IS NULL
    UNION ALL SELECT 'EVT-02','WARN','Failure timestamps outside the telemetry window',COUNT(*)
           FROM fct_failure WHERE failure_ts < (SELECT MIN(reading_ts) FROM fct_telemetry)
                               OR failure_ts > (SELECT MAX(reading_ts) FROM fct_telemetry)

    -- ---- Process feed ----------------------------------------------------------
    UNION ALL SELECT 'AI4-01','BLOCK','Process temperature below air temperature (sensor swap)',COUNT(*)
           FROM fct_process_run WHERE process_temp_c < air_temp_c
    UNION ALL SELECT 'AI4-02','WARN','Failure flag set with no failure mode labelled',COUNT(*)
           FROM fct_process_run WHERE is_failure = 1 AND failure_mode = 'Unclassified Failure'
    UNION ALL SELECT 'AI4-03','WARN','Run flagged with a mode but no machine-failure flag',COUNT(*)
           FROM fct_process_run WHERE is_failure = 0
             AND (twf_tool_wear + hdf_heat_dissipation + pwf_power + osf_overstrain + rnf_random) > 0
    UNION ALL SELECT 'AI4-04','BLOCK','Non-positive torque or speed',COUNT(*)
           FROM fct_process_run WHERE torque_nm <= 0 OR rotational_speed_rpm <= 0
)
SELECT rule_id, severity, rule_name, row_count,
       CASE WHEN severity='INFO' THEN 'INFO' WHEN row_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks
ORDER BY CASE severity WHEN 'BLOCK' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, row_count DESC;

COPY dq_report TO 'outputs/data_quality_report.csv' (HEADER, DELIMITER ',');
SELECT * FROM dq_report;
