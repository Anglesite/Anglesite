// Stands in for a `@dwk/*` catalog package so the captured stack shows how a package frame's
// path survives bundling + source mapping — the input to the relay's attribution rule (§3).
// Two nested named functions so the trace has more than one package frame.

export class SpikePackageError extends Error {
  override name = "SpikePackageError";
}

export function handleSpikeRequest(kind: string): never {
  return parseSpikeInput(kind);
}

function parseSpikeInput(kind: string): never {
  throw new SpikePackageError(`spike failure (${kind})`);
}
