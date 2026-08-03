# Data Dictionary & Metric Definitions

## Source feeds

### Telemetry feed — Azure Predictive Maintenance

100 machines, hourly, 1 Jan 2015 – 1 Jan 2016. Five related files.

| File | Grain | Rows | Columns |
|---|---|---:|---|
| `PdM_telemetry.csv` | machine-hour | 876,100 | `datetime`, `machineID`, `volt`, `rotate`, `pressure`, `vibration` |
| `PdM_errors.csv` | event | 3,919 | `datetime`, `machineID`, `errorID` (error1–5) |
| `PdM_failures.csv` | event | 761 | `datetime`, `machineID`, `failure` (comp1–4) |
| `PdM_maint.csv` | event | 3,286 | `datetime`, `machineID`, `comp` (comp1–4) |
| `PdM_machines.csv` | machine | 100 | `machineID`, `model` (model1–4), `age` |

### Process feed — AI4I 2020 (UCI)

10,000 process runs with five labelled failure modes.

| Column | Mapped to | Note |
|---|---|---|
| `Air temperature [K]` | `air_temp_c` | Converted K → °C |
| `Process temperature [K]` | `process_temp_c` | Converted K → °C |
| — | `temp_delta_k` | **Derived.** Process − air. The heat-dissipation driver |
| `Rotational speed [rpm]` | `rotational_speed_rpm` | |
| `Torque [Nm]` | `torque_nm` | Mechanical load — the current/load proxy |
| `Tool wear [min]` | `tool_wear_min` | Cumulative runtime on the tool |
| — | `power_w` | **Derived.** `torque × rpm × 2π / 60`. The power-failure driver |
| `TWF/HDF/PWF/OSF/RNF` | `failure_mode` | Tool Wear / Heat Dissipation / Power / Overstrain / Random |

---

## Parameter coverage

The brief specifies temperature, current, vibration, voltage and runtime. Coverage across the two real
feeds:

| Brief parameter | Source | Column |
|---|---|---|
| Timestamp | Telemetry | `reading_ts`, hourly |
| **Temperature** | Process feed | `air_temp_c`, `process_temp_c`, `temp_delta_k` |
| **Vibration** | Telemetry | `vibration` |
| **Voltage** | Telemetry | `voltage` |
| **Current** | Process feed (proxy) | `torque_nm` — mechanical load. **No current sensor exists in either feed**; torque is the closest physical analogue and is labelled as a proxy throughout |
| **Runtime** | Both | `age_years` (machine), `tool_wear_min` (tool), `operating_hours_observed` |
| **Machine Status** | Derived | From failure / maintenance events |
| **Fault Code** | Both | `error_code` (error1–5), `component` (comp1–4), `failure_mode` (5 AI4I modes) |

Current is the one parameter neither real dataset measures. It is mapped to torque with the substitution
stated, rather than fabricating a column.

---

## Model tables

### `dim_machine` — 100 rows
`machine_id`, `machine_model`, `age_years`, `age_band` (New <8y / Mid-life 8–15y / Old 15y+)

### `fct_telemetry` — 876,100 rows
`reading_ts`, `reading_date`, `machine_id`, `voltage`, `rotation_rpm`, `pressure`, `vibration`,
`hour_of_day`, `year_month`

### `fct_failure` / `fct_error` — 761 / 3,919 rows
Event timestamp, machine, and `component` / `error_code`.

### `fct_maintenance` — 3,286 rows

The source does **not** say whether a replacement was preventive or a repair. It is derived:

```sql
maintenance_type = 'Unplanned (post-failure)'
    WHEN a failure of the SAME component on the SAME machine
         falls within ±6 hours of the replacement
    ELSE 'Planned (preventive)'
```

This single classification is what makes the **planned-vs-reactive ratio** — the headline maintenance
KPI — computable at all. Measured result: **22.61% reactive**.

