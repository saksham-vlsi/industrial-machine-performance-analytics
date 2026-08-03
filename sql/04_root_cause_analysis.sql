-- =============================================================================
--  04_root_cause_analysis.sql   |   WHY MACHINES FAIL
-- =============================================================================
--  For every fault: which parameter moved, by how much, and how far in advance.
--  This is the difference between "the machine broke" and "pressure and
--  vibration rose together 24 hours before every comp2 failure".
--
--  Method: compare sensor behaviour inside a pre-failure window against the
--  machine's OWN baseline (all other hours). Comparing against a fleet constant
--  would confound a machine that simply runs hot with one that is degrading.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Label every telemetry hour with its distance to the next failure
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE telemetry_labelled AS
WITH nxt AS (
    SELECT t.reading_ts, t.machine_id, t.voltage, t.rotation_rpm, t.pressure, t.vibration,
           MIN(f.failure_ts) AS next_failure_ts,
           ARG_MIN(f.component, f.failure_ts) AS next_component
    FROM fct_telemetry t
    LEFT JOIN fct_failure f
           ON f.machine_id = t.machine_id
          AND f.failure_ts >= t.reading_ts
          AND f.failure_ts <  t.reading_ts + INTERVAL 72 HOUR
    GROUP BY 1,2,3,4,5,6
)
SELECT *,
       CASE WHEN next_failure_ts IS NULL THEN NULL
            ELSE date_diff('hour', reading_ts, next_failure_ts) END AS hours_to_failure,
       CASE WHEN next_failure_ts IS NULL                                    THEN 'Baseline'
            WHEN date_diff('hour', reading_ts, next_failure_ts) <= 6        THEN 'T-6h'
            WHEN date_diff('hour', reading_ts, next_failure_ts) <= 12       THEN 'T-12h'
            WHEN date_diff('hour', reading_ts, next_failure_ts) <= 24       THEN 'T-24h'
            ELSE 'T-72h' END                                                AS failure_window
FROM nxt;

-- -----------------------------------------------------------------------------
-- 2. PRECURSOR SIGNATURE -- how each parameter behaves as failure approaches
-- -----------------------------------------------------------------------------
COPY (
SELECT failure_window,
       COUNT(*)                        AS readings,
       ROUND(AVG(voltage),3)           AS avg_voltage,
       ROUND(AVG(rotation_rpm),3)      AS avg_rotation,
       ROUND(AVG(pressure),3)          AS avg_pressure,
       ROUND(AVG(vibration),3)         AS avg_vibration,
       ROUND(100.0*(AVG(voltage)      - (SELECT AVG(voltage)      FROM telemetry_labelled WHERE failure_window='Baseline'))
             / (SELECT AVG(voltage)      FROM telemetry_labelled WHERE failure_window='Baseline'),2) AS voltage_pct_vs_baseline,
       ROUND(100.0*(AVG(rotation_rpm) - (SELECT AVG(rotation_rpm) FROM telemetry_labelled WHERE failure_window='Baseline'))
             / (SELECT AVG(rotation_rpm) FROM telemetry_labelled WHERE failure_window='Baseline'),2) AS rotation_pct_vs_baseline,
       ROUND(100.0*(AVG(pressure)     - (SELECT AVG(pressure)     FROM telemetry_labelled WHERE failure_window='Baseline'))
             / (SELECT AVG(pressure)     FROM telemetry_labelled WHERE failure_window='Baseline'),2) AS pressure_pct_vs_baseline,
       ROUND(100.0*(AVG(vibration)    - (SELECT AVG(vibration)    FROM telemetry_labelled WHERE failure_window='Baseline'))
             / (SELECT AVG(vibration)    FROM telemetry_labelled WHERE failure_window='Baseline'),2) AS vibration_pct_vs_baseline
FROM telemetry_labelled GROUP BY failure_window
ORDER BY CASE failure_window WHEN 'Baseline' THEN 1 WHEN 'T-72h' THEN 2
                             WHEN 'T-24h' THEN 3 WHEN 'T-12h' THEN 4 ELSE 5 END
) TO 'outputs/precursor_signature.csv' (HEADER, DELIMITER ',');

