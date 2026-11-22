import { describe, expect, it } from "vitest";
import {
  addSample, cardScale, DIM, gestureAxis, PARALLAX, popFrame, pullOffset, pullProgress, REFRESH_THRESHOLD, rubberBand,
  settleDuration, sheetOffset, shouldCompletePop, shouldDismissSheet, spokesFor, swipeProgress, velocityOf,
} from "../../../src/ui/motion/math";

describe("cuentas de los gestos", () => {
  it("rubberBand frena cada vez más y nunca pasa la dimensión", () => {
    expect(rubberBand(0, 800)).toBe(0);
    const a = rubberBand(100, 800);
    const b = rubberBand(200, 800);
    expect(a).toBeGreaterThan(0);
    expect(a).toBeLessThan(100);
    expect(b - a).toBeLessThan(a);
    expect(rubberBand(1e6, 800)).toBeLessThan(800);
    expect(rubberBand(-100, 800)).toBeCloseTo(-a);
    expect(rubberBand(50, 0)).toBe(0);
  });

  it("el gesto de volver: progreso, paralaje y oscurecimiento", () => {
    expect(swipeProgress(-20, 400)).toBe(0);
    expect(swipeProgress(200, 400)).toBe(0.5);
    expect(swipeProgress(900, 400)).toBe(1);
    expect(popFrame(0, 400)).toEqual({ topX: 0, underX: -PARALLAX * 400, dim: DIM });
    const end = popFrame(1, 400);
    expect(end.topX).toBe(400);
    expect(end.underX).toBeCloseTo(0);
    expect(end.dim).toBe(0);
    expect(popFrame(0.5, 400).underX).toBeCloseTo(-60);
  });

  it("al soltar: pasado un tercio o con un tirón vuelve; un tirón hacia atrás cancela", () => {
    expect(shouldCompletePop(140, 0, 393)).toBe(true);
    expect(shouldCompletePop(120, 0, 393)).toBe(false);
    expect(shouldCompletePop(40, 0.8, 393)).toBe(true);
    expect(shouldCompletePop(300, -0.5, 393)).toBe(false);
  });

  it("la hoja: baja con el dedo, rebota hacia arriba y se cierra por distancia o velocidad", () => {
    expect(sheetOffset(120, 700)).toBe(120);
    expect(sheetOffset(-120, 700)).toBeGreaterThan(-120);
    expect(sheetOffset(-120, 700)).toBeLessThan(0);
    expect(shouldDismissSheet(300, 0, 700)).toBe(true);
    expect(shouldDismissSheet(200, 0, 700)).toBe(false);
    expect(shouldDismissSheet(60, 1, 700)).toBe(true);
    expect(shouldDismissSheet(400, -0.5, 700)).toBe(false);
    expect(shouldDismissSheet(4, 2, 700)).toBe(false);
  });

  it("tirar para actualizar: resistencia, progreso y rayos del indicador", () => {
    expect(pullOffset(-30, 800)).toBe(0);
    expect(pullOffset(200, 800)).toBeLessThan(200);
    expect(pullProgress(REFRESH_THRESHOLD)).toBe(1);
    expect(pullProgress(REFRESH_THRESHOLD / 2)).toBe(0.5);
    expect(spokesFor(0)).toBe(0);
    expect(spokesFor(0.5)).toBe(4);
    expect(spokesFor(3)).toBe(8);
  });

  it("eje del gesto y velocidad con las muestras recientes", () => {
    expect(gestureAxis(3, 2)).toBeNull();
    expect(gestureAxis(20, 4)).toBe("x");
    expect(gestureAxis(10, 10)).toBe("y");
    let samples = addSample([], 0, 0);
    samples = addSample(samples, 50, 25);
    samples = addSample(samples, 100, 50);
    expect(velocityOf(samples)).toBeCloseTo(0.5);
    // Las muestras viejas no cuentan: se frenó al final.
    samples = addSample(samples, 400, 50);
    expect(velocityOf(samples)).toBe(0);
    expect(velocityOf([])).toBe(0);
  });

  it("duración restante según la velocidad, entre un mínimo y un máximo", () => {
    expect(settleDuration(200, 0)).toBe(420);
    expect(settleDuration(200, 1)).toBe(200);
    expect(settleDuration(200, 10)).toBe(180);
    expect(settleDuration(2000, 1, 100, 300)).toBe(300);
  });

  it("la tarjeta de atrás deja 16 px a cada lado", () => {
    expect(cardScale(393) * 393).toBeCloseTo(361);
    expect(cardScale(0)).toBe(1);
  });
});
