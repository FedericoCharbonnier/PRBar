import { render } from "preact";
import { App } from "./ui/app";
import "./ui/tokens.css";
import "./ui/base.css";

// Punto de entrada. Las pantallas llegan en las tareas C4–C5.
const root = document.getElementById("app");
if (root) render(<App />, root);
