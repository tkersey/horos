# Horos producer compatibility fixture

`horos-v1.json` was emitted by `assembleHoros` / `produceRecord` from the native
producer's actual source archive and inventory for frozen Horos commit
`2fbcc41c98887bcd6ece56060d263730394b1bc6`. The native producer executed the existing
clean package consumer before retaining these source facts. The archive has
10,694,656 bytes and SHA-256
`f1747bb1158ac9059a57c7faf960d3a3e7bd42110b794e50bcc8c9fcc025f9ee`.
Its 432-file inventory is retained here; the 10-MiB source archive is not checked
into the product repository.

Review, qualification, admission, and toolchain evidence fields are deliberately
synthetic test inputs. The evidence payload says so explicitly. This fixture has
no valid attestation and cannot be accepted by production release admission.
It proves producer/consumer schema compatibility and the recorded source facts,
not complete product qualification, review, or live publication.

Regenerate from the native producer's frozen output and Git source with:

```sh
node tools/release/make-fixture.mjs NATIVE_OUTPUT FROZEN_REPOSITORY
```

Consumers use these exact fixture bytes and their corruption variants. Actual
refresh integration separately consumes the native-produced source archive and
executes each consumer's real generation and coherence checks.
