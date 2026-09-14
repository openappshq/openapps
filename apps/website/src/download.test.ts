import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import DownloadPage from "./DownloadPage";

test("download page never promises a download before an installer is configured", () => {
  const pending = renderToStaticMarkup(createElement(DownloadPage));
  expect(pending).toContain("Mac release coming soon");
  expect(pending).not.toContain("Your download should start automatically");
  expect(pending).not.toContain("download again");
  expect(pending).toContain("Star on GitHub");
  expect(pending).toContain("https://twitter.com/intent/tweet?");

  const available = renderToStaticMarkup(
    createElement(DownloadPage, { downloadUrl: "https://example.com/OpenKlack.dmg" }),
  );
  expect(available).not.toContain("Mac release coming soon");
  expect(available).toContain("Your download should start automatically");
  expect(available).toContain('href="https://example.com/OpenKlack.dmg"');
  expect(available).toContain("download again");
});
