# JOIN: add a Host

JOIN is for an operator who owns the target Host. The operator creates and
keeps that Host's keys. No Genesis secrets or manual approval are required.

## Prerequisites

Add the SSH alias:

```bash
cat >> ~/.ssh/config <<'EOL'
Host <ssh-alias>
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

## Join

```bash
./gdc.sh host join [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

The command imports the public Genesis data, detects the target DNS and GPU,
creates the Host's accounts, installs the pinned release, synchronizes the
node, registers it and waits for `ACTIVE`. No configuration file is required.
When the optional GPU SSH alias is provided, the command qualifies that GPU,
configures the validator to use it and attaches its MLNode automatically.

`ACTIVE` is an onboarding state, not a successful validator join. The command
continues through a bounded four-epoch acceptance window and returns
`JOIN_PASS` only after a chain-recorded exact runtime, positive PoC weight,
positive consensus voting power and an authenticated gateway regression. Give
the joining operator a separate client credential for that final regression:

```bash
export GDC_JOIN_GATEWAY_CLIENT_KEY_FILE=/absolute/path/to/client-key
chmod 600 "$GDC_JOIN_GATEWAY_CLIENT_KEY_FILE"
GDC_OPERATOR_MODE=external-operator ./gdc.sh host join <ssh-alias>
```

The file is read locally and is never copied into the runbook state, logs or
receipt. If it is not available or is not mode `0600`, the result is
`BLOCKED`, not success. A reachable chain that has not produced the required
epoch evidence before the deadline is `INCONCLUSIVE`.

For an independent Gate A proof, run the join from this operator's clean
checkout and separate `GDC_HOME`, set `GDC_OPERATOR_MODE=external-operator`,
then share only the resulting `join-acceptance-<ssh-alias>/` evidence bundle.
Its `receipt.json` contains public chain-verifiable identifiers and no
mnemonic, keyring, client credential or private account material.

The receipt also records the epoch and reconciled positive PoC weight that
made the bounded acceptance window eligible. A Gate A observer rejects a
receipt without this evidence or with a committed total that differs from the
accepted weight sum.

If the SSH alias uses an IP address and DNS cannot be detected automatically,
pass the node's public DNS name explicitly:

```bash
./gdc.sh host join --public-host node3.gonka-dev.net gdc-node3
```

## Host lifecycle

```bash
./gdc.sh host verify <ssh-alias>
./gdc.sh host stop <ssh-alias>
./gdc.sh host start <ssh-alias>
./gdc.sh host reset <ssh-alias>
./gdc.sh host join [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

To reuse a previously validated model installation without running the ML
qualification probe again:

```bash
./gdc.sh host join --skip-qualification [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

`host reset` removes only runbook-managed services and state for that Host.
Its chain account remains owned by the operator.

If the GPU runs on another machine, see `host ml-attach` in
[ROLE-HOST.md](ROLE-HOST.md).
