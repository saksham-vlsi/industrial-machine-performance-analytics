# Findings & Recommendations

Every figure is reproducible with `.\run_pipeline.ps1` + `python python/predictive_maintenance.py`
and traceable to a file in `outputs/`.

---

## Finding 1 — Each fault type has a unique, non-overlapping sensor fingerprint

**Evidence** — `outputs/root_cause_by_component.csv`

Deviation from fleet baseline in the 24 hours before failure:

| Component | Failures | Voltage | Rotation | Pressure | Vibration | Dominant |
|---|---:|---:|---:|---:|---:|---|
| comp1 | 192 | **+11.92%** | −0.32% | −0.01% | −0.11% | Voltage |
| comp2 | 259 | +0.42% | **−17.58%** | +0.48% | −0.04% | Rotation |
| comp3 | 131 | +0.54% | −0.84% | **+24.53%** | −0.38% | Pressure |
| comp4 | 179 | +0.21% | −1.45% | +0.53% | **+25.07%** | Vibration |

For every component exactly **one** parameter moves and the other three stay within ±1.5% of baseline.
This is unusually clean, and it is the single most valuable result in the project: a fault can be
diagnosed from the sensor trace before anyone opens the machine.

**Recommendation.** Replace the single fleet-wide alarm with **four parameter-specific rules**, each
routed to the team that owns the fix:

| Signal | Diagnosis | Route to |
|---|---|---|
| Voltage ↑ >8% over own baseline | comp1 | Electrical — supply stability, voltage regulation |
| Rotation ↓ >12% | comp2 | Mechanical — drive coupling, rotational load |
| Pressure ↑ >18% | comp3 | Hydraulics — line pressure, seals |
| Vibration ↑ >18% | comp4 | Mechanical — mounting, balance, damping |

**Owner:** Maintenance Engineering. **Effort:** Low — the thresholds already exist in the data.

---

## Finding 2 — Three components cause 82.7% of failures

**Evidence** — `outputs/fault_distribution.csv`

| Component | Failures | % | Cumulative | Machines affected |
|---|---:|---:|---:|---:|
| comp2 | 259 | 34.0% | 34.0% | 91 |
| comp1 | 192 | 25.2% | 59.2% | 83 |
| comp4 | 179 | 23.5% | **82.7%** | 84 |
| comp3 | 131 | 17.2% | 100.0% | 74 |

The failure mode is fleet-wide, not machine-specific — comp2 has failed on 91 of 100 machines. That
rules out "a few bad machines" and points at a design or duty-cycle issue with the component itself.

**Recommendation.** Concentrate the spares holding and the inspection checklist on comp2, comp1 and
comp4. Raise a component-level engineering review for comp2 specifically: a part failing on 91% of the
fleet is a specification problem, not a maintenance problem.

**Owner:** Reliability Engineering + Spares. **Effort:** Low.

---

## Finding 3 — The useful warning window is 24 hours, and it does not get better

**Evidence** — `outputs/precursor_signature.csv`, `outputs/threshold_exceedance.csv`,
`outputs/degradation_curve.csv`

| Window | Voltage | Rotation | Pressure | Vibration | Any threshold breached |
|---|---:|---:|---:|---:|---:|
| Baseline | — | — | — | — | 3.20% |
| T−72h | +1.59% | −3.41% | +2.46% | +3.18% | 12.95% |
| **T−24h** | **+3.22%** | **−6.58%** | **+4.56%** | **+6.15%** | **21.40%** |
| T−12h | +3.22% | −6.45% | +4.64% | +6.15% | 21.15% |
| T−6h | +2.93% | −6.37% | +4.64% | +6.15% | 21.24% |

Degradation is visible at 72 hours, roughly doubles by 24 hours, then **plateaus** — T−12h and T−6h are
statistically indistinguishable from T−24h. The signal saturates.

**Recommendation.** Set the intervention trigger at **T−24h**. Waiting longer gains no diagnostic
information and burns a day of response time. At 72 hours the deviation is real but only ~3%, which at
current precision would generate too many false alarms to be actionable — so 72h is a *watch* trigger,
24h is an *act* trigger.

**Owner:** Operations. **Effort:** Low.

---

## Finding 4 — A global threshold rule would be ignored within a week

**Evidence** — `outputs/detection_rule_performance.csv`

