import { describe, expect, it } from "vite-plus/test";
import { products } from "../catalog";
import {
  checkoutUrl,
  DODO_CHECKOUT_ORIGINS,
  dodoConfigFrom,
  licensingFor,
  macDownloadUrlsFrom,
  officialBuilds,
} from "./licensing";

const liveEnv = {
  VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
  VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
};
const downloads = {
  openreaction: "https://downloads.example/OpenReaction.dmg",
  openklack: "https://downloads.example/OpenKlack.dmg",
};
import { activateUrl, cleanedUrl, parseCheckoutReturn, readCheckoutReturn } from "./thanks";
import { CHECKOUT_GLOBAL } from "./checkoutCapture";

describe("checkoutUrl", () => {
  it("builds Dodo's static payment link with quantity and redirect", () => {
    expect(checkoutUrl("pdt_abc", "https://openapps.space/openreaction/thanks/")).toBe(
      "https://checkout.dodopayments.com/buy/pdt_abc?quantity=1&redirect_url=https%3A%2F%2Fopenapps.space%2Fopenreaction%2Fthanks%2F",
    );
    expect(checkoutUrl("pdt_abc", "https://x/", "https://test.checkout.dodopayments.com")).toMatch(
      /^https:\/\/test\.checkout\.dodopayments\.com\/buy\/pdt_abc\?/,
    );
  });

  it("returns null for missing or malformed IDs so buttons render disabled", () => {
    expect(checkoutUrl("PLACEHOLDER_OPENREACTION_PAID", "https://x/")).toBeNull();
    expect(checkoutUrl("", "https://x/")).toBeNull();
    expect(checkoutUrl(undefined, "https://x/")).toBeNull();
    expect(checkoutUrl("pdt_a/../b", "https://x/")).toBeNull();
  });
});

describe("dodoConfigFrom", () => {
  it("reads the paid product ID per app and defaults to live checkout", () => {
    const config = dodoConfigFrom(liveEnv);
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.live);
    expect(config.products).toEqual({
      openreaction: { paid: "pdt_orPaid" },
      openklack: { paid: "pdt_okPaid" },
    });
  });

  it("uses test checkout when asked, ignoring a trailing slash and whitespace", () => {
    const config = dodoConfigFrom({
      ...liveEnv,
      VITE_DODO_CHECKOUT_ORIGIN: " https://test.checkout.dodopayments.com/ ",
    });
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.test);
    expect(Object.keys(config.products)).toHaveLength(2);
  });

  it("sells nothing when the checkout origin is not Dodo's", () => {
    const config = dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: "https://evil.example" });
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.live);
    expect(config.products).toEqual({});
    expect(dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: "///" }).products).toEqual({});
  });

  it("sells an app on its paid ID alone, skipping missing or malformed IDs", () => {
    const config = dodoConfigFrom({
      VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
      VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "not-an-id",
      VITE_OPENKLACK_DODO_TRIAL_PRODUCT_ID: "pdt_okTrial",
    });
    expect(config.products).toEqual({ openreaction: { paid: "pdt_orPaid" } });
    expect(dodoConfigFrom({}).products).toEqual({});
  });
});

