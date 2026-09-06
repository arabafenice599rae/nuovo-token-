# Frontend

A single static page for the sale: read the state, buy, claim, refund. No build
step, no framework, no package manager — `index.html`, `app.css`, `app.js`,
`config.js`, and nothing else.

```bash
# any static server works; this one is just what ships with python
python3 -m http.server -d frontend 8080
```

## Configure

Edit `config.js` after deploying and commit the result:

```js
window.SALE_CONFIG = Object.freeze({
  chainId: "0x1",
  chainName: "Ethereum",
  saleAddress: "0x…",      // the FixedSaleV4 address, not the token
  explorer: "https://etherscan.io"
});
```

The page refuses to do anything while `saleAddress` is the zero address, and
checks that the address actually holds code on the configured chain before every
transaction.

## Security model

The threat here is not a clever exploit against the contract — it is the page
itself lying to the person signing. The choices below all follow from that.

**No dependencies.** The whole ABI surface used is nine view calls and three
argument-less calls, so the encoding is written out by hand (~40 lines). There
is no npm tree, no lockfile to audit, no transitive package that can ship a
malicious update to a page that asks people to sign transactions. What you read
in `app.js` is what runs.

**Selectors cannot drift.** The hardcoded selectors are checked against the
compiled contract by `tools/check-selectors.sh` (`make check-selectors`), which
runs in CI. Rename a function in the contract and the build fails instead of the
page calling into nothing.

**The page makes no network requests.** `connect-src 'none'` in the CSP: no
CDN, no fonts, no analytics, no RPC of its own. Every read and every write goes
through the wallet's injected provider, so no third-party server ever sees which
address is looking at the page.

**Content Security Policy.** `default-src 'none'`, scripts and styles only from
the page's own origin, no inline script, no `eval`, no `innerHTML` anywhere in
the code — every piece of dynamic text goes through `textContent`.

**Clickjacking.** `frame-ancestors 'none'` is in the meta CSP, but meta tags
cannot enforce it, so `app.js` also refuses to run inside a frame. When serving
this page, send the real headers as well:

```
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
```

**Wrong-chain and wrong-address guards.** Before any transaction the page checks
`eth_chainId` against the configured chain (offering a switch), and
`eth_getCode` at the sale address. A typo, a stale config or a wallet on another
network surfaces as a refusal here, not as ETH sent into nothing.

**No approvals, ever.** The sale takes native ETH, so the page never asks for an
ERC-20 approval — the single most abused signature in this space. If a page
claiming to be this one asks you to approve a token, it is not this one.

**Money never touches a float.** Amounts are `BigInt` end to end; parsing and
formatting are fixed-point. The quote shown before a purchase mirrors the
contract's own arithmetic, including the clamp on the last purchase and the fee
taken from what is actually spent.

**No keys, no storage.** The page never sees a private key, writes nothing to
`localStorage`, sets no cookies, and keeps no state between reloads.

## What it still cannot protect you from

- **A malicious copy.** Anyone can host these files with a different
  `saleAddress`. Check the address on the page against a source you trust before
  sending anything — that is why it is displayed rather than hidden.
- **A compromised wallet or extension.** Everything is signed there.
- **The contract itself.** The sale is not audited; see the repository README.

## Deploying

The directory is fully static, so it can go anywhere that serves files: IPFS
(content-addressed, which makes the exact bytes verifiable), GitHub Pages, or a
plain web server with the headers above. Keep `config.js` in the deployed copy,
and prefer publishing the same commit that the contract was deployed from.
