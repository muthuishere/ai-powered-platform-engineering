# Step 05: Platform maturity report

Use when the user asks for a report, scorecard, grade, or "how mature is this cluster".

## Show the command, then run

```bash
python3 .claude/skills/platform-sre/scripts/report.py --cluster {cluster}
```

Runs all four read-only capabilities (health, reliability, security, certs),
converts each dimension's finding count into a 0–100 score (−15 per finding,
floored at 0), and prints a scored report with bars + letter grades. **Always
exits 0** — it's a report, not a gate.

## Summarize

- Present the table as-is; it's the headline artifact.
- Call out the weakest dimension and the single highest-impact fix.
- Offer to drill into a dimension (steps 01–04) or to remediate (step 06).

## Example shape

```
  Reliability    [######....]  60 / 100  (D)  [2 findings]
  Security       [########..]  85 / 100  (B)  [1 findings]
  Certificates   [##########] 100 / 100  (A)  [0 findings]
  Operations     [##########] 100 / 100  (A)  [0 findings]
  PLATFORM MATURITY  [########..]  86 / 100   GRADE B
```
