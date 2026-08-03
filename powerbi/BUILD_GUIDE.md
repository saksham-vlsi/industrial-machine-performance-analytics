# Power BI Build Guide

Builds the three-page machine health report from `outputs/`. Run `.\run_pipeline.ps1` and
`python python/predictive_maintenance.py` first.

---

## 1 · Load the data

**Home → Get Data → Text/CSV** from `outputs/`:

| Query | File | Rows |
|---|---|---:|
| `MachineDaily` | `fact_machine_daily.csv` | 36,600 |
| `MachineHealth` | `machine_health_score.csv` | 100 |
| `MachineOverview` | `machine_overview.csv` | 100 |
| `FaultDist` | `fault_distribution.csv` | 4 |
| `ErrorDist` | `error_distribution.csv` | 5 |
| `Precursor` | `precursor_signature.csv` | 5 |
| `RootCause` | `root_cause_by_component.csv` | 4 |
| `Threshold` | `threshold_exceedance.csv` | 5 |
| `ErrorLink` | `error_to_failure_link.csv` | — |
| `ProcessRCA` | `process_root_cause.csv` | 7 |
| `FailureMode` | `failure_mode_analysis.csv` | 7 |
| `Alerts` | `alert_and_maintenance_schedule.csv` | 100 |
| `Monthly` | `monthly_trend.csv` | 13 |
| `ModelComp` | `model_comparison.csv` | 4 |
| `AgeBand` | `age_band_reliability.csv` | 3 |
| `Degradation` | `degradation_curve.csv` | 169 |
| `Detection` | `detection_rule_performance.csv` | 5 |
| `Quality` | `data_quality_report.csv` | 21 |

**Do not load `PdM_telemetry.csv` (876,100 rows).** `MachineDaily` is the pre-aggregated grain and every
published KPI is daily or coarser — loading hourly data makes the model slow for no analytical gain.

### Power Query steps on `MachineDaily`

1. **Set types explicitly.** `reading_date` → Date; all `avg_*`, `max_*`, `sd_*` → Decimal Number;
   `readings`, `error_count`, `failure_count`, `maint_count`, `unplanned_maint_count`, `age_years`
   → Whole Number.
2. **Add Column → Conditional Column** `Day Status`:
   `failure_count > 0` → `"Failure"`; `maint_count > 0` → `"Maintenance"`;
   `error_count > 0` → `"Error"`; else `"Normal"`.
3. **Add Column → Custom Column** `Vibration Band`:
   ```
   if [avg_vibration] >= 45 then "High (45+)"
   else if [avg_vibration] >= 40 then "Elevated (40-45)"
   else "Normal (<40)"
   ```
4. **Close & Apply.**

---

## 2 · Date table

```dax
DimDate =
ADDCOLUMNS (
    CALENDAR ( DATE ( 2015, 1, 1 ), DATE ( 2016, 1, 1 ) ),
    "Year",       YEAR ( [Date] ),
    "Month Num",  MONTH ( [Date] ),
    "Month",      FORMAT ( [Date], "MMM" ),
    "Year Month", FORMAT ( [Date], "YYYY-MM" ),
    "Week",       WEEKNUM ( [Date] ),
    "Day Name",   FORMAT ( [Date], "ddd" )
)
```

**Table tools → Mark as date table → `Date`.** Sort `Month` by `Month Num`.

---

## 3 · Relationships

| From | To | Cardinality | Direction |
|---|---|---|---|
| `MachineDaily[reading_date]` | `DimDate[Date]` | Many-to-one | Single |
| `MachineDaily[machine_id]` | `MachineHealth[machine_id]` | Many-to-one | Single |
| `Alerts[machine_id]` | `MachineHealth[machine_id]` | One-to-one | Single |
| `MachineOverview[machine_id]` | `MachineHealth[machine_id]` | One-to-one | Single |

`RootCause`, `Precursor`, `Threshold`, `Detection`, `Degradation` and `ProcessRCA` are **standalone
analysis tables** — leave them unrelated. Forcing a relationship onto a summary table with a different
grain is the fastest way to get silently wrong totals.

---

## 4 · Measures

