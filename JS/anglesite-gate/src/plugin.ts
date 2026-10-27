/**
 * The `anglesite-gate` EmDash plugin entry. The hooks and policy live in the app-owned template
 * (`Resources/Template/scripts/emdash-gate/`), where owner decision D5's hash pin covers them and
 * `npm test` exercises them with no EmDash install. This file only holds that object to EmDash's
 * real `SandboxedPlugin` type — so a drift between the policy's local event type and EmDash's
 * fails `npm run typecheck` — and is what `emdash-plugin build` bundles.
 */
import type { SandboxedPlugin } from "emdash/plugin";
import gate from "../../../Resources/Template/scripts/emdash-gate/plugin";

const plugin: SandboxedPlugin = gate;

export default plugin;
