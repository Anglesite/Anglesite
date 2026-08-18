// Shopify Buy Button SDK loader for ShopifyBuyButton.astro. Served as a same-origin static
// file (rather than an Astro `is:inline define:vars` script body) so the site's CSP
// script-src 'self' policy (no 'unsafe-inline') covers it. Per-instance config comes from
// data-shopify-* attributes instead of server-injected variables.
(function () {
  var container = document.getElementById("shopify-buy-button-container");
  if (!container) return;

  var shopDomain = container.dataset.shopifyShopDomain;
  var storefrontAccessToken = container.dataset.shopifyStorefrontAccessToken;
  var productId = container.dataset.shopifyProductId;

  var scriptURL = "https://sdks.shopifycdn.com/buy-button/latest/buy-button-storefront.min.js";
  function loadScript() {
    var script = document.createElement("script");
    script.async = true;
    script.src = scriptURL;
    (document.getElementsByTagName("head")[0] || document.getElementsByTagName("body")[0]).appendChild(script);
    script.onload = ShopifyBuyInit;
  }
  function ShopifyBuyInit() {
    var client = ShopifyBuy.buildClient({ domain: shopDomain, storefrontAccessToken: storefrontAccessToken });
    ShopifyBuy.UI.onReady(client).then(function (ui) {
      ui.createComponent("product", {
        id: productId,
        node: container,
        moneyFormat: "%24%7B%7Bamount%7D%7D",
        options: { product: { contents: { img: true, title: true, price: true } } },
      });
    });
  }
  if (window.ShopifyBuy && window.ShopifyBuy.UI) {
    ShopifyBuyInit();
  } else {
    loadScript();
  }
})();
