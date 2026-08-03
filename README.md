# Industrial Machine Performance Analytics

**Condition monitoring and root-cause analysis on 876,100 real sensor readings from 100 machines.**

Industrial equipment fails. The question is whether the sensor data saw it coming — and whether the
warning arrives early enough to act on. This project answers both, and then reports honestly on where
a simple threshold rule is *not* good enough.

| | |
|---|---|
| **Telemetry feed** | [Azure Predictive Maintenance](https://github.com/microsoft/SQL-Server-R-Services-Samples) — 876,100 hourly readings, 100 machines, full year 2015 |
| **Process feed** | [AI4I 2020 (UCI)](https://archive.ics.uci.edu/dataset/601/ai4i+2020+predictive+maintenance+dataset) — 10,000 process runs with 5 labelled failure modes |
| **Scale** | 886,100 readings · 761 failures · 3,919 errors · 3,286 maintenance events |
| **Stack** | SQL · Python (pandas, numpy, matplotlib) · Power BI · Excel |
| **Run it** | `.\run_pipeline.ps1` then `python python/predictive_maintenance.py` |

---

## Headline results

| KPI | Value |
|---|---:|
| Machines monitored | **100** |
| Sensor readings | **876,100** |
| Failures | **761** |
| Error events | **3,919** |
| Maintenance events | **3,286** |
| **Reactive maintenance** | **22.61%** |
| Fleet MTBF | **1,151.2 h (48.0 days)** |
| Estimated uptime | **99.07%** |
| Estimated downtime | **8,130 h** |
| Average health score | **90.0 / 100** |
| Critical machines | **8** |
| Elevated-risk machines | **8** |

---

## The four findings that matter

### 1 · Every fault type has a unique parameter fingerprint

This is the core result. Comparing sensor behaviour in the 24 hours before failure against the fleet
baseline, **each component fails with a different, non-overlapping signature**:

| Component | Failures | Voltage | Rotation | Pressure | Vibration | Dominant signal |
|---|---:|---:|---:|---:|---:|---|
| **comp1** | 192 | **+11.92%** | −0.32% | −0.01% | −0.11% | **Voltage** |
| **comp2** | 259 | +0.42% | **−17.58%** | +0.48% | −0.04% | **Rotation** |
| **comp3** | 131 | +0.54% | −0.84% | **+24.53%** | −0.38% | **Pressure** |
| **comp4** | 179 | +0.21% | −1.45% | +0.53% | **+25.07%** | **Vibration** |

One parameter moves; the other three do not. That means a fault can be *diagnosed from the sensor trace
alone*, before anyone opens the machine:

- Voltage rising → **comp1** → check supply stability and voltage regulation
- Rotation dropping → **comp2** → check drive coupling and rotational load
- Pressure rising → **comp3** → inspect hydraulic line and seals
- Vibration rising → **comp4** → inspect mounting, balance and damping

### 2 · The top 3 components cause 82.7% of all failures

| Component | Failures | % of failures | Cumulative |
|---|---:|---:|---:|
| comp2 | 259 | 34.0% | 34.0% |
| comp1 | 192 | 25.2% | 59.2% |
| comp4 | 179 | 23.5% | **82.7%** |
| comp3 | 131 | 17.2% | 100.0% |

A spares and inspection programme covering three components addresses more than four in five failures.

### 3 · The warning arrives 24 hours ahead — and then stops improving

Sensor deviation from baseline, by time before failure:

| Window | Readings | Voltage | Rotation | Pressure | Vibration | Any threshold breached |
|---|---:|---:|---:|---:|---:|---:|
| Baseline | 825,345 | — | — | — | — | 3.20% |
| T−72h | 32,853 | +1.59% | −3.41% | +2.46% | +3.18% | 12.95% |
| **T−24h** | 8,565 | **+3.22%** | **−6.58%** | **+4.56%** | **+6.15%** | **21.40%** |
| T−12h | 4,308 | +3.22% | −6.45% | +4.64% | +6.15% | 21.15% |
| T−6h | 5,029 | +2.93% | −6.37% | +4.64% | +6.15% | 21.24% |

Degradation is detectable **72 hours out**, roughly doubles by **24 hours**, then **plateaus** — T−12h and
T−6h are statistically identical to T−24h. Waiting past the 24-hour mark buys no extra information and
loses a day of response time.

Threshold breaches rise from 3.20% at baseline to 21.40% at T−24h — a **6.7× increase**.

### 4 · A naive threshold rule is not good enough — and saying so is the point

The Python layer scores a P99 threshold rule honestly, on precision *and* recall:

| Rule | Alerts | True positives | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|
| Voltage | 8,756 | 1,737 | 19.84% | 9.70% | 13.03% |
| Rotation | 8,756 | 2,037 | 23.26% | 11.38% | 15.28% |
| Pressure | 8,756 | 1,348 | 15.40% | 7.53% | 10.11% |
| Vibration | 8,756 | 1,534 | 17.52% | 8.57% | 11.51% |
| **Any parameter** | 34,389 | 6,423 | **18.68%** | **35.88%** | **24.57%** |

**Four out of five alerts would be false.** On a shop floor that means the alarm gets ignored within a
week, and the monitoring system becomes worse than nothing.

The reason is visible in Finding 1: a *global* threshold ignores that each fault only moves one
parameter. The fix the data points to is **per-component rules on the diagnostic parameter**, combined
with each machine's own baseline rather than a fleet constant — which is exactly what
`outputs/root_cause_by_component.csv` provides.

Reporting recall without precision is how condition-monitoring projects quietly fail. It is reported
here because the honest number is the useful one.

---

## Root cause on the process feed (AI4I)

The second feed carries **temperature**, torque and tool wear with five physically-labelled failure
modes, so the failure physics can be read directly rather than inferred:

| Failure mode | Runs | Temp delta | Torque | Tool wear | Power | Dominant driver |
|---|---:|---:|---:|---:|---:|---|
| Heat Dissipation | 115 | **−17.9%** | +34.2% | +0.5% | +19.0% | Strain (wear × torque) |
| Power | 91 | −0.8% | **+20.4%** | −5.6% | +14.7% | Torque |
| Overstrain | 78 | +1.6% | +43.5% | **+95.2%** | +28.8% | Strain |
| Tool Wear | 46 | −1.5% | −4.5% | **+102.8%** | −3.6% | Tool wear |
| Random | 18 | −0.3% | +9.8% | +12.4% | +6.9% | — (no signature) |

- **Heat dissipation failures** happen when the air/process temperature delta *collapses* (−17.9%) —
  cooling stops working — while torque climbs.
- **Overstrain** is driven by tool wear × torque, not by either alone: wear +95.2% *and* torque +43.5%.
- **Random failures show no parameter signature at all** — correctly, since they are not preventable by
  condition monitoring. Any model claiming to predict them is fitting noise.

---

## Architecture

```
data/raw/           PdM_telemetry · PdM_errors · PdM_failures · PdM_maint · PdM_machines · ai4i2020
        │
        ▼
sql/01_build_model.sql        dim_machine · fct_telemetry (876,100) · fct_error · fct_failure
        │                     fct_maintenance (planned vs unplanned, derived)
        │                     fct_machine_daily (36,600) · fct_process_run (10,000)
        ▼
sql/02_data_quality.sql       21 rules incl. stuck-transmitter and dropout detection
        ▼
sql/03_machine_health.sql     MTBF · uptime · fault distribution · fleet-relative health score
        ▼
sql/04_root_cause_analysis.sql  precursor signatures · per-component RCA · threshold exceedance
        │                       error→failure lead time · alert & maintenance schedule
        ▼
python/predictive_maintenance.py  degradation curve · detection-rule scoring · 4 charts
        │
        ├──▶ powerbi/   DAX measure library + build guide
        └──▶ excel/     PivotTables, KPI cards, conditional formatting
```

**Why the health score is fleet-relative.** Each machine is scored on z-scores against the fleet
distribution of failures, errors, vibration level and vibration instability — not against fixed
constants. A machine that simply runs hot by design is not penalised; a machine drifting away from how
its peers behave is.

---

## Data quality — what the gate caught

Sensor data fails quietly. A stuck transmitter reports a plausible constant; a dropped hour leaves no
trace. 21 rules run before any reliability number is published.

| Rule | Severity | Rows | Meaning |
|---|---|---:|---|
| Incomplete hourly series | BLOCK | 0 | All 100 machines have a complete 8,761-hour series |
| Duplicate machine-hour readings | BLOCK | 0 | Grain is clean |
| Stuck transmitter (zero daily variance) | WARN | 0 | No frozen sensors |
| Readings beyond 5σ | WARN | 58 | Retained — genuine extremes, not errors |
| Failures with no component replacement within 6h | WARN | 18 | Repair not logged; excluded from planned/reactive split |
| Machines with zero failures | WARN | 2 | Real — 2 of 100 machines never failed |
| Process temp below air temp | BLOCK | 0 | No sensor swap |
| AI4I mode flagged without failure flag | WARN | 18 | Known source inconsistency, documented |

---

## Documented assumptions

| Input | Value | Why |
|---|---|---|
| **MTTR (unplanned)** | 4 hours | The source records *when* a machine failed, not when it was restored. Downtime is therefore not directly measurable. |
| **MTTR (planned)** | 2 hours | Same |
| Alert threshold | Fleet P95 | Computed from data, not chosen |
| Detection threshold | Fleet P99 (P1 for rotation) | Rotation *falls* before failure |
| Service interval | 70% of measured MTBF | Service before the expected failure point, not on a fixed calendar |

Everything derived from MTTR carries an `est_` prefix. **MTBF, failure counts, error counts and all
sensor statistics are measured, not assumed.**

---

## Reproduce

```powershell
git clone https://github.com/saksham-vlsi/industrial-machine-performance-analytics.git
cd industrial-machine-performance-analytics
.\run_pipeline.ps1                            # SQL layer -> outputs/*.csv
pip install -r requirements.txt
python python/predictive_maintenance.py       # Python layer -> outputs/ + assets/*.png
```

---

## Repository map

```
sql/        01 model · 02 quality gate · 03 health & reliability · 04 root cause
python/     predictive_maintenance.py — degradation curve, detection scoring, charts
outputs/    20 published marts (committed)
assets/     4 generated charts
powerbi/    measures.dax · BUILD_GUIDE.md
excel/      BUILD_GUIDE.md
docs/       business problem · data dictionary · metric definitions · findings
data/       download_data.ps1 (raw data gitignored — 77 MB)
```

---

*Data: Azure Predictive Maintenance (MIT) and AI4I 2020 (UCI, CC BY 4.0). Analysis and code: MIT.*
