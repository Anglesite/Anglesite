import { getViteConfig } from "astro/config";

export default getViteConfig({
  test: {
    include: ["src/lib/effects-catalog.spec.ts", "src/lib/effects-scroll-driven.spec.ts"],
  },
});
