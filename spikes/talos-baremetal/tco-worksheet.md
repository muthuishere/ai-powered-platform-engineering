# Bare-metal vs cloud — TCO worksheet (fill in your own numbers)

> A **decision tool, not a verdict.** Plug your real numbers into the left
> (owned, amortized) and right (cloud-equivalent) columns and compare the monthly
> totals. The break-even swings hard on **scale, egress volume, and utilization** —
> the worked example below uses placeholder numbers and is *not* a recommendation.

All figures are **per month** unless noted. Amortize hardware over its expected
life (commonly 36–60 months) and divide to a monthly number.

## Column A — Owned hardware (on-prem)

| Line item | Formula / note | Your number |
|---|---|---|
| Nodes (count) | how many physical servers | `____` |
| Hardware capex, amortized | `(server $ + memory + disk) / life-months × nodes` | `$ ____` |
| Power | `node watts × 24 × 30 / 1000 × $/kWh × nodes` (× PUE for cooling) | `$ ____` |
| Rack / colo | rack-unit or cabinet fee + cross-connect (or owned-DC overhead) | `$ ____` |
| Network / transit | committed bandwidth / transit port (NOT per-GB) | `$ ____` |
| Ops labor | `ops hours/month × loaded $/hr` (lifecycle, remote hands, on-call) | `$ ____` |
| Spares / replacement | budget for disk/PSU/node failure | `$ ____` |
| **Column A total** | sum | **`$ ____`** |

## Column B — Cloud equivalent

| Line item | Formula / note | Your number |
|---|---|---|
| Managed-k8s control plane | per-cluster control-plane fee × clusters | `$ ____` |
| Compute | equivalent instances (on-demand or committed/reserved) | `$ ____` |
| Block + object storage | provisioned GB × $/GB | `$ ____` |
| **Egress** | `GB out/month × $/GB` — often the swing line item | `$ ____` |
| Load balancer / NAT / IPs | per-LB + per-hour NAT + static IPs | `$ ____` |
| Support plan | % of spend or flat tier | `$ ____` |
| **Column B total** | sum | **`$ ____`** |

## Worked example (PLACEHOLDER numbers — illustrative only)

A small 6-node cluster, sustained high utilization, moderate egress.

| Line item | Column A (owned) | Column B (cloud) |
|---|---|---|
| Nodes | 6 | 6 equiv instances |
| Hardware amortized | $6,000 / 48mo = **$125/mo** | — |
| Compute | — | **$2,400/mo** |
| Power (250W/node, $0.15/kWh, PUE 1.5) | ~**$120/mo** | — |
| Rack / colo | **$400/mo** | — |
| Network / transit | **$300/mo** (committed) | — |
| Storage | **$50/mo** | **$200/mo** |
| Egress (5 TB out @ $0.08/GB) | $0 (in transit) | **$400/mo** |
| LB / NAT / IPs | **$0** | **$150/mo** |
| Managed-k8s control plane | — | **$75/mo** |
| Ops labor (20 hrs @ $100) | **$2,000/mo** | (reduced — managed) **$600/mo** |
| Support | — | **$250/mo** |
| **TOTAL** | **≈ $2,995/mo** | **≈ $4,475/mo** |

In *this* placeholder scenario owned hardware wins — but note **ops labor is the
biggest owned line item** and **egress is the biggest cloud-only line item**. Flip
utilization low, or egress to near-zero, or ops headcount up, and the columns
cross.

## Honest caveats (read before you conclude anything)

- **Utilization decides it.** Cloud bills for what you provision; owned hardware
  costs the same idle or saturated. Owned wins on *sustained high* utilization and
  loses on spiky/low utilization where cloud elasticity earns its premium.
- **Egress is the cloud's swing cost.** Heavy data-out workloads tilt strongly
  toward owned/colo. Low-egress workloads remove that advantage.
- **Ops labor is the repatriation tax.** You take on capacity planning, hardware
  lifecycle, power/cooling, and remote hands. This is exactly where the read-only
  `platform-sre` agent (Chapters 1–6) earns its keep — it's the leverage that lets
  a *small* team run owned infra without a 24/7 NOC. Budget the labor line
  honestly; don't zero it because "the agent does it."
- **Scale changes the slope.** A 6-node closet and a 600-node datacenter have very
  different per-node economics (volume hardware pricing, owned-DC overhead, staff
  amortization). Don't extrapolate this worksheet across an order of magnitude.
