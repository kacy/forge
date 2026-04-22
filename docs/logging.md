# structured logging

`std.log` is the blessed logging layer for forge programs. it keeps the old
simple helpers, but the main path for application code is now a structured
logger with typed fields.

```fg
import std.log as log

logger := log.root()
    .with([log.str("service", "api")])
    .target("http")
    .json()

logger.info()
    .str("route", "/health")
    .int("status", 200)
    .duration_ms("elapsed_ms", 4)
    .msg("request complete")
```

## compatibility

the existing global helpers still work:

```fg
log.info("started")
log.warn_kv("cache miss", "key=user:1")
log.set_level(log.warn_level())
```

console output stays the default so local tools remain easy to read. use
`log.set_json()` globally or `log.root().json()` for newline-delimited json.

## fields and context

use typed field constructors instead of formatting key/value strings by hand:

- `log.str(key, value)`
- `log.int(key, value)`
- `log.float(key, value)`
- `log.bool(key, value)`
- `log.err(value)`
- `log.duration_ms(key, value)`

`logger.with(fields)` returns a child logger with context fields. event fields
are added fluently before `msg(...)`.

## otel-ready shape

json logs intentionally keep stable mapping points for a future first-party
otel package:

- `time` maps to otel `Timestamp`
- `level` maps to `SeverityText`
- `severity` maps to `SeverityNumber`
- `message` maps to `Body`
- `fields` maps to `Attributes`
- `trace_id` and `span_id` map to trace context fields

this module does not export to otel yet. it only makes the record shape stable
enough for that package to build on later.
