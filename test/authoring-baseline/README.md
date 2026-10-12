These 42 canonical BPI3 files were emitted by Horos revision
`f245dfc92b4b13412e84b1a7ece73da3e6d39305` with Zig 0.17.0:

```sh
zig build emit-examples -Doptimize=safe
```

They preserve the declaration and operation schedule of the pre-migration source
examples. `check-semantics` compares the successor's complete images with these
independent baseline bytes. A source-breaking authoring change does not authorize
regenerating these files. Semantic results are also checked by the independent
source oracle and by Kosmos native/WASM source agreement.

`src/data/testdata/record-unions.bin` captures 396 deterministic union records from the same baseline record serializer: every tag across 12 portable union families, each with four empty/populated nested payload modes. The migration differential also compared every truncation and decode budget against that serializer before removing the temporary oracle.

`src/data/testdata/opcode-records.bin` captures 96 instruction records from the baseline BPI3 grammar (all 48 opcodes, absent faults/zero immediate and possible faults/nonzero immediate). Development differential checks also compared malformed flags, lists, truncations, writer/parser positions and allocation budgets before removing the oracle.
