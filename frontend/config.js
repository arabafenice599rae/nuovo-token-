// Deployment configuration. Edit this file after deploying, commit the result,
// and serve the directory as-is: there is no build step and nothing here is
// fetched at runtime.
//
// saleAddress must be the FixedSaleV4 address, not the token address.
window.SALE_CONFIG = Object.freeze({
  chainId: "0x1", // hex chain id the sale is deployed on (0x1 = Ethereum mainnet)
  chainName: "Ethereum",
  saleAddress: "0x0000000000000000000000000000000000000000",
  explorer: "https://etherscan.io"
});