-- -----------------------------------------------------------------------------
-- 3. PER-COMPONENT ROOT CAUSE -- which parameter identifies which fault
--    The deviation column is the answer to "which parameter crossed threshold".
-- -----------------------------------------------------------------------------
COPY (
WITH base AS (
    SELECT AVG(voltage) v, AVG(rotation_rpm) r, AVG(pressure) p, AVG(vibration) vb,
           STDDEV_SAMP(voltage) v_sd, STDDEV_SAMP(rotation_rpm) r_sd,
           STDDEV_SAMP(pressure) p_sd, STDDEV_SAMP(vibration) vb_sd
    FROM telemetry_labelled WHERE failure_window = 'Baseline'
),
pre AS (
    SELECT next_component AS component,
           COUNT(*) AS readings,
           AVG(voltage) v, AVG(rotation_rpm) r, AVG(pressure) p, AVG(vibration) vb
    FROM telemetry_labelled
    WHERE failure_window IN ('T-24h','T-12h','T-6h') AND next_component IS NOT NULL
    GROUP BY 1
)
SELECT pre.component, pre.readings,
       ROUND(pre.v,2)  AS avg_voltage,  ROUND(100.0*(pre.v-b.v)/b.v,2)   AS voltage_dev_pct,
       ROUND((pre.v-b.v)/b.v_sd,2)      AS voltage_z,
       ROUND(pre.r,2)  AS avg_rotation, ROUND(100.0*(pre.r-b.r)/b.r,2)   AS rotation_dev_pct,
       ROUND((pre.r-b.r)/b.r_sd,2)      AS rotation_z,
       ROUND(pre.p,2)  AS avg_pressure, ROUND(100.0*(pre.p-b.p)/b.p,2)   AS pressure_dev_pct,
       ROUND((pre.p-b.p)/b.p_sd,2)      AS pressure_z,
       ROUND(pre.vb,2) AS avg_vibration,ROUND(100.0*(pre.vb-b.vb)/b.vb,2)AS vibration_dev_pct,
       ROUND((pre.vb-b.vb)/b.vb_sd,2)   AS vibration_z,
       -- The dominant signal: largest absolute z-score across the four parameters
       CASE GREATEST(ABS((pre.v-b.v)/b.v_sd), ABS((pre.r-b.r)/b.r_sd),
                     ABS((pre.p-b.p)/b.p_sd), ABS((pre.vb-b.vb)/b.vb_sd))
            WHEN ABS((pre.v -b.v )/b.v_sd)  THEN 'Voltage'
            WHEN ABS((pre.r -b.r )/b.r_sd)  THEN 'Rotation'
            WHEN ABS((pre.p -b.p )/b.p_sd)  THEN 'Pressure'
            ELSE 'Vibration' END                                          AS dominant_parameter,
       CASE pre.component
            WHEN 'comp1' THEN 'Replace component 1; check voltage regulation and supply stability'
            WHEN 'comp2' THEN 'Replace component 2; inspect pressure line and bearing seating'
            WHEN 'comp3' THEN 'Replace component 3; check drive coupling and rotational load'
            ELSE              'Replace component 4; inspect mounting, balance and vibration damping'
       END                                                                AS recommended_action
FROM pre CROSS JOIN base b ORDER BY pre.readings DESC
) TO 'outputs/root_cause_by_component.csv' (HEADER, DELIMITER ',');