describe("licensingFor", () => {
  const dodo = dodoConfigFrom(liveEnv);

  it("sells an app only when it is on sale and both its paid product and installer are set", () => {
    for (const product of products) {
      expect(officialBuilds[product.id], product.id).toBe(true);
      const licensing = licensingFor(product.id, { dodo, downloads });
      expect(licensing.officialBuildAvailable, product.id).toBe(true);
      expect(licensing.buyUrl, product.id).not.toBeNull();
      expect(licensing.downloadUrl, product.id).toBe(downloads[product.id as keyof typeof downloads]);
    }
  });

  it.each([
    ["taken off sale", { officialBuildAvailable: false }],
    ["with no paid product ID", { dodo: dodoConfigFrom({}) }],
    ["with a malformed paid product ID", { dodo: dodoConfigFrom({ VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "nope", VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "nope" }) }],
    ["with no installer URL", { downloads: {} }],
    ["with only an http installer URL", { downloads: macDownloadUrlsFrom({ VITE_OPENKLACK_MAC_DOWNLOAD_URL: "http://downloads.example/OpenKlack.dmg", VITE_OPENREACTION_MAC_DOWNLOAD_URL: "http://downloads.example/OpenReaction.dmg" }) }],
    ["on sale but with neither product nor installer", { officialBuildAvailable: true, dodo: dodoConfigFrom({}), downloads: {} }],
    ["off sale with only an installer", { officialBuildAvailable: false, dodo: dodoConfigFrom({}) }],
    ["off sale with only a product", { officialBuildAvailable: false, downloads: {} }],
  ])("fails closed %s: no checkout, no installer, not available", (_, override) => {
    for (const product of products) {
      const licensing = licensingFor(product.id, { dodo, downloads, ...override });
      expect(licensing.officialBuildAvailable, product.id).toBe(false);
      expect(licensing.buyUrl, product.id).toBeNull();
      expect(licensing.downloadUrl, product.id).toBeNull();
    }
  });

  it("reads installer URLs from the environment, https only", () => {
    expect(
      macDownloadUrlsFrom({
        VITE_OPENKLACK_MAC_DOWNLOAD_URL: ` ${downloads.openklack} `,
        VITE_OPENREACTION_MAC_DOWNLOAD_URL: downloads.openreaction,
      }),
    ).toEqual(downloads);
    for (const bad of ["", "http://x.example/a.dmg", "/OpenKlack.dmg", "javascript:alert(1)", "not a url"]) {
      expect(macDownloadUrlsFrom({ VITE_OPENKLACK_MAC_DOWNLOAD_URL: bad }), bad).toEqual({});
    }
  });

  it("links the configured product ID to the configured checkout", () => {
    const test = dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: DODO_CHECKOUT_ORIGINS.test });
    const licensing = licensingFor("openreaction", { officialBuildAvailable: true, dodo: test, downloads });
    expect(licensing.buyUrl).toMatch(/^https:\/\/test\.checkout\.dodopayments\.com\/buy\/pdt_orPaid\?/);
  });

  it("returns paid checkout to the thanks page and offers no trial checkout", () => {
    for (const product of products) {
      const licensing = licensingFor(product.id, { officialBuildAvailable: true, dodo, downloads });
      const ids = dodo.products[product.id];
      expect(ids, product.id).toBeDefined();
      expect(licensing.buyUrl, product.id).toContain(`${DODO_CHECKOUT_ORIGINS.live}/buy/${ids!.paid}?`);
      expect(licensing.thanksUrl).toBe(`https://openapps.space${product.route}/thanks/`);
      expect(licensing.buyUrl).toContain(encodeURIComponent(licensing.thanksUrl));
      expect(licensing.downloadPageUrl).toBe(`${product.route}/download/`);
      expect(licensing).not.toHaveProperty("trialUrl");
      expect(licensing).not.toHaveProperty("trialThanksUrl");
    }
  });

  it("quotes each app's own price rather than one price for the catalogue", () => {
    for (const product of products) {
      expect(product.price, product.id).toMatch(/^\$\d/);
      expect(licensingFor(product.id).price, product.id).toBe(product.price);
    }
  });

  it("rejects apps that are not in the catalog", () => {
    expect(() => licensingFor("nope")).toThrow("Unknown app");
  });
});

describe("parseCheckoutReturn", () => {
  it("reads a single key and the email", () => {
    expect(
      parseCheckoutReturn("?payment_id=pay_1&status=succeeded&license_key=LK-001&email=a%40b.c"),
    ).toEqual({
      keys: ["LK-001"],
      email: "a@b.c",
      status: "succeeded",
    });
  });

  it("splits comma-separated keys and drops blanks", () => {
    expect(parseCheckoutReturn("?license_key=LK-1,%20LK-2,,").keys).toEqual(["LK-1", "LK-2"]);
  });

  it("handles a missing key gracefully", () => {
    expect(parseCheckoutReturn("")).toEqual({ keys: [], email: null, status: null });
    expect(parseCheckoutReturn("?license_key=&email=").keys).toEqual([]);
  });
});

describe("activateUrl", () => {
  it("encodes keys with unusual characters", () => {
    expect(activateUrl("openreaction", "LK-001")).toBe("openreaction://activate?key=LK-001");
    expect(activateUrl("openklack", "a b&c=d/é")).toBe(
      "openklack://activate?key=a%20b%26c%3Dd%2F%C3%A9",
    );
  });
});

describe("readCheckoutReturn", () => {
  it("prefers what the head script captured and leaves the URL alone", () => {
    const replaceState = () => {
      throw new Error("must not touch history");
    };
    const win = {
      [CHECKOUT_GLOBAL]: { license_key: "LK-1", email: "a@b.c", status: "succeeded" },
      location: {
        search: "",
        href: "https://openapps.space/thanks/",
        pathname: "/thanks/",
        hash: "",
      },
      history: { state: null, replaceState },
    } as unknown as Window;
    expect(readCheckoutReturn(win)).toEqual({
      keys: ["LK-1"],
      email: "a@b.c",
      status: "succeeded",
    });
  });

  it("falls back to the query string and scrubs it when the head script did not run", () => {
    const replaced: string[] = [];
    const win = {
      location: {
        search: "?license_key=LK-2&status=succeeded",
        href: "https://openapps.space/openreaction/thanks/?license_key=LK-2&status=succeeded",
        pathname: "/openreaction/thanks/",
        hash: "",
      },
      history: {
        state: null,
        replaceState: (_s: unknown, _t: string, url: string) => replaced.push(url),
      },
    } as unknown as Window;
    expect(readCheckoutReturn(win).keys).toEqual(["LK-2"]);
    expect(replaced).toEqual(["/openreaction/thanks/"]);
  });
});

describe("cleanedUrl", () => {
  it("removes checkout details but keeps the path, other params and hash", () => {
    expect(
      cleanedUrl(
        "https://openapps.space/openreaction/thanks/?payment_id=p&status=succeeded&license_key=LK&email=a%40b.c",
      ),
    ).toBe("/openreaction/thanks/");
    expect(cleanedUrl("https://openapps.space/openklack/thanks/?license_key=LK&ref=x#steps")).toBe(
      "/openklack/thanks/?ref=x#steps",
    );
  });
});
