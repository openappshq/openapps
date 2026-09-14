import { SoundBrowser } from "@openklack/ui/sound-browser";
import "@openklack/ui/browser.css";
import { useState } from "react";
import { Button } from "@heroui/react";
import { Check, Play, Square, Star } from "lucide-react";
import { packLabel, type Desktop, type Preset } from "./useDesktop";

const core = ["novelkeys-cream", "cherry-mx-blue-pbt", "topre-unknown", "ibm-buckling-spring"];

export function SoundLibrary({ desktop, preset }: { desktop: Desktop; preset: Preset }) {
  const { packs, busy, preview } = desktop;
  const [browse, setBrowse] = useState(false);
  const [search, setSearch] = useState("");
  const [kind, setKind] = useState("All");
  const favorites = desktop.snapshot!.preferences.favoritePackIds ?? [];
  const starting = [
    ...new Set([
      preset.packId,
      ...favorites,
      ...core.map((id) => packs.find((p) => p.originalId === id)?.id).filter(Boolean),
    ]),
  ];
  const visible = packs
    .filter(
      (pack) =>
        (browse || starting.slice(0, Math.max(4, favorites.length + 1)).includes(pack.id)) &&
        (kind === "All" || pack.kind === kind) &&
        `${packLabel(pack)} ${pack.kind}`.toLowerCase().includes(search.trim().toLowerCase()),
    )
    .sort((a, b) => Number(favorites.includes(b.id)) - Number(favorites.includes(a.id)));
  const choices = (
    <div
      className={`sound-choices ${browse ? "expanded" : ""}`}
      role="group"
      aria-label="Sounds"
      tabIndex={browse ? 0 : undefined}
    >
      {visible.map((pack) => (
        <div className={`sound-choice ${pack.id === preset.packId ? "active" : ""}`} key={pack.id}>
          <Button
            variant="ghost"
            type="button"
            className="choose-sound"
            data-static=""
            isDisabled={busy}
            aria-pressed={pack.id === preset.packId}
            aria-label={`Use ${packLabel(pack)}`}
            onPress={() => {
              if (pack.id !== preset.packId)
                void desktop.changePreset(preset.id, { packId: pack.id });
            }}
          >
            <span>
              <strong>{pack.name === "Unknown" ? "Classic" : pack.name}</strong>
              <small>
                {pack.brand}
                {pack.source === "" ? " · Imported" : ""}
              </small>
            </span>
            {pack.id === preset.packId && <Check size={17} aria-label="In use" />}
          </Button>
          <Button
            isIconOnly
            variant="ghost"
            isDisabled={busy}
            className="star-sound"
            data-static=""
            aria-pressed={favorites.includes(pack.id)}
            aria-label={`${favorites.includes(pack.id) ? "Unstar" : "Star"} ${packLabel(pack)}`}
            onPress={() =>
              void desktop.save((p) => ({
                ...p,
                favoritePackIds: (p.favoritePackIds ?? []).includes(pack.id)
                  ? p.favoritePackIds!.filter((id) => id !== pack.id)
                  : [...(p.favoritePackIds ?? []), pack.id],
              }))
            }
          >
            <Star size={16} fill={favorites.includes(pack.id) ? "currentColor" : "none"} />
          </Button>
          <Button
            isIconOnly
            variant="ghost"
            isDisabled={busy}
            className="sound-preview"
            data-static=""
            aria-label={`${preview === pack.id ? "Stop preview of" : "Preview"} ${packLabel(pack)}`}
            onPress={() => void desktop.audition(pack.id)}
          >
            {preview === pack.id ? <Square size={16} /> : <Play className="play-glyph" size={16} />}
          </Button>
        </div>
      ))}
    </div>
  );
  return (
    <section className="sound-library" aria-labelledby="library-heading">
      <div className="section-heading">
        <h2 id="library-heading">Sounds</h2>
        <Button
          variant="ghost"
          aria-expanded={browse}
          onPress={() => {
            setBrowse(!browse);
            setSearch("");
            setKind("All");
          }}
        >
          {browse ? "Show less" : `Browse all ${packs.length}`}
        </Button>
      </div>
      {browse ? (
        <SoundBrowser search={search} onSearch={setSearch} kind={kind} onKind={setKind}>
          {choices}
        </SoundBrowser>
      ) : (
        choices
      )}
      {!visible.length && (
        <div className="empty-state">
          <p>No matching sounds.</p>
          <Button
            variant="secondary"
            onPress={() => {
              setSearch("");
              setKind("All");
            }}
          >
            Clear filters
          </Button>
        </div>
      )}
    </section>
  );
}
