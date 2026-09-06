"use strict";

// Minimal client for FixedSaleV4.
//
// Deliberately dependency-free: the ABI surface used here is a handful of view
// calls and four argument-less calls, so hand-rolled encoding costs ~60 lines
// and removes the entire npm supply chain from a page that asks people to sign
// transactions.
//
// Selectors are hardcoded and checked against the compiled contract by
// tools/check-selectors.sh, which runs in CI: they cannot drift silently.

(function () {
  const SEL = Object.freeze({
    buy: "0xa6f2ae3a", // buy()
    claim: "0x4e71d92d", // claim()
    refund: "0x590e1ae3", // refund()
    finalize: "0x4bb278f3", // finalize()
    totalSold: "0x9106d7ba", // totalSold()
    saleSupply: "0xa96af0f4", // saleSupply()
    pricePerToken: "0x7b1b1de6", // pricePerToken()
    saleDeadline: "0x888ea120", // saleDeadline()
    softCapTokens: "0x897cb036", // softCapTokens()
    finalized: "0xb3f05b97", // finalized()
    token: "0xfc0c546a", // token()
    feeBps: "0xbf333f2c", // FEE_BPS()
    finalizeGrace: "0x37dd150f", // FINALIZE_GRACE()
    purchased: "0x522fe98e", // purchased(address)
    contributed: "0x995c5e9d", // contributed(address)
    symbol: "0x95d89b41", // symbol()
    name: "0x06fdde03" // name()
  });

  const WEI = 10n ** 18n;
  const BPS = 10000n;
  const ZERO = "0x0000000000000000000000000000000000000000";

  const cfg = window.SALE_CONFIG || {};
  const $ = (id) => document.getElementById(id);

  let provider = null;
  let account = null;
  let sale = null; // on-chain state, amounts as BigInt
  let quote = null; // { value, spend, tokens, fee, toPool, clamped }
  let pending = null; // hash of a transaction being watched
  const POLL_MS = 15000; // background refresh while the tab is visible
  const RECEIPT_MS = 3000;

  // ---------------------------------------------------------------- helpers

  function isAddress(value) {
    return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);
  }

  function encodeAddressArg(address) {
    return address.slice(2).toLowerCase().padStart(64, "0");
  }

  function decodeUint(hex) {
    if (typeof hex !== "string" || !hex.startsWith("0x") || hex.length < 66) {
      throw new Error("unexpected call result");
    }
    return BigInt(hex.slice(0, 66));
  }

  function decodeAddress(hex) {
    return "0x" + hex.slice(26, 66);
  }

  function decodeBool(hex) {
    return decodeUint(hex) === 1n;
  }

  // ABI string: offset, length, then the bytes. Control characters are stripped
  // and bad data yields "" rather than throwing — this text comes from a
  // contract and is only ever written to the page with textContent.
  function decodeString(hex) {
    try {
      const body = hex.slice(2);
      const offset = Number(BigInt("0x" + body.slice(0, 64))) * 2;
      const length = Number(BigInt("0x" + body.slice(offset, offset + 64)));
      const bytes = body.slice(offset + 64, offset + 64 + length * 2);
      const buf = new Uint8Array(Math.floor(bytes.length / 2));
      for (let i = 0; i < buf.length; i++) buf[i] = parseInt(bytes.slice(i * 2, i * 2 + 2), 16);
      // Solidity strings are UTF-8: decoding byte by byte turns "Citt\u00e0" into
      // "CittÃ ". Invalid sequences become U+FFFD instead of throwing.
      const out = new TextDecoder("utf-8").decode(buf);
      // C0/C1 controls plus the zero-width and bidi-override characters, which a
      // name chosen by whoever deployed the contract must not smuggle onto the page.
      return out.replace(/[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, "").trim().slice(0, 32);
    } catch (err) {
      return "";
    }
  }

  // Fixed point end to end: money never goes through a float. Ungrouped, so the
  // result can go straight back into an input the parser will read again.
  function plainUnits(value, decimals, maxFractionDigits) {
    const base = 10n ** BigInt(decimals);
    const negative = value < 0n;
    const abs = negative ? -value : value;
    let frac = (abs % base).toString().padStart(decimals, "0");
    if (typeof maxFractionDigits === "number") frac = frac.slice(0, maxFractionDigits);
    frac = frac.replace(/0+$/, "");
    return (negative ? "-" : "") + (abs / base).toString() + (frac ? "." + frac : "");
  }

  // The same number grouped in thousands: for display only.
  function formatUnits(value, decimals, maxFractionDigits) {
    const text = plainUnits(value, decimals, maxFractionDigits);
    const dot = text.indexOf(".");
    const whole = dot === -1 ? text : text.slice(0, dot);
    return whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + (dot === -1 ? "" : text.slice(dot));
  }

  // A comma is the decimal separator in most of Europe, and phone keypads offer
  // whichever one the locale picked: accept both rather than quoting nothing.
  function parseEther(input) {
    const text = String(input).trim().replace(",", ".");
    if (!/^\d*\.?\d*$/.test(text) || text === "" || text === ".") return null;
    const parts = text.split(".");
    const whole = parts[0];
    const frac = parts[1] || "";
    if (frac.length > 18) return null;
    return BigInt(whole || "0") * WEI + BigInt((frac || "0").padEnd(18, "0"));
  }

  const NO_FLASH = { countdown: true, status: true };

  // Values fade in only when they actually change: no pulse on every repaint,
  // and none at all for the ticking countdown.
  function setText(id, text) {
    const el = $(id);
    const next = String(text);
    if (el.textContent === next) return;
    el.textContent = next;
    if (NO_FLASH[id]) return;
    el.classList.remove("tick");
    void el.offsetWidth; // restart the animation
    el.classList.add("tick");
  }

  function status(message, tone) {
    const el = $("status");
    el.textContent = message;
    if (tone) el.dataset.tone = tone;
    else delete el.dataset.tone;
  }

  function now() {
    return BigInt(Math.floor(Date.now() / 1000));
  }

  function busy(state) {
    $("app").setAttribute("aria-busy", state ? "true" : "false");
  }

  // ------------------------------------------------------------------- rpc

  async function request(method, params) {
    if (!provider) throw new Error("No wallet detected. Install an EIP-1193 wallet to continue.");
    return provider.request({ method: method, params: params || [] });
  }

  async function call(to, data) {
    return request("eth_call", [{ to: to, data: data }, "latest"]);
  }

  const callSale = (selector, arg) => call(cfg.saleAddress, arg ? selector + arg : selector);

  // Refuses to act on the wrong chain rather than letting the wallet decide.
  async function assertChain() {
    const current = await request("eth_chainId");
    if (String(current).toLowerCase() !== String(cfg.chainId).toLowerCase()) {
      try {
        await request("wallet_switchEthereumChain", [{ chainId: cfg.chainId }]);
      } catch (err) {
        throw new Error("Wrong network. Switch your wallet to " + cfg.chainName + " and try again.");
      }
    }
  }

  // The configured address must hold code: a typo, a wrong network or a
  // not-yet-deployed sale surfaces here instead of as a lost transaction.
  async function assertDeployed() {
    const code = await request("eth_getCode", [cfg.saleAddress, "latest"]);
    if (!code || code === "0x" || code === "0x0") {
      throw new Error("No contract at " + cfg.saleAddress + " on " + cfg.chainName + ".");
    }
  }

  // ------------------------------------------------------------------ reads

  async function readSale() {
    const results = await Promise.all([
      callSale(SEL.totalSold), callSale(SEL.saleSupply), callSale(SEL.pricePerToken),
      callSale(SEL.saleDeadline), callSale(SEL.softCapTokens), callSale(SEL.finalized),
      callSale(SEL.token), callSale(SEL.feeBps), callSale(SEL.finalizeGrace)
    ]);

    const token = decodeAddress(results[6]);
    const meta = await Promise.all([call(token, SEL.symbol), call(token, SEL.name)]);

    sale = {
      totalSold: decodeUint(results[0]),
      saleSupply: decodeUint(results[1]),
      price: decodeUint(results[2]),
      deadline: decodeUint(results[3]),
      softCap: decodeUint(results[4]),
      finalized: decodeBool(results[5]),
      token: token,
      feeBps: decodeUint(results[7]),
      grace: decodeUint(results[8]),
      symbol: decodeString(meta[0]) || "TOKEN",
      name: decodeString(meta[1]) || "",
      purchased: 0n,
      contributed: 0n
    };

    if (account) {
      const arg = encodeAddressArg(account);
      const mine = await Promise.all([callSale(SEL.purchased, arg), callSale(SEL.contributed, arg)]);
      sale.purchased = decodeUint(mine[0]);
      sale.contributed = decodeUint(mine[1]);
    }
  }

  // ------------------------------------------------------------- predicates

  const soldOut = (s) => s.totalSold >= s.saleSupply;
  const open = (s) => !s.finalized && !soldOut(s) && now() < s.deadline;

  function canFinalize(s) {
    if (s.finalized) return false;
    return soldOut(s) || (now() >= s.deadline && s.totalSold >= s.softCap);
  }

  function canRefund(s) {
    if (s.finalized || now() < s.deadline) return false;
    if (s.totalSold >= s.softCap && now() < s.deadline + s.grace) return false;
    return s.contributed > 0n;
  }

  function countdown(deadline) {
    const left = deadline - now();
    if (left <= 0n) return "ENDED";
    const pad = (v) => String(v).padStart(2, "0");
    return pad(left / 86400n) + "d " + pad((left % 86400n) / 3600n) + ":"
      + pad((left % 3600n) / 60n) + ":" + pad(left % 60n);
  }

  // ----------------------------------------------------------------- render

  function render() {
    setText("sale-addr", cfg.saleAddress || "—");
    setText("network", (cfg.chainName || "—") + " " + (cfg.chainId || ""));
    const link = $("sale-link");
    if (cfg.explorer && isAddress(cfg.saleAddress) && cfg.saleAddress !== ZERO) {
      link.href = cfg.explorer.replace(/\/+$/, "") + "/address/" + cfg.saleAddress;
    } else {
      link.removeAttribute("href");
    }

    $("connect").textContent = account ? account.slice(0, 6) + "…" + account.slice(-4) : "Connect";
    $("connect").disabled = Boolean(account);

    if (!sale) {
      // Nothing read yet: keep every write path shut rather than half-enabled.
      $("buy").disabled = true;
      $("claim").disabled = true;
      $("refund").disabled = true;
      $("finalize").disabled = true;
      return;
    }

    setText("symbol", sale.symbol);
    setText("token-name", sale.name || "—");
    setText("tokens-unit", sale.symbol);
    setText("price", formatUnits(sale.price, 18, 18) + " ETH");
    setText("price-unit", "per " + sale.symbol);
    setText("finalized-flag", String(sale.finalized));

    const pct = sale.saleSupply === 0n ? 0 : Number((sale.totalSold * 10000n) / sale.saleSupply) / 100;
    $("meter-fill").style.width = Math.min(pct, 100) + "%";
    $("meter").setAttribute("aria-label", pct.toFixed(2) + "% of the sale supply sold");
    setText("pct", pct.toFixed(1) + "%");
    setText("sold", formatUnits(sale.totalSold, 18, 0));
    setText("supply", " / " + formatUnits(sale.saleSupply, 18, 0));
    setText("softcap", formatUnits(sale.softCap, 18, 0) + " " + sale.symbol);
    setText("countdown", sale.finalized ? "MIGRATED" : countdown(sale.deadline));

    setText("claim-value", sale.purchased > 0n ? formatUnits(sale.purchased, 18, 2) : "—");
    setText("refund-value", canRefund(sale) ? formatUnits(sale.contributed, 18, 4) + " ETH" : "—");
    setText("finalize-value", sale.finalized ? "Done" : canFinalize(sale) ? "Ready" : "—");

    $("buy").disabled = Boolean(account) && !(open(sale) && quote);
    $("buy").textContent = account ? "Buy" : "Connect to Buy";
    $("claim").disabled = !(sale.finalized && sale.purchased > 0n && account);
    $("refund").disabled = !(canRefund(sale) && account);
    $("finalize").disabled = !(canFinalize(sale) && account);
  }

  function tick() {
    if (sale && !sale.finalized) setText("countdown", countdown(sale.deadline));
  }

  // ------------------------------------------------------------------ quote

  // Mirrors buy(): tokens are floor(value * 1e18 / price), clamped to what is
  // left, and the fee comes out of what is actually spent.
  function updateQuote() {
    quote = null;
    setText("tokens-out", "0");
    setText("fee-note", "—");
    setText("pool-note", "");

    if (!sale) return;
    const value = parseEther($("amount").value);
    if (value === null || value === 0n) {
      render();
      return;
    }

    const remaining = sale.saleSupply - sale.totalSold;
    let tokens = (value * WEI) / sale.price;
    let spend = value;
    let clamped = false;
    if (tokens > remaining) {
      tokens = remaining;
      spend = (tokens * sale.price) / WEI;
      clamped = true;
    }
    const fee = (spend * sale.feeBps) / BPS;

    setText("tokens-out", formatUnits(tokens, 18, 2));
    if (tokens === 0n) {
      setText("fee-note", "too small: this buys zero tokens");
      render();
      return;
    }

    quote = { value: value, spend: spend, tokens: tokens, fee: fee, toPool: spend - fee, clamped: clamped };
    setText("fee-note", Number(sale.feeBps) / 100 + "% fee included");
    setText("pool-note", "≈ " + formatUnits(spend - fee, 18, 4) + " ETH to pool"
      + (clamped ? " · rest refunded" : ""));
    render();
  }

  // One wei more than the nominal cost: a wei buys 1e5 token units and the
  // remaining supply is not a multiple of that, so the last fraction needs it.
  function fillMax() {
    if (!sale) return;
    const remaining = sale.saleSupply - sale.totalSold;
    if (remaining <= 0n) return;
    $("amount").value = plainUnits((remaining * sale.price) / WEI + 1n, 18, 18);
    updateQuote();
  }

  // ------------------------------------------------------------------ write

  async function send(data, value) {
    await assertChain();
    await assertDeployed();
    const tx = { from: account, to: cfg.saleAddress, data: data };
    if (value !== undefined) tx.value = "0x" + value.toString(16);
    // No gas or fee fields: the wallet estimates and the user sees the result.
    const hash = await request("eth_sendTransaction", [tx]);
    status("pending " + hash.slice(0, 10) + "…");
    watch(hash);
    return hash;
  }

  // Watch the transaction to completion so the page updates itself instead of
  // asking the user to come back and refresh.
  async function watch(hash) {
    pending = hash;
    for (let i = 0; i < 200 && pending === hash; i++) {
      await new Promise((resolve) => setTimeout(resolve, RECEIPT_MS));
      let receipt = null;
      try {
        receipt = await request("eth_getTransactionReceipt", [hash]);
      } catch (err) {
        continue; // transient provider error: keep waiting
      }
      if (!receipt) continue;
      pending = null;
      status(receipt.status === "0x1" ? "confirmed" : "reverted", receipt.status === "0x1" ? undefined : "error");
      if (receipt.status === "0x1") $("amount").value = "";
      await quietRefresh();
      return;
    }
    // The poll gave up before the receipt landed. Release the lock, or the
    // background refresh stays parked and the page freezes until a reload.
    if (pending === hash) {
      pending = null;
      status("still pending — check the explorer", "error");
      await quietRefresh();
    }
  }

  // Keeps the numbers alive without touching the status line or throwing at
  // the user when a single poll fails.
  async function quietRefresh() {
    try {
      if (!isAddress(cfg.saleAddress) || cfg.saleAddress === ZERO) return;
      await readSale();
      updateQuote();
      render();
    } catch (err) {
      /* transient: the next tick tries again */
    }
  }

  async function withErrors(fn) {
    try {
      status("");
      await fn();
    } catch (err) {
      const message = (err && (err.message || (err.data && err.data.message))) || String(err);
      status(message, "error");
    }
  }

  // ------------------------------------------------------------------- boot

  async function connect() {
    const accounts = await request("eth_requestAccounts");
    account = accounts && accounts[0] ? accounts[0] : null;
    if (!account) throw new Error("No account returned by the wallet.");
    await assertChain();
    await refresh();
  }

  async function refresh() {
    if (!isAddress(cfg.saleAddress) || cfg.saleAddress === ZERO) {
      status("not configured: set saleAddress in config.js", "error");
      render();
      return;
    }
    busy(true);
    try {
      await assertDeployed();
      await readSale();
      updateQuote();
      render();
    } finally {
      busy(false);
    }
  }

  function wire() {
    $("connect").addEventListener("click", () => withErrors(connect));
    $("max").addEventListener("click", fillMax);
    $("amount").addEventListener("input", updateQuote);

    $("buy").addEventListener("click", () => withErrors(async () => {
      if (!account) return connect();
      if (!quote) throw new Error("Enter an amount first.");
      await send(SEL.buy, quote.value);
    }));
    $("claim").addEventListener("click", () => withErrors(() => send(SEL.claim)));
    $("refund").addEventListener("click", () => withErrors(() => send(SEL.refund)));
    $("finalize").addEventListener("click", () => withErrors(() => send(SEL.finalize)));

    if (provider && provider.on) {
      provider.on("accountsChanged", (accounts) => {
        account = accounts && accounts[0] ? accounts[0] : null;
        withErrors(refresh);
      });
      provider.on("chainChanged", () => window.location.reload());
    }

    setInterval(tick, 1000);

    // Poll only while the tab is in front, and catch up as soon as it is.
    setInterval(function () {
      if (document.visibilityState === "visible" && !pending) quietRefresh();
    }, POLL_MS);
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "visible") quietRefresh();
    });
  }

  function start() {
    // Clickjacking guard: the CSP frame-ancestors directive is ignored in a
    // meta tag, so refuse to run framed regardless of how the page is served.
    if (window.top !== window.self) {
      $("blocked").hidden = false;
      return;
    }
    $("app").hidden = false;

    provider = window.ethereum || null;
    wire();
    render();

    if (!provider) {
      status("no wallet detected", "error");
      return;
    }
    withErrors(async () => {
      const accounts = await request("eth_accounts"); // does not prompt
      account = accounts && accounts[0] ? accounts[0] : null;
      await refresh();
    });
  }

  document.addEventListener("DOMContentLoaded", start);
})();
