import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import { paidProducts } from "../catalog";
import BuyButtons from "./BuyButtons";
import { dodoConfigFrom, licensingFor } from "./licensing";

const dodo = dodoConfigFrom({
  VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
  VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
});
const casks = {
  openreaction: "openappshq/tap/openreaction",
  openklack: "openappshq/tap/openklack",
};
const downloads = {
  openreaction: "https://downloads.example/OpenReaction.dmg",
  openklack: "https://downloads.example/OpenKlack.dmg",
};

test("app pages offer the install with its trial and a priced purchase, and no trial checkout", () => {
  for (const product of paidProducts) {
    const html = renderToStaticMarkup(<BuyButtons app={product.id} />);
    expect(html, product.id).toContain(`href="${product.route}/download/"`);
    expect(html, product.id).toContain(`Buy for ${product.price}`);
    expect(html, product.id).toContain("Free 3-day trial, no signup");
    expect(html, product.id).not.toMatch(/try free|thanks\/trial/i);
  }
});

test("without a configured product and cask, Buy is a coming-soon plate, not a checkout link", () => {
  // The test environment sets no VITE_ product IDs or casks.
  for (const product of paidProducts) {
    const html = renderToStaticMarkup(<BuyButtons app={product.id} />);
    expect(html, product.id).toContain("Coming soon");
    expect(html, product.id).toContain('aria-disabled="true"');
    expect(html, product.id).toContain("Install with Homebrew");
    expect(html, product.id).not.toContain("Download for Mac");
    expect(html, product.id).not.toContain("brew install");
    expect(html, product.id).not.toContain("dodopayments.com");
  }
});

test("with a product and cask, the brew command is shown with a Copy button and Buy is live", () => {
  for (const product of paidProducts) {
    const licensing = licensingFor(product.id, { dodo, casks, downloads: {} });
    const html = renderToStaticMarkup(<BuyButtons app={product.id} licensing={licensing} />);
    expect(html, product.id).toContain(
      `<code tabindex="-1">brew install --cask ${casks[product.id as keyof typeof casks]}</code>`,
    );
    expect(html, product.id).toContain('aria-label="Copy install command"');
    expect(html, product.id).toContain('href="https://brew.sh"');
    expect(html, product.id).toContain("Requires");
    expect(html, product.id).toContain(`href="${licensing.buyUrl!.replace("&", "&amp;")}"`);
    expect(html, product.id).toContain("dodopayments.com");
    expect(html, product.id).not.toContain("Coming soon");
    // Brew is the only way in: no button points at a page that repeats the command.
    expect(html, product.id).not.toContain(`href="${product.route}/download/"`);
    expect(html, product.id).not.toContain("Download for Mac");
  }
});

test("with a direct download too, the Download button stays beside the brew command", () => {
  for (const product of paidProducts) {
    const licensing = licensingFor(product.id, { dodo, casks, downloads });
    const html = renderToStaticMarkup(<BuyButtons app={product.id} licensing={licensing} />);
    expect(html, product.id).toContain("brew install --cask");
    expect(html, product.id).toContain(`href="${product.route}/download/"`);
    expect(html, product.id).toContain("Download for Mac");
    expect(html, product.id).not.toContain("Install with Homebrew");
    expect(html, product.id).not.toContain("Coming soon");
  }
});

test("a direct download alone never opens Buy", () => {
  for (const product of paidProducts) {
    const licensing = licensingFor(product.id, { dodo, casks: {}, downloads });
    const html = renderToStaticMarkup(<BuyButtons app={product.id} licensing={licensing} />);
    expect(html, product.id).toContain("Coming soon");
    expect(html, product.id).not.toContain("brew install");
    expect(html, product.id).not.toContain("dodopayments.com");
  }
});
