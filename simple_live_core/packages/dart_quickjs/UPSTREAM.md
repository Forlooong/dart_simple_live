# Local compatibility fork

Source: https://github.com/xiaoyaocz/dart_quickjs
Commit: a31682801e209f925cdb90fcf4e379e512b713d2.

Retains upstream sources and individual license notices (QuickJS-ng: MIT).
Adds a bounded, isolated regular-expression runtime, a UTF-16 string entry,
and warning-only build logging. Existing signing runtime APIs are unchanged.
The compatibility engine checks its deadline inside QuickJS (including regexp
execution), not through a Dart timeout. Every entry refreshes the native stack
base because a Dart isolate can migrate between operating-system threads.

The bundled C toolchain also preserves Unicode Windows environment paths,
executes native tools without shell argument corruption, and omits environment
variables from build diagnostic logs.

The iOS build excludes the unused command-line `quickjs-libc.c` std/os modules,
which depend on process APIs prohibited by the iOS SDK. The core engine and all
Dart bindings remain available; other platforms retain the upstream modules.
