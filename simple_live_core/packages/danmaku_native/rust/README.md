# Native danmaku engine

The Dart worker owns each session exclusively. Never call the same handle
concurrently, dispose it with a native call in flight, or retain a returned
buffer after `dm_free_buffer`. `include/danmaku_native.h` is the ABI contract.
Every exported function guards against Rust unwinding across the C boundary.
Pointers must still satisfy the ordinary C ABI validity/ownership requirements.

## Build and verify

Use the pinned `rust-toolchain.toml` and committed `Cargo.lock`:

```sh
cargo test --lib --locked
cargo clippy --all-targets --locked -- -D warnings
cargo build --release --locked
```

Flutter/Dart packaging is owned by the parent package's build hook. This crate
does not open sockets, start threads, log environment variables, or manage app
lifecycle. Android linker/API configuration is provided by that hook.

## CBOR version 1

CBOR maps use text keys. **Every user-controlled string** (message, nickname,
super-chat fields, keyword and regex) is an even-length UTF-16LE **byte string**,
not CBOR text. This retains lone surrogate code units across the ABI. Diagnostic
strings and protocol operation names are CBOR text. Integers remain integers;
in particular Douyin ACK `logId` is never converted through a signed Dart value.

- `dm_create`: protocol `0` filter/encode only, `1` Bilibili, `2` Douyu,
  `3` Huya, `4` Douyin. `dm_reset` clears consecutive malformed-payload state,
  retaining installed filters.
- Decode input is the raw WebSocket binary payload. Result:
  `{v:1, events:[...], acks:[bytes], diagnostics:[text], fatal:bool}`.
  Events preserve wire order. ACKs are complete wire payloads and should be sent
  immediately for the still-current connection before scheduling filtering.
- Chat: `{type:0,user:bytes,text:bytes,color:uint24}`.
- Online: `{type:2,online:int64}`.
- Super-chat: `{type:3,user:bytes,text:bytes,color:uint24,sc:{user:bytes,
  face:bytes,text:bytes,price:int64,start:int64,end:int64,background:bytes,
  bottom:bytes}}`. `start`/`end` are epoch milliseconds.
- Install rules: `{v:1,version:uint64,rules:[{regex:bool,text:bytes}]}`.
  Result: `{v:1,version,unsupported:[index],invalid:[],blocked:bool,
  diagnostics:[text]}`. The caller validates syntax with Dart at compile time;
  any pattern regress cannot compile is reported for controlled ECMAScript
  compatibility evaluation. Such rules are **not evaluated by the native
  filter**, so the caller must apply them before publishing kept messages.
- Filter: `{v:1,version:uint64,texts:[bytes]}` ->
  `{v:1,version,keep:[bool],quarantined:bool,diagnostics:[text]}`. Version mismatch
  is an error. A budget failure rejects the entire batch and quarantines that
  rules version until another successful install. Diagnostics are emitted once.
- Encode: `{v:1,kind:'bili',text:bytes,operation:uint32}`, or
  `{v:1,kind:'douyu',text:bytes}`, or
  `{v:1,kind:'huya_join',ayyuid:int64,top:int64,sub:int64}` ->
  `{v:1,wire:bytes}`. Bilibili/Douyu wire text is UTF-8; encoding replaces lone
  surrogates, matching Dart's UTF-8 encoder. No internal text/filter conversion
  replaces surrogate units.

All output buffers, including nonzero-status diagnostic results, must be freed.
Statuses: `0` success, `1` malformed payload, `2` resource limit, `3` invalid
request, `4` caught panic. When status is nonzero inspect diagnostics and `fatal`.
A length-valid frame with a bad inner message retains other valid messages.
Bad framing stops the current payload. Three consecutive framing failures or
any resource limit requests a connection reset; a valid payload clears the
consecutive-failure count. Reconnection/backoff is the Dart owner's job.

## Bounds

WebSocket input is limited to 4 MiB; aggregate inflated data and output to
16 MiB; compression depth to 4; JSON/CBOR/TARS/protobuf-group depth to 32.
CBOR rules requests may use up to 16 MiB. Filters accept up to 2,000 rules,
4,096 UTF-16 units per rule, 1 MiB aggregate UTF-16 rule text, and 200 messages/
1 MiB per batch. The aggregate rule cap bounds matcher construction memory;
oversized sets are quarantined with a diagnostic while their stored text is
retained. Regex execution
has 100,000 backtracks per rule/search and 1,000,000 shared per batch. Exceeding
rule limits blocks that rules version; the Dart side must retain stored rules
and present the diagnostic rather than truncate or pass through messages.

Protocol fixtures and adversarial cases are in `src/tests.rs`. `vendor/regress`
retains upstream licenses and documents its pinned commit and local patch.
Differential Dart/ECMAScript tests and app lifecycle/queue tests belong to the
parent package; native microbenchmarks alone do not establish device power or
temperature improvements.
