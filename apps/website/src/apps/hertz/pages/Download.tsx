import { ArrowDown } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { installAction } from "../../../shared/installAction";
import { licensingFor } from "../../../shared/licensing";
import { MarketingFooter, MarketingHeader } from "../../../shared/MarketingChrome";
import "../styles.css";

/* One concrete thing it did, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT = "I can see what my Mac is doing from the menu bar now. Hertz, $5, open source.";

/* Universal binary and nothing to grant; the default line would say Apple Silicon. */
const REQUIREMENTS = (
  <>
    macOS 14+ <span aria-hidden="true">·</span> No permissions
  </>
);

export default function DownloadPage({
  // Only when the app's product and cask are configured; the download is a bonus.
  installCommand = licensingFor("hertz").installCommand,
  brewCommand = licensingFor("hertz").brewCommand,
  downloadUrl = licensingFor("hertz").downloadUrl,
}: {
  installCommand?: string | null;
  brewCommand?: string | null;
  downloadUrl?: string | null;
}) {
  return (
    <Page
      installCommand={installCommand}
      installScriptSourceUrl={licensingFor("hertz").installScriptSourceUrl}
      brewCommand={brewCommand}
      downloadUrl={downloadUrl}
      name="Hertz"
      app="hertz"
      requirements={REQUIREMENTS}
      shareText={SHARE_TEXT}
      playgroundHref="/hertz/#see"
      playgroundLabel={
        <>
          Or see what it shows first <ArrowDown size={16} aria-hidden="true" />
        </>
      }
      header={
        <MarketingHeader
          productId="hertz"
          links={[
            { label: "What it shows", href: "/hertz/#see" },
            { label: "Install", href: "/hertz/#install" },
            { label: "Questions", href: "/hertz/#questions" },
          ]}
          action={installAction("hertz")}
        />
      }
      footer={<MarketingFooter productId="hertz" />}
    />
  );
}
