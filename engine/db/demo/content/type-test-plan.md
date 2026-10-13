## Acceptance checks

| Case | Action | Expected result |
| --- | --- | --- |
| Happy path | Accept a valid invitation | One membership, correct role |
| Duplicate tap | Accept twice | Same membership returned |
| Expiration | Accept after expiry | Clear expiration message |
| Offline | Disconnect during acceptance | Pending state; recover on reconnect |

## Browser coverage

- [ ] Wide desktop viewport
- [ ] Narrow mobile viewport
- [ ] Keyboard-only acceptance
- [ ] Light and dark appearance

## Evidence

Record the receipt ID and final membership count for each case. Keep screenshots of the pending and expired states with the test run.
