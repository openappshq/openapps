import { ArrowDown } from "lucide-react";
import Page from "../../../shared/DownloadPage";
import { SiteFooter, SiteHeader } from "../SiteChrome";
import "../styles.css";

/* One concrete thing it did, the price, the licence. No hashtags, no
   adjectives, nothing a person would not actually say. */
const SHARE_TEXT = "I just gave my MacBook keyboard a Cherry MX Brown. OpenKlack, $5, open source.";

export default function DownloadPage({
  downloadUrl = import.meta.env.VITE_OPENKLACK_MAC_DOWNLOAD_URL,
}: {
  downloadUrl?: string;
}) {
  return (
    <Page
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
