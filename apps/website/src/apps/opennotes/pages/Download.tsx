import { ArrowDown } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { installAction } from "../../../shared/installAction";
import { licensingFor } from "../../../shared/licensing";
import { MarketingFooter, MarketingHeader } from "../../../shared/MarketingChrome";
import "../styles.css";

/* One concrete thing it does, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT =
  "My sticky notes live on the edge of the screen now, as Markdown files I own. OpenNotes, $5, open source.";

/* Nothing to grant; the default line would say Apple Silicon. */
const REQUIREMENTS = (
  <>
    macOS 14+ <span aria-hidden="true">·</span> No permissions
  </>
);

export default function DownloadPage({
  // Only when the app's product and cask are configured; the download is a bonus.
  installCommand = licensingFor("opennotes").installCommand,
  brewCommand = licensingFor("opennotes").brewCommand,
  downloadUrl = licensingFor("opennotes").downloadUrl,
}: {
  installCommand?: string | null;
  brewCommand?: string | null;
  downloadUrl?: string | null;
}) {
  return (
    <Page
      installCommand={installCommand}
      installScriptSourceUrl={licensingFor("opennotes").installScriptSourceUrl}
      brewCommand={brewCommand}
      downloadUrl={downloadUrl}
      name="OpenNotes"
      app="opennotes"
      requirements={REQUIREMENTS}
      shareText={SHARE_TEXT}
      playgroundHref="/opennotes/#deck"
      playgroundLabel={
        <>
          Or see how the deck works first <ArrowDown size={16} aria-hidden="true" />
        </>
      }
      header={
        <MarketingHeader
          productId="opennotes"
          links={[
            { label: "The deck", href: "/opennotes/#deck" },
            { label: "The Mac app", href: "/opennotes/#app" },
            { label: "Install", href: "/opennotes/#install" },
            { label: "Questions", href: "/opennotes/#questions" },
          ]}
          action={installAction("opennotes")}
        />
      }
      footer={<MarketingFooter productId="opennotes" />}
    />
  );
}
