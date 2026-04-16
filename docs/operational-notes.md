# Operational Notes

Small notes for day-to-day outbox handling.

## Outbox Retry

- `pending` events are eligible for publishing when `next_retry_at` is empty or already in the past.
- On a publish error, increment `retry_count`, store `error_message`, and set a future `next_retry_at`.
- A simple stepped backoff is enough here: `1m`, `5m`, `15m`, then move to `failed`.

## Failed Events

- Move an event to `failed` after the retry limit is reached.
- Do not auto-delete failed events. They are still useful when somebody has to figure out what happened.
- Recovery can stay manual: inspect the cause, fix the dependency or payload issue, then reset the record back to `pending`.

## Stuck Processing Records

- A `processing` record with an old `locked_at` should be treated as stale.
- A worker or operator can release it by clearing lock fields and returning the record to `pending`.
- Keep the timeout longer than a normal publish attempt, but not so long that records sit stuck for hours.

## Stable Contract Fields

- Treat `messageId`, `eventType`, `aggregateType`, `aggregateId`, and `headers.schemaVersion` as stable integration fields.
- Add new fields as optional and keep existing field meanings unchanged within the same schema version.
