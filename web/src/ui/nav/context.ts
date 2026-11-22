import { createContext, type RefObject } from "preact";
import { useContext } from "preact/hooks";

// Lo que una pantalla sabe de la capa donde está (NavHost): el título de la de abajo y su contenedor de scroll. Fuera
// de la app (las historias) no hay capa y los componentes se dibujan como en el diseño.

export interface PageInfo {
  /** El título de la pantalla de abajo (el botón Back lo muestra). */
  backTitle?: string | undefined;
  scroller: RefObject<HTMLDivElement>;
  /** La pantalla está a la vista (arriba de la pila de la pestaña elegida). */
  visible: boolean;
}

export const PageContext = createContext<PageInfo | null>(null);

export function usePage(): PageInfo | null {
  return useContext(PageContext);
}
