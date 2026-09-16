import { ArrowDown } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { licensingFor } from "../../../shared/licensing";
import { SiteFooter, SiteHeader } from "../SiteChrome";
import "../styles.css";

/* One concrete thing it did, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT = "I just gave my MacBook keyboard a Cherry MX Brown. OpenKlack, $5, open source.";

export default function DownloadPage({
  // Only when the app's product and cask are configured; the download is a bonus.
  installCommand = licensingFor("openklack").installCommand,
  brewCommand = licensingFor("openklack").brewCommand,
  downloadUrl = licensingFor("openklack").downloadUrl,
}: {
  installCommand?: string | null;
  brewCommand?: string | null;
  downloadUrl?: string | null;
}) {
  return (
    <Page
      installCommand={installCommand}
      installScriptSourceUrl={licensingFor("openklack").installScriptSourceUrl}
      brewCommand={brewCommand}
      downloadUrl={downloadUrl}
      name="OpenKlack"
      app="openklack"
      permission="Input Monitoring"
      shareText={SHARE_TEXT}
      playgroundHref="/openklack/#playground"
      playgroundLabel={
        <>
          Or try the sounds first <ArrowDown size={16} aria-hidden="true" />
        </>
      }
      header={<SiteHeader />}
      footer={<SiteFooter />}
    />
  );
}
