# Business Problem

## Context

A fleet of 100 industrial machines, instrumented on four channels, sampled hourly for a full year:
**876,100 sensor readings**, **761 failures**, **3,919 error events**, **3,286 component replacements**.

Roughly one maintenance action in four (**22.61%**) is a reaction to a breakdown rather than a planned
intervention. Reactive maintenance is the most expensive way to run equipment: unplanned downtime,
expedited spares, and production lost at the worst possible moment.

## The questions this project has to answer

1. **How reliable is the fleet?** MTBF, uptime, failure and error rates — per machine, model and age band.
2. **What actually breaks?** Fault distribution, and whether failures concentrate in a few components or
   a few machines.
3. **Does the sensor data see failure coming?** And if so, *how early* — because a warning that arrives
   an hour ahead is not actionable.
4. **Which parameter identifies which fault?** So a diagnosis can be made from the trace, before the
   machine is opened.
5. **Would an alerting rule actually work in production?** Measured on precision as well as recall.
6. **Which machines need attention first?** A ranked, prioritised maintenance schedule.

## Why root cause is the centre of the design

"Vibration is high" is not actionable. "Vibration is 25% above this machine's baseline, which on this
fleet uniquely indicates a comp4 mounting fault, typically 24 hours before failure" is a work order.

The project is therefore built around comparing sensor behaviour in a **pre-failure window** against a
**baseline**, per component. That single design decision produces Finding 1 — that each of the four
components fails with a distinct, non-overlapping parameter signature — which everything else depends on.

## Why the honest detection score is included

The easy version of this project reports "our rule catches 36% of failures" and stops. This one also
reports that the same rule is **wrong 81% of the time it fires**.

That matters because it changes the recommendation completely. A rule at 19% precision generates four
false alarms for every real one, gets muted by operators within a week, and takes the credibility of the
whole monitoring programme with it. The correct conclusion from this data is *do not deploy the global
threshold rule* — build per-component rules on per-machine baselines instead.

Reporting recall without precision is the standard way condition-monitoring projects get built and then
quietly abandoned.

## Success criteria

| Criterion | Met |
|---|---|
| Sensor integrity verified before any KPI | 21 rules incl. stuck-transmitter and dropout detection |
| Failures attributable to a specific parameter | Finding 1 — four distinct signatures |
| Warning window quantified, not asserted | Degradation measurable at T−72h, saturating at T−24h |
| Alerting evaluated on precision *and* recall | `outputs/detection_rule_performance.csv` |
| Metrics depending on assumptions are labelled | `est_` prefix on everything derived from MTTR |
| Output is a work list, not a chart | `outputs/alert_and_maintenance_schedule.csv`, P1–P4 |

## Scope boundary

This project covers **condition monitoring and diagnosis**. It deliberately stops short of a trained
predictive model: with 761 failures across 876,100 readings the positive class is 0.09%, and a model
fitted without careful time-series cross-validation and class balancing would report a misleading
accuracy. The threshold analysis here establishes what a model would have to beat — which is the correct
first step, and the one usually skipped.
