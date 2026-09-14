import type { ReactNode } from "react";
import { SearchField, Tabs } from "@heroui/react";

export function SoundBrowser({
  search,
  onSearch,
  kind,
  onKind,
  children,
}: {
  search: string;
  onSearch: (value: string) => void;
  kind: string;
  onKind: (value: string) => void;
  children: ReactNode;
}) {
  return (
    <div className="sound-browser">
      <SearchField aria-label="Search sounds" value={search} onChange={onSearch} fullWidth>
        <SearchField.Group>
          <SearchField.SearchIcon />
          <SearchField.Input placeholder="Search sounds" />
          <SearchField.ClearButton />
        </SearchField.Group>
      </SearchField>
      <Tabs
        selectedKey={kind}
        onSelectionChange={(key) => onKind(String(key))}
        className="sound-type-tabs"
      >
        <Tabs.ListContainer>
          <Tabs.List aria-label="Sound type">
            {["All", "Linear", "Tactile", "Clicky"].map((value) => (
              <Tabs.Tab id={value} key={value}>
                {value}
                <Tabs.Indicator />
              </Tabs.Tab>
            ))}
          </Tabs.List>
        </Tabs.ListContainer>
        <Tabs.Panel key={kind} id={kind}>
          {children}
        </Tabs.Panel>
      </Tabs>
    </div>
  );
}
