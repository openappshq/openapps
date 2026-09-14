import ThanksPage from "../../../shared/ThanksPage";
import { SiteFooter, SiteHeader } from "../SiteChrome";
import "../styles.css";

export default function TrialThanks() {
  return (
    <>
      <SiteHeader />
      <ThanksPage app="openklack" kind="trial" />
      <SiteFooter />
    </>
  );
}
