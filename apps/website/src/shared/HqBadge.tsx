/** "An OpenApps HQ original" pill with the HQ tile, linking to the studio home. */
export default function HqBadge() {
  return (
    <a className="hq-badge" href="/" aria-label="An OpenApps HQ original - see all apps">
      <img src="/brand/openapps-hq/app-icon.svg" alt="" width="18" height="18" />
      An OpenApps HQ original
    </a>
  );
}
