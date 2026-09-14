import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import DownloadPage from "./pages/Download";

test("download page says the release is coming soon and offers no file without an installer", () => {
  for (const downloadUrl of [undefined, null]) {
    const pending = renderToStaticMarkup(createElement(DownloadPage, { downloadUrl }));
    expect(pending).toContain("Mac release is coming soon");
    expect(pending).not.toContain("Start it manually");
    expect(pending).not.toContain("download=");
    expect(pending).not.toContain("/releases");
  }

  const available = renderToStaticMarkup(
    createElement(DownloadPage, { downloadUrl: "https://example.com/OpenKlack.dmg" }),
  );
  expect(available).toContain("Start it manually");
  expect(available).toContain('href="https://example.com/OpenKlack.dmg"');
  expect(available).not.toContain("coming soon");
  expect(available).not.toContain("/releases");
});
