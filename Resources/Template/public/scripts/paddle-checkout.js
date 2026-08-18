// Paddle Billing init/checkout loader for PaddleCheckout.astro. Served as a same-origin static
// file (rather than an Astro `is:inline define:vars` script body) so the site's CSP
// script-src 'self' policy (no 'unsafe-inline') covers it. Per-instance config comes from
// data-paddle-* attributes on #paddle-checkout-button instead of server-injected variables.
document.addEventListener("DOMContentLoaded", function () {
  var button = document.getElementById("paddle-checkout-button");
  if (!button) return;

  var clientToken = button.dataset.paddleClientToken;
  var priceId = button.dataset.paddlePriceId;

  Paddle.Initialize({ token: clientToken });
  button.addEventListener("click", function () {
    Paddle.Checkout.open({ items: [{ priceId: priceId, quantity: 1 }] });
  });
});
