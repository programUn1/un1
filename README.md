# Un1corn (UN1)

10,000 pixel fragments from Bitcoin’s first 10,000 blocks. Collect them on Ethereum, compose parts that fit and make a
UN1 of your own.

This repository holds the contracts and the source bundle of the UN1 Programmable Custom Launch.
Website: [un1.art](https://un1.art) · X: [@UN1hook](https://x.com/UN1hook) · Review notes: [REVIEW.md](REVIEW.md)

## Contracts

| Contract | Role |
|---|---|
| `src/UN1Token.sol` | Un1corn (UN1): ERC-20 with units (cards, pending slots, plain tokens), PoolManager gate (swap allowances per direction, liquidity allowances netted), draw credit, dealing and measurement, pruning, composition and the composition chain, rewards accumulator, work guard, `revoke`, coin metadata in the FoundationTokenV1 layout (`metadata()`, `metadataHash()`) |
| `src/UN1Hook.sol` | Hook of the official UN1 / UNI pool: fees in UNI with halving, allowances, launch protection (canonical router, 2% per buyer, 30-second opening fee, six opening-fee exemptions besides the developer), bounty reserve and per-round budget, fee claims |
| `src/UN1Beacon.sol` | Reveal against drand quicknet signatures, bounty, block-hash fallback after one day; a round's randomness is fixed once it starts (infrastructure, bound to the token's predicted address) |
| `src/UN1Distributor.sol` | `sync` (7/8 : 1/8), `claim` / `claimFor`, permanent bid |
| `src/UN1Mirror.sol` | ERC-721 / ERC-4906 view of the cards (collection Un1corn) |
| `src/UN1Seeder.sol` | One-time launch: opening valuation check (Chainlink UNI / USD, at least USD 15,000), pool, the supply in a token-only range, the required launch buy (delivered to the developer as plain tokens), UNI left over as a locked bid; every position locked forever |
| `src/UN1Renderer.sol` | On-chain SVG and tokenURI (infrastructure) |
| `src/libraries/` | Appearance, Deal (dealing permutation), DrandRound, DrandBeacon, FeeMath, Polish (art v7), Buf |
| `src/data/` | UN1MasksData, UN1PartsData (generated data contracts) |

The launch graph deploys Token, Hook, Distributor, Mirror and Seeder. Renderer, the two data contracts and Beacon are
deployed beforehand through the deterministic CREATE2 proxy (EIP-7825 caps a transaction at 2^24 gas). The token and the
hook check at initialization that the beacon is bound to this token; a missing or misbound beacon reverts the launch.

## Build and test

