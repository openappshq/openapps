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
