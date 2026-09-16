import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import InstallCommand from "./InstallCommand";

const command = "curl -fsSL https://openapps.space/install/openklack | sh";
const sourceUrl = "https://github.com/openappshq/openapps/blob/main/apps/website/public/install/openklack";

test("shows the exact command, a Copy button, what the script does and where to read it", () => {
  const html = renderToStaticMarkup(
    <InstallCommand
      command={command}
      name="OpenKlack"
      sourceUrl={sourceUrl}
      brewCommand="brew install --cask openappshq/tap/openklack"
    />,
  );
  expect(html).toContain(`<code tabindex="-1">${command}</code>`);
  expect(html).toContain('<button type="button" aria-label="Copy install command"');
  expect(html).toContain("Copy</button>");
  expect(html).toContain("downloads the signed release, checks it, puts OpenKlack in Applications and opens it");
  expect(html).toMatch(new RegExp(`<a href="${sourceUrl}" target="_blank" rel="noopener noreferrer">Read the script`));
  // Homebrew is the alternative, under the command and not a second Copy button.
  expect(html).toContain("Prefer Homebrew? <code>brew install --cask openappshq/tap/openklack</code>");
  expect(html.indexOf(command)).toBeLessThan(html.indexOf("brew install"));
  expect(html.match(/Copy</g)).toHaveLength(1);
});

test("leaves the Homebrew line out when there is no cask to name", () => {
  const html = renderToStaticMarkup(
    <InstallCommand command={command} name="OpenKlack" sourceUrl={sourceUrl} />,
  );
  expect(html).toContain(command);
  expect(html).not.toContain("Prefer Homebrew");
  expect(html).not.toContain("brew install");
});
