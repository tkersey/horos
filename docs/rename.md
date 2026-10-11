# Boundary → Horos

Horos is the renamed Boundary package. Horos 4.0.0 introduces the canonical
shape-preserving authoring interface. Use `horos`, `horos_data`
and `horos-link`; downstream World and Agent are now Kosmos and Protean.
There are no legacy import aliases or duplicate executables.

The `boundary.*` semantic IDs and hash domains, and
`boundary-profile/v1/zig-` profile identity remain byte-for-byte unchanged.
BMO1/BPI3/PST3 and invocation grammars are unchanged. Generic ownership and
control boundaries are still called boundaries. Copyright attribution,
historical qualification links and commands, and retained operational records
keep their original spelling and claims.

Zig requires the fingerprint checksum to match the package name. Its CRC32
name checksum is now `7039c714`; the existing lineage ID `6825577e` is unchanged.
The stable 4.0.0 version marks the source-interface break. Zig computes package
hashes from the actual contents.
New outputs use Horos names. No old user state is discovered, moved or deleted.
Renamed sources may produce different build identities: restore existing tasks
with their original pinned build, never by converting or bypassing bindings.
