# GENESIS: create the first Host

Genesis creates the network and its first Host

## Prerequisites

Add the SSH alias:

```bash
cat >> ~/.ssh/config <<'EOL'
Host gdc-node0
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

## Create the network

```bash
./gdc.sh --release v2026.07.23 genesis gdc-node0
```

The command prepares the host, detects its public DNS and GPU, creates
Genesis, starts the first Host, proves three authenticated completions, then
waits through the bounded validator-effectiveness acceptance gate. No
configuration file is required. A completed default command is therefore not
just a running container or an `ACTIVE` participant.

If the SSH alias does not map to a detectable public DNS name, provide only
that missing value:

```bash
./gdc.sh --release v2026.07.23 genesis my-host --public-host node.example.net
```

To create the chain without inference access:

```bash
./gdc.sh --release v2026.07.23 genesis gdc-node0 --no-bootstrap-access
```

This intentionally produces an incomplete setup, not a lifecycle `PASS`:
there is no authenticated-gateway or bounded effective-validator proof.

To explicitly bypass the ML qualification gate, use:

```bash
./gdc.sh --release v2026.07.23 genesis gdc-node0 --skip-qualification
```

This records `ml_qualification=skipped_by_operator` in the Genesis evidence.
Skipping the gate does not disable the later node startup and authenticated
inference checks, so a host that cannot serve the configured model will still
fail the Genesis command.

The Host publishes a checksum-protected join bundle. It contains public chain
data only, never private keys or passwords.

For recovery convenience, each cold-wallet mnemonic saved in
`$GDC_HOME/mnemonics/` has a matching mode-0600 `.address` file. The address
is public, but keeping it beside the recovery seed lets the operator identify
the wallet without importing that seed; a mismatch with the keyring stops the
run rather than overwriting the reference.
