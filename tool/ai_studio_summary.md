Here is a comprehensive summary of the major changes, features, and improvements made to the Flutter Web Engine over the past year (mid-2025 to mid-2026).

This year was defined by massive architectural unifications, a heavy focus on deep accessibility (a11y) integration, the highly anticipated introduction of Impeller on the web, and significant quality-of-life improvements for custom shaders and text rendering.

---

# 🚀 Flutter Web Engine: 2025–2026 Year in Review

## 1. Rendering Architecture: Unification & Next-Gen Graphics
The underlying architecture of Flutter Web underwent major structural changes to improve maintainability, performance, and memory management.

* **CanvasKit & Skwasm Unification:** The engine underwent a massive refactor to unify the frontend code (SceneBuilder, Platform View embedding, and Surface code) between the CanvasKit and Skwasm renderers. This means fewer renderer-specific bugs and consistent behavior across web backends.
* **Initial "Impeller on Web" Implementation:** The foundation for Impeller on the web was officially merged. While initially experimental (and lacking some features like MSAA and multithreading), this marks the beginning of transitioning the web engine to Flutter’s next-generation rendering backend.
* **Skwasm Memory & GC Overhaul:** Skwasm’s reliance on the browser's Garbage Collection (`FinalizationRegistry`) was heavily reduced. By introducing `LazyPath` objects and unified native memory management (`UniqueRef`/`CountedRef`), Skwasm now explicitly cleans up native resources at the end of frames, preventing linear memory Out-Of-Memory (OOM) crashes and reducing UI jank.
* **WebGL Context Loss Recovery:** Thanks to the unified surface architecture, Skwasm can now gracefully handle and recover from WebGL context loss events without crashing the app.
* **Multithreading Fallbacks:** The engine is now smarter about WebAssembly threading, forcing single-threading for Chrome Extensions where SharedArrayBuffers aren't allowed, and using `queueMicrotask` over `postMessage` for faster single-threaded performance.

## 2. Text, Typography, and "WebParagraph"
Text rendering on the web saw both immediate bug fixes and the dawn of a new, lighter-weight text layout system.

* **The Dawn of `WebParagraph`:** A major experimental feature, `WebParagraph`, was introduced. This implements `SkParagraph` functionality using native browser `TextCluster` APIs. By moving text rendering to the DOM, this aims to significantly reduce the CanvasKit bundle size by stripping out embedded text/font libraries in the future.
* **Improved Text Editing & Selection:** Fixed notorious multiline text selection bugs in Chrome caused by coalesced pointer events. Furthermore, disabling interactive selection (`enableInteractiveSelection: false`) now strictly prevents copying, pasting, and highlighting at the DOM level.
* **Email Input Fixes:** Semantics for email inputs now use `type="text"` combined with `inputmode="email"`. This preserves the mobile email keyboard while bypassing severe browser bugs that broke text selection and cursor movement inside `type="email"` fields.
* **IME and Spacing Sync:** Letter-spacing, word-spacing, and line-height are now fully synchronized to the underlying DOM elements, ensuring that Input Method Editor (IME) overlays and text selection boxes align perfectly with the rendered Flutter text.

## 3. Deep Accessibility (A11y) & Semantics
Accessibility received arguably the highest volume of updates this year, moving Flutter Web much closer to native DOM accessibility standards.

* **`SliverEnsureSemantics`:** A massive win for scrolling accessibility. Screen readers can now detect and navigate to off-screen sliver items (lists, grids) without them needing to be rendered in the active viewport.
* **Semantics Flag Architecture:** The engine migrated away from a restrictive 32-bit integer bitmask for semantics flags. It now uses a dedicated `SemanticsFlags` object, allowing the framework to support an infinite number of accessibility traits.
* **Focus & Screen Reader Navigation:** Fixed critical issues where screen readers (like VoiceOver) would lose focus context when navigating between routes. Assistive technology activations now seamlessly bridge with Flutter's internal focus tracking.
* **ARIA & DOM Attribute Enhancements:**
  * Form validation errors and hint texts are now explicitly passed to screen readers using `aria-description` (or `aria-describedby` fallbacks).
  * Landmark roles (`main`, `navigation`, `region`) were added.
  * Platform Views are now properly marked with `aria-hidden` to prevent screen readers from reading duplicate content.
* **Interactive Elements:** Semantic tabs were updated to ensure VoiceOver users can click them using standard screen-reader activation commands, and progress bars now support human-readable percentage strings (e.g., "50%" instead of "0.5").

## 4. Shaders, Graphics & Visual Effects
Rich graphics and custom shaders became much easier to work with and more visually accurate.

* **Uniforms by Name:** A massive quality-of-life update for custom Fragment Shaders. Developers can now fetch and set uniforms by their string names (e.g., `shader.getUniformVec3('uColor').set(...)`) instead of relying on brittle integer indices. Support includes floats, vectors, matrices, and arrays.
* **iOS-Style "Bounded" Blur:** Implemented a new blurring mode that restricts the blur filter from sampling transparent/background pixels outside a defined boundary. This accurately replicates the "liquid glass" look required for modern iOS 26 UI designs.
* **Shape & Color Enhancements:**
  * `RSuperellipse` (squircle) support was added to the web with global path caching and radius clamping.
  * Paint dithering was added to gradients for both CanvasKit and Skwasm, fixing color banding issues.
  * `Color.lerp` now supports mixing colors across different color spaces (e.g., interpolating between sRGB and Display P3 without crashing).

## 5. Platform Integration, DOM, and PWAs
Improvements were made to how Flutter interacts with the browser window, iframes, and device settings.

* **Media Queries & System Settings:** The engine now continuously monitors the browser for system-level changes to Reduced Motion, Disabled Animations, High Contrast, Dark Mode, and dynamically adjusts the internal text scale factors.
* **Service Workers & PWA Strategy:** The old `--pwa-strategy` flag was deprecated. The engine now uses a "self-cleaning" service worker to prevent aggressive caching issues that historically trapped users on old versions of Flutter web apps.
* **Iframe Scrolling & Keyboards:** Fixed bugs where scroll events wouldn't bubble up properly when Flutter was embedded in an iframe. Additionally, text inputs inside iOS iframes will now correctly scroll into view when the virtual keyboard appears, rather than being hidden behind it.
* **Autofill in iOS 26:** Safari's new blur-then-focus autofill behavior was breaking forms. Flutter Web now reuses DOM autofill forms and successfully re-establishes connections with the framework to ensure seamless password and address autofill.
