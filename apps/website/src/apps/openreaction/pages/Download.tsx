import { ArrowDown } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { installAction } from "../../../shared/installAction";
import { licensingFor } from "../../../shared/licensing";
import { MarketingFooter, MarketingHeader } from "../../../shared/MarketingChrome";
import "../styles.css";

/* One concrete thing it did, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT = "I can type :tada anywhere on my Mac now. OpenReaction, $5, open source.";

export default function DownloadPage({
  // Only when the app's product and cask are configured; the download is a bonus.
  installCommand = licensingFor("openreaction").installCommand,
  brewCommand = licensingFor("openreaction").brewCommand,
  downloadUrl = licensingFor("openreaction").downloadUrl,
}: {
  installCommand?: string | null;
  brewCommand?: string | null;
  downloadUrl?: string | null;
}) {
  return (
    <Page
      installCommand={installCommand}
      installScriptSourceUrl={licensingFor("openreaction").installScriptSourceUrl}
      brewCommand={brewCommand}
      downloadUrl={downloadUrl}
      name="OpenReaction"
      app="openreaction"
      permission="Accessibility"
      shareText={SHARE_TEXT}
      playgroundHref="/openreaction/#try"
      playgroundLabel={
        <>
          Or try the demo first <ArrowDown size={16} aria-hidden="true" />
        </>
      }
      header={
        <MarketingHeader
          productId="openreaction"
          links={[
            { label: "Try it", href: "/openreaction/#try" },
            { label: "The Mac app", href: "/openreaction/#mac" },
            { label: "Questions", href: "/openreaction/#questions" },
          ]}
          action={installAction("openreaction")}
        />
      }
      footer={<MarketingFooter productId="openreaction" />}
    />
  );
}
