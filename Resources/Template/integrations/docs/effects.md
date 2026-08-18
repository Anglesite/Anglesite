# Animations

This site template ships [`@astroanimate/core`](https://www.astroanimate.com) `0.1.2` as a
default dependency (`Resources/Template/package.json`) — every new site has it installed with no
extra step. It is a CSS-first, Astro-native animated component library: components render
meaningful content with zero client JS by default, and respect
`prefers-reduced-motion` automatically.

## CSS-only policy

Every component below supports an `enhance` prop that opts into an IntersectionObserver-based
JS enhancement path. **Never set `enhance={true}` (or `enhance="true"`) on a component in this
site.** The library's `enhance` mode emits inline `<script>` tags, and this site's Content
Security Policy has no `'unsafe-inline'` and no script hashes — an inline script from
`enhance={true}` is blocked in production and will silently do nothing. CSS-only usage
(`enhance` left unset, which defaults to `false` on every component below except
`CardStack`, where it must be passed explicitly as `enhance={false}`) is the supported and
tested mode.

## Import style

Import each component from its own export path, not the package root:

```astro
---
import FadeInText from "@astroanimate/core/FadeInText";
---
```

## Curated components

Only the components listed below have been vetted for this site: each renders under Astro 7,
respects `prefers-reduced-motion`, has meaningful content without JS, and emits zero
`<script>` tags with the props shown here. The full `@astroanimate/core` package has more
components than this — the rest are not curated for this site and are not guaranteed to be
CSP-safe.

**Text**

## FadeInText

Text that fades in with a soft blur when the page loads.

| Prop | Notes |
| --- | --- |
| `duration` | seconds (default 0.6) |
| `delay` | seconds (default 0) |
| `as` | wrapper tag, e.g. "h1" |

```astro
---
import FadeInText from "@astroanimate/core/FadeInText";
---
<FadeInText as="h1">Welcome</FadeInText>
```

## ScaleIn

Text or content that grows into place from a slightly smaller size.

| Prop | Notes |
| --- | --- |
| `initialScale` | starting scale (default 0.9) |
| `duration` | milliseconds (default 600) |
| `as` | wrapper tag, e.g. "h2" |

```astro
---
import ScaleIn from "@astroanimate/core/ScaleIn";
---
<ScaleIn as="h2">Grows into place</ScaleIn>
```

## RevealImage

A headline where the letters reveal a background image as you scroll past.

| Prop | Notes |
| --- | --- |
| `text` | overlay text (required) |
| `image1` | first image URL (required) |
| `image2` | second image URL (required) |

```astro
---
import RevealImage from "@astroanimate/core/RevealImage";
---
<RevealImage text="REVEAL" image1="/images/before.jpg" image2="/images/after.jpg" />
```

## HighlightText

A highlighter-style underline or background sweep behind a phrase.

| Prop | Notes |
| --- | --- |
| `variant` | "underline" | "background" (default "background") |
| `color` | highlight color (default "#FFD700") |
| `trigger` | "load" | "hover" (default "load") |

```astro
---
import HighlightText from "@astroanimate/core/HighlightText";
---
<p>This is <HighlightText>important</HighlightText> text.</p>
```

## TypewriterText

A line of text that types itself out, one character at a time.

| Prop | Notes |
| --- | --- |
| `texts` | array of strings to cycle through (required) |
| `showCursor` | boolean (default true) |
| `cursor` | cursor character (default "|") |

```astro
---
import TypewriterText from "@astroanimate/core/TypewriterText";
---
<TypewriterText texts={["Design.", "Build.", "Ship."]} />
```

**Cards**

## AnimatedCard

A card that lifts, scales, or shines on hover.

| Prop | Notes |
| --- | --- |
| `title` | card title (required) |
| `description` | card description (required) |
| `variant` | "lift" | "scale" | "flip" | "shine" (default "lift") |

```astro
---
import AnimatedCard from "@astroanimate/core/AnimatedCard";
---
<AnimatedCard title="Feature" description="A short description of the feature." />
```

## CardStack

A stack of testimonial or feature cards, one in front of the other.

| Prop | Notes |
| --- | --- |
| `cards` | array of { title, content } cards (required) |
| `stackSize` | visible cards (default 3) |
| `enhance` | keep false — CSS-only mode (site CSP blocks enhance=true) |

```astro
---
import CardStack from "@astroanimate/core/CardStack";
---
<CardStack
  enhance={false}
  cards={[
    { title: "Alex", content: "Loved the onboarding flow." },
    { title: "Sam", content: "Setup took five minutes." },
  ]}
/>
```

## ArticleCard

A blog-post or article preview card with a title, summary, and link.

| Prop | Notes |
| --- | --- |
| `title` | article title (required) |
| `description` | summary text (required) |
| `href` | link target (default "#") |

```astro
---
import ArticleCard from "@astroanimate/core/ArticleCard";
---
<ArticleCard title="Article title" description="A short summary of the article." href="/blog/post" />
```

**Buttons**

## AnimatedButton

A button with a shimmer, fill, or border sweep on hover.

| Prop | Notes |
| --- | --- |
| `variant` | "shimmer" | "fill" | "border" | "none" (default "none") |
| `href` | renders as a link when set |
| `disabled` | boolean (default false) |

```astro
---
import AnimatedButton from "@astroanimate/core/AnimatedButton";
---
<AnimatedButton variant="shimmer">Get started</AnimatedButton>
```

## FillHoverButton

A button whose background fills in from one edge on hover.

| Prop | Notes |
| --- | --- |
| `as` | "button" | "a" (default "button") |
| `href` | link target when as="a" |

```astro
---
import FillHoverButton from "@astroanimate/core/FillHoverButton";
---
<FillHoverButton>Subscribe</FillHoverButton>
```

## ArrowCTAButton

A call-to-action link whose arrow slides forward on hover.

| Prop | Notes |
| --- | --- |
| `label` | button text (required) |
| `as` | "button" | "a" (default "button") |
| `href` | link target when as="a" |

```astro
---
import ArrowCTAButton from "@astroanimate/core/ArrowCTAButton";
---
<ArrowCTAButton label="Learn more" href="/about" as="a" />
```

## SlidingOverlayButton

A button with a color overlay that slides in on hover.

| Prop | Notes |
| --- | --- |
| `as` | "button" | "a" (default "button") |
| `href` | link target when as="a" |

```astro
---
import SlidingOverlayButton from "@astroanimate/core/SlidingOverlayButton";
---
<SlidingOverlayButton>Contact us</SlidingOverlayButton>
```

**Backgrounds**

## GridDotsBackground

A subtle dot-grid or line-grid backdrop for a section.

| Prop | Notes |
| --- | --- |
| `variant` | "dots" | "grid" (default "dots") |
| `dotColor` | CSS color (default "rgba(255,255,255,0.25)") |
| `height` | CSS height (default "300px") |

```astro
---
import GridDotsBackground from "@astroanimate/core/GridDotsBackground";
---
<GridDotsBackground variant="grid" height="200px" />
```

## InfiniteMarquee

A row of logos, text, or cards that scrolls continuously and loops.

| Prop | Notes |
| --- | --- |
| `direction` | "left" | "right" | "up" | "down" (default "left") |
| `speed` | CSS duration (default "30s") |
| `pauseOnHover` | boolean (default true) |

```astro
---
import InfiniteMarquee from "@astroanimate/core/InfiniteMarquee";
---
<InfiniteMarquee>
  <span>Trusted by teams everywhere</span>
</InfiniteMarquee>
```

**Navigation**

## Loader

A spinning, dotted, or pulsing loading indicator.

| Prop | Notes |
| --- | --- |
| `type` | "spinner" | "dots" | "pulse" (default "spinner") |
| `size` | pixels (default 40) |
| `color` | CSS color (default "#3b82f6") |

```astro
---
import Loader from "@astroanimate/core/Loader";
---
<Loader type="dots" />
```

## ProgressBar

A labeled progress bar that fills to a given value.

| Prop | Notes |
| --- | --- |
| `value` | current value 0-max (required) |
| `max` | maximum value (default 100) |
| `label` | optional label text |

```astro
---
import ProgressBar from "@astroanimate/core/ProgressBar";
---
<ProgressBar value={60} label="Upload progress" />
```

## Effects library

The 12 components below live in this template at `src/components/effects/` — hand-authored,
script-first effects distinct from the `@astroanimate/core` set above. They power the app's
Effects gallery: each carries a `placement` (`inline` or `background`) in `integrations/effects.json`
so the gallery knows where it can be dropped, and a matching entry in `blocks.manifest.json` so the
component editor can place it. Every animated component here respects `prefers-reduced-motion`
(generative-art components do so purely in CSS, with zero `<script>`; the rest gate a real client
script behind a `matchMedia("(prefers-reduced-motion: reduce)")` check). Import from the template's
own `src/components/effects/` path, not a package.

**Canvas Backgrounds**

## ParticleField

Drifting dots connected by faint lines when close.

| Prop | Notes |
| --- | --- |
| `density` | particle count (default 60) |
| `color` | dot/line color (default currentColor) |

```astro
---
import ParticleField from "../components/effects/ParticleField.astro";
---
<div style="position: relative;">
  <ParticleField />
</div>
```

## AuroraGradient

Slow blurred color-blob blending.

| Prop | Notes |
| --- | --- |
| `colors` | array of CSS colors (default a purple/blue/teal trio) |

```astro
---
import AuroraGradient from "../components/effects/AuroraGradient.astro";
---
<div style="position: relative;">
  <AuroraGradient />
</div>
```

## GrainOverlay

Subtle animated film-grain texture.

| Prop | Notes |
| --- | --- |
| `opacity` | 0-1 (default 0.05) |

```astro
---
import GrainOverlay from "../components/effects/GrainOverlay.astro";
---
<div style="position: relative;">
  <GrainOverlay />
</div>
```

**Cursor-Reactive**

## MagneticButton

A button that eases toward the pointer as it gets close, then springs back.

| Prop | Notes |
| --- | --- |
| `text` | button label (default "Get in touch") |
| `href` | renders as a link when set |

```astro
---
import MagneticButton from "../components/effects/MagneticButton.astro";
---
<MagneticButton text="Get in touch" href="/contact" />
```

## CursorGlow

A soft glow that follows the pointer around the page.

| Prop | Notes |
| --- | --- |
| `color` | glow color (default "rgba(124, 58, 237, 0.35)") |

```astro
---
import CursorGlow from "../components/effects/CursorGlow.astro";
---
<CursorGlow />
```

## TiltCard

A card that tilts in 3D as the pointer moves over it.

| Prop | Notes |
| --- | --- |
| `title` | card title (default "Card title") |
| `body` | supporting copy (default a short placeholder line) |
| `imageSrc` | optional image URL |

```astro
---
import TiltCard from "../components/effects/TiltCard.astro";
---
<TiltCard title="Card title" body="A short line of supporting copy." />
```

**Scroll-Driven**

## ParallaxLayers

A two-layer decorative block where the back layer drifts slower than the page scroll.

| Prop | Notes |
| --- | --- |
| `height` | block height (default "40vh") |

```astro
---
import ParallaxLayers from "../components/effects/ParallaxLayers.astro";
---
<ParallaxLayers height="40vh" />
```

## RevealMask

Content that reveals with a clip-path wipe the first time it scrolls into view.

```astro
---
import RevealMask from "../components/effects/RevealMask.astro";
---
<RevealMask>
  Sample content that reveals as you scroll.
</RevealMask>
```

## ScrollProgressTrace

A slim reading-progress line along the viewport edge that fills as the page scrolls.

| Prop | Notes |
| --- | --- |
| `color` | trace color (default "currentColor") |

```astro
---
import ScrollProgressTrace from "../components/effects/ScrollProgressTrace.astro";
---
<ScrollProgressTrace />
```

**Generative Art**

## BlobMorph

An organic blob shape that continuously morphs between rounded shapes.

| Prop | Notes |
| --- | --- |
| `color` | CSS color (default "currentColor") |
| `size` | CSS size (default "320px") |

```astro
---
import BlobMorph from "../components/effects/BlobMorph.astro";
---
<BlobMorph color="#7c3aed" size="320px" />
```

## MeshGradient

Soft blurred color blobs that drift slowly, creating an organic gradient mesh.

| Prop | Notes |
| --- | --- |
| `colors` | array of CSS colors (default purple/blue/teal/pink) |

```astro
---
import MeshGradient from "../components/effects/MeshGradient.astro";
---
<MeshGradient colors={["#7c3aed", "#2563eb", "#0891b2", "#db2777"]} />
```

## DotGridPulse

A grid of dots that pulse in a wave pattern, creating a rhythmic animation.

| Prop | Notes |
| --- | --- |
| `columns` | grid columns (default 8) |
| `rows` | grid rows (default 4) |
| `color` | dot color (default "currentColor") |

```astro
---
import DotGridPulse from "../components/effects/DotGridPulse.astro";
---
<DotGridPulse columns={8} rows={4} color="currentColor" />
```