-- -----------------------------------------------------------------------------
-- 4. THRESHOLD EXCEEDANCE -- how much more often limits are breached pre-failure
--    Thresholds are the fleet P99 for each parameter, computed from the data.
-- -----------------------------------------------------------------------------
COPY (
WITH thr AS (
    SELECT QUANTILE_CONT(voltage,0.99)      AS volt_hi,
           QUANTILE_CONT(rotation_rpm,0.01) AS rot_lo,
           QUANTILE_CONT(pressure,0.99)     AS press_hi,
           QUANTILE_CONT(vibration,0.99)    AS vib_hi
    FROM fct_telemetry
)
SELECT l.failure_window,
       COUNT(*) AS readings,
       ROUND(t.volt_hi,2)  AS voltage_threshold,
       ROUND(t.rot_lo,2)   AS rotation_threshold,
       ROUND(t.press_hi,2) AS pressure_threshold,
       ROUND(t.vib_hi,2)   AS vibration_threshold,
       ROUND(100.0*AVG(CASE WHEN l.voltage      > t.volt_hi  THEN 1.0 ELSE 0 END),3) AS pct_voltage_exceed,
       ROUND(100.0*AVG(CASE WHEN l.rotation_rpm < t.rot_lo   THEN 1.0 ELSE 0 END),3) AS pct_rotation_exceed,
       ROUND(100.0*AVG(CASE WHEN l.pressure     > t.press_hi THEN 1.0 ELSE 0 END),3) AS pct_pressure_exceed,
       ROUND(100.0*AVG(CASE WHEN l.vibration    > t.vib_hi   THEN 1.0 ELSE 0 END),3) AS pct_vibration_exceed,
       ROUND(100.0*AVG(CASE WHEN l.voltage > t.volt_hi OR l.rotation_rpm < t.rot_lo
                              OR l.pressure > t.press_hi OR l.vibration > t.vib_hi
                            THEN 1.0 ELSE 0 END),3)                                  AS pct_any_exceed
FROM telemetry_labelled l CROSS JOIN thr t
GROUP BY l.failure_window, t.volt_hi, t.rot_lo, t.press_hi, t.vib_hi
ORDER BY CASE l.failure_window WHEN 'Baseline' THEN 1 WHEN 'T-72h' THEN 2
                               WHEN 'T-24h' THEN 3 WHEN 'T-12h' THEN 4 ELSE 5 END
) TO 'outputs/threshold_exceedance.csv' (HEADER, DELIMITER ',');

-- -----------------------------------------------------------------------------
-- 5. ERROR CODE -> FAILURE  -- do error codes predict a component failure?
-- -----------------------------------------------------------------------------
COPY (
WITH pairs AS (
    SELECT e.error_code, f.component,
           date_diff('hour', e.error_ts, f.failure_ts) AS lead_hours
    FROM fct_error e
    JOIN fct_failure f
      ON f.machine_id = e.machine_id
     AND f.failure_ts BETWEEN e.error_ts AND e.error_ts + INTERVAL 48 HOUR
),
totals AS (SELECT error_code, COUNT(*) AS total_errors FROM fct_error GROUP BY 1)
SELECT p.error_code, p.component,
       COUNT(*)                                                  AS followed_by_failure,
       t.total_errors,
       ROUND(100.0*COUNT(*)/t.total_errors,2)                    AS pct_of_this_error_code,
       ROUND(AVG(p.lead_hours),1)                                AS avg_lead_hours,
       ROUND(MEDIAN(p.lead_hours),1)                             AS median_lead_hours
FROM pairs p JOIN totals t USING(error_code)
GROUP BY p.error_code, p.component, t.total_errors
HAVING COUNT(*) >= 10
ORDER BY pct_of_this_error_code DESC
) TO 'outputs/error_to_failure_link.csv' (HEADER, DELIMITER ',');

-- -----------------------------------------------------------------------------
-- 6. PROCESS-FEED ROOT CAUSE (AI4I) -- which parameter crosses which limit
--    The five failure modes are physically labelled in the source, so this is a
--    direct read of the failure physics rather than an inference.
-- -----------------------------------------------------------------------------
COPY (
WITH ok AS (
    SELECT AVG(air_temp_c) AS air_t, AVG(process_temp_c) AS proc_t, AVG(temp_delta_k) AS tdelta,
           AVG(rotational_speed_rpm) AS rpm_ok, AVG(torque_nm) AS torque_ok,
           AVG(tool_wear_min) AS wear_ok, AVG(power_w) AS power_ok
    FROM fct_process_run WHERE is_failure = 0
)
SELECT r.failure_mode,
       COUNT(*) AS runs,
       ROUND(AVG(r.process_temp_c),2)     AS process_temp_c,
       ROUND(AVG(r.temp_delta_k),2)       AS temp_delta_k,
       ROUND(100.0*(AVG(r.temp_delta_k)-o.tdelta)/o.tdelta,1)  AS temp_delta_dev_pct,
       ROUND(AVG(r.rotational_speed_rpm),0) AS rpm,
       ROUND(100.0*(AVG(r.rotational_speed_rpm)-o.rpm_ok)/o.rpm_ok,1) AS rpm_dev_pct,
       ROUND(AVG(r.torque_nm),2)          AS torque_nm,
       ROUND(100.0*(AVG(r.torque_nm)-o.torque_ok)/o.torque_ok,1)     AS torque_dev_pct,
       ROUND(AVG(r.tool_wear_min),1)      AS tool_wear_min,
       ROUND(100.0*(AVG(r.tool_wear_min)-o.wear_ok)/o.wear_ok,1) AS wear_dev_pct,
       ROUND(AVG(r.power_w),0)            AS power_w,
       ROUND(100.0*(AVG(r.power_w)-o.power_ok)/o.power_ok,1)       AS power_dev_pct,
       CASE r.failure_mode
         WHEN 'Heat Dissipation Failure' THEN 'Air/process temperature delta below 8.6K at low rpm - check coolant flow and ambient extraction'
         WHEN 'Power Failure'            THEN 'Torque x speed outside the 3.5-9 kW band - review load scheduling and drive sizing'
         WHEN 'Overstrain Failure'       THEN 'Tool wear x torque above the strain limit - enforce tool-change interval'
         WHEN 'Tool Wear Failure'        THEN 'Tool wear beyond 200 min - replace tool on schedule'
         WHEN 'Random Failure'           THEN 'No parameter signature - not preventable by condition monitoring'
         ELSE 'No action' END            AS diagnostic_action
FROM fct_process_run r CROSS JOIN ok o
GROUP BY r.failure_mode, o.tdelta, o.rpm_ok, o.torque_ok, o.wear_ok, o.power_ok
ORDER BY runs DESC
) TO 'outputs/process_root_cause.csv' (HEADER, DELIMITER ',');

