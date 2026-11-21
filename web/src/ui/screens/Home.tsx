import { Banner, Button, GlassButton, HeroCircle, Icon, LargeTitle, MacPill, PRRow, Screen, Section, Spinner, TopBar } from "../components";
import type { HomeProps } from "./types";
import "./screens.css";

// home (To Review), home:mine (My PRs) y home:offline: píldora de la Mac + filtro, título grande y secciones.
export function Home({
  mac, title, sections, offline, banner, refreshing, onOpen, onAction, onToggleSection, onFilter, onRetry, onBannerAction,
}: HomeProps) {
  return (
    <Screen label={title}>
      <TopBar title={title}>
        <MacPill mac={mac} />
        <GlassButton icon="line.3.horizontal.decrease" label="Filter" onClick={onFilter} iconSize={21} />
      </TopBar>
      <LargeTitle>{title}</LargeTitle>
      {refreshing && (
        <div class="home-refresh" role="status" aria-label="Refreshing">
          <Spinner size={20} />
        </div>
      )}
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