Solidity `0.8.26+commit.8a97fa7a` with Foundry; compile target `cancun`, test EVM `prague` (EIP-2537); no CBOR metadata
(`foundry.toml`). Dependencies are git submodules: v4-core v4.0.0 (the mainnet PoolManager's version, with solmate),
OpenZeppelin Contracts v5.6.1, forge-std v1.9.7.

```sh
git clone --recurse-submodules https://github.com/programUn1/un1.git
cd un1 && forge build
forge test -j 1                    # mainnet fork tests are skipped without ETH_RPC_URL
ETH_RPC_URL=<rpc> forge test -j 1  # with them (read only: nothing is broadcast)
```

Some tests read generated fixtures from the parent workspace (`../data/computed`, `../art/exports`); the Standard JSON
input in `launch-build/` reproduces the build without them. Reports are generated single-threaded (`-j 1`).

| File | Covers | Tests |
|---|---|---|
| `test/OnlyHook.t.sol` | only the official pool deals cards; no other v4 pool can move UN1; UNI fees in four directions; permissions | 15 |
| `test/LaunchProtection.t.sol` | launch protection: buys only through the canonical router, 2% per buyer and per recipient, the 30-second opening fee to the platform, the launch buy counted as the developer's | 13 |
| `test/LaunchBuyAndExemptions.t.sol` | the launch buy as plain tokens (`LAUNCH_BUY` only on the first swap), six opening-fee exemptions (no opening fee, the same 2% caps, bad lists rejected) | 7 |
| `test/Metadata.t.sol` | names and the FoundationTokenV1 metadata layout; `metadataHash` checked against a live FoundationTokenV1 (fork) | 3 |
| `test/ForkProtection.t.sol` | mainnet fork: the real canonical router names the buyer, an older router cannot buy during protection, multi-hop, the 2% cap, router-simulated quotes, the Chainlink opening valuation | 6 |
| `test/Cards.t.sol` | part data, appearance against the reference, dealing permutation, target rounds, leave order, transfers across whole tokens, decoherence, mirror transfers and approvals, account kinds, gas per unit, invariant fuzzing | 26 |
| `test/Reveal.t.sol` | real drand signatures, reveal order, fallback, bounty and per-round budget | 16 |
| `test/Compose.t.sol` | composition rules, appearance and details, retiring and burning, the composition chain, the light proof, works back in the pool, works leave last, halving | 14 |
| `test/Rewards.t.sol` | the 7/8 : 1/8 split, one-day stream, weight × time, same-block trades earn nothing, optIn, carry, claimFor, permanent bid, exact conservation | 15 |
| `test/Render.t.sol` | 46 cases byte for byte against the reference renderer, tokenURI, worst-case gas | 5 |
| `test/Fork.t.sol` | mainnet fork: launch, real Universal Router single and multi hop, real drand, EIP-2935, rewards and the permanent bid | 7 |
| `test/ForkEdge.t.sol` | V4Quoter, aggregator-style routing, UniswapX Permit2, direct PoolManager calls, ERC-6909, a real Safe, real EIP-7702 | 10 |
| `test/ForkRehearsal.t.sol` | launch rehearsal: a stand-in factory in six combinations, the real Graph Factory (including a misbound beacon reverting), infrastructure, token address prediction, permissions | 14 |
| `test/Preflight.t.sol` | Programmable static admission: compiler, CBOR, banned opcodes, sizes, hook permissions, initializer permissions, beacon binding | 10 |
| `test/Findings.t.sol` | findings of the code review (K-1, K-2, K-4, K-5, K-6, K-7, G-1) | 16 |
| `test/Algorithms.t.sol` | the dealing permutation covers every id, walk gas, drand target rounds 15–44 seconds | 3 |
| `test/WebVectors.t.sol` | Universal Router encoding vectors for the website | 1 |
| `test/review/` | regressions from external reviews (18 files) | 49 |

`test/utils/Base.sol` is the local base: a local PoolManager, a mock UNI and every UN1 contract, with the test contract as
the initial holder; `_fulfill` reveals with chosen randomness in place of the beacon (`Reveal.t.sol` uses the real
UN1Beacon and real signatures). `test/fixtures/fork.json` pins the fork block and that round's drand signature.

## Reports

`reports/test-results.txt` and `reports/gas-report.txt` are the raw outputs of the full suite on a read-only mainnet fork;
`reports/env.txt` records how they were produced and `reports/manifest.sha256` the exact sources they cover. Earlier
reports are kept in `reports/history/`.

## Source bundle

The repository root is the root of the Programmable source bundle: `foundry.toml`, `remappings.txt`, `src/`,
`launch-build/un1.standard-json.json`, the graph artifacts in `launch-build/artifacts/`, the test and gas evidence in
`launch-build/evidence/` and the project image `launch-build/assets/un1.png` (also at
`ipfs://bafkreieulpcs7d7rqzf537rcphmgzgcgmbrf3dkuuxqvfn2gfkmpxg2rou` and `https://un1.art/un1corn.png`). The evidence
refers to the reports in `reports/`. Files are stored byte for byte (`.gitattributes`: no line-ending conversion).

## License

MIT, as declared in the SPDX headers in `src/`.
