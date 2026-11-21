import { Icon, type IconName } from "./Icon";
import { Badge } from "./basics";
import type { TabId } from "../screens/types";
import "./components.css";

// Barra de pestañas flotante de vidrio (estilo iOS 26). La seleccionada va en accentfg sobre una cápsula `fill`.

const TABS: { id: TabId; label: string; icon: IconName }[] = [
  { id: "review", label: "To Review", icon: "tray" },
  { id: "mine", label: "My PRs", icon: "prbar" },
  { id: "activity", label: "Activity", icon: "gauge" },
  { id: "settings", label: "Settings", icon: "gearshape" },
];

export interface TabBarProps {
  selected: TabId;
  /** Ítems que piden acción (insignia roja en To Review). */
  reviewBadge?: number | undefined;
  onSelect: (tab: TabId) => void;
}

export function TabBar({ selected, reviewBadge = 0, onSelect }: TabBarProps) {
  return (
    <nav class="tabbar" aria-label="Tabs">
      <div class="tabbar__inner" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={t.id === selected}
            class={t.id === selected ? "tabbar__tab tabbar__tab--on" : "tabbar__tab"}
            onClick={() => onSelect(t.id)}
          >
            <span class="tabbar__icon">
              <Icon name={t.icon} size={24} />
              {t.id === "review" && <Badge count={reviewBadge} />}
            </span>
            <span class="tabbar__label">{t.label}</span>
          </button>
        ))}
      </div>
    </nav>
  );
}
