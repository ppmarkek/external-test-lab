# UPGRADE: independent Host operations

An upgrade proposal author, each governance voter, and each Host operator have
separate authority. No command below needs another Host's SSH access, keyring,
or mnemonic.

## Proposal author

Render or submit the immutable `v2026.08.06` target only after the baseline
Gate B evidence is available. The proposal height must be at least 60 blocks
ahead of the live chain height.

```bash
./gdc.sh --release v2026.08.06 upgrade propose
```

Each validator owner votes from its own operator home:

```bash
./gdc.sh --release v2026.08.06 governance vote <proposal-id> yes
```

## Host operator

After the proposal has passed, each Host owner prepares only its own machine.
Preparation records canonical Genesis and proposal lineage, pre-fetches the
pinned archives into a private Host cache, and verifies their SHA-256 digests.

```bash
GDC_HOME=/absolute/operator-b \
  ./gdc.sh --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>

GDC_HOME=/absolute/operator-b \
  ./gdc.sh --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>
```

`watch` is resumable and records `PREPARED`, `WAITING_HEIGHT`, `ACTIVATED`,
`SYNCED`, then `VALIDATOR_EFFECTIVE`. A timed-out watch is `INCONCLUSIVE`; it
does not make other Hosts fail or declare a network PASS.

## Public post-upgrade gate

Save the pre-upgrade public `network verify` bundle. An independent observer
uses it to reject a new Genesis or changed participant identity set before
checking the target runtime and the complete post-upgrade public network gate:

```bash
GDC_HOME=/absolute/observer \
GDC_CHAIN_PUBLIC_BASE=https://node0.gonka-dev.net \
GDC_UPGRADE_BASELINE_EVIDENCE_DIR=/absolute/pre-upgrade/public-network-verify \
GDC_EXPECTED_TOPOLOGY_FILE=/absolute/current-run-topology.json \
GDC_EXTERNAL_JOIN_RECEIPT_DIR=/absolute/external-join-acceptance \
GDC_GATE_A_EVIDENCE_DIR=/absolute/gate-a/public-network-verify \
GDC_VERIFY_EXPECTED_ACTIVE_COUNT=5 \
  ./gdc.sh --release v2026.08.06 network upgrade verify <proposal-id>
```

Only after that public PASS may a bridge operator deploy the Genesis-specific
Sepolia contract. Its private key must be supplied solely through an absolute
mode-0600 `GDC_SEPOLIA_PRIVATE_KEY_FILE`, never through `.env` or
an argument.
