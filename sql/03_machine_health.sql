-- =============================================================================
--  03_machine_health.sql   |   HEALTH, RELIABILITY & MAINTENANCE MARTS
-- =============================================================================
--  DOCUMENTED ASSUMPTION -- MTTR
--    The source records WHEN a machine failed but not when it was restored, so
--    downtime is not directly measurable. A mean time to repair of 4 hours is
--    assumed for unplanned failures and 2 hours for planned replacements.
--    Every column derived from it is prefixed `est_`. MTBF, failure counts and
--    all sensor statistics below are measured, not assumed.
-- =============================================================================

CREATE OR REPLACE TABLE reliability_assumptions AS
SELECT 4.0 AS mttr_unplanned_hours,
       2.0 AS mttr_planned_hours,
       (SELECT COUNT(DISTINCT reading_ts) FROM fct_telemetry) AS observed_hours;

-- =============================================================================
--  MACHINE OVERVIEW  -- one row per machine
-- =============================================================================
CREATE OR REPLACE TABLE machine_health AS
WITH tel AS (
    SELECT machine_id,
           COUNT(*)                       AS readings,
           ROUND(AVG(voltage),2)          AS avg_voltage,
           ROUND(AVG(rotation_rpm),2)     AS avg_rotation,
           ROUND(AVG(pressure),2)         AS avg_pressure,
           ROUND(AVG(vibration),2)        AS avg_vibration,
           ROUND(STDDEV_SAMP(voltage),2)  AS sd_voltage,
           ROUND(STDDEV_SAMP(vibration),2)AS sd_vibration,
           ROUND(MAX(vibration),2)        AS peak_vibration,
           ROUND(MAX(pressure),2)         AS peak_pressure
    FROM fct_telemetry GROUP BY machine_id
),
ev AS (
    SELECT m.machine_id,
           COALESCE(f.failures,0)  AS failures,
           COALESCE(e.errors,0)    AS errors,
           COALESCE(mt.maints,0)   AS maintenance_events,
           COALESCE(mt.unplanned,0)AS unplanned_maintenance
    FROM dim_machine m
    LEFT JOIN (SELECT machine_id, COUNT(*) failures FROM fct_failure GROUP BY 1) f  USING(machine_id)
    LEFT JOIN (SELECT machine_id, COUNT(*) errors   FROM fct_error   GROUP BY 1) e  USING(machine_id)
    LEFT JOIN (SELECT machine_id, COUNT(*) maints,
                      SUM(CASE WHEN maintenance_type LIKE 'Unplanned%' THEN 1 ELSE 0 END) unplanned
               FROM fct_maintenance GROUP BY 1) mt USING(machine_id)
),
base AS (
    SELECT d.machine_id, d.machine_model, d.age_years, d.age_band,
           t.*, ev.failures, ev.errors, ev.maintenance_events, ev.unplanned_maintenance,
           a.observed_hours, a.mttr_unplanned_hours, a.mttr_planned_hours
    FROM dim_machine d
    JOIN tel t USING(machine_id)
    JOIN ev  USING(machine_id)
    CROSS JOIN reliability_assumptions a
)
SELECT
    machine_id, machine_model, age_years, age_band,
    readings AS operating_hours_observed,
    failures, errors, maintenance_events, unplanned_maintenance,

    -- MTBF is measured: observed operating hours / number of failures.
    ROUND(observed_hours / NULLIF(failures,0), 1)                       AS mtbf_hours,
    ROUND(observed_hours / NULLIF(failures,0) / 24.0, 1)                AS mtbf_days,
    ROUND(failures * 8760.0 / NULLIF(observed_hours,0), 2)              AS failures_per_year,

    -- Downtime and uptime are ESTIMATED from the documented MTTR.
    ROUND(failures * mttr_unplanned_hours
          + (maintenance_events - unplanned_maintenance) * mttr_planned_hours, 1) AS est_downtime_hours,
    ROUND(100.0 * (1 - (failures * mttr_unplanned_hours
          + (maintenance_events - unplanned_maintenance) * mttr_planned_hours)
          / NULLIF(observed_hours,0)), 2)                               AS est_uptime_pct,

    avg_voltage, avg_rotation, avg_pressure, avg_vibration,
    sd_voltage, sd_vibration, peak_vibration, peak_pressure,

    ROUND(100.0 * unplanned_maintenance / NULLIF(maintenance_events,0), 1) AS reactive_maintenance_pct,
    ROUND(errors * 1.0 / NULLIF(failures,0), 2)                         AS errors_per_failure
FROM base;

