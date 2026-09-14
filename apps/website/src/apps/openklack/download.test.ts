import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import DownloadPage from "./pages/Download";

test("download page never offers a file before an installer is configured", () => {
  const pending = renderToStaticMarkup(createElement(DownloadPage));
  // Same link either way; without an installer it can only point at releases.
  expect(pending).toContain("Start it manually");
  expect(pending).not.toContain("download=");
  expect(pending).toContain("/releases");

  const available = renderToStaticMarkup(
    createElement(DownloadPage, { downloadUrl: "https://example.com/OpenKlack.dmg" }),
  );
  expect(available).toContain("Start it manually");
  expect(available).toContain('href="https://example.com/OpenKlack.dmg"');
  expect(available).not.toContain("/releases");
});
