# Community DevNet runbook

## TLDL

Add the SSH alias:

```bash
cat >> ~/.ssh/config <<'EOL'
Host <ssh-alias>
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

Setup network:

```bash
git clone git@github.com:paranjko/external-test-lab.git
cd external-test-lab/net-deployment-runbook

gdc --release v2026.07.23 genesis gdc-node0
gdc host join gdc-node1
gdc host join gdc-node2
gdc host join gdc-node3
gdc host join gdc-node4 gdc-node4-ml # node net only + gpu net
```

## Overview

This package recreates a Gonka Community DevNet for release and
distributed-behaviour testing, the clean baseline is `v2026.07.23` with
chain ID `gonka-devnet-community`

The `community-lab` deployment profile intentionally uses a 90-block epoch
with a 20-block PoC generation and 10-block exchange window.  This is a
reproducible lab timing profile (not a release-default claim): it gives an
MLNode enough time to return an artifact and still reserves a complete
confirmation-PoC lifecycle.  Genesis rendering rejects timing combinations
that cannot fit that lifecycle.

Choose the document for your role, each role has separate authority and keeps
only the credentials it actually needs

| Role | Document | Owns | Must not own |
| --- | --- | --- | --- |
| OPS | [ROLE-OPS.md](ROLE-OPS.md) | [gonka-dev.net](https://gonka-dev.net/), Prometheus and the reference Telegram inference consumer | Genesis mnemonic, validator keys, Host accounts, gateway creator/admin keys |
| GENESIS | [ROLE-GENESIS.md](ROLE-GENESIS.md) | first validator, chain genesis, public bootstrap, faucet and initial access | later Host private keys |
| JOIN | [ROLE-JOIN.md](ROLE-JOIN.md) | one validator, its accounts, identity and ML permission | Genesis and other Host secrets |
| HOST | [ROLE-HOST.md](ROLE-HOST.md) | an active Host, its Network Node, MLNode and governance key | another Host's keys or OPS credentials |
| GATEWAY | [ROLE-GATEWAY.md](ROLE-GATEWAY.md) | gateway runtime, escrow creator and client-key pool | Host governance keys or public-observation administration |
| DEVELOPER | [ROLE-DEVELOPER.md](ROLE-DEVELOPER.md) | an application and its client API key | any infrastructure or signer credential |

Use [UPGRADE.md](UPGRADE.md) for the separate proposal-author, voter, Host
operator and public-observer upgrade flow.

`OPS` is an observation service, not a network controller, node collectors are
installed by `GENESIS` or the relevant `JOIN` operator, `OPS` scrapes published
endpoints and the website reads live chain participants, a down endpoint is
shown as down, a configured inventory entry is never treated as evidence that
it joined the chain

## Public network observer

Any observer can verify public chain and participant state without an OPS
`.env`, SSH access, account files, mnemonics or a Genesis operator home:

```bash
GDC_HOME=/absolute/observer-evidence \
GDC_CHAIN_PUBLIC_BASE=https://node0.gonka-dev.net \
GDC_EXPECTED_TOPOLOGY_FILE=/absolute/current-run-topology.json \
GDC_EXTERNAL_JOIN_RECEIPT_DIR=/absolute/external-join-acceptance \
GDC_VERIFY_EXPECTED_ACTIVE_COUNT=2 \
  ./gdc.sh --release v2026.07.23 network verify
```

The command binds its receipt to canonical Genesis, reads ACTIVE participants,
consensus voting power, exact model runtime identities, public endpoint
convergence and current PoC weights from chain state. It reports `BLOCKED` if
the required confirmation-PoC profile is absent and `INCONCLUSIVE` until a
complete public confirmation-PoC event lineage and its next-epoch application
can be proved; neither outcome is a network PASS. Gate A requires the
independent operator's current-lineage `JOIN_PASS` receipt. Gate B additionally
requires `GDC_GATE_A_EVIDENCE_DIR` pointing to the completed public Gate A
bundle and uses `GDC_VERIFY_EXPECTED_ACTIVE_COUNT=5`; it cannot be started from
Genesis-owner self-attestation alone.

`GDC_EXPECTED_TOPOLOGY_FILE` is a sanitized, current-run roster shared with
the public observer. It prevents an unrelated set of similarly configured
ACTIVE participants from satisfying a topology count. It contains no secret,
but must bind every Host identity to the canonical Genesis:

```json
{
  "schema_version": 1,
  "chain_id": "gonka-devnet-community",
  "genesis_sha256": "<canonical-sha256>",
  "participants": [
    {
      "address": "gonka1...",
      "validator_key": "<consensus-public-key>",
      "public_host": "node1.example.net",
      "runtime_id": "qwen3-0.6b:gonka1...",
      "model_id": "Qwen/Qwen3-0.6B"
    }
  ]
}
```

The observer requires exactly the requested number of unique entries and
matches address, validator key and public host against live chain state. The
external Gate A receipt must name one of those same identities.
