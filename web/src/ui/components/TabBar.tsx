import { bounce } from "../motion/animate";
import { Icon, type IconName } from "./Icon";
import { Badge } from "./basics";
import type { TabId } from "../screens/types";
import "./components.css";

// Barra de pestañas flotante de vidrio (estilo iOS 26). La seleccionada va en accentfg sobre una cápsula `fill`.

// `on`: el símbolo relleno de la pestaña elegida (como en UITabBar).
const TABS: { id: TabId; label: string; icon: IconName; on: IconName }[] = [
  { id: "review", label: "To Review", icon: "tray", on: "tray.fill" },
  { id: "mine", label: "My PRs", icon: "prbar", on: "prbar" },
  { id: "activity", label: "Activity", icon: "gauge", on: "gauge.fill" },
  { id: "settings", label: "Settings", icon: "gearshape", on: "gearshape.fill" },
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
            onClick={(e) => {
              // Un rebote corto del ícono al tocarlo.
              void bounce((e.currentTarget as HTMLElement).querySelector(".tabbar__icon"));
              onSelect(t.id);
            }}
          >
            <span class="tabbar__icon">
              <Icon name={t.id === selected ? t.on : t.icon} size={24} />
              {t.id === "review" && <Badge count={reviewBadge} />}
            </span>
            <span class="tabbar__label">{t.label}</span>
          </button>
        ))}
      </div>
    </nav>
  );
}
