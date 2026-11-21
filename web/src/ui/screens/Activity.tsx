import { Button, Card, Icon, LargeTitle, MacPill, Screen, SectionHeader, Spinner } from "../components";
import type { ActivityProps } from "./types";
import "./screens.css";

// activity: recursos de la Mac, tareas de Claude corriendo y gasto del mes.
export function Activity({ mac, stats, running, month, onStop }: ActivityProps) {
  const total = month.segments.reduce((s, x) => s + x.value, 0) || 1;
  return (
    <Screen label="Activity">
      <div class="home-top">
        <MacPill mac={mac} />
      </div>
      <LargeTitle>Activity</LargeTitle>
      <div class="stats">
        {stats.map((s) => (
          <div key={s.label} class="stat">
            <span class="stat__label">
              <Icon name={s.icon} size={14} />
              {s.label}
            </span>
            <span class="stat__value">{s.value}</span>
            <span class="stat__sub">{s.sub}</span>
            <span class="stat__bar" role="meter" aria-label={s.label} aria-valuemin={0} aria-valuemax={1} aria-valuenow={s.fraction}>
              <span class={`stat__fill stat__fill--${s.tone}`} style={{ width: `${Math.round(Math.min(1, Math.max(0, s.fraction)) * 100)}%` }} />
            </span>
          </div>
        ))}
      </div>
      <section class="activity-section">
        <SectionHeader title="Running" count={running.length} />
        {running.length > 0 && (
          <Card>
            {running.map((t) => (
              <div key={t.id} class="task">
                <span class="task__spin">
                  <Spinner size={17} />
                </span>
                <span class="task__text">
                  <span class="task__title">{t.title}</span>
                  <span class="task__sub">{t.sub}</span>
                </span>
                <Button variant="destructive-tinted" size="sm" icon="stop.fill" class="task__stop" onClick={() => onStop(t.id)}>
                  Stop
                </Button>
              </div>
            ))}
          </Card>
        )}
      </section>
      <section class="activity-section">
        <SectionHeader title="Claude this month" />
        <Card class="spend">
          <p class="spend__total">
            <strong>{month.total}</strong>
            <span>{month.caption}</span>
          </p>
          <div class="spend__bar" aria-hidden="true">
            {month.segments.map((s) => (
              <span key={s.label} class={`spend__seg spend__seg--${s.tone}`} style={{ flexGrow: s.value / total }} />
            ))}
          </div>
          <ul class="spend__legend">
            {month.segments.map((s) => (
              <li key={s.label}>
                <span class={`spend__dot spend__seg--${s.tone}`} />
                <span class="spend__name">{s.label}</span>
                <span class="spend__count">{s.count}</span>
                <span class="spend__amount">{s.amount}</span>
              </li>
            ))}
          </ul>
        </Card>
      </section>
    </Screen>
  );
}