### `fct_machine_daily` — 36,600 rows
Daily rollup per machine: mean/max/σ of each parameter, plus error, failure and maintenance counts.
This is the grain Power BI and Excel consume — 876k hourly rows would slow the model for no analytical
gain, since every published KPI is daily or coarser.

### `telemetry_labelled` — 876,100 rows
Every reading tagged with `hours_to_failure` and a `failure_window`
(`Baseline` / `T-72h` / `T-24h` / `T-12h` / `T-6h`). The basis of all root-cause analysis.

---

## Reliability metrics

| Metric | Formula | Measured? |
|---|---|---|
| **MTBF** | `observed operating hours / failures` | **Measured** |
| Failures per year | `failures × 8760 / observed hours` | Measured |
| Errors per failure | `errors / failures` | Measured |
| Reactive maintenance % | `unplanned / total maintenance events` | Measured (from the derived split) |
| **Est. downtime** | `failures × MTTR_unplanned + planned events × MTTR_planned` | **Estimated** |
| **Est. uptime %** | `100 × (1 − est_downtime / observed hours)` | **Estimated** |

**On MTTR.** The source records when a machine failed but not when it was restored, so downtime cannot
be measured. 4 hours (unplanned) and 2 hours (planned) are assumed. Every column derived from them is
prefixed `est_`. Nothing else in this project depends on an assumption.

---

## Health score

```
health_score = 100 − 12·z(failures) − 7·z(errors) − 6·z(vibration) − 5·z(vibration σ)
```

clamped to 0–100, where each `z` is the machine's z-score against the **fleet** distribution.

| Band | Score |
|---|---|
| A · Healthy | ≥ 90 |
| B · Monitor | 75 – 90 |
| C · Elevated risk | 60 – 75 |
| D · Critical | < 60 |

**Why fleet-relative rather than fixed thresholds.** A machine that runs hot by design would be
permanently penalised by a fixed limit. Scoring against how peer machines actually behave isolates
*drift* — the thing maintenance can act on. Weights put failures first (the outcome that matters), then
error load, then vibration level, then vibration instability — because a rising standard deviation
often precedes a rising mean.

---

## Root cause metrics

### Precursor deviation

```
deviation_pct = 100 × (mean in window − baseline mean) / baseline mean
z             = (mean in window − baseline mean) / baseline σ
```

Baseline = all readings more than 72 hours from any failure (825,345 readings).

### Dominant parameter

The parameter with the largest absolute z-score in the pre-failure window. This is the diagnostic
signal — the answer to "which parameter crossed threshold".

### Threshold exceedance

Thresholds are the **fleet P99** for voltage, pressure and vibration, and the **fleet P1** for rotation
(which falls before failure). Percentages report how often each window breaches them.

### Detection rule scoring

```
precision = TP / (TP + FP)      recall = TP / (TP + FN)      F1 = 2PR/(P+R)
```

Ground truth: a failure occurs within 24 hours. **Precision is reported alongside recall in every case.**
A rule with high recall and 19% precision fires four false alarms for every real one and will be ignored
in production — reporting only recall would hide exactly the thing that makes the system fail.

---

## Maintenance scheduling

```
recommended_service_interval_days = 0.70 × measured MTBF (days)
```

| Priority | Trigger |
|---|---|
| P1 — within 7 days | Health band D (Critical) |
| P2 — within 30 days | Health band C (Elevated risk) |
| P3 — next planned window | Health band B (Monitor) |
| P4 — routine | Health band A (Healthy) |

Servicing at 70% of a machine's **own measured** MTBF replaces a fixed calendar that ignores how the
machine actually behaves.

---

## Conventions

- Temperatures in °C (converted from Kelvin). Nobody reads a shop-floor dashboard in Kelvin.
- Percentages stored out of 100.
- `NULLIF(...,0)` guards every denominator.
- `est_` prefix = depends on the MTTR assumption. Everything else is measured.
