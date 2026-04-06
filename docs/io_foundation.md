# io foundation

this branch is about giving forge one io vocabulary that the rest of the stdlib
can share.

right now the stdlib has a few different styles:
- `std.fs` is whole-file and path-based
- `std.net.tcp` is fd-based
- `std.os.process` is handle-based
- `std.io` is basically just stdin prompts

that works for small modules, but it doesn't scale into a great standard
library. every protocol or format layer ends up reinventing the same loops.

## the target

we want something closer to the best parts of go's `io` package:
- tiny interfaces
- reusable helpers
- transports and formats layered on the same contracts
- easy testing with in-memory adapters

we should not copy go blindly, though. forge has different constraints:
- result types are explicit
- interfaces are best used as compile-time bounds today
- a lot of runtime io is string-based right now, not bytes-based
- plain structs are value types, so mutable adapters need care

## phase one shape

phase one is intentionally small:
- `Reader`
- `Writer`
- `Closer`
- `Flusher`
- `read_all`
- `write_all`
- `copy`
- handle-backed in-memory adapters for testing and composition

the first cut stays string-oriented:
- `fn read(max_bytes: Int) -> String!`
- `fn write(data: String) -> Int!`

that matches the runtime we already have. it also lets us start unifying code
in tcp, process, http, and future stdlib modules right away.

## why the in-memory adapters are handle-backed

forge structs are value types today. that means a helper like `copy(reader,
writer)` can't rely on mutating a caller-owned struct field and having that
mutation show up back at the call site.

for phase one, the practical workaround is simple: keep the adapter state in
module-level tables and pass around tiny wrapper structs that only hold a
handle. that gives us stable, observable state without waiting on reference
parameters or a bigger ownership model.

it's not the final shape forever, but it's a solid bridge.

## what makes this worth doing

once the core exists, a lot of stdlib work gets cheaper:
- http parsing and body handling can share read helpers
- websocket framing can sit on reader/writer contracts
- process pipelines can reuse copy loops
- future file streaming can plug into the same interfaces
- tests get easier because adapters are cheap to fake

the big win is consistency. new stdlib modules stop inventing one-off io loops.

## staged path

### milestone 1

land the core interfaces, handle-backed adapters, and concrete helpers in
`std.io`.

the concrete helpers matter because they let us prove the state model now,
without depending on every cross-module interface dispatch edge being perfect
yet.

### milestone 2

add generic interface-driven helpers once that path is hardened in real code,
then wrap the current runtime surfaces:
- tcp connections
- process stdout/stderr/stdin

### milestone 3

add real file-handle streaming to the runtime and move `std.fs` beyond
whole-file helpers.

### milestone 4

add higher-level layers:
- buffered reader/writer
- line reader
- scanner-style helpers
- framed protocol helpers

### milestone 5

move higher stdlib modules onto the shared layer so the design proves itself in
real code, not just in toy examples.

## the long-term version

the long-term version should be bytes-first and protocol-friendly. but the best
way to get there is not to wait for the perfect runtime surface. it's to land a
small useful core now, then extend it in place with real users.
