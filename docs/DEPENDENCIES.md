# Offline dependencies and provenance

No dependency requires `npm install`, a Git submodule, a package registry, a CDN, or a network connection at build/test time.

| Dependency | Pinned version | Committed files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.1.0 | `lib/openzeppelin-contracts/contracts/access/{Ownable,Ownable2Step}.sol`, `utils/Context.sol` | MIT, license included |
| forge-std | v1.9.7 | `lib/forge-std/src/` | MIT / Apache-2.0, both included |
| ethers | 6.13.5 | `web/vendor/ethers.min.js` (ES module distribution) | MIT, `ethers.LICENSE.md` included |

Sources:

- [OpenZeppelin v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0)
- [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7)
- [ethers 6.13.5](https://www.npmjs.com/package/ethers/v/6.13.5), extracted from the published tarball's `dist/ethers.min.js`.

The production interfaces were checked against [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) and the [official registry source at b9e466c250744a7e06b13dff9d3c2844ed64f825](https://github.com/erc-8004/erc-8004-contracts/tree/b9e466c250744a7e06b13dff9d3c2844ed64f825). AgentSkill does not vendor or deploy these upstream registry implementations. Test mocks implement the relevant interface semantics without claiming to be production registries.

Solidity 0.8.26, Foundry, Python and Node are execution tools, not vendored binaries. Compiler resolution is by the version pinned in `foundry.toml`. The dashboard uses native browser APIs and a local/system font stack; no external fonts or raster assets are needed.
