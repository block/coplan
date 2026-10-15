## Small table with precise comment targets

Select a cell, then press **C** or choose **Comment**. Selection alone keeps you in reading mode. The first queued status has a seeded discussion; the repeated label in the next row is a different target.

| Receipt | Status | Destination | Notes |
| --- | --- | --- | --- |
| Beta-001 | queued | [Delivery guide](https://guides.rubyonrails.org/active_job_basics.html) | Initial attempt |
| Beta-002 | queued | Email | |
| Beta-003 | delivered | Email | **Confirmed** |
| Beta-004 | expired | Email | `receipt_id` retained |

## Wide table

Expand this table to inspect the full row. Try a comment in the expanded view and return to the document.

| Cohort | Owner | Region | Requests | Delivered | Retried | Expired | Queue p95 | Delivery p95 | Duplicate memberships | Last checked | Next action |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: | --- | --- |
| Beta | Hampton | North America | 1200 | 1180 | 18 | 2 | 80 ms | 900 ms | 0 | Monday | Continue |
| Expanded | Alex | Europe | 4000 | 3950 | 45 | 5 | 110 ms | 1.2 s | 0 | Tuesday | Inspect retries |
| Mobile | Mateo | Asia Pacific | 900 | 880 | 16 | 4 | 95 ms | 1.1 s | 0 | Wednesday | Confirm offline acceptance |
