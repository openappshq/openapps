import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import InstallCommand from "./InstallCommand";

test("shows the exact command, a Copy button and where Homebrew comes from", () => {
  const html = renderToStaticMarkup(
    <InstallCommand command="brew install --cask openappshq/tap/openklack" />,
  );
  expect(html).toContain(
    '<code tabindex="-1">brew install --cask openappshq/tap/openklack</code>',
  );
  expect(html).toContain('<button type="button" aria-label="Copy install command"');
  expect(html).toContain("Copy</button>");
  expect(html).toContain("Requires");
  expect(html).toMatch(/<a href="https:\/\/brew\.sh" target="_blank" rel="noopener noreferrer">Homebrew/);
});
