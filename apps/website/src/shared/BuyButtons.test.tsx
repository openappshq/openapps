import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import { products } from "../catalog";
import BuyButtons from "./BuyButtons";

test("app pages offer the download with its trial and a priced purchase, and no trial checkout", () => {
  for (const product of products) {
    const html = renderToStaticMarkup(<BuyButtons app={product.id} />);
    expect(html, product.id).toContain(`href="${product.route}/download/"`);
    expect(html, product.id).toContain(`Buy for ${product.price}`);
    expect(html, product.id).toContain("Free 3-day trial, no signup");
    expect(html, product.id).not.toMatch(/try free|thanks\/trial/i);
  }
});

test("without a configured product and installer, Buy is a coming-soon plate, not a checkout link", () => {
  // The test environment sets no VITE_ product IDs or installer URLs.
  for (const product of products) {
    const html = renderToStaticMarkup(<BuyButtons app={product.id} />);
    expect(html, product.id).toContain("Coming soon");
    expect(html, product.id).toContain('aria-disabled="true"');
    expect(html, product.id).not.toContain("dodopayments.com");
  }
});