-- -----------------------------------------------------------------------------
--  HEALTH SCORE  -- 0-100, built only from measured quantities.
--  Each component is normalised against the fleet distribution so the score is
--  relative to how this fleet actually behaves, not to arbitrary constants.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE machine_health_score AS
WITH fleet AS (
    SELECT AVG(failures) f_mu, STDDEV_SAMP(failures) f_sd,
           AVG(errors)   e_mu, STDDEV_SAMP(errors)   e_sd,
           AVG(avg_vibration) v_mu, STDDEV_SAMP(avg_vibration) v_sd,
           AVG(sd_vibration)  sv_mu, STDDEV_SAMP(sd_vibration) sv_sd
    FROM machine_health
),
z AS (
    SELECT h.*,
           (h.failures      - f.f_mu)  / NULLIF(f.f_sd,0)  AS z_failures,
           (h.errors        - f.e_mu)  / NULLIF(f.e_sd,0)  AS z_errors,
           (h.avg_vibration - f.v_mu)  / NULLIF(f.v_sd,0)  AS z_vibration,
           (h.sd_vibration  - f.sv_mu) / NULLIF(f.sv_sd,0) AS z_instability
    FROM machine_health h CROSS JOIN fleet f
)
SELECT machine_id, machine_model, age_years, age_band,
       failures, errors, mtbf_days, est_uptime_pct,
       avg_vibration, sd_vibration, peak_vibration, reactive_maintenance_pct,
       ROUND(z_failures,2) AS z_failures, ROUND(z_errors,2) AS z_errors,
       ROUND(z_vibration,2) AS z_vibration, ROUND(z_instability,2) AS z_instability,
       -- Weighted: failures dominate, then error load, then vibration level and
       -- vibration instability. Clamped to 0-100.
       ROUND(GREATEST(0, LEAST(100,
             100 - 12*COALESCE(z_failures,0)
                 -  7*COALESCE(z_errors,0)
                 -  6*COALESCE(z_vibration,0)
                 -  5*COALESCE(z_instability,0))), 1)                 AS health_score,
       CASE WHEN 100 - 12*COALESCE(z_failures,0) - 7*COALESCE(z_errors,0)
                     - 6*COALESCE(z_vibration,0) - 5*COALESCE(z_instability,0) >= 90 THEN 'A - Healthy'
            WHEN 100 - 12*COALESCE(z_failures,0) - 7*COALESCE(z_errors,0)
                     - 6*COALESCE(z_vibration,0) - 5*COALESCE(z_instability,0) >= 75 THEN 'B - Monitor'
            WHEN 100 - 12*COALESCE(z_failures,0) - 7*COALESCE(z_errors,0)
                     - 6*COALESCE(z_vibration,0) - 5*COALESCE(z_instability,0) >= 60 THEN 'C - Elevated risk'
            ELSE 'D - Critical' END                                    AS health_band
FROM z;

COPY (SELECT * FROM machine_health_score ORDER BY health_score ASC)
  TO 'outputs/machine_health_score.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM machine_health ORDER BY failures DESC)
  TO 'outputs/machine_overview.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  FLEET EXECUTIVE KPI
-- =============================================================================
COPY (
SELECT
    (SELECT COUNT(*) FROM dim_machine)                                   AS machines,
    (SELECT COUNT(*) FROM fct_telemetry)                                 AS sensor_readings,
    (SELECT COUNT(*) FROM fct_process_run)                               AS process_runs,
    (SELECT MIN(reading_date) FROM fct_telemetry)                        AS window_start,
    (SELECT MAX(reading_date) FROM fct_telemetry)                        AS window_end,
    (SELECT COUNT(*) FROM fct_failure)                                   AS total_failures,
    (SELECT COUNT(*) FROM fct_error)                                     AS total_errors,
    (SELECT COUNT(*) FROM fct_maintenance)                               AS maintenance_events,
    (SELECT ROUND(100.0*AVG(CASE WHEN maintenance_type LIKE 'Unplanned%' THEN 1.0 ELSE 0 END),2)
       FROM fct_maintenance)                                             AS reactive_maintenance_pct,
    ROUND((SELECT SUM(readings) FROM (SELECT COUNT(*) readings FROM fct_telemetry))
          / NULLIF((SELECT COUNT(*) FROM fct_failure),0), 1)             AS fleet_mtbf_hours,
    ROUND((SELECT SUM(readings) FROM (SELECT COUNT(*) readings FROM fct_telemetry))
          / NULLIF((SELECT COUNT(*) FROM fct_failure),0) / 24.0, 1)      AS fleet_mtbf_days,
    (SELECT ROUND(AVG(est_uptime_pct),2)  FROM machine_health)           AS avg_est_uptime_pct,
    (SELECT ROUND(SUM(est_downtime_hours),0) FROM machine_health)        AS est_downtime_hours,
    (SELECT ROUND(AVG(health_score),1) FROM machine_health_score)        AS avg_health_score,
    (SELECT COUNT(*) FROM machine_health_score WHERE health_band='D - Critical')      AS critical_machines,
    (SELECT COUNT(*) FROM machine_health_score WHERE health_band='C - Elevated risk') AS elevated_risk_machines,
    (SELECT ROUND(AVG(voltage),2)   FROM fct_telemetry)                  AS avg_voltage,
    (SELECT ROUND(AVG(rotation_rpm),2) FROM fct_telemetry)               AS avg_rotation_rpm,
    (SELECT ROUND(AVG(pressure),2)  FROM fct_telemetry)                  AS avg_pressure,
    (SELECT ROUND(AVG(vibration),2) FROM fct_telemetry)                  AS avg_vibration,
    (SELECT ROUND(AVG(process_temp_c),2) FROM fct_process_run)           AS avg_process_temp_c,
    (SELECT ROUND(100.0*AVG(is_failure),2) FROM fct_process_run)         AS process_failure_rate_pct
) TO 'outputs/fleet_kpi_executive.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  FAULT DISTRIBUTION  -- the "top 3 fault drivers" analysis
-- =============================================================================
COPY (
SELECT component,
       COUNT(*)                                                       AS failures,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2)                  AS pct_of_failures,
       ROUND(100.0*SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC)
             / SUM(COUNT(*)) OVER (),2)                               AS cumulative_pct,
       COUNT(DISTINCT machine_id)                                     AS machines_affected,
       ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC)                     AS rank_by_frequency
