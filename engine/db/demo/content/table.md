## Experiment question

Does increasing recall help new merchants find useful results without spending the mobile latency budget? Keep the query set and cohort definitions fixed for the full comparison window.

## Results

| Variant | Cohort | Sessions | Success | Errors | p95 latency | Revenue / session | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Control | All | 41,208 | 61.2% | 18.4% | 412ms | $2.14 | Baseline ranker, unchanged since March |
| Treatment A | All | 40,876 | 62.9% | 17.7% | 438ms | $2.31 | Recall boost on long-tail queries |
| Treatment B | All | 12,004 | 59.8% | 21.3% | 507ms | $1.96 | Reranker on top; latency cost too high |
| Control | New | 8,912 | 54.1% | 22.8% | 401ms | $1.42 | New accounts see fewer personalized results |
| Treatment A | New | 8,844 | 58.6% | 19.9% | 430ms | $1.71 | Largest lift in the whole experiment |
| Treatment B | New | 2,610 | 55.2% | 24.1% | 512ms | $1.38 | Same latency story as the pooled cohort |
| Control | Returning | 32,296 | 63.1% | 17.2% | 414ms | $2.34 | |
| Treatment A | Returning | 32,032 | 64.1% | 17.1% | 440ms | $2.47 | Small but consistent across every week |
| Treatment B | Returning | 9,394 | 61.1% | 20.5% | 505ms | $2.12 | |
| Control | Mobile | 19,441 | 57.8% | 20.6% | 486ms | $1.88 | Mobile is latency-bound before it is ranking-bound |
| Treatment A | Mobile | 19,388 | 59.9% | 19.4% | 511ms | $2.02 | Lift holds, but the latency budget is nearly spent |
| Treatment B | Mobile | 5,702 | 54.3% | 25.7% | 604ms | $1.61 | Rejected on mobile outright |

## Decision

Ship Treatment A to new accounts first. Reject Treatment B: its relevance gain does not offset the error and latency costs. Mobile rollout stays gated on a lower p95.

## Follow-up

Repeat the analysis after two weeks and inspect long-tail queries separately. Report both the pooled lift and the cohort-level tradeoffs.
