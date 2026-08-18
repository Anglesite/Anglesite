import { getViteConfig } from "astro/config";

export default getViteConfig({
  test: {
    include: ["src/lib/effects-catalog.spec.ts", "src/lib/effects-generative-art.spec.ts"],
  },
});