Create a blank table `_Measures` (**Home → Enter Data**, delete the column, Load), then paste from
[`measures.dax`](measures.dax). Hide raw numeric columns on `MachineDaily` afterwards.

---

## 5 · Page build

### Page 1 — Machine Overview

**KPI cards:** `Machines` · `MTBF Days` · `Est Uptime %` · `Total Failures` · `Reactive Maintenance %` ·
`Avg Health Score`.
On the health card set **Format → Callout value → Colour → fx → Field value → `Health Colour`**.

| Visual | Type | Fields |
|---|---|---|
| Failures & errors trend | Line and clustered column | Axis `Year Month` · Column `Total Failures` · Line `Total Errors` |
| Machine status mix | Donut | Legend `Day Status` · Values count of rows |
| Health band distribution | Clustered bar | Axis `health_band` · Values count of `machine_id` |
| Parameter trend | Line chart | Axis `Year Month` · Values `Avg Vibration` (add `Avg Pressure` as a **separate** chart — never a second y-axis) |
| Model comparison | Clustered bar | Axis `machine_model` · Values `avg_mtbf_days`, `failures` |
| Age vs reliability | Scatter | X `age_years` · Y `mtbf_days` · Size `failures` · Details `machine_id` |
| Header | Card | `Report Header` |

**Slicers (sync all pages):** `DimDate[Year Month]`, `machine_model`, `age_band`, `health_band`.

### Page 2 — Fault Analysis

| Visual | Type | Fields |
|---|---|---|
| Fault Pareto | Line and clustered column | Axis `component` · Column `failures` · Line `cumulative_pct` |
| Error code mix | Treemap | Group `error_code` · Values `occurrences` |
| **Root cause matrix** | Matrix | Rows `component` · Values `voltage_dev_pct`, `rotation_dev_pct`, `pressure_dev_pct`, `vibration_dev_pct` |
| Downtime trend | Area chart | Axis `Year Month` · Values `Est Downtime Hours` |
| Error → failure lead | Table | `error_code`, `component`, `pct_of_this_error_code`, `median_lead_hours` |

**The root cause matrix is the visual to lead with.** Apply **Conditional formatting → Background colour**
across all four deviation columns using a diverging scale centred on 0. The result is a 4×4 grid with
exactly one hot cell per row — the fingerprint result, visible at a glance.

### Page 3 — Predictive Maintenance

| Visual | Type | Fields |
|---|---|---|
| **Degradation curve** | Line chart | Axis `hours_to_failure` (reverse the axis) · Values `volt_index`, `rotate_index`, `pressure_index`, `vibration_index` |
| Threshold exceedance | Clustered column | Axis `failure_window` · Values `pct_any_exceed` |
| Detection performance | Clustered bar | Axis `rule` · Values `precision_pct`, `recall_pct` |
| Process failure modes | Scatter | X `rpm` · Y `torque_nm` · Legend `failure_mode` |
| **Maintenance work list** | Table | `machine_id`, `health_score`, `health_band`, `failures_last_year`, `recommended_service_interval_days`, `maintenance_priority` |
| Alerts | Card | `Active Alerts`, `P1 Machines` |

Because the indexed degradation columns share a baseline of 100, all four parameters sit on **one** axis
— no dual-axis chart is needed, and none should be used.

Sort the work list by `health_score` ascending and conditional-format `maintenance_priority` (red on P1).
This table is the actual deliverable: a ranked list of machines to service.

### Page 4 — Data Quality

Table over `Quality`: `rule_id`, `severity`, `rule_name`, `row_count`, `status`. Red fill on `FAIL`.
Card: `COUNTROWS(FILTER(Quality,[severity]="BLOCK" && [status]="FAIL"))`.

---

## 6 · Polish

- **Drill-through** page filtered by `machine_id` so any machine in any visual opens its detail.
- **Tooltip page** (page size = Tooltip) showing that machine's parameter trend.
- **Bookmarks** to toggle "Reliability view" / "Diagnostic view".
- Import the four PNGs from `assets/` as static images if you want the Python charts in the report.

## 7 · Refresh

Re-run the pipeline and the Python script, then **Home → Refresh**.
