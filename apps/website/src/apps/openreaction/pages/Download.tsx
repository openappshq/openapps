import { ArrowDown, Download } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { MarketingFooter, MarketingHeader } from "../../../shared/MarketingChrome";
import "../styles.css";

/* One concrete thing it did, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT = "I can type :tada anywhere on my Mac now. OpenReaction, $5, open source.";

export default function DownloadPage({
  downloadUrl = import.meta.env.VITE_OPENREACTION_MAC_DOWNLOAD_URL,
}: {
  downloadUrl?: string;
}) {
  return (
    <Page
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
          action={{
            label: "Download for Mac",
            href: "/openreaction/download/",
            icon: <Download size={16} />,
          }}
        />
      }
      footer={<MarketingFooter productId="openreaction" />}
    />
  );
}
