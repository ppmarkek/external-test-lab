#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

jq -n '{app_name:"inferenced",app_version:"0.2.14",app_hash:null,chain_id:"gonka-devnet-community",initial_height:1,consensus:{params:{block:{max_bytes:"22020096",max_gas:"-1"}}},app_state:{bank:{params:{}}}}' >"$tmp/generated.json"
jq -n '{app_hash:"",chain_id:"gonka-devnet-community",initial_height:"1",consensus_params:{block:{max_bytes:"22020096",max_gas:"-1"}},app_state:{bank:{params:{}}}}' >"$tmp/public.json"

[[ "$(genesis_sha256 "$tmp/generated.json")" == "$(genesis_sha256 "$tmp/public.json")" ]] || {
  echo 'canonical Genesis lineage differs across CometBFT representations' >&2
  exit 1
}

echo 'PASS canonical Genesis lineage normalizes CometBFT representation'
