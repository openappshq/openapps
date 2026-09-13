import { motion } from "motion/react";
import { enter } from "@openklack/ui/transitions";
import { useState } from "react";
import { Button } from "@heroui/react";
import { AudioLines, Check, Download, Play, Search, Square, Star } from "lucide-react";
import { packLabel, type Desktop, type Preset } from "./useDesktop";

const core = [
  "cherry-mx-brown-pbt",
  "cherry-mx-blue-pbt",
  "novelkeys-cream",
  "ibm-buckling-spring",
];

export function SoundLibrary({ desktop, preset }: { desktop: Desktop; preset: Preset }) {
  const { packs, busy, preview, audition, changePreset } = desktop;
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState("Essentials");
  const [selectedId, setSelectedId] = useState(preset.packId);
  const [favorites, setFavorites] = useState<string[]>(() => {
    try {
      const saved: unknown = JSON.parse(localStorage.getItem("openklack-favorite-packs") ?? "[]");
      return Array.isArray(saved) ? saved.filter((id): id is string => typeof id === "string") : [];
    } catch {
      return [];
    }
  });
  const selected =
    packs.find((pack) => pack.id === selectedId) ??
    packs.find((pack) => pack.id === preset.packId) ??
    packs[0];
  const filtered = packs.filter(
    (pack) =>
      (filter !== "Essentials" ||
        search.trim() ||
        core.includes(pack.originalId) ||
        pack.id === preset.packId) &&
      (filter !== "Favorites" || favorites.includes(pack.originalId)) &&
      (["Essentials", "All sounds", "Favorites"].includes(filter) || pack.kind === filter) &&
      `${packLabel(pack)} ${pack.kind} ${pack.description}`
        .toLowerCase()
        .includes(search.trim().toLowerCase()),
  );
  function favorite(id: string) {
    const next = favorites.includes(id)
      ? favorites.filter((value) => value !== id)
      : [...favorites, id];
    try {
      localStorage.setItem("openklack-favorite-packs", JSON.stringify(next));
      setFavorites(next);
    } catch {
      desktop.setError("Your favorites could not be saved. Please try again.");
    }
  }
  return (
    <section className="sound-library" aria-labelledby="library-heading">
      <div className="library-toolbar">
        <label className="sound-search">
          <Search size={19} />
          <span className="sr-only">Search sounds</span>
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search sounds, switches, makers"
            autoCorrect="off"
            spellCheck={false}
          />
        </label>
        <label className="library-filter">
          <span className="sr-only">Filter sounds</span>
          <select value={filter} onChange={(e) => setFilter(e.target.value)}>
            {["Essentials", "All sounds", "Favorites", "Linear", "Tactile", "Clicky"].map(
              (kind) => (
                <option key={kind}>{kind}</option>
              ),
            )}
          </select>
        </label>
      </div>
      <div className="library-content">
        <div className="sound-list">
          <div className="section-heading">
            <h2 id="library-heading">
              {search.trim()
                ? "Search results"
                : filter === "Essentials"
                  ? "The essentials"
                  : filter}
            </h2>
            <span className="count-label">{filtered.length} sounds</span>
          </div>
          {filtered.map((pack) => (
            <motion.article
              layout="position"
              {...enter}
              className={`sound-row ${pack.id === selected?.id ? "selected" : ""}`}
              key={pack.id}
            >
              <button
                type="button"
                className="sound-select"
                aria-pressed={pack.id === selected?.id}
                onClick={() => setSelectedId(pack.id)}
              >
                <span className="sound-tile" style={{ background: pack.color }} aria-hidden="true">
                  <AudioLines size={26} />
                </span>
                <span className="sound-row-copy">
                  <strong>{packLabel(pack)}</strong>
                  <span>
                    {pack.kind} · {pack.description}
                  </span>
                </span>
                {pack.id === preset.packId && <Check size={16} aria-label="Currently applied" />}
              </button>
              <Button
                isIconOnly
                variant="ghost"
                className="pack-favorite"
                aria-label={`${favorites.includes(pack.originalId) ? "Unfavorite" : "Favorite"} ${packLabel(pack)}`}
                aria-pressed={favorites.includes(pack.originalId)}
                onPress={() => favorite(pack.originalId)}
              >
                <Star
                  size={15}
                  fill={favorites.includes(pack.originalId) ? "currentColor" : "none"}
                />
              </Button>
              <Button
                isIconOnly
                variant="secondary"
                aria-label={`${preview === pack.id ? "Stop preview of" : "Preview"} ${packLabel(pack)}`}
                isDisabled={busy}
                onPress={() => void audition(pack.id)}
              >
                {preview === pack.id ? <Square size={16} /> : <Play size={16} />}
              </Button>
            </motion.article>
          ))}
          {filtered.length === 0 && (
            <div className="empty-state">
              <h3>
                {filter === "Favorites" && !search ? "Your favorites live here" : "No sounds match"}
              </h3>
              <p>
                {filter === "Favorites" && !search
                  ? "Star a sound to keep it close."
                  : "Try another name or clear your filters."}
              </p>
              <Button
                variant="secondary"
                onPress={() => {
                  setSearch("");
                  setFilter("All sounds");
                }}
              >
                Show all sounds
              </Button>
            </div>
          )}
          {filter === "Essentials" && !search && (
            <Button variant="ghost" className="browse-all" onPress={() => setFilter("All sounds")}>
              Explore all {packs.length} sounds <span aria-hidden="true">↗</span>
            </Button>
          )}
        </div>
        {selected && (
          <aside className="sound-inspector" aria-label="Selected sound">
            <motion.div key={selected.id} {...enter}>
              <span className="eyebrow">{selected.brand || "Your own sound"}</span>
              <h2>{selected.name}</h2>
              <p>{selected.description}</p>
              <span className="sound-kind">
                {selected.kind} · {selected.supportsKeyUp ? "Press + release" : "Press only"}
              </span>
              <div className="inspector-actions">
                <Button
                  isIconOnly
                  variant="secondary"
                  aria-label="Preview selected sound"
                  isDisabled={busy}
                  onPress={() => void audition(selected.id)}
                >
                  {preview === selected.id ? <Square size={17} /> : <Play size={17} />}
                </Button>
                <Button
                  variant="primary"
                  isDisabled={busy || selected.id === preset.packId}
                  onPress={() => void changePreset(preset.id, { packId: selected.id })}
                >
                  {selected.id === preset.packId ? (
                    <>
                      <Check size={16} />
                      Applied
                    </>
                  ) : (
                    "Apply sound"
                  )}
                </Button>
              </div>
              <p className="inspector-hint">
                {selected.id === preset.packId
                  ? `Part of ${preset.name}.`
                  : `Apply to ${preset.name}.`}{" "}
                Preview leaves your preset unchanged.
              </p>
              <details className="recording-credits">
                <summary>Recording details & credits</summary>
                <p>
                  By {selected.author}. Installed version{" "}
                  <code>{selected.version.slice(0, 12)}</code>.
                </p>
                <p>This version stays until you explicitly apply another.</p>
                <pre>{selected.credits}</pre>
              </details>
            </motion.div>
          </aside>
        )}
      </div>
      <div className="library-foot">
        <span>{packs.length} installed pack versions · Works offline</span>
        <Button variant="ghost" isDisabled={busy} onPress={() => void desktop.checkPackUpdates()}>
          <Download size={14} />
          Add bundled updates
        </Button>
      </div>
    </section>
  );
}
