# Local compatibility fork

Source: https://github.com/xiaoyaocz/dart_quickjs
Commit: a31682801e209f925cdb90fcf4e379e512b713d2.

Retains upstream sources and individual license notices (QuickJS-ng: MIT).
Adds a bounded, isolated regular-expression runtime, a UTF-16 string entry,
and warning-only build logging. The signing runtime now uses UTF-8 byte lengths,
refreshes the native stack on entry, and supports a monotonic native execution
deadline and bounded string results. Douyu signing runs in a separate isolate;
its entire evaluation shares a one-second budget and always releases its runtime.
The compatibility engine checks its deadline inside QuickJS (including regexp
execution), not through a Dart timeout. Every entry refreshes the native stack
base because a Dart isolate can migrate between operating-system threads.

The bundled C toolchain also preserves Unicode Windows environment paths,
executes native tools without shell argument corruption, and omits environment
variables from build diagnostic logs.

The iOS build excludes the unused command-line `quickjs-libc.c` std/os modules,
which depend on process APIs prohibited by the iOS SDK. The core engine and all
Dart bindings remain available; other platforms retain the upstream modules.