| Rule | Alerts raised | True positives | Precision | Recall | F1 |
|---|---:|---:|---:|---:|---:|
| Voltage (P99) | 8,756 | 1,737 | 19.84% | 9.70% | 13.03% |
| Rotation (P1) | 8,756 | 2,037 | 23.26% | 11.38% | 15.28% |
| Pressure (P99) | 8,756 | 1,348 | 15.40% | 7.53% | 10.11% |
| Vibration (P99) | 8,756 | 1,534 | 17.52% | 8.57% | 11.51% |
| **Any parameter** | 34,389 | 6,423 | **18.68%** | **35.88%** | **24.57%** |

The best combined rule catches **36% of failures** while being **wrong 81% of the time it fires**. In a
plant, that alarm is muted within a week and the monitoring system becomes worse than nothing.

**Why it fails is visible in Finding 1.** A global threshold ignores that each fault moves only one
parameter, so three quarters of the alert budget is spent watching parameters that are not degrading
for that fault.

**Recommendation.** Do not deploy a global threshold rule. Build instead:

1. **Per-component rules** on the diagnostic parameter only (Finding 1).
2. **Per-machine baselines** rather than a fleet constant — a machine that always runs at high vibration
   should not alarm continuously.
3. **Two-of-four confirmation** before escalating, to suppress single-sensor noise.

This finding is reported rather than buried because a condition-monitoring project that reports recall
without precision is the standard way these systems get built and then abandoned.

**Owner:** Reliability Engineering. **Effort:** Medium.

---

## Finding 5 — 22.61% of maintenance is reactive; 8 machines are critical

**Evidence** — `outputs/fleet_kpi_executive.csv`, `outputs/machine_health_score.csv`,
`outputs/alert_and_maintenance_schedule.csv`

- 3,286 maintenance events, **22.61% unplanned** (post-failure repairs)
- Fleet MTBF **1,151.2 hours (48.0 days)**
- **8 machines Critical**, **8 Elevated risk** out of 100
- Estimated downtime **8,130 hours** across the fleet-year

Roughly one maintenance action in four is a reaction to a breakdown rather than a planned intervention —
the most expensive way to maintain equipment.

**Recommendation.** Move to condition-based intervals set from each machine's **own measured MTBF**
(the schedule in `outputs/alert_and_maintenance_schedule.csv` uses 70% of measured MTBF), starting with
the 16 Critical and Elevated-risk machines. Track reactive % as the programme's headline KPI — it is the
single number that shows whether predictive maintenance is actually working.

**Owner:** Maintenance Planning. **Effort:** Medium.

---

## Finding 6 — Process failures are driven by parameter *interactions*, not single limits

**Evidence** — `outputs/process_root_cause.csv`, `outputs/ai4i_failure_drivers.csv`

| Failure mode | Runs | Temp delta | Torque | Tool wear | Power | Driver |
|---|---:|---:|---:|---:|---:|---|
| Heat Dissipation | 115 | **−17.9%** | +34.2% | +0.5% | +19.0% | Strain (wear × torque) |
| Power | 91 | −0.8% | **+20.4%** | −5.6% | +14.7% | Torque |
| Overstrain | 78 | +1.6% | +43.5% | **+95.2%** | +28.8% | Strain |
| Tool Wear | 46 | −1.5% | −4.5% | **+102.8%** | −3.6% | Tool wear |
| Random | 18 | −0.3% | +9.8% | +12.4% | +6.9% | none |

- **Heat dissipation** fails when the temperature *delta collapses* (−17.9%) — cooling has stopped
  working — while torque rises. Monitoring absolute temperature would miss this entirely; the delta is
  the signal.
- **Overstrain** needs both high wear (+95.2%) **and** high torque (+43.5%). Neither alone triggers it.
- **Random failures show no signature** — correctly, since they are not preventable by condition
  monitoring. A model claiming to predict them is fitting noise.

**Recommendation.** Monitor **derived** quantities, not just raw channels: temperature *delta*,
mechanical *power* (torque × speed), and *strain* (wear × torque). None of the three is a column in the
source — all must be computed — and each is the dominant driver of a distinct failure mode.

**Owner:** Process Engineering. **Effort:** Low.

---

## Priority

| # | Finding | Effort | Impact | Sequence |
|---|---|---|---|---|
| 1 | Per-component parameter rules | Low | High | **First** — thresholds already derived |
| 3 | 24-hour act trigger | Low | High | First — same change |
| 6 | Monitor derived parameters | Low | Medium | Second |
| 2 | comp2 engineering review | Low | High | Second — 34% of failures |
| 5 | Condition-based intervals | Medium | High | Third |
| 4 | Do **not** deploy the global rule | — | High | Immediate — a decision not to act |

Finding 4 is the one that saves the programme: shipping a rule that is wrong 81% of the time would
destroy operator trust and make every later improvement unsellable.
