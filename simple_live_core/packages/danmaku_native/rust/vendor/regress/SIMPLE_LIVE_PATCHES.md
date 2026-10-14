Vendored from https://github.com/ridiculousfish/regress at
771e6c8fa1e472ef86c45b5206b37fa4e4494e25 (MIT OR Apache-2.0).

Local changes expose budgeted UCS-2 search with consumed-backtrack accounting,
and stop searching additional starting positions after budget exhaustion.
This preserves non-Unicode ECMAScript UTF-16 code-unit matching, including lone
surrogates, while allowing the caller to enforce a shared batch budget.

The upstream workspace section is removed so this package can be a path
dependency in the embedding crate's workspace.