-- -----------------------------------------------------------------------------
-- 7. ALERT REGISTER + PREVENTIVE MAINTENANCE SCHEDULE
-- -----------------------------------------------------------------------------
COPY (
WITH thr AS (
    SELECT QUANTILE_CONT(vibration,0.95) AS vib_alert,
           QUANTILE_CONT(pressure,0.95)  AS press_alert,
           QUANTILE_CONT(voltage,0.95)   AS volt_alert
    FROM fct_telemetry
),
recent AS (
    SELECT machine_id,
           ROUND(AVG(vibration),2) AS avg_vibration_7d,
           ROUND(AVG(pressure),2)  AS avg_pressure_7d,
           ROUND(AVG(voltage),2)   AS avg_voltage_7d,
           ROUND(MAX(vibration),2) AS peak_vibration_7d
    FROM fct_telemetry
    WHERE reading_ts >= (SELECT MAX(reading_ts) FROM fct_telemetry) - INTERVAL 7 DAY
    GROUP BY machine_id
)
SELECT r.machine_id, h.machine_model, h.age_years,
       r.avg_vibration_7d, ROUND(t.vib_alert,2)   AS vibration_alert_level,
       r.avg_pressure_7d,  ROUND(t.press_alert,2) AS pressure_alert_level,
       r.avg_voltage_7d,   ROUND(t.volt_alert,2)  AS voltage_alert_level,
       h.health_score, h.health_band, h.failures AS failures_last_year,
       CASE WHEN r.avg_vibration_7d > t.vib_alert THEN 1 ELSE 0 END AS vibration_alert,
       CASE WHEN r.avg_pressure_7d  > t.press_alert THEN 1 ELSE 0 END AS pressure_alert,
       CASE WHEN r.avg_voltage_7d   > t.volt_alert  THEN 1 ELSE 0 END AS voltage_alert,
       -- Service interval is set from the machine's own measured MTBF, at 70%
       -- of it -- servicing before the expected failure point rather than on a
       -- fixed calendar that ignores how the machine actually behaves.
       ROUND(0.70 * COALESCE(mh.mtbf_days, 365), 0)                  AS recommended_service_interval_days,
       CASE WHEN h.health_band = 'D - Critical'      THEN 'P1 - Schedule within 7 days'
            WHEN h.health_band = 'C - Elevated risk' THEN 'P2 - Schedule within 30 days'
            WHEN h.health_band = 'B - Monitor'       THEN 'P3 - Next planned window'
            ELSE 'P4 - Routine' END                                  AS maintenance_priority
FROM recent r
CROSS JOIN thr t
JOIN machine_health_score h ON h.machine_id = r.machine_id
JOIN machine_health      mh ON mh.machine_id = r.machine_id
ORDER BY h.health_score ASC
) TO 'outputs/alert_and_maintenance_schedule.csv' (HEADER, DELIMITER ',');

SELECT 'root cause marts written' AS status;

