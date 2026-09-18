import { ArrowDown } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { installAction } from "../../../shared/installAction";
import { licensingFor } from "../../../shared/licensing";
import { MarketingFooter, MarketingHeader } from "../../../shared/MarketingChrome";
import "../styles.css";

/* One concrete thing it did, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT =
  "My Mac makes its own wallpapers now, from the menu bar. macPaper, $5, open source.";

/* Nothing to grant; the default line would say Apple Silicon. */
const REQUIREMENTS = (
  <>
    macOS 14+ <span aria-hidden="true">·</span> No permissions
  </>
);

export default function DownloadPage({
  // Only when the app's product and cask are configured; the download is a bonus.
  installCommand = licensingFor("macpaper").installCommand,
  brewCommand = licensingFor("macpaper").brewCommand,
  downloadUrl = licensingFor("macpaper").downloadUrl,
}: {
  installCommand?: string | null;
  brewCommand?: string | null;
  downloadUrl?: string | null;
}) {
  return (
    <Page
      installCommand={installCommand}
      installScriptSourceUrl={licensingFor("macpaper").installScriptSourceUrl}
      brewCommand={brewCommand}
      downloadUrl={downloadUrl}
      name="macPaper"
      app="macpaper"
      requirements={REQUIREMENTS}
      shareText={SHARE_TEXT}
      playgroundHref="/macpaper/#make"
      playgroundLabel={
        <>
          Or see what it makes first <ArrowDown size={16} aria-hidden="true" />
        </>
      }
      header={
        <MarketingHeader
          productId="macpaper"
          links={[
            { label: "What it makes", href: "/macpaper/#make" },
            { label: "The Mac app", href: "/macpaper/#app" },
            { label: "Install", href: "/macpaper/#install" },
            { label: "Questions", href: "/macpaper/#questions" },
          ]}
          action={installAction("macpaper")}
        />
      }
      footer={<MarketingFooter productId="macpaper" />}
    />
  );
}