FROM fct_failure GROUP BY component ORDER BY failures DESC
) TO 'outputs/fault_distribution.csv' (HEADER, DELIMITER ',');

COPY (
SELECT error_code,
       COUNT(*)                                       AS occurrences,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2)  AS pct_of_errors,
       COUNT(DISTINCT machine_id)                     AS machines_affected,
       ROUND(COUNT(*)*1.0/COUNT(DISTINCT machine_id),1) AS avg_per_affected_machine
FROM fct_error GROUP BY error_code ORDER BY occurrences DESC
) TO 'outputs/error_distribution.csv' (HEADER, DELIMITER ',');

-- Failure mode mix from the process feed (AI4I labelled modes)
COPY (
SELECT failure_mode,
       COUNT(*)                                       AS runs,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),3)  AS pct_of_runs,
       ROUND(AVG(air_temp_c),2)      AS avg_air_temp_c,
       ROUND(AVG(process_temp_c),2)  AS avg_process_temp_c,
       ROUND(AVG(temp_delta_k),2)    AS avg_temp_delta_k,
       ROUND(AVG(rotational_speed_rpm),0) AS avg_rpm,
       ROUND(AVG(torque_nm),2)       AS avg_torque_nm,
       ROUND(AVG(tool_wear_min),1)   AS avg_tool_wear_min,
       ROUND(AVG(power_w),0)         AS avg_power_w
FROM fct_process_run GROUP BY failure_mode ORDER BY runs DESC
) TO 'outputs/failure_mode_analysis.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  TRENDS
-- =============================================================================
COPY (
SELECT d.year_month,
       COUNT(DISTINCT d.machine_id)          AS machines,
       SUM(d.failure_count)                  AS failures,
       SUM(d.error_count)                    AS errors,
       SUM(d.maint_count)                    AS maintenance_events,
       SUM(d.unplanned_maint_count)          AS unplanned_maintenance,
       ROUND(100.0*SUM(d.unplanned_maint_count)/NULLIF(SUM(d.maint_count),0),1) AS reactive_pct,
       ROUND(AVG(d.avg_voltage),2)   AS avg_voltage,
       ROUND(AVG(d.avg_rotation),2)  AS avg_rotation,
       ROUND(AVG(d.avg_pressure),2)  AS avg_pressure,
       ROUND(AVG(d.avg_vibration),2) AS avg_vibration,
       ROUND(SUM(d.readings)/NULLIF(SUM(d.failure_count),0),1) AS mtbf_hours
FROM fct_machine_daily d GROUP BY 1 ORDER BY 1
) TO 'outputs/monthly_trend.csv' (HEADER, DELIMITER ',');

COPY (
SELECT machine_model,
       COUNT(DISTINCT machine_id)      AS machines,
       ROUND(AVG(age_years),1)         AS avg_age_years,
       SUM(failures)                   AS failures,
       SUM(errors)                     AS errors,
       ROUND(AVG(mtbf_days),1)         AS avg_mtbf_days,
       ROUND(AVG(est_uptime_pct),2)    AS avg_est_uptime_pct,
       ROUND(AVG(avg_vibration),2)     AS avg_vibration,
       ROUND(AVG(reactive_maintenance_pct),1) AS reactive_pct
FROM machine_health GROUP BY 1 ORDER BY 1
) TO 'outputs/model_comparison.csv' (HEADER, DELIMITER ',');

COPY (
SELECT age_band,
       COUNT(*) AS machines,
       SUM(failures) AS failures,
       ROUND(AVG(failures),2) AS avg_failures_per_machine,
       ROUND(AVG(mtbf_days),1) AS avg_mtbf_days,
       ROUND(AVG(avg_vibration),2) AS avg_vibration
FROM machine_health GROUP BY 1 ORDER BY 1
) TO 'outputs/age_band_reliability.csv' (HEADER, DELIMITER ',');

-- Daily fact for Power BI / Excel
COPY (SELECT * FROM fct_machine_daily ORDER BY reading_date, machine_id)
  TO 'outputs/fact_machine_daily.csv' (HEADER, DELIMITER ',');

SELECT 'health marts written' AS status;
