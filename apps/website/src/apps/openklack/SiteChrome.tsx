import { installAction } from "../../shared/installAction";
import { MarketingFooter, MarketingHeader } from "../../shared/MarketingChrome";

export function SiteFooter() {
  return <MarketingFooter productId="openklack" />;
}

export function SiteHeader() {
  return (
    <MarketingHeader
      productId="openklack"
      links={[
        { label: "Try the sounds", href: "/openklack/#playground" },
        { label: "The Mac app", href: "/openklack/#desktop" },
        { label: "Questions", href: "/openklack/#questions" },
      ]}
      action={installAction("openklack")}
    />
  );
}
