import "./components.css";

// Interruptor del sistema (51×31) y control segmentado.

export function Toggle({ on, disabled, label, onChange }: {
  on: boolean; disabled?: boolean | undefined; label?: string | undefined; onChange: (on: boolean) => void;
}) {
  return (
    <input
      type="checkbox"
      role="switch"
      class="toggle"
      checked={on}
      disabled={disabled}
      aria-label={label}
      aria-checked={on}
      onChange={(e) => onChange((e.currentTarget as HTMLInputElement).checked)}
      onClick={(e) => e.stopPropagation()}
    />
  );
}

export interface Segment<T extends string> {
  id: T;
  label: string;
}

export function SegmentedControl<T extends string>({ segments, selected, label, disabled, onChange }: {
  segments: Segment<T>[]; selected: T; label: string; disabled?: boolean | undefined; onChange: (id: T) => void;
}) {
  const index = segments.findIndex((s) => s.id === selected);
  return (
    <div class="segmented" role="radiogroup" aria-label={label}>
      {index >= 0 && (
        <span
          class="segmented__thumb"
          aria-hidden="true"
          style={{ width: `calc((100% - 4px) / ${segments.length})`, transform: `translateX(${index * 100}%)` }}
        />
      )}
      {segments.map((s) => (
        <button
          key={s.id}
          type="button"
          role="radio"
          aria-checked={s.id === selected}
          disabled={disabled}
          class={s.id === selected ? "segmented__item segmented__item--on" : "segmented__item"}
          onClick={() => onChange(s.id)}
        >
          {s.label}
        </button>
      ))}
    </div>
  );
}
