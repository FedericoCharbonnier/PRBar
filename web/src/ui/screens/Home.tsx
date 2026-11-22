import { Banner, Button, HeroCircle, Icon, LargeTitle, MacPill, PRRow, Screen, Section, TopBar } from "../components";
import type { HomeProps } from "./types";
import "./screens.css";

// home (To Review), home:mine (My PRs) y home:offline: píldora de la Mac, título grande y secciones. El botón Filter de
// DESIGN.md no tiene comportamiento definido: no se muestra hasta que lo tenga (un botón que no hace nada confunde).
export function Home({
  mac, title, sections, offline, banner, onOpen, onAction, onToggleSection, onRetry, onBannerAction,
}: HomeProps) {
  return (
    <Screen label={title}>
      <TopBar title={title}>
        <MacPill mac={mac} />
      </TopBar>
      <LargeTitle>{title}</LargeTitle>
      {banner && <Banner banner={banner} onAction={onBannerAction} />}
      {offline && (
        <div class="card offline-card">
          <span class="offline-card__art">
            <HeroCircle icon="laptopcomputer" tone="fill" size={76} iconSize={50} />
            <Icon name="moon.zzz" size={22} class="offline-card__moon" />
          </span>
          <h2>{offline.title}</h2>
          <p>{offline.message}</p>
          <Button variant="tinted" size="md" icon="arrow.clockwise" busy={offline.retrying} onClick={onRetry}>
            Try Again
          </Button>
        </div>
      )}
      {sections.map((s) => (
        <Section
          key={s.id}
          title={s.title}
          count={s.count}
          collapsed={s.collapsed}
          dimmed={!!offline || s.collapsed}
          onToggle={() => onToggleSection(s.id)}
        >
          {s.rows.map((r) => (
            <PRRow key={r.id} row={r} onOpen={() => onOpen(r.id)} onAction={() => onAction(r.id)} />
          ))}
        </Section>
      ))}
    </Screen>
  );
}
