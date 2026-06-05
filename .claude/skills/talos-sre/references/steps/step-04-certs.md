# Step 04: Certificate expiry → outage prediction

Use when the user asks about certs, expiry, PKI rotation, or "when will the API break".

## Show the command, then run

```bash
python3 .claude/skills/talos-sre/scripts/certs.py --cluster {cluster} [--threshold-days 30]
```

Read-only. Reads the kubeconfig admin client cert and the live kube-apiserver
serving cert, computes days-to-expiry, and prints an **outage prediction** (the
earliest control-plane cert failure = the predicted API outage window).

## Summarize

- Exit code = findings within `--threshold-days` (default 30).
- Lead with the *earliest* expiry and the predicted outage window.
- If anything is already expired, that's an active/imminent outage — escalate.

## Notes

- Talos PKI is short-lived by design; this is why the book treats cert expiry as an
  outage predictor, not a paperwork item.
- Remediation for the lab is recreate/rotate (not yet wired into `remediate.py`).
