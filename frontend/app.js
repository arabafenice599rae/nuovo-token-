"use strict";

// Minimal client for FixedSaleV4.
//
// Deliberately dependency-free: the whole ABI surface used here is nine view
// calls and three payable/nonpayable calls with no arguments, so hand-rolled
// encoding costs ~40 lines and removes the entire npm supply chain from a page
// that asks people to sign transactions.
//
// Selectors are hardcoded and checked against the compiled contract by
// tools/check-selectors.sh, which runs in CI: they cannot drift silently.

(function () {
  const SEL = Object.freeze({
    buy: "0xa6f2ae3a", // buy()
    claim: "0x4e71d92d", // claim()
    refund: "0x590e1ae3", // refund()
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
    contributed: "0x995c5e9d" // contributed(address)
  });

  const WEI = 10n ** 18n;
  const BPS = 10000n;
  const ZERO = "0x0000000000000000000000000000000000000000";

  const cfg = window.SALE_CONFIG || {};
  const $ = (id) => document.getElementById(id);

  let provider = null;
  let account = null;
  let sale = null; // on-chain state, all BigInt
  let quote = null; // { value, tokens, fee, clamped }

  // ---------------------------------------------------------------- utilities

  function isAddress(value) {
    return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);
  }

  function pad32(hexNo0x) {
    return hexNo0x.padStart(64, "0");
  }

  function encodeAddressArg(address) {
    return pad32(address.slice(2).toLowerCase());
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

  // Fixed-point formatting: money never goes through a float.
  function formatUnits(value, decimals, maxFractionDigits) {
    const base = 10n ** BigInt(decimals);
    const negative = value < 0n;
    const abs = negative ? -value : value;
    const whole = abs / base;
    let frac = (abs % base).toString().padStart(decimals, "0");
    if (typeof maxFractionDigits === "number") frac = frac.slice(0, maxFractionDigits);
    frac = frac.replace(/0+$/, "");
    const grouped = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return (negative ? "-" : "") + grouped + (frac ? "." + frac : "");
  }

  function parseEther(input) {
    const text = String(input).trim();
    if (!/^\d*\.?\d*$/.test(text) || text === "" || text === ".") return null;
    const [whole, frac = ""] = text.split(".");
    if (frac.length > 18) return null;
    return BigInt(whole || "0") * WEI + BigInt((frac || "0").padEnd(18, "0"));
  }

  function shortAddress(address) {
    return address.slice(0, 6) + "…" + address.slice(-4);
  }

  function setText(id, text) {
    $(id).textContent = text;
  }

  function status(message, tone) {
    const el = $("status");
    el.textContent = message;
    if (tone) el.dataset.tone = tone;
    else delete el.dataset.tone;
  }

  // ------------------------------------------------------------------- rpc

  async function request(method, params) {
    if (!provider) throw new Error("No wallet detected. Install an EIP-1193 wallet to continue.");
    return provider.request({ method: method, params: params || [] });
  }

  async function callSale(selector, argHex) {
    const data = argHex ? selector + argHex : selector;
    return request("eth_call", [{ to: cfg.saleAddress, data: data }, "latest"]);
  }

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

  // The configured address must actually hold code: a typo, a wrong network or
  // a not-yet-deployed sale all show up here instead of as a lost transaction.
  async function assertDeployed() {
    const code = await request("eth_getCode", [cfg.saleAddress, "latest"]);
    if (!code || code === "0x" || code === "0x0") {
      throw new Error("No contract at " + cfg.saleAddress + " on " + cfg.chainName + ".");
    }
  }

  // ------------------------------------------------------------------ reads

  async function readSale() {
    const [
      totalSold, saleSupply, pricePerToken, saleDeadline, softCapTokens,
      finalized, tokenAddr, feeBps, grace
    ] = await Promise.all([
      callSale(SEL.totalSold), callSale(SEL.saleSupply), callSale(SEL.pricePerToken),
      callSale(SEL.saleDeadline), callSale(SEL.softCapTokens), callSale(SEL.finalized),
      callSale(SEL.token), callSale(SEL.feeBps), callSale(SEL.finalizeGrace)
    ]);

    sale = {
      totalSold: decodeUint(totalSold),
      saleSupply: decodeUint(saleSupply),
      price: decodeUint(pricePerToken),
      deadline: decodeUint(saleDeadline),
      softCap: decodeUint(softCapTokens),
      finalized: decodeBool(finalized),
      token: decodeAddress(tokenAddr),
      feeBps: decodeUint(feeBps),
      grace: decodeUint(grace),
      purchased: 0n,
      contributed: 0n
    };

    if (account) {
      const arg = encodeAddressArg(account);
      const [purchased, contributed] = await Promise.all([
        callSale(SEL.purchased, arg),
        callSale(SEL.contributed, arg)
      ]);
      sale.purchased = decodeUint(purchased);
      sale.contributed = decodeUint(contributed);
    }
  }

  // ----------------------------------------------------------------- render

  function phaseOf(s) {
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (s.finalized) return { label: "Migrated — tokens claimable", tone: "closed", canBuy: false };
    if (s.totalSold >= s.saleSupply) return { label: "Sold out — awaiting migration", tone: "warn", canBuy: false };
    if (now >= s.deadline) {
      const met = s.totalSold >= s.softCap;
      return {
        label: met ? "Closed — awaiting migration" : "Closed below the soft cap — refunds open",
        tone: met ? "warn" : "closed",
        canBuy: false
      };
    }
    return { label: "Open", tone: "open", canBuy: true };
  }

  function refundable(s) {
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (s.finalized || now < s.deadline) return false;
    if (s.totalSold >= s.softCap && now < s.deadline + s.grace) return false;
    return s.contributed > 0n;
  }

  function render() {
    const link = (id, address) => {
      const a = $(id);
      if (cfg.explorer && isAddress(address) && address !== ZERO) {
        a.href = cfg.explorer.replace(/\/+$/, "") + "/address/" + address;
      } else {
        a.removeAttribute("href");
      }
    };

    setText("sale-addr", cfg.saleAddress || "—");
    link("sale-link", cfg.saleAddress);
    setText("network", cfg.chainName + " (" + cfg.chainId + ")");

    if (!sale) {
      // Nothing read yet: keep every write path shut rather than half-enabled.
      $("buy").disabled = true;
      $("claim").disabled = true;
      $("refund").disabled = true;
      return;
    }

    setText("token-addr", sale.token);
    link("token-link", sale.token);
    setText("price", formatUnits(sale.price, 18, 18) + " ETH per token");

    const phase = phaseOf(sale);
    const phaseEl = $("phase");
    phaseEl.textContent = phase.label;
    phaseEl.dataset.tone = phase.tone;

    const pct = sale.saleSupply === 0n ? 0 : Number((sale.totalSold * 10000n) / sale.saleSupply) / 100;
    const capPct = sale.saleSupply === 0n ? 0 : Number((sale.softCap * 10000n) / sale.saleSupply) / 100;
    $("meter-fill").style.width = Math.min(pct, 100) + "%";
    $("meter-cap").style.left = Math.min(capPct, 100) + "%";
    $("meter").setAttribute("aria-label", pct.toFixed(2) + "% of the sale supply sold");

    setText("sold", formatUnits(sale.totalSold, 18, 2) + " / " + formatUnits(sale.saleSupply, 18, 2)
      + " (" + pct.toFixed(2) + "%)");
    setText("softcap", formatUnits(sale.softCap, 18, 2));
    setText("deadline", new Date(Number(sale.deadline) * 1000).toLocaleString());

    setText("account", account ? shortAddress(account) : "not connected");
    setText("purchased", formatUnits(sale.purchased, 18, 4) + " tokens");
    setText("contributed", formatUnits(sale.contributed, 18, 6) + " ETH");

    $("buy").disabled = !phase.canBuy || !account || !quote;
    $("claim").disabled = !(sale.finalized && sale.purchased > 0n && account);
    $("refund").disabled = !(refundable(sale) && account);
    $("connect").disabled = Boolean(account);
    $("connect").textContent = account ? "Connected" : "Connect wallet";
  }

  // ------------------------------------------------------------------ quote

  // Mirrors buy(): tokens are floor(value * 1e18 / price), clamped to what is
  // left, and the fee is taken from what is actually spent.
  function updateQuote() {
    quote = null;
    setText("q-tokens", "—");
    setText("q-fee", "—");
    setText("quote-note", "");

    if (!sale) return;
    const value = parseEther($("amount").value);
    if (value === null || value === 0n) {
      if ($("amount").value.trim() !== "") setText("quote-note", "Enter an amount in ETH, up to 18 decimals.");
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

    quote = { value: value, tokens: tokens, fee: fee, spend: spend, clamped: clamped };
    setText("q-tokens", formatUnits(tokens, 18, 6) + " tokens");
    setText("q-fee", formatUnits(fee, 18, 6) + " ETH (" + Number(sale.feeBps) / 100 + "%)");
    if (tokens === 0n) {
      setText("quote-note", "Too small: this buys zero tokens and the contract would reject it.");
      quote = null;
    } else if (clamped) {
      setText("quote-note", "Only " + formatUnits(remaining, 18, 6)
        + " tokens are left: the contract spends " + formatUnits(spend, 18, 18)
        + " ETH and returns the rest in the same transaction.");
    }
    render();
  }

  // One wei more than the nominal cost: a wei buys 1e5 token units and the
  // remaining supply is not a multiple of that, so the last fraction needs it.
  function fillMax() {
    if (!sale) return;
    const remaining = sale.saleSupply - sale.totalSold;
    if (remaining <= 0n) return;
    const cost = (remaining * sale.price) / WEI + 1n;
    $("amount").value = formatUnits(cost, 18, 18).replace(/,/g, "");
    updateQuote();
  }

  // ------------------------------------------------------------------ writes

  async function send(data, value) {
    await assertChain();
    await assertDeployed();
    const tx = { from: account, to: cfg.saleAddress, data: data };
    if (value !== undefined) tx.value = "0x" + value.toString(16);
    // No gas or fee fields: the wallet estimates and the user sees the result.
    const hash = await request("eth_sendTransaction", [tx]);
    status("Sent: " + hash, "ok");
    return hash;
  }

  async function withErrors(fn) {
    try {
      status("");
      await fn();
    } catch (err) {
      const message = err && (err.message || err.data && err.data.message) || String(err);
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
      status("This page is not configured yet: set saleAddress in config.js.", "error");
      render();
      return;
    }
    await assertDeployed();
    await readSale();
    updateQuote();
    render();
  }

  function wire() {
    $("connect").addEventListener("click", () => withErrors(connect));
    $("refresh").addEventListener("click", () => withErrors(refresh));
    $("max").addEventListener("click", fillMax);
    $("amount").addEventListener("input", updateQuote);

    $("buy").addEventListener("click", () => withErrors(async () => {
      if (!quote) throw new Error("Enter an amount first.");
      await send(SEL.buy, quote.value);
    }));
    $("claim").addEventListener("click", () => withErrors(async () => {
      await send(SEL.claim);
    }));
    $("refund").addEventListener("click", () => withErrors(async () => {
      await send(SEL.refund);
    }));

    if (provider && provider.on) {
      provider.on("accountsChanged", (accounts) => {
        account = accounts && accounts[0] ? accounts[0] : null;
        withErrors(refresh);
      });
      provider.on("chainChanged", () => window.location.reload());
    }
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
      status("No wallet detected. The page still shows nothing it cannot read.", "error");
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
