import { Download } from "lucide-react";
import { MarketingHeader } from "../../shared/MarketingChrome";
export { MarketingFooter as SiteFooter } from "../../shared/MarketingChrome";

export function SiteHeader() {
  return (
    <MarketingHeader
      productId="openklack"
      links={[
        { label: "Try the sounds", href: "/OpenKlack/#playground" },
        { label: "The Mac app", href: "/OpenKlack/#desktop" },
        { label: "Questions", href: "/OpenKlack/#questions" },
      ]}
      action={{
        label: "Download for Mac",
        href: "/OpenKlack/download/",
        icon: <Download size={16} />,
      }}
    />
  );
}
