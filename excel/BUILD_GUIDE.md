# Excel Build Guide

Builds a refreshable machine-health workbook from `outputs/`. Excel 2016+ or Microsoft 365.
Run `.\run_pipeline.ps1` and `python python/predictive_maintenance.py` first.

---

## 1 · Connect with Power Query

**Data → Get Data → From File → From Folder →** `outputs\`. Import each as a connection and tick
**Add this data to the Data Model**.

| Query | File | Load as |
|---|---|---|
| `MachineDaily` | `fact_machine_daily.csv` | Data Model only (36,600 rows) |
| `Health` | `machine_health_score.csv` | Table + Data Model |
| `Overview` | `machine_overview.csv` | Table + Data Model |
| `Faults` | `fault_distribution.csv` | Table + Data Model |
| `Errors` | `error_distribution.csv` | Table + Data Model |
| `RootCause` | `root_cause_by_component.csv` | Table |
| `Precursor` | `precursor_signature.csv` | Table |
| `Threshold` | `threshold_exceedance.csv` | Table |
| `Detection` | `detection_rule_performance.csv` | Table |
| `Degradation` | `degradation_curve.csv` | Table |
| `ProcessRCA` | `process_root_cause.csv` | Table |
| `Alerts` | `alert_and_maintenance_schedule.csv` | Table + Data Model |
| `Monthly` | `monthly_trend.csv` | Table + Data Model |
| `Models` | `model_comparison.csv` | Table |
| `Quality` | `data_quality_report.csv` | Table |

> Do **not** import `PdM_telemetry.csv` — 876,100 rows exceeds what a worksheet handles comfortably and
> `MachineDaily` already carries every daily statistic.

### Transform steps on `MachineDaily`

1. **Set types explicitly** — `reading_date` → Date; `avg_*`/`max_*`/`sd_*` → Decimal; counts → Whole Number.
2. **Add Column → Conditional Column** `Day Status`: `failure_count > 0` → `Failure`;
   `maint_count > 0` → `Maintenance`; `error_count > 0` → `Error`; else `Normal`.
3. **Add Column → Custom Column** `Month`: `= Date.ToText([reading_date], "yyyy-MM")`.
4. **Home → Remove Rows → Remove Errors**, then **Close & Load**.

---

## 2 · Sheet 1 — Machine Health Dashboard

```excel
Machines                =COUNTA(Health[machine_id])
Total Failures          =SUM(Overview[failures])
Total Errors            =SUM(Overview[errors])
Maintenance Events      =SUM(Overview[maintenance_events])
Unplanned Maintenance   =SUM(Overview[unplanned_maintenance])
Reactive Maintenance %  =SUM(Overview[unplanned_maintenance])/SUM(Overview[maintenance_events])
Operating Hours         =SUM(Overview[operating_hours_observed])
MTBF Hours              =SUM(Overview[operating_hours_observed])/SUM(Overview[failures])
MTBF Days               =[MTBF Hours]/24
Est Downtime Hours      =SUM(Overview[est_downtime_hours])
Est Uptime %            =1-[Est Downtime Hours]/[Operating Hours]
Avg Health Score        =AVERAGE(Health[health_score])
Critical Machines       =COUNTIF(Health[health_band],"D - Critical")
Elevated Risk Machines  =COUNTIF(Health[health_band],"C - Elevated risk")
Machines Needing Action =[Critical Machines]+[Elevated Risk Machines]
Avg Vibration           =SUMPRODUCT(Overview[avg_vibration],Overview[operating_hours_observed])/[Operating Hours]
```

> **MTBF divides the totals**, it does not average per-machine MTBFs — averaging ratios overweights
> machines with few failures and produces a number that disagrees with the SQL. The same reasoning
> drives the `SUMPRODUCT` weighting on Avg Vibration.

**Cards:** merge a 3×2 block per KPI. **Conditional Formatting → Icon Sets** on
Avg Health Score (green ≥ 90, amber ≥ 75, red below) and on Reactive Maintenance %
(reverse — high is bad).

**Sparklines:** `Insert → Sparklines → Line`, range `Monthly[failures]`, one per card.

---

## 3 · Sheet 2 — PivotTables

**Insert → PivotTable → Use this workbook's Data Model.**

| PivotTable | Rows | Values | Chart |
|---|---|---|---|
| Monthly reliability | `Month` | Sum `failures`, Sum `errors`, Avg `mtbf_hours` | Line + column combo |
| Fault Pareto | `component` | Sum `failures`, running % of total | Bar + cumulative line |
| Error mix | `error_code` | Sum `occurrences` | Treemap |
| Health bands | `health_band` | Count `machine_id` | Donut |
| Model comparison | `machine_model` | Avg `avg_mtbf_days`, Sum `failures` | Bar |
| Age vs failures | `age_band` | Avg `avg_failures_per_machine` | Bar |
| Machine ranking | `machine_id` | Avg `health_score`, Sum `failures` | Bar, Bottom 15 |

For the Pareto, add `failures` a second time and set **Show Values As → % Running Total In → component**.

---

## 4 · Sheet 3 — Root Cause (the money sheet)

Paste-link `RootCause` and build the 4×4 deviation grid:

| | Voltage | Rotation | Pressure | Vibration |
|---|---|---|---|---|
| comp1 | `voltage_dev_pct` | … | … | … |
| comp2 | … | … | … | … |
| comp3 | … | … | … | … |
| comp4 | … | … | … | … |

Select the 4×4 body → **Conditional Formatting → Colour Scales → red-white-blue diverging**, centred
on 0. Exactly one cell per row lights up. That grid *is* the finding — one parameter fingerprints each
fault — and it reads in two seconds without any explanation.

Beneath it, paste-link `Precursor` and chart `voltage_pct_vs_baseline`, `rotation_pct_vs_baseline`,
`pressure_pct_vs_baseline`, `vibration_pct_vs_baseline` against `failure_window` as a line chart. Order
the axis Baseline → T−72h → T−24h → T−12h → T−6h to show the signal building and then plateauing.

---

## 5 · Sheet 4 — Maintenance work list

The operational output. From `Alerts`, columns: `machine_id`, `machine_model`, `age_years`,
`health_score`, `health_band`, `failures_last_year`, `avg_vibration_7d`, `vibration_alert`,
`recommended_service_interval_days`, `maintenance_priority`.

Sort by `health_score` ascending. Add:

```excel
Days Until Service  =[@recommended_service_interval_days]
Action              =IF([@maintenance_priority]="P1 - Schedule within 7 days","URGENT",
                     IF([@maintenance_priority]="P2 - Schedule within 30 days","Plan","Routine"))
```

**Conditional formatting:** red fill where `maintenance_priority` starts with `P1`; amber for `P2`;
data bars on `health_score`.

---

## 6 · Sheet 5 — Detection honesty check

Paste-link `Detection`. Chart `precision_pct` and `recall_pct` by `rule` as a clustered column.

Add a note cell:

```excel
="Best rule catches "&TEXT(MAX(Detection[recall_pct]),"0.0")&"% of failures but is wrong "&
 TEXT(100-INDEX(Detection[precision_pct],MATCH(MAX(Detection[recall_pct]),Detection[recall_pct],0)),"0.0")&
 "% of the time it fires - do not deploy as-is"
```

Keeping this sheet in the workbook is the difference between a report that gets trusted and one that
gets quietly overridden the first time the alarm cries wolf.

---

## 7 · Slicers and refresh

**Insert Slicer:** `machine_model`, `age_band`, `health_band`, `Day Status`. **Insert Timeline:**
`reading_date`. Connect every slicer to every PivotTable via **Report Connections**.

Re-run the pipeline, then **Data → Refresh All**. Save as `.xlsx`.

Optionally insert the four PNGs from `assets/` (**Insert → Pictures**) onto a "Charts" sheet.
