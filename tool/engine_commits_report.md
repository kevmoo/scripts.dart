# Engine Commits Report (Filtered)
Filtered by: engine/src/flutter/lib/web_ui

### [A11y] Allow percentage strings like "50%" as `SemanticsValue` for `ProgressIndicator` (#183670)
- **Author**: Hannah Jin
- **Date**: 2026-04-06
- **Link**: https://github.com/flutter/flutter/commit/e42df5214c137c1b49fd63d85d1434bea7a4203a

Fix: #182491 

So they can make the progress bar read "50%" instead of "0.5", "50" and
provide a better user experience.

---

### [web] Fix autofill in iOS 26 Safari (#182024)
- **Author**: Mouad Debbar
- **Date**: 2026-03-31
- **Link**: https://github.com/flutter/flutter/commit/79218a376c4223d5eec11e8b9dd8bb296c32a669

This fix has 2 parts basically:

1. Reuse autofill forms. Prior to this PR, the autofill forms were being
recreated every time a text input connection is established. This
behavior prevents Safari from autofilling the entire form. This PR
reuses the existing form and fields instead of recreating them.

2. Re-establish the text input connection with the framework when the
text field receives focus from the browser. This is necessary for
iOS26's new focus behavior where it blurs the text field then focuses it
before autofilling it. That blur-then-focus is a new behavior that was
not accounted for by the web engine.

Fixes https://github.com/flutter/flutter/issues/177248

---------

Co-authored-by: Loïc Sharma <737941+loic-sharma@users.noreply.github.com>

---

### fix(web): call ui.Picture.onDispose for the original picture only (#184348)
- **Author**: Harry Terkelsen
- **Date**: 2026-03-30
- **Link**: https://github.com/flutter/flutter/commit/dcc3ab2054b11df9867bdf7930a06ed301dba6e8

This reverts a recent change where ui.Picture.onDispose is only called
when the original picture and all clones have been disposed. This change
broke leak tracker tests.

Fixes https://github.com/flutter/flutter/issues/184312

---

### [web] Make it safe to call dispose multiple times on a CkSurface (#184270)
- **Author**: Jason Simmons
- **Date**: 2026-03-30
- **Link**: https://github.com/flutter/flutter/commit/7587e6e90d40d682c4f7f5d43b3d3a763e3b1614

References to a CkSurface instance may be held by multiple users.
Specifically, the PlatformViewEmbedder and the DisplayCanvasFactory can
use the same surface, and both classes will dispose that surface during
a hot restart.

This PR changes CkSurface.dispose to set _skSurface to null so that
future calls to dispose will do nothing.

See https://github.com/flutter/flutter/issues/183923

---

### feat(web): unify CanvasKit and Skwasm garbage collection (#183867)
- **Author**: Harry Terkelsen
- **Date**: 2026-03-27
- **Link**: https://github.com/flutter/flutter/commit/d14f52f3832a7c56c8406a96661b47e5fb68da4e

Introduce a shared memory management system in
`lib/src/engine/native_memory.dart` that both CanvasKit and Skwasm
renderers now utilize. This unification replaces renderer-specific
finalization logic with a consistent, efficient, and type-safe approach.

Key changes:
- Created `NativeMemoryFinalizer`, `UniqueRef`, and `CountedRef` as
generic base classes for native resource management.
- Refactored CanvasKit to use `CkUniqueRef` and `CkCountedRef`, which
specialize the base classes for Skia objects.
- Refactored Skwasm to use the unified `UniqueRef` and `CountedRef`
abstractions, enabling proper `ui.Image` and `ui.Picture` cloning via
reference counting.
- Improved efficiency by using tokens to detach manually disposed
objects from the `DomFinalizationRegistry`.
- Added a `Finalizer` interface to support mocking and verification of
finalization behavior in tests.
- Comprehensive test coverage across generic engine logic and
renderer-specific implementations.

Testing:
- Generic memory management tests: `test/engine/native_memory_test.dart`
- CanvasKit-specific tests: `test/canvaskit/native_memory_test.dart`
- Skwasm-specific tests: `test/skwasm/native_memory_test.dart`

Fixes https://github.com/flutter/flutter/issues/175628

---

### refactor(web): use positive logic and platform defaults for accessibility features (#183907)
- **Author**: Harry Terkelsen
- **Date**: 2026-03-23
- **Link**: https://github.com/flutter/flutter/commit/c7990b47e54399f664010f63ee5701b44c0c88a6

Refactors EngineAccessibilityFeatures to simplify its bitfield logic and
enforce proper initialization patterns.

Key highlights:
- Removed complex negated-bit logic for `supportsAnnounce`,
`autoPlayAnimatedImages`, and `autoPlayVideos`, switching to positive
"enabled" flags.
- Made the `EngineAccessibilityFeatures` constructor private, ensuring
the builder and `defaultFeatures` constant are the only ways to create
new instances.
- Optimized `copyWith` and removed redundant explicit zero
initializations across the engine and tests.

---

### fix(web): handle asynchronously disposed platform views (#183666)
- **Author**: Harry Terkelsen
- **Date**: 2026-03-17
- **Link**: https://github.com/flutter/flutter/commit/537bb2ca26dcaefbcf726c94e7a25b13aef0a3fe

Check if platform views still exist in PlatformViewManager before
compositing to avoid crashes if they are disposed during async gaps in
the rendering pipeline.

Added test/ui/async_rendering_test.dart.

Fixes https://github.com/flutter/flutter/issues/182844
Fixes https://github.com/flutter/flutter/issues/176299

---

### fix(web): fix crash in Skwasm when transferring non-transferable texture sources (#183799)
- **Author**: Harry Terkelsen
- **Date**: 2026-03-17
- **Link**: https://github.com/flutter/flutter/commit/483cce9b9ac4ccf08f7bf10aa6c87ff01da4dc8f

The engine was previously attempting to transfer non-transferable
objects like `HTMLImageElement` to the web worker via `postMessage` when
`transferOwnership` was set to `true`. This resulted in a
`DataCloneError`.

This change adds a check to see if the texture source is a transferable
type when in multi-threaded mode. If not, it converts it to an
`ImageBitmap` using `createImageBitmap` before transferring.

A new test `test/ui/image_texture_source_test.dart` has been added to
verify this behavior across all renderers.

Fixes https://github.com/flutter/flutter/issues/183166

---

### fix(web_ui): move prepareToDraw after raster to improve concurrency and stability (#183791)
- **Author**: Harry Terkelsen
- **Date**: 2026-03-17
- **Link**: https://github.com/flutter/flutter/commit/b805f9f13489218371aecd198f8bd89dd0b0ec31

Moving prepareToDraw after the synchronous raster recording phase
ensures that the UI state is captured immediately. This prevents
potential race conditions in Skwasm where resizing the surface
immediately before measuring and painting could lead to uninitialized
Skia resources or incorrect rendering states.

By deferring physical surface sizing until after the pictures are
recorded, we also allow asynchronous surface preparation to better
overlap with other work, improving overall frame performance.

Fixes https://github.com/flutter/flutter/issues/182354

---

### [web] Fix occasional failure to find Chrome tab (#183737)
- **Author**: Mouad Debbar
- **Date**: 2026-03-17
- **Link**: https://github.com/flutter/flutter/commit/5ffb474e1830731797137718aeb73dca5718d722

I got the following error several times locally:
```
Failed to load "<name>_test.dart": Failed to run browser process: Null check operator used on a null value.
  ../../dev/chrome.dart 400:58          setupChromiumTab
  ===== asynchronous gap ===========================
  ../../dev/chrome.dart 129:9           new Chrome.<fn>
  ===== asynchronous gap ===========================
  ../../dev/browser_process.dart 25:33  new BrowserProcess.<fn>
```

For some reason, newer versions of Chrome allow the WIP connection to be
established before tabs have had a chance to launch. This results in the
code failing to find any tabs to connect to. The fix in this PR is to
retry for a few seconds until tabs are available.

We had a similar
[report](https://github.com/flutter/flutter/issues/183335) of this issue
happening in the `web_benchmark` package. A similar fix will be
implemented there.

---

### [web] Prevent Firefox auto-updates (#183330)
- **Author**: Mouad Debbar
- **Date**: 2026-03-11
- **Link**: https://github.com/flutter/flutter/commit/a6dab0a3d1b1d60a724925ff91027d810c132d34

Examples of previous tree closures caused by Firefox auto-updates:
- https://github.com/flutter/flutter/issues/172713
- https://github.com/flutter/flutter/pull/182855

---

### [web] Updates to the README (#176292)
- **Author**: Mouad Debbar
- **Date**: 2026-03-10
- **Link**: https://github.com/flutter/flutter/commit/195ae7b3a1220a0eaf0525637b0249c5b624af94

The main addition here is the instructions for using a locally built
dart sdk.

Along the way, I also did some other minor updates to this file.

---

### [web] Use pointer-events: auto for non-interactive leaf semantics nodes (#183077)
- **Author**: zhongliugo
- **Date**: 2026-03-04
- **Link**: https://github.com/flutter/flutter/commit/d53fa918cf14dfa647484c3e13077fb4f2c56756

Fixes https://github.com/flutter/flutter/issues/182493

**Problem**

When semantics are enabled, `OverlayPortal` overlay content cannot
receive pointer events. Clicks pass through the overlay to the widget
underneath because every non-interactive semantics DOM node was assigned
`pointer-events: none`, bypassing the browser's z-index stacking order.

**Fix**

Non-interactive leaf semantics nodes now use `pointer-events: auto`
instead of `none`. This delegates hit testing to the browser's native
z-index stacking, so higher-z-index overlays naturally intercept events.
Containers keep `none` (children handle their own events), and explicit
`transparent` nodes (e.g. platform views) also keep `none`.

**Demo**

Before change 
https://flutter-demo-13-before.web.app

After change
https://flutter-demo-13-afte.web.app

Steps: click "Press to show/hide tooltip" → click the yellow tooltip
box.
Before: toggles the button behind it. A
fter: click lands on the overlay.

---

### Support mixed color spaces in `Color.lerp` (#182934)
- **Author**: Lukas Klingsbo
- **Date**: 2026-03-03
- **Link**: https://github.com/flutter/flutter/commit/8cd2df19349718cab28be2fbbe4a104dc9ea088d

Instead of asserting that both colors must share the same color space,
Color.lerp now converts both colors to the wider gamut color space
before interpolating. For example, lerping between an sRGB color and a
Display P3 color produces a Display P3 result.

Instead of asserting that both colors must share the same color space,
Color.lerp now converts both colors to the wider gamut color space
before interpolating. For example, lerping between an sRGB color and a
Display P3 color produces a Display P3 result.

Fixes: #182777

---

### Use isA to test for exceptions (#183129)
- **Author**: Srujan Gaddam
- **Date**: 2026-03-02
- **Link**: https://github.com/flutter/flutter/commit/6593592c450e5399a703353f42a6cc91b128b888

This code was never testing that the exception was a DOMException. When
compiling to JS, this is just checking if it is a JS object and when
compiling to Wasm, this is just checking if the value is a JS value.
With recent [lint
changes](https://dart-review.googlesource.com/c/sdk/+/483960), this will
now be linted and will therefore block the SDK roll.

Instead, we should catch the exception without a type, do an isA check
(now that it supports arbitrary values), and then rethrow if it isn't
the exception we were looking for.

Note that this does mean if this code was accidentally catching a
different JS value before, it now rethrows it.

---

### Make TextDecoration final and unify maskValue across platforms (#183070)
- **Author**: GyuBin Hwang
- **Date**: 2026-03-03
- **Link**: https://github.com/flutter/flutter/commit/c46f6f40e824eb4503b5288f216bacdb6e9adc6a

## Description

Make `TextDecoration` a `final class` and add the `maskValue` getter to
the non-web implementation for API consistency.

### Problem

`TextDecoration` has a platform-inconsistent API: the web implementation
exposes a `maskValue` getter (used by Skwasm) that the non-web
implementation does not. Code that `implements TextDecoration` compiles
on mobile but fails on web due to the missing `maskValue`.

### Solution

1. Make `TextDecoration` a `final class` in both web and non-web
implementations to prevent external extension/implementation
2. Add `maskValue` getter to the non-web implementation so the public
API is consistent across platforms

As @jason-simmons suggested, adding `maskValue` to the non-web side
provides consistency, similar to how enum-based text style attributes
expose their `index` property.

## Changes

- `engine/src/flutter/lib/ui/text.dart`: `class` → `final class`, add
`maskValue` getter
- `engine/src/flutter/lib/web_ui/lib/text.dart`: `class` → `final class`
(already has `maskValue`)
- `engine/src/flutter/testing/dart/text_test.dart`: add
`testTextDecoration` verifying `maskValue` for predefined and combined
decorations

No usages of `extends TextDecoration` or `implements TextDecoration`
exist in the codebase, so the `final` change has no internal impact.

## Tests

Added 3 test cases in `engine/src/flutter/testing/dart/text_test.dart`:
- `maskValue` returns correct bit mask for each predefined decoration
(`none`, `underline`, `overline`, `lineThrough`)
- `maskValue` returns combined bit mask for `TextDecoration.combine`
with partial decorations
- `maskValue` returns combined bit mask for all decorations combined

## Related Issue

Closes https://github.com/flutter/flutter/issues/181662

---

### Fixes future warning for `await`ing `Future` returns in `async` bodies inside `try` blocks (#182301)
- **Author**: Felipe Morschel
- **Date**: 2026-02-27
- **Link**: https://github.com/flutter/flutter/commit/b31c97ceb13c4ebfb32406c71d89a4986abba1d4



---

### Fix issue where web embedder is synthesizing key up events too eagerly (#180692)
- **Author**: Onnimanni Hannonen
- **Date**: 2026-02-27
- **Link**: https://github.com/flutter/flutter/commit/46a3d37f814f7191dfc92b10e04d9ff60df7541c



---

### [web] Fix stack corruption in Skwasm and harden withStackScope API (#182912)
- **Author**: Harry Terkelsen
- **Date**: 2026-02-26
- **Link**: https://github.com/flutter/flutter/commit/2ba67e99809b85c50377efb121f5d94fd1a7d38a

This PR fixes a critical memory crash in Skwasm. The root cause was the
incorrect usage of `withStackScope` with an `async` closure in
`SkwasmSurface.rasterizeToImageBitmaps`.

Because `withStackScope` restores the WASM linear memory stack
immediately after the closure returns, any asynchronous yields (waits)
inside the closure would cause the stack to be reclaimed while the
closure was still potentially using pointers to that memory.

Changes:
- Fixed `SkwasmSurface.rasterizeToImageBitmaps` to use a synchronous
closure and handle initialization outside the stack scope.
- Hardened `withStackScope` to throw a `StateError` at runtime if the
provided closure returns a `Future`, preventing this class of bug from
reoccurring.
- Added a dedicated test suite in
`web_ui/test/skwasm/raw_memory_test.dart` to verify the safety check.

Fixes https://github.com/flutter/flutter/issues/182367

---

### Paint the paragraph as a single image (#181206)
- **Author**: Rusino
- **Date**: 2026-02-25
- **Link**: https://github.com/flutter/flutter/commit/c847578020cf133ed1bd2a82dc1f180a3aef9daa



---

### [web] Fix failure on Firefox 148 (#182855)
- **Author**: Mouad Debbar
- **Date**: 2026-02-25
- **Link**: https://github.com/flutter/flutter/commit/b31548feb941947afb7c0c4b2be9f6584fe1a41c

Prior to 148, Firefox didn't have support for `TrustedTypes`, so it made
sense to always run the non-TrustedTypes test on Firefox.

With 148, Firefox [added
support](https://www.firefox.com/en-US/firefox/148.0/releasenotes/) for
TrustedTypes, but we are still running the non-TrustedTypes tests on
Firefox.

Solution: instead of skipping tests based on browser name, let's detect
at runtime if the browser supports TrustedTypes or not.

Example failure:
https://logs.chromium.org/logs/flutter/buildbucket/cr-buildbucket/8688958443747938497/+/u/test:_run_suite_firefox-dart2js-canvaskit-canvaskit/stdout

---

### [web] Run webparagraph tests in CI (#182092)
- **Author**: Mouad Debbar
- **Date**: 2026-02-24
- **Link**: https://github.com/flutter/flutter/commit/7672bd756ac34099907137e51f276ee5c0cfb582

Part of https://github.com/flutter/flutter/issues/172561

---

### [web] scroll iOS iframe text input into view (#179759)
- **Author**: zhongliugo
- **Date**: 2026-02-23
- **Link**: https://github.com/flutter/flutter/commit/ee7e28ec979562d0ab722fd24b5e145068ec6b63

Fixes https://github.com/flutter/flutter/issues/178743

**Summary**
Ensure iOS text inputs inside iframes are scrolled into view instead of
being covered by the keyboard.

**Before change**
https://flutter-demo-02-before.web.app/

**After change**
https://flutter-demo-02-after.web.app/

---

### fix(web_ui): use static whitelist for image codec tests (#182648)
- **Author**: Harry Terkelsen
- **Date**: 2026-02-20
- **Link**: https://github.com/flutter/flutter/commit/6d42ae50140884ec72886665cfb5d4bf39f30afe

The `codecs_test.dart` previously fetched all images from
`/test_images/` dynamically. This caused flakiness when Skia added new
images that were purposely undecodable or problematic for the Flutter
web engine.

This change introduces a static whitelist of verified test images and
removes the dynamic fetching logic. It also cleans up obsolete skip
conditions for images that are no longer in the whitelist.

Fixes #182629

---

### Manual roll Skia from 7bbdc51ab0aa to ce5854495a3a (#182637)
- **Author**: Jason Simmons
- **Date**: 2026-02-19
- **Link**: https://github.com/flutter/flutter/commit/6c9a881a59f6a2e79e0896e0b475ee9293983947

Includes a workaround for a Skia BMP test image that is not compatible
with Safari.

---

### [web] Stop double loading fonts for WebParagraph (#182026)
- **Author**: Mouad Debbar
- **Date**: 2026-02-19
- **Link**: https://github.com/flutter/flutter/commit/0ef66c7d1a4c3ed303fdd2aa0349d39955b0e0ef

Asset fonts were being downloaded twice for historical reasons that
don't apply to Chrome.

---

### [web] Pass form validation errors to screen readers via aria-description (#180556)
- **Author**: zhongliugo
- **Date**: 2026-02-18
- **Link**: https://github.com/flutter/flutter/commit/c023e5b2474f8ff1c146240dd685237cd8490f89

Fixes part of #180496

## Summary
Pass form validation errors to screen readers via `aria-description` on
text fields.

**Before:** 
https://flutter-demo-04-before.web.app/

**After:** 
https://flutter-demo-04-after.web.app/

## Limitations & Future Work

This handles **string-based errors** (`errorText`). For more complex
cases(brought in
https://github.com/flutter/flutter/issues/180496#issuecomment-3713178684),
a follow-up implementation using `aria-describedby` with element IDs is
tracked in #180496:

- Custom error widgets (`InputDecoration.error`)
- Errors outside `InputDecoration`
- Custom announcement ordering

The `aria-description` approach (current) and `aria-describedby`
approach (future) can coexist per ARIA specifications.

## Related
- Related discussion: #169157 comments

---

### Implement getUniformMatX and getUniformMatXArray functionality on web (#182249)
- **Author**: walley892
- **Date**: 2026-02-17
- **Link**: https://github.com/flutter/flutter/commit/8f61855dede30a55e9e00c9cb0caa62829798cd1

What it says on the tin.

Implementes getUniformMat2, getUniformMat3, getUniformMat4,
getUniformMat2Array, getUniformMat3Array, and getUniformMat4Array on the
web. This will allow users to get matrix uniforms by name.

Also adds tests for existing matrix functionality on web.

Before:
```dart
setFloat(0, 1.0);
setFloat(1, 0.0);
setFloat(2, 0.0);
setFloat(3, 1.0);
```

After:
```
shader.getUniformMat2('uIdentity').set(
    1.0, 0.0,
    0.0, 1.0,
)
```

---

### [Web] Fix IME and selection by syncing more text styles (#180436)
- **Author**: Koji Wakamiya
- **Date**: 2026-02-14
- **Link**: https://github.com/flutter/flutter/commit/8798c519980c81b6149679b6c16fcfb9222fcb2b

fix https://github.com/flutter/flutter/issues/161592

The current implementation does not fully reflect
[letter-spacing](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/letter-spacing),
[word-spacing](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/word-spacing),
and
[line-height](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/line-height)
in the DOM. 0bc99f8c4f70973a1877c88ca35804e9bc5fabcf
And the current implementation generates an DomHTMLTextAreaElement every
time the `enabled`. Therefore, it reapplies the
[scrollTop](https://developer.mozilla.org/en-US/docs/Web/API/Element/scrollTop)
value that the Element had been holding internally.
726491298d2b1f17681cab421c7c9276dde19ee6


https://github.com/user-attachments/assets/6f575366-12a0-4246-b2ab-eb2a0e85cfa5


https://github.com/user-attachments/assets/ec660d4c-5166-450c-be38-77b90fcfce76

```dart
import 'package:flutter/material.dart';

void main() => runApp(const MainApp());

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: MainPage());
  }
}

class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Selection position')),
      body: SingleChildScrollView(
        padding: const .all(16),
        child: Column(
          children: [
            const Text('height=null'),
            TextField(maxLines: 5, style: TextStyle(height: null)),
            const Text('height=1.0'),
            TextField(maxLines: 5, style: TextStyle(height: 1.0)),
            const Text('height=2.0'),
            TextField(maxLines: 5, style: TextStyle(height: 2.0)),
          ],
        ),
      ),
    );
  }
}
```

---

### [web] Makes Tappable semantics behavior adaptive (#182167)
- **Author**: chunhtai
- **Date**: 2026-02-12
- **Link**: https://github.com/flutter/flutter/commit/6ac6d3ec0f4fdac87f2c783e2d603d960ec832e8



---

### [web] Fix scroll event bubbling in iframes (#179703)
- **Author**: zhongliugo
- **Date**: 2026-02-12
- **Link**: https://github.com/flutter/flutter/commit/7bafe12c4f69c41b8bee4466296e6a30ba3564ea

Fixes scroll event bubbling when Flutter web is embedded in an
iframe(#156985).

When a scrollable handles a wheel event, it now calls
respond(allowPlatformDefault: false) to signal the engine.

In iframe mode, the engine always calls preventDefault() to block native
scroll chaining, then uses postMessage to explicitly scroll the parent
page only when all scrollables are at boundary

Before change:
https://issue-156985-before.web.app/

After change:
https://issue-156985-after.web.app/

---

### engine: Use a super-parameter in one missed case (#181914)
- **Author**: Sam Rawlins
- **Date**: 2026-02-11
- **Link**: https://github.com/flutter/flutter/commit/bacb47284f209337fbae4011636ab915474629f3

Work towards https://github.com/dart-lang/sdk/issues/58729

The lint rule will suggest using a super-parameter for a named parameter
even if the positional parameters cannot be super-parameters.

---

### Update web ui fragment shader tests (#181877)
- **Author**: walley892
- **Date**: 2026-02-10
- **Link**: https://github.com/flutter/flutter/commit/836c295085f1250e7f1127ac65dc69d03a2b7db4

Adds a bunch of tests for uniform setting functionality for custom
fragment shaders on the web.

Deletes redundant tests.

Fixes a discovered issue in the uniform offset calculation. We were
previously using the `location`, which is the integer offset of the
uniform, not the offset in floats.

---

### Add getUniformMatX support for desktop and mobile (#182117)
- **Author**: walley892
- **Date**: 2026-02-10
- **Link**: https://github.com/flutter/flutter/commit/409d62612bcc32cc0a552e96f84af875b3095e5c

Adds getUniformMatX and getUniformMatXArray functions to desktop and
mobile.

Also fixes a padding issue with mat3s on Vulkan.

---

### Bump Dart to 3.10 (#174066)
- **Author**: Loïc Sharma
- **Date**: 2026-02-09
- **Link**: https://github.com/flutter/flutter/commit/499812219444c39c22689d4a4b336b053511e426

This version of Dart supports dot shorthands.

Follow-up to: https://github.com/flutter/flutter/issues/180607

See also:

 * https://flutter.dev/go/flutter-style-updates
 * https://github.com/flutter/flutter/pull/181934

---

### perf: web ui loadFontFromList (#181440)
- **Author**: jingweicai
- **Date**: 2026-02-06
- **Link**: https://github.com/flutter/flutter/commit/e12f8c282fdb5cef62d8e64f41520c813ec1fb13



---

### In the Web codec tests, skip an undecodable image that is used to test a Skia error handling code path. (#181870)
- **Author**: Jason Simmons
- **Date**: 2026-02-04
- **Link**: https://github.com/flutter/flutter/commit/f539ad0bfe684e58a59fb132222344f0095dae1f

A recent Skia change added an invalid image file that tests a decoding
failure case (see
https://skia.googlesource.com/skia/+/12cb69b2700acfccee52bacf63321800af8c138c)

That file should be excluded from the set of Skia image assets used by
the Flutter Web codec tests.

---

### fix(web_ui): handle non-invertible matrices in ImageFilter.matrix (#181742)
- **Author**: Harry Terkelsen
- **Date**: 2026-02-03
- **Link**: https://github.com/flutter/flutter/commit/9b9f9975c76a1474b96426d22cd34cc589ad6f53

In CanvasKit, `MakeMatrixTransform` returns null if the matrix is
non-invertible (e.g., all zeros or zero scale). Previously, the web
engine assumed this would always return a valid object, leading to a
crash when calling methods like `delete()` or `getOutputBounds()` on the
null result.

This change:
- Updates `MakeMatrixTransform` signature to allow returning null.
- Gracefully handles null filters in `CkMatrixImageFilter` by skipping
the borrow callback.
- Defaults `filterBounds` to `ui.Rect.zero` when the filter is null,
indicating that no content is rendered.
- Adds a comprehensive test suite to ensure non-invertible matrices do
not cause crashes during scene building or painting.

Fixes https://github.com/flutter/flutter/issues/181411

---

### [Web] Fix flt-platform-view comment (#181576)
- **Author**: Loïc Sharma
- **Date**: 2026-02-03
- **Link**: https://github.com/flutter/flutter/commit/41389b123c5137ebf36fc0813ed7fe1f9d068a99



---

### Fix P3-to-sRGB color conversion to operate in linear light (#181720)
- **Author**: nmarci89
- **Date**: 2026-01-30
- **Link**: https://github.com/flutter/flutter/commit/f8aaee56949afc14a49b3a30ad613e735dff08bf



---

### [web] Use defensive null check in text editing placeElement (#180795)
- **Author**: zhongliugo
- **Date**: 2026-01-29
- **Link**: https://github.com/flutter/flutter/commit/fc6d13a1b2d365083f6aae715629df982c5bc8f8

Fixes #178619

Uses defensive null check (?.) instead of null assertion (!) when
calling focusWithoutScroll() on focusedFormElement in
GloballyPositionedTextEditingStrategy.placeElement().

This prevents a crash that can occur due to a race condition where
hasAutofillGroup returns true but focusedFormElement is null by the time
it's accessed.

---

### Don't pass bounds to saveLayer call when painting ImageFilter (#181353)
- **Author**: Harry Terkelsen
- **Date**: 2026-01-27
- **Link**: https://github.com/flutter/flutter/commit/12052207976a8d58a93a99ce3f6597237a4677cb

This causes the filter to apply incorrectly with certain TileModes in
Skwasm.

Fixes https://github.com/flutter/flutter/issues/178028

---

### Fixing getPositionForOffset (#180913)
- **Author**: Rusino
- **Date**: 2026-01-21
- **Link**: https://github.com/flutter/flutter/commit/3b206173454ec192938126322c58b5a1f090652f

It had few bugs and also baseline APIs for WebParagraph were not
implemented (they make little sense but still)

---

### [Android] Add display corner radii support. (#179219)
- **Author**: Kostia Sokolovskyi
- **Date**: 2026-01-21
- **Link**: https://github.com/flutter/flutter/commit/697572a67c43255354d761ff38959cc5bcd1718a

Closes https://github.com/flutter/flutter/issues/97349
Unblocks https://github.com/flutter/flutter/issues/178463

### Description

This PR focuses only on the Android side.

As was discussed in https://github.com/flutter/flutter/issues/97349, the
iOS API for getting display corner radii is private. The only safe way
to get the radii values is to generate a lookup table ahead and use its
values at runtime. I would be happy to work on the iOS implementation in
a separate PR after this lands.

- Adds `displayCornerRadii` in the physical pixels to the engine's
window metrics
- Adds `displayCornerRadii` support on the Android API 31+
- Adds `displayCornerRadii` in the logical pixels to the `MediaQuery`
- Adds and updates tests

---

### Improve the algorithm for rounded superellipse paths to work better at very large ratio (#180453)
- **Author**: Tong Mu
- **Date**: 2026-01-20
- **Link**: https://github.com/flutter/flutter/commit/5d93b2e71b3380bd0d2e4f0daf14379fcbd64a4d

This PR uses a new algorithm that approximates the superellipse curve
with two conic curves, instead of one cubic curves. This algorithm works
much better at very large ratio. Fixes
https://github.com/flutter/flutter/issues/179875 .

A new playground is added in this PR to show enlarged corner of a
rounded superellipse at very large ratio and compares its path version
and filled version.

<details>
<summary>
For comparison: The best result possible with one cubic curve
</summary>

As the following video shows, the flat segment of the superellipse curve
is the hardest to approximate, since most of its curvature happens near
the right end. The best that a single cubic curve can do is close to a
straight line.


https://github.com/user-attachments/assets/2ed1666d-f96c-4465-9d5c-1f8f4a660bba

Although the largest deviation is only ~1e-6, the "feeling" from the
lack of curvature is sensible as shown in the following screenshot.

<img width="476" height="543" alt="image"
src="https://github.com/user-attachments/assets/6e6b96ed-80b3-487c-b621-3cddd4537ec0"
/>

</details>

**Result after this PR:**


https://github.com/user-attachments/assets/d0012e62-f61f-4d69-95a5-27646c0bb750

The following screenshot shows the reproduction app as commented in
https://github.com/flutter/flutter/issues/179875#issuecomment-3672426282
after the PR:

<img width="476" height="543" alt="image"
src="https://github.com/user-attachments/assets/d93b83be-a9fc-4b25-aca2-0e2c3f9a7e56"
/>

For comparison, the following screenshot shows the same shape drawn as
filled:

<img width="476" height="543" alt="image"
src="https://github.com/user-attachments/assets/bf94a20a-278b-42a2-9162-5aa4a61915af"
/>

**Before the PR:**
<img width="1024" height="796" alt="image"
src="https://github.com/user-attachments/assets/053cc229-01f1-4181-97a6-48b96bf16fcf"
/>

Also, a new golden test:
<img width="2400" height="1800" alt="image"
src="https://github.com/user-attachments/assets/6e741066-89a3-4282-bdc2-fa02b1eea14d"
/>

---

### Fix style_manager_test for Firefox (#181084)
- **Author**: Harry Terkelsen
- **Date**: 2026-01-16
- **Link**: https://github.com/flutter/flutter/commit/c652e45cd186c364ee641d041a33e520a452ed63

Fixes style_manager_test.dart for Firefox by

1. changing the CSS to explicitly set `outline: rgb(0, 0, 0) none 0px`
2. actually focusing the element before checking it's computed style

Fixes https://github.com/flutter/flutter/issues/180940

---

### Add support for fetching array uniforms by name (#180647)
- **Author**: walley892
- **Date**: 2026-01-16
- **Link**: https://github.com/flutter/flutter/commit/3b49eb44295023848d7c2ec1a680dc4202462b5d

Adds support for fetching objects representing array Uniforms of type
float, vec2, vec3, and vec4. Happy new year!

Before this change, setting an array of uniforms was verbose.
```glsl
uniform vec3[2] uColors;
```

```dart
shader.setFloat(0, 1.0);
shader.setFloat(1, 0.0);
shader.setFloat(2, 1.0);
shader.setFloat(3, 0.0);
shader.setFloat(4, 1.0);
shader.setFloat(5, 0.0);
```

After this change, we have:

```glsl
uniform vec3[2] uColors;
```

```dart
final colors = shader.getUniformVec3Array("uColors");
colors[0].set(1.0, 0.0, 1.0);
colors[1].set(0.0, 1.0, 0.0);
```

- Adds a class UniformArray to represent uniform arrays in Dart.
- Adds a bunch of methods that construct these arrays for various
datatypes
- Adds tests
- Also removes some of the awkwardness in the _getUniformFloatIndex
function by replacing that function entirely

---

### Fix bug in multisurfacerenderer where canvases do not have "position: absolute" (#181053)
- **Author**: Harry Terkelsen
- **Date**: 2026-01-15
- **Link**: https://github.com/flutter/flutter/commit/5cefaad4a587cce8ca1a216310bb5d9327aa7568

When using MultiSurfaceRasterizer, the on-screen canvases did not have
`position: absolute`, causing layout issues when platform views with
overlaid content was rendered.

Fixes internal bug b/475770800

---

### Fix style manager test by actually focusing the tested element. (#181012)
- **Author**: Harry Terkelsen
- **Date**: 2026-01-15
- **Link**: https://github.com/flutter/flutter/commit/abe64db7ba57be1ace46ec34d57f1f1090fbee7c

The test was incorrect before since it assumed
`getComputedStyle(element, 'focus')` gets the style for element when it
is focused. Instead, it just gets the default style since the `'focus'`
parameter doesn't specify a real pseudo-element or pseudo-class. This
fixes the test by manually focusing the element and then getting the
computed style. This returns the computed style of the element when it
is focused.

Fixes https://github.com/flutter/flutter/issues/180940

---

### Skip flaky test on Firefox (#180941)
- **Author**: Harry Terkelsen
- **Date**: 2026-01-14
- **Link**: https://github.com/flutter/flutter/commit/0eab137bcdd15c41cb8413f446211349cc2ed579

Skips flaky test on Firefox until
https://github.com/flutter/flutter/issues/180940 is fixed.

---

### Add support for reduced motion/disable animations on the web (#180041)
- **Author**: David Iglesias
- **Date**: 2026-01-14
- **Link**: https://github.com/flutter/flutter/commit/c62f8891b7604b7eab9154c295c60d00cd9f034c

This PR listens to changes to the value of the `(prefers-reduced-motion:
reduce)` media query to update the `reduceMotion` and
`disableAnimations` properties of the `AccessibilityFeatures`
configuration object.

This is achieved by introducing a new `MediaQueryManager` object to the
`EnginePlatformDispatcher` that handles handles all the engine
configuration values that are driven by media queries: "reduced motion",
"high contrast" and "dark mode".

Unifying the code paths of all these values, allows this PR to slightly
increase testing coverage of those values, by injecting fake browser
events in the `platform_dispatcher_test.dart` file.

### Issues

* Fixes #167566

### Testing

* Added browser tests for new (and existing) media-queries
* Deployed test app to: https://dit-tests.web.app (may get offline!)

---

### [web] Fix loading of fragment shader with space in name. (#180919)
- **Author**: Kostia Sokolovskyi
- **Date**: 2026-01-14
- **Link**: https://github.com/flutter/flutter/commit/bc63dfe662d6b18ad8fed6bdcc9d91eeb2d8e76d

Fixes https://github.com/flutter/flutter/issues/180862

### Description

- Adds `assetKey` encoding in `FragmentProgram.fromAsset` in `web_ui` to
be consistent with the implementation in `ui`

https://github.com/flutter/flutter/blob/7e176f8c3fde96342b2c61e5b4043d53113a2b31/engine/src/flutter/lib/ui/painting.dart#L5354-L5369
- Adds test

---

### [canvaskit] Fix image decoding in CPU-only mode (#180706)
- **Author**: Harry Terkelsen
- **Date**: 2026-01-13
- **Link**: https://github.com/flutter/flutter/commit/3b7caba768bd2a259b426df3dcbe37da128957ab

In CPU-only rendering mode, we were using
`MakeLazyImageFromTextureSource` which only works if a WebGL context is
available (which it isn't in CPU-only mode). This fixes the problem by
using `MakeImageFromCanvasImageSource` which uses a 2d canvas when we
have fallen back to software rendering.

Fixes https://github.com/flutter/flutter/issues/175423

---

### Move all getUniformX tests to web_ui/test. (#180910)
- **Author**: walley892
- **Date**: 2026-01-13
- **Link**: https://github.com/flutter/flutter/commit/264816f75c171e7ac58e87e21bae94e358afc1d0

- Moves all the existing web tests for getUniformX to web_ui/tests.

- Commits shaders to github in addition to the impellerc generated
string. Had to manually translate them from the dumped SKSL string to
GLSL and recompile, there may be small differences.

- Updates the impellerc generated strings

Does not fix the web testing build system to have this happen in a
non-brittle way. That should happen at some point.

---

### Add new motion accessibility features to iOS. (#178102)
- **Author**: Kostia Sokolovskyi
- **Date**: 2026-01-08
- **Link**: https://github.com/flutter/flutter/commit/3892c57dd61337cbef918c69e8562b9f89fd16bb

Closes https://github.com/flutter/flutter/issues/177330
Contributes to https://github.com/flutter/flutter/issues/175878

### Description

This PR implements support for three new iOS accessibility motion
features.
- `Auto-Play Animated Images`: Informs the app when the user has chosen
to pause automatically playing GIFs and other animated content.
- `Auto-Play Video Previews`: Informs the app when the user has disabled
the automatic playback of video previews.
- `Prefer Non-Blinking Cursor`: Informs the app that the user prefers a
non-blinking text insertion indicator in editable text fields.

The original issue requested seven features. I was able to find and
implement features with clear, public, and general-purpose APIs.

The remaining features were not included for the following reasons:

- `Vehicle Motion Cues`: No public API found.
- `Auto-Play Message Effects`: No public API found. This is likely a
feature exclusive to the Messages framework.
- `Limit Frame Rate`: No public API found.
- `Dim Flashing Lights`: There is a public API available
[MADimFlashingLightsEnabled](https://developer.apple.com/documentation/mediaaccessibility/madimflashinglightsenabled()).
It is intended for media playback frameworks. It's unclear if exposing
this feature is necessary or actionable for a general-purpose
application UI.

| Feature Name | API | Flutter AccessibilityFeatures |
| :-: | :-: | :-: |
| Vehicle Motion Cues | - | - |
| Dim Flashing Lights |
[MADimFlashingLightsEnabled](https://developer.apple.com/documentation/mediaaccessibility/madimflashinglightsenabled())
| - |
| Auto-Play Animated Images |
[animatedImagesEnabled](https://developer.apple.com/documentation/accessibility/accessibilitysettings/animatedimagesenabled)
| autoPlayAnimatedImages |
| Auto-Play Video Previews |
[isVideoAutoplayEnabled](https://developer.apple.com/documentation/uikit/uiaccessibility/isvideoautoplayenabled)
| autoPlayVideos |
| Auto-Play Message Effects | - | - |
| Prefer Non-Blinking Cursor |
[prefersNonBlinkingTextInsertionIndicator](https://developer.apple.com/documentation/accessibility/accessibilitysettings/prefersnonblinkingtextinsertionindicator)
| deterministicCursor |
| Limit Frame Rate | - | - |

The `AccessibilityFeatures.swift` was introduced to refactor all native
iOS accessibility logic into a single, dedicated class. This change
moves the responsibility of querying settings and observing
notifications out of `FlutterViewController.mm`, which cleans up the
controller, simplifies future maintenance, and makes logic
unit-testable.

### Demo


https://github.com/user-attachments/assets/1b3e7a2f-03b4-4716-959e-dbeea938e4d2

<details closed><summary>Code sample</summary>

```dart
import 'package:flutter/material.dart';

void main() {
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Screen(),
    ),
  );
}

class Screen extends StatefulWidget {
  @override
  State<Screen> createState() => _ScreenState();
}

class _ScreenState extends State<Screen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accessibilityFeatures = View.of(
      context,
    ).platformDispatcher.accessibilityFeatures;

    return Scaffold(
      body: Center(
        child: Column(
          spacing: 10,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final feature in [
              'accessibleNavigation: ${accessibilityFeatures.accessibleNavigation}',
              'invertColors: ${accessibilityFeatures.invertColors}',
              'disableAnimations: ${accessibilityFeatures.disableAnimations}',
              'boldText: ${accessibilityFeatures.boldText}',
              'reduceMotion: ${accessibilityFeatures.reduceMotion}',
              'highContrast: ${accessibilityFeatures.highContrast}',
              'onOffSwitchLabels: ${accessibilityFeatures.onOffSwitchLabels}',
              'supportsAnnounce: ${accessibilityFeatures.supportsAnnounce}',
              'autoPlayAnimatedImages: ${accessibilityFeatures.autoPlayAnimatedImages}',
              'autoPlayVideos: ${accessibilityFeatures.autoPlayVideos}',
              'deterministicCursor: ${accessibilityFeatures.deterministicCursor}',
            ])
              Text(feature),
          ],
        ),
      ),
    );
  }
}
```

</details>

---

### [web] Fix SemanticsService.announce not working inside dialogs (#179958)
- **Author**: zhongliugo
- **Date**: 2026-01-08
- **Link**: https://github.com/flutter/flutter/commit/773923a55d71f1a78a93564556d84fcc6f7342c9

Fixes #179076

**Solution**
When a modal dialog is present, temporarily move the existing aria-live
element inside the modal dialog before making the announcement, then
move it back afterward. A small delay is also added to allow VoiceOver
to finish reading the button's accessible name first.

**Demo**
Before (bug): https://flutter-demo-03-before.web.app
After (fix): https://flutter-demo-03-after.web.app

**Testing**
Enable VoiceOver (Cmd+F5 on macOS)
Open a dialog and click the "Announce" button
Verify the announcement is spoken after the button label

**Next step**
Filing a follow-up issue for: Adding a delay parameter to
SemanticsService.announce() API for developers who need custom delays
for long button labels

---

### Relands "Feat: Add a11y for loading indicators (#165173)" (#178402)
- **Author**: chunhtai
- **Date**: 2026-01-02
- **Link**: https://github.com/flutter/flutter/commit/423a30323c19cc302e3937b6dc367fe93b506ff0

This reverts commit ef29db350f0951ab976e2fdb5d092e65578329e5.

---

### [Framework] iOS style blurring and `ImageFilterConfig` (#175473)
- **Author**: Tong Mu
- **Date**: 2025-12-30
- **Link**: https://github.com/flutter/flutter/commit/0015d2b6bfa03e6db7c63e5d1a6d3c91ce0a947c

This PR adds the framework support for a new iOS-style blur. The new
style, which I call "bounded blur", works by adding parameters to the
blur filter that specify the bounds for the region that the filter
sources pixels from.

As discussed in design doc
[flutter.dev/go/ios-style-blur-support](http://flutter.dev/go/ios-style-blur-support),
it's impossible to pass layout information to filters with the current
`ImageFilter` design. Therefore this PR creates a new class
`ImageFilterConfig`.

This PR also applies bounded blur to `CupertinoPopupSurface`. The
following images show the different looks of a dialog in front of
background with abrupt color changes just outside of the border. Notice
how the abrupt color changes no longer bleed in.

<img width="639" height="411" alt="image"
src="https://github.com/user-attachments/assets/4ceb9620-1056-45c3-b5fa-2ed16d90aace"
/>

<img width="639" height="411" alt="image"
src="https://github.com/user-attachments/assets/abe564f7-ea60-4d07-ad58-063c0e3794a5"
/>

This feature continues to matter for iOS 26, since the liquid glass
design also heavily features blurring.

### API changes

* `BackdropFilter`: Add `filterConfig`
* `RenderBackdropFilter`: Add `filterConfig`. Deprecate `filter`.
* `ImageFilter`: Add `debugShortDescription` (previously private
property `_shortDescription`)

### Demo

The following video compares the effect of a bounded blur and an
unbounded blur.


https://github.com/user-attachments/assets/f715db44-c0a0-4ac8-a163-6b859665b032

<details>
<summary>
Demo source
</summary>

```
// Add to pubspec.yaml:
//
//  assets:
//      - assets/kalimba.jpg
//
// and download the image from
// https://github.com/flutter/flutter/blob/ec6f55023760ea4f44d311b9c69c39910f6b8b0c/engine/src/flutter/impeller/fixtures/kalimba.jpg

import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: BlurEditorApp()));

class ControlPoint extends StatefulWidget {
  const ControlPoint({
    super.key,
    required this.position,
    required this.onPanUpdate,
    this.radius = 20.0,
  });

  final Offset position;
  final GestureDragUpdateCallback onPanUpdate;
  final double radius;

  @override
  ControlPointState createState() => ControlPointState();
}

class ControlPointState extends State<ControlPoint> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.position.dx - widget.radius,
      top: widget.position.dy - widget.radius,
      child: MouseRegion(
        onEnter: (_) { setState((){ isHovering = true; }); },
        onExit: (_) { setState((){ isHovering = false; }); },
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          onPanUpdate: widget.onPanUpdate,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: widget.radius * 2,
            height: widget.radius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isHovering
                  ? Colors.white.withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.4),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                if (isHovering)
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.5),
                    blurRadius: 10,
                    spreadRadius: 2,
                  )
              ],
            ),
            child: const Icon(Icons.drag_indicator, size: 16, color: Colors.black54),
          ),
        ),
      ),
    );
  }
}

class BlurPanel extends StatelessWidget {
  const BlurPanel({super.key, required this.blurRect, required this.bounded});

  final Rect blurRect;
  final bool bounded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    'assets/kalimba.jpg',
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned.fromRect(
                  rect: blurRect,
                  child: ClipRect(
                      child: BackdropFilter(
                    filterConfig: ImageFilterConfig.blur(
                        sigmaX: 10, sigmaY: 10, bounded: bounded),
                    child: Container(),
                  )),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              bounded ? 'Bounded Blur' : 'Unbounded Blur',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class BlurEditorApp extends StatefulWidget {
  const BlurEditorApp({super.key});

  @override
  State<BlurEditorApp> createState() => _BlurEditorAppState();
}

class _BlurEditorAppState extends State<BlurEditorApp> {
  Offset p1 = const Offset(100, 100);
  Offset p2 = const Offset(300, 300);

  @override
  Widget build(BuildContext context) {
    final blurRect = Rect.fromPoints(p1, p2);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                  child: BlurPanel(blurRect: blurRect, bounded: true),
                ),
                Expanded(
                  child: BlurPanel(blurRect: blurRect, bounded: false),
                ),
              ],
            ),
          ),

          ControlPoint(position: p1, onPanUpdate: (details) { setState(() => p1 = details.globalPosition); }),
          ControlPoint(position: p2, onPanUpdate: (details) { setState(() => p2 = details.globalPosition); }),
        ],
      ),
    );
  }
}

```

</details>

---

### Allow setting vector uniforms by name. (#179927)
- **Author**: walley892
- **Date**: 2025-12-29
- **Link**: https://github.com/flutter/flutter/commit/b51ad9db3808c15954700467f6de92e7c20b66da

Create a few thin wrappers around `UniformFloatSlot` that allow users to
get Vector uniforms by name and set all elements in one go.

Before:
```dart
shader.getUniformFloat('uColor', 0).set(color.r);
shader.getUniformFloat('uColor', 1).set(color.g);
shader.getUniformFloat('uColor', 2).set(color.b);
```

After:
```dart
shader.getUniformVec3('uColor').set(color.r, color.g, color.b);
```

This enforces that the requested vector is actually of the requested
size. For example:
```dart
shader.getUniformVec2('someVec3Uniform');
```
will fail instead of allowing partial uniform access.

## Follow up
This doesn't add list or matrix datatypes, those will come later. 
Also doesn't have anything super fancy like accessors/setters for
individual elements.

---

### [Engine] iOS style blurring (#175458)
- **Author**: Tong Mu
- **Date**: 2025-12-22
- **Link**: https://github.com/flutter/flutter/commit/906d520c2bee7849ec97ed36f1d9f906975d9db1

This PR adds the engine support for a new iOS-style blur. It works by
adding parameters to the blur filter that specify its _blurring bounds_.

This is the engine-side implementation. The corresponding framework
changes that expose this to developers are in:
* Framework PR: https://github.com/flutter/flutter/pull/175473

Related issues:
* Main tracking issue: https://github.com/flutter/flutter/issues/99691
* Algorithm details:
https://github.com/flutter/flutter/issues/164267#issuecomment-2731163225

Design doc & previous discussions:
[flutter.dev/go/ios-style-blur-support](flutter.dev/go/ios-style-blur-support)

### The Visual (Before & After)

This new mode, which I'm calling "bounded blur," is different from the
traditional (global) gaussian blur in that blurs would not sample
transparent pixels from outside the provided area.

The demo below shows the old blur (left) and the new bounded blur
(right). Both are blurring a black triangle.

<img width="1008" height="557" alt="image"
src="https://github.com/user-attachments/assets/202fa4a1-a61f-4357-9dce-73c545cf3b07"
/>

<img height="557" alt="image"
src="https://github.com/user-attachments/assets/0d544e6a-4c88-488d-84c3-60d617c9d614"
/>

Notice the new version on the right no longer has the bright "lining" at
the top and left edges. This is because the blur algorithm now knows its
own bounds and correctly stops sampling pixels from outside that area.

### Technical details

#### API Change

To pass the bounds information down, I've added new parameters to
`_initBlur`:

```dart
  // painting.dart
  external void _initBlur(
    double sigmaX,
    double sigmaY,
    int tileMode,
    bool bounded,  // Start of new parameters
    double boundsLeft,
    double boundsTop,
    double boundsRight,
    double boundsBottom,
  );
```

#### How the Bounds Are Used
These bounds are passed all the way down to `GaussianBlurFilterContents`
and affect two key parts of the process:

* Downsampling Pass: The shader is instructed not to sample any pixels
outside the provided bounds.
* Blurring Passes: The final blurred result is divided by the resulting
opacity. This normalizes the varying alpha (due to varying sum of
weights) across the pixels near the edge.

#### Notable Engine Changes
To handle the downsampling logic, I created a new downsampling shader
`texture_downsample_bounded`.

---

### [reland] Unify canvas creation and Surface code in Skwasm and CanvasKit (#179473)
- **Author**: Harry Terkelsen
- **Date**: 2025-12-19
- **Link**: https://github.com/flutter/flutter/commit/effb2e1ac169524ffc21b72dde571a04d6c0d898

This PR introduces a significant refactoring of the web engine's
rendering layer by unifying the Surface and Rasterizer implementations.
These components have been moved from being renderer-specific to a
generic compositing directory, making the architecture more modular and
easier to maintain. The rasterizers are now renderer-agnostic and are
provided with renderer-specific surface factories via dependency
injection. A new CanvasProvider abstraction has also been introduced to
manage the lifecycle of the underlying canvas elements.

A key outcome of this work is that the Skwasm backend now correctly
handles WebGL context loss events. This was achieved by refactoring
SkwasmSurface to allow the Dart side to manage the OffscreenCanvas
lifecycle. A communication channel between the main thread and the web
worker is now used to gracefully handle context loss and recovery. This
effort also included fixing several related bugs around surface sizing,
resource cleanup, and callback handling in multi-surface scenarios.

To validate these changes, new testing APIs have been added to allow for
the creation of renderer-agnostic surface tests. A new test file,
surface_context_lost_test.dart, has been added to verify the context
loss and recovery behavior across all supported renderers, ensuring the
new architecture is robust and reliable.

---

### [ Web ] Pass `--enable-experimental-ffi` when compiling WASM tests (#180127)
- **Author**: Ben Konyi
- **Date**: 2025-12-19
- **Link**: https://github.com/flutter/flutter/commit/adfcf515fd2dc2e182f02c4525daeb456599cc8d

The CFE will start treating unsupported library imports as errors in an
upcoming change (see https://github.com/dart-lang/sdk/issues/62125)
which will cause web engine compilation tests to fail without the
`--enable-experimental-ffi` flag.

This change passes `--enable-experimental-ffi` to `dart2wasm` in
preparation for this change in behavior.

---

### [web] Fix `resizeToAvoidBottomInset` on Android web (#179581)
- **Author**: Mouad Debbar
- **Date**: 2025-12-15
- **Link**: https://github.com/flutter/flutter/commit/34bb652f5949e1223fc5f5e0c01bd752b04c8762

Fixes https://github.com/flutter/flutter/issues/175074

There was an implicit expectation in the resizing code: When the virtual
keyboard is up on mobile, the view's `physicalSize` remains fixed, and
any resizes (presumably caused by the virtual keyboard itself) should be
considered as `viewInsets`.

This expectation was broken inadvertently by my PR:
https://github.com/flutter/flutter/pull/172493

<hr>

The sequence of events that lead to the reported issue:

1. View's physical size is calculated based on window size.
2. Text editing starts, virtual keyboard comes up.
3. View's physical size remains unchanged, and the difference caused by
the keyboard is reported as view insets to the framework.
4. (so far so good).
5. When `resizeToAvoidBottomInset` is true, the framework will re-render
its content to fit the available size.
6. The new render call comes with a new size that's basically `physical
height - bottom inset`.
7. The engine takes that new size and applies it to the DOM.
8.  (now the view's DOM element has been resized incorrectly).
9. ...
10. Eventually, this leads to the new insets being calculated
incorrectly resulting in negative insets which cause the framework to
throw.

<hr>

The fix involves the following:
1. Respect the expectation mentioned above: when the keyboard is up,
view's physical size should remain unchanged.
2. *_If_* we ever end up with negative insets, catch it earlier in the
engine so it's easier to debug the root cause.
3. New regression test.

---

### Add FilterQuality parameter to FragmentShader.setImageSampler (#179760)
- **Author**: b-luk
- **Date**: 2025-12-12
- **Link**: https://github.com/flutter/flutter/commit/add442b29ca6b883407d62e4ca3c373b8bad458c

Add FilterQuality parameter to FragmentShader.setImageSampler

Fixes #133944

---

### Update Skwasm to engine style guidelines. (#179756)
- **Author**: Jackson Gardner
- **Date**: 2025-12-12
- **Link**: https://github.com/flutter/flutter/commit/19633544a4ae1f2f99d31384ec6546d225977d6d

This updates the Skwasm library to conform to the style of the rest of
the engine. This includes:
* Moving the location of the skwasm library into
`engine/src/flutter/skwasm` instead of
`engine/src/flutter/lib/web_ui/skwasm`, since that was altogether too
nested and weird.
* Changed all the file extensions to `.cc` instead of `.cpp`
* Changed all local include paths to be from the `engine/src/flutter`
directory rather than relying on the source file's location.
* Changed ordering of include paths.
* Removed instances of `using namespace`
* Changed local variable names and argument names to use snake_case
* Changed class functions to use UpperCamelCase
* Changed private member variables to use trailing_ underscore instead
of _leading.
* Removed some uses of `auto`

---

### Implements decodeImageFromPixelsSync (#179519)
- **Author**: gaaclarke
- **Date**: 2025-12-12
- **Link**: https://github.com/flutter/flutter/commit/feaec27593d3fa0003be37f450dce4f99bc3b959

fixes https://github.com/flutter/flutter/issues/178488

This doesn't implement the following. They can be implemented in later
PRs.
- a skia implementation (maybe won't implement?)
- a web implementation
- resizing
- target pixel format

---

### [ios][pv] accept/reject gesture based on hitTest (with new widget API) (#179659)
- **Author**: hellohuanlin
- **Date**: 2025-12-11
- **Link**: https://github.com/flutter/flutter/commit/87d15897b220d62339c77260b429c645515b09e7

This is a follow up PR to [this original
PR](https://github.com/flutter/flutter/pull/177859).

The difference is the API - the original PR chooses Option 1 [in the
design
doc](https://docs.google.com/document/d/1ag4drAdJsR7y-rQZkqJWc6tOQ4qCbflQSGyoxsSC6MM/edit?tab=t.0),
while this PR chooses Option 3.

## Usage

To directly use flutter API, just pass in the policy when creating
UiKitView widget.

```
UiKitView(
  ...
  gestureBlockingPolicy: UiKitViewGestureBlockingPolicy)
  ...
)
```

For plugins, we need to update plugins to use this new API. 

```
WebView(
  ...
  gestureBlockingPolicy: UiKitViewGestureBlockingPolicy
) {
  return UiKitView(
    ..
    gestureBlockingPolicy: gestureBlockingPolicy
  )
}
```
For more information, refer to [the old
PR](https://github.com/flutter/flutter/pull/177859).



*List which issues are fixed by this PR. You must list at least one
issue. An issue is not required if the PR fixes something trivial like a
typo.*


https://github.com/flutter/flutter/issues/175099
https://github.com/flutter/flutter/issues/165787

*If you had to change anything in the [flutter/tests] repo, include a
link to the migration guide as per the [breaking change policy].*

---

### WebParagrah: ellipsis (#178748)
- **Author**: Rusino
- **Date**: 2025-12-09
- **Link**: https://github.com/flutter/flutter/commit/84b5f5372dc6908e92aea2980018a2b1ce4c92b9

Part of https://github.com/flutter/flutter/issues/172561

---------

Co-authored-by: Mouad Debbar <mdebbar@google.com>

---

### [wimp] Initial Impeller on Web implementation. (#175442)
- **Author**: Jackson Gardner
- **Date**: 2025-12-09
- **Link**: https://github.com/flutter/flutter/commit/e0f544bf6203cf30725792967491fe7074f8a94b

This PR adds an initial implementation of a impeller-based version of
skwasm. As of right now, the main things that are missing are:
* Image support https://github.com/flutter/flutter/issues/175371
* Custom shader support https://github.com/flutter/flutter/issues/175431
* Turn on MSAA https://github.com/flutter/flutter/issues/175441
* Multithreading is turned off
https://github.com/flutter/flutter/issues/178749

I plan on implementing these in smaller followup PRs.

Towards https://github.com/flutter/flutter/issues/174980

---

### Force WASM single threading in Chrome extensions. (#179400)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-12-05
- **Link**: https://github.com/flutter/flutter/commit/6e9567e973f50fdfcae8178ccb6356c9e515c689

Fixes https://github.com/flutter/flutter/issues/177974

### Description
- Forces WASM single-threading when running a web app as a Chrome
extension.

| BEFORE | AFTER |
| - | - |
| <video alt="before"
src="https://github.com/user-attachments/assets/4b67fce6-4bd7-4646-a0db-dc6ad2ec70aa"
/> | <video alt="after"
src="https://github.com/user-attachments/assets/3f0df9c5-7524-40db-a631-776777f855f9"/>
|

---

### [web] Add clone method to LayerPicture and dispose pictures in PictureLayer (#179162)
- **Author**: Harry Terkelsen
- **Date**: 2025-12-04
- **Link**: https://github.com/flutter/flutter/commit/42d6f773a5e5d05ee4a7f62851f0205b8be655c7

Fixes https://github.com/flutter/flutter/issues/82878

---

### Adds format argument to Picture.toImageSync (#178691)
- **Author**: gaaclarke
- **Date**: 2025-12-02
- **Link**: https://github.com/flutter/flutter/commit/d57f6f81c67b1d27298515d4c0dd790cf8dc92e3

fixes https://github.com/flutter/flutter/issues/178539

This allows users to chain together fragment shaders with pixel formats
other than rgba8.

---

### [web] Fix onTextScaleFactorChanged not getting called. (#178862)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-12-02
- **Link**: https://github.com/flutter/flutter/commit/daddf7ab8efedbdedba4d8c14613108816de80fa

Fixes https://github.com/flutter/flutter/issues/178856
Fixes https://github.com/flutter/flutter/issues/178271
Fixes https://github.com/flutter/flutter/issues/178238

### Description

- Fixes an issue in `lineHeightScaleFactorOverride` calculation, causing
it to have abnormal values.
- Integrates text scale factor update into recently added
`_addTypographySettingsObserver`. The `ResizeObserver` on the typography
probe element is getting notified each time the font size changes,
because it leads to the element's size change.
- Removes `DomMutationObserver` previously used for font size
observations.
- Adds/Updates tests to verify the fixes.

| BEFORE | AFTER |
| - | - |
| <video
src="https://github.com/user-attachments/assets/f62fb3c6-63e1-447f-b4ef-8f22ad944a0a"/>
| <video
src="https://github.com/user-attachments/assets/c220dd30-89d9-4f76-a43f-b908a940fafb"/>
|

### Demo

https://flutter-text-scale-factor.web.app

<details closed><summary>Code sample</summary>

```dart
import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Screen(),
    );
  }
}

class Screen extends StatefulWidget {
  const Screen({super.key});

  @override
  State<Screen> createState() => _ScreenState();
}

class _ScreenState extends State<Screen> with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 10,
            children: [
              Builder(
                builder: (context) {
                  print(
                    'lineHeightScaleFactorOverride: ${MediaQuery.maybeLineHeightScaleFactorOverrideOf(context)}',
                  );
                  final scale = MediaQuery.textScalerOf(context).scale(1);

                  return Text(
                    'Scale ${scale.toStringAsFixed(3)}',
                    style: TextStyle(
                      fontSize: 30,
                      backgroundColor: Colors.grey.shade200,
                    ),
                    textAlign: TextAlign.center,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

</details>

---

### Bump Dart to 3.9 (#179041)
- **Author**: Kate Lovett
- **Date**: 2025-11-24
- **Link**: https://github.com/flutter/flutter/commit/460d55e659ad8c8a2538d43c8f0c7971edabb640

Prep for https://github.com/flutter/flutter/issues/178827

This bumps Dart to 3.9.

We are holding off on 3.10 until we can include best practices for dot
shorthands in the style guide, which will follow the lint update in
#178827

---

### Update .ci.yaml in flutter/flutter to use either macOS 15.5 or macOS … (#178666)
- **Author**: Elijah Okoroh
- **Date**: 2025-11-21
- **Link**: https://github.com/flutter/flutter/commit/64c1b7d0d70edbe1aff9862fb2497c7c5b06d249

Update .ci.yaml in flutter/flutter to use 15.5 or 15.7.2

*List which issues are fixed by this PR. You must list at least one
issue. An issue is not required if the PR fixes something trivial like a
typo.*

Fixes #176930

*If you had to change anything in the [flutter/tests] repo, include a
link to the migration guide as per the [breaking change policy].*

---

### Corrects invalid Flutter wiki links (#178158)
- **Author**: Srivats Venkataraman
- **Date**: 2025-11-17
- **Link**: https://github.com/flutter/flutter/commit/811f9c4c9e2f6865516991458d7a8a012bd467de

Fixes: [#177797](https://github.com/flutter/flutter/issues/177797)

This PR replaces all flutter/wikis with the correct URL across all
READMEs

Note:

I wasn't able to find the correct readme for this:
https://github.com/flutter/flutter/wiki/Debugging-the-engine#debugging-windows-builds-with-visual-studio

---

### Impeller: Allows R32G32B32A32_SFLOAT images (#177959)
- **Author**: gaaclarke
- **Date**: 2025-11-13
- **Link**: https://github.com/flutter/flutter/commit/33a30cb318a3d711e11ed32cca8722bf6bfd1506

fixes https://github.com/flutter/flutter/issues/141289

design doc:
https://docs.google.com/document/d/1zpkMutZkqo2GVdMhiKzFURpgN8JDZTjtIVwwqqHKM90/edit?tab=t.0

---

### Fixing zoom, dropping subpixel shift (#177460)
- **Author**: Rusino
- **Date**: 2025-11-13
- **Link**: https://github.com/flutter/flutter/commit/90f26f514833681449661d5c310721070d83576e

Also, fixed decoration color and the cursor in TextEditField

Part of https://github.com/flutter/flutter/issues/172561

---------

Co-authored-by: Mouad Debbar <mdebbar@google.com>

---

### [web] API to customize semantics placeholder message (#178309)
- **Author**: Mouad Debbar
- **Date**: 2025-11-12
- **Link**: https://github.com/flutter/flutter/commit/e4d2b8743f75a899b7201dd79390c9942ed2016b

To customize the accessibility placeholder message:

```dart
import 'dart:ui_web' as ui_web;

void main() {
  ui_web.accessibilityPlaceholderMessage = 'My Custom Accessibility Message!';
  // ....
}
```

Fixes https://github.com/flutter/flutter/issues/178172

---

### Listen to text spacing overrides on the web (#178081)
- **Author**: Renzo Olivares
- **Date**: 2025-11-11
- **Link**: https://github.com/flutter/flutter/commit/36b18770737e52b0b504da38659dceb3964b4934

Original PR/Discussion: https://github.com/flutter/flutter/pull/172915

# Framework:
* `EditableText`/`SelectableText`, applies
`lineHeightScaleFactorOverride`, `wordSpacingOverride`, and
`letterSpacingOverride` to it's `TextStyle` similarly to how we already
do for bold platform overrides. Note `SelectableText` is built on
`EditableText` so it also applies these overrides.
* `Text`, applies `lineHeightScaleFactorOverride`,
`wordSpacingOverride`, and `letterSpacingOverride` to it's `TextStyle`
similarly to how we already do for bold platform overrides.
* Exposes line height override through
`MediaQueryData.lineHeightScaleFactorOverride` and
`maybeLineHeightScaleFactorOverrideOf(context)`.
* Exposes letter spacing override through
`MediaQueryData.letterSpacingOverride` and
`maybeLetterSpacingOverrideOf(context)`.
* Exposes word spacing override through
`MediaQueryData.wordSpacingOverride` and
`maybeWordSpacingOverrideOf(context)`.
* Exposes paragraph spacing override through
`MediaQueryData.paragraphSpacingOverride` and
`maybeParagraphSpacingOverrideOf(context)`.
* `MediaQuery.applyTextStyleOverrides()` \
`MediaQueryData.applyTextStyleOverrides()` to be able to reset/override
the text spacing settings on `MediaQueryData`.

# Engine:
* Introduces new members on `PlatformDispatcher` API that hold the text
spacing properties that are overridden on the web.
* We provide the `lineHeightScaleFactorOverride`,
`letterSpacingOverride`, `wordSpacingOverride`, and
`paragraphSpacingOverride` on the web by attaching a `ResizeObserver` to
an off-screen hidden element, when its size changes we capture its text
spacing CSS properties, and notify the framework through
`onMetricsChanged`.

Fixes #142712


https://github.com/user-attachments/assets/aaaa3e74-c232-4956-acd2-ae1a4487e415

---

### Feat: Add a11y for loading indicators (#165173)
- **Author**: Kishan Rathore
- **Date**: 2025-11-11
- **Link**: https://github.com/flutter/flutter/commit/2981516d74bc2b3307a7386e7be906602b65cf22

Feat: Add a11y for loading indicators
fixes: #161631

---

### Reland "Refactor OverlayPortal semantics (#173005)" (#178095)
- **Author**: Qun Cheng
- **Date**: 2025-11-10
- **Link**: https://github.com/flutter/flutter/commit/fccfa978a97633800aff123b776937d28262c04f

Reverts flutter/flutter#178007

This PR is to reland https://github.com/flutter/flutter/pull/173005 and
add a fix to avoid infinite loop. The fix doesn't contain engine
changes.

---

### Reland "Update all uses of mutable SkPath methods to use SkPathBuilder" (#178142)
- **Author**: Jason Simmons
- **Date**: 2025-11-07
- **Link**: https://github.com/flutter/flutter/commit/acdca8735690062c7d1c64b34d500bdfdec94e57

This is a reland of https://github.com/flutter/flutter/pull/177738 with
a fix to the `Op` function in `tools/path_ops`.

To match the previous behavior, `Op` will use `SkPathBuilder::operator=`
to copy the result path so that attributes like the fill type will be
copied.

---------

Co-authored-by: Kaylee Lubick <kjlubick@users.noreply.github.com>

---

### Add haptic notifications support. (#177721)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-11-06
- **Link**: https://github.com/flutter/flutter/commit/c0e052941af58233d0b962e26fcfc03c8fb1124f

Closes https://github.com/flutter/flutter/issues/150029

### Description
- Adds `successNotification`, `warningNotification` and
`errorNotification` haptics to the framework
- Adds `UINotificationFeedbackTypeSuccess`,
`UINotificationFeedbackTypeWarning` and
`UINotificationFeedbackTypeError` haptics support on iOS
- Adds `HapticFeedbackConstants.CONFIRM` and
`HapticFeedbackConstants.REJECT` haptics support on Android
- Adds tests


| iOS | Android | Web |
|:-:|:-:|:-:|
| UINotificationFeedbackTypeSuccess | HapticFeedbackConstants.CONFIRM |
20ms vibration |
| UINotificationFeedbackTypeWarning |
HapticFeedbackConstants.KEYBOARD_TAP | 20ms vibration |
| UINotificationFeedbackTypeError | HapticFeedbackConstants.REJECT |
30ms vibration |

---

### Use aria-hidden attribute for platform view accessibility on web (#177969)
- **Author**: zhongliugo
- **Date**: 2025-11-06
- **Link**: https://github.com/flutter/flutter/commit/f19a80a14283f07ebb2470e2c0184f7512a59602

Use aria-hidden attribute for platform view accessibility on web

Before change:
https://map-1023-before.web.app/

After change:
https://map-1023-after.web.app/

Fixes #171948.

Note: When a descendant element receives focus (for example, a marker),
the browser automatically overrides aria-hidden. This behavior is
correct and expected for accessibility compliance.

---

### Update .ci.yaml in flutter/flutter to use 15.5 (#177939)
- **Author**: Elijah Okoroh
- **Date**: 2025-11-06
- **Link**: https://github.com/flutter/flutter/commit/aebe02b44fe2df57604bebdac8e6d724ae80ecf6

Update .ci.yaml in flutter/flutter to use 15.5 

Note: (Not all devicelab bots are macOS 15.5. Some are 15.1 and 15.6.1)

*List which issues are fixed by this PR. You must list at least one
issue. An issue is not required if the PR fixes something trivial like a
typo.*

Fixes #177394

*If you had to change anything in the [flutter/tests] repo, include a
link to the migration guide as per the [breaking change policy].*

---

### Update all uses of mutable SkPath methods to use SkPathBuilder (#177738)
- **Author**: Kaylee Lubick
- **Date**: 2025-11-06
- **Link**: https://github.com/flutter/flutter/commit/6925f8b815ea2d2352393c111c5483867f5ce32c

Skia is removing the APIs that allow changing an SkPath. This updates
those callsites to use SkPathBuilder where appropriate.

---

### [web] Unify Surface code between Skwasm and CanvasKit (#177138)
- **Author**: Harry Terkelsen
- **Date**: 2025-11-05
- **Link**: https://github.com/flutter/flutter/commit/9eee9653ddb8bd351d52df89dff395405c1bc9d0

This PR introduces a significant refactoring of the web engine's
rendering layer by unifying the `Surface` and `Rasterizer`
implementations. These components have been moved from being
renderer-specific to a generic `compositing` directory, making the
architecture more modular and easier to maintain. The rasterizers are
now renderer-agnostic and are provided with renderer-specific surface
factories via dependency injection. A new `CanvasProvider` abstraction
has also been introduced to manage the lifecycle of the underlying
canvas elements.

A key outcome of this work is that the Skwasm backend now correctly
handles WebGL context loss events. This was achieved by refactoring
`SkwasmSurface` to allow the Dart side to manage the `OffscreenCanvas`
lifecycle. A communication channel between the main thread and the web
worker is now used to gracefully handle context loss and recovery. This
effort also included fixing several related bugs around surface sizing,
resource cleanup, and callback handling in multi-surface scenarios.

To validate these changes, new testing APIs have been added to allow for
the creation of renderer-agnostic surface tests. A new test file,
`surface_context_lost_test.dart`, has been added to verify the context
loss and recovery behavior across all supported renderers, ensuring the
new architecture is robust and reliable.

---

### [web] Don't add webparagraph suite to CI (#177681)
- **Author**: Mouad Debbar
- **Date**: 2025-11-04
- **Link**: https://github.com/flutter/flutter/commit/3fd81edbf1e015221e143c92b2664f4371bdc04a

Fix `generate-builder-json` to only include test bundles that are needed
by enabled test suites.

## Before this PR
The script was unconditionally including all test bundles in CI. The
result is that the `dart2js-canvaskit-experimental-webparagraph` bundle
was being generated, even though it was only required by the
`chrome-dart2js-experimental-webparagraph-ui` suite, which had
`enable-ci: false`.

## After this PR
The script starts by finding all test suites with `enable-ci: true`,
then only adds the bundles required by those suites.

---

### [web] Upgrade Chrome to 141 (for engine tests) (#177743)
- **Author**: Mouad Debbar
- **Date**: 2025-11-04
- **Link**: https://github.com/flutter/flutter/commit/e5d5c01850f2d33106f00a19017682f09e83e48b

- Update Chrome to 141 for web engine tests.
- Improve image codec tests so they exercise all frames.
- Skip the frames of certain images that are known to cause problems in
Chrome.

Chrome bug for the problematic images:
https://issues.chromium.org/456445108

Fixes https://github.com/flutter/flutter/issues/168686

---

### [web] Delete unused futurize util (#177861)
- **Author**: Mouad Debbar
- **Date**: 2025-11-04
- **Link**: https://github.com/flutter/flutter/commit/0f9853333f2f0ab888e56adb2140d3573f142651



---

### Add blockAccessibilityFocus flag (#175551)
- **Author**: Hannah Jin
- **Date**: 2025-11-03
- **Link**: https://github.com/flutter/flutter/commit/ed19f47bec7918d5ea84eb41ca3e63db7394d45a

Add a new flag for a11y focusable

- Accessibility focus, which is the focus used by screen readers like
TalkBack and VoiceOver, is different from input focus.
- Our current logic use some existing flags to decide if a node is
accessibilty focusable. like "if it's a slider / has a check state / has
keyboard focus/..., then it's a11y focusable"
https://github.com/flutter/flutter/blob/ecbb115ae3a8cba2977ecab9f52086df860cfb1a/engine/src/flutter/shell/platform/android/io/flutter/view/AccessibilityBridge.java#L98
- but we lack the ability to explicitly set a node to be unfocusable in
a11y!
- This flag can be used to explicitly set some semantics nodes to be
unfocusable in a11y mode. if it is false, we fall back to the logic "if
it's a slider / has a check state / has keyboard focus/..., then it's
a11y focusable"

future use case 1:
user can set live region to be not focusable, so when content changes,
it will still announce, but the content can't be focused by swiping.
future use case 2:
when pushing a new route like a dialog, setting the semantics nodes in
old pages to be un focusable.

---

### wires up set application locale to web engine (#177284)
- **Author**: chunhtai
- **Date**: 2025-11-03
- **Link**: https://github.com/flutter/flutter/commit/bcd359d74604b82bc6dc5e888db82046f87d1773



---

### Clean up links to docs website (#177792)
- **Author**: Pierre
- **Date**: 2025-11-01
- **Link**: https://github.com/flutter/flutter/commit/f234d269266120ca1a987f9d98e93ed7cdff282c

- remove link without use (PowerShell version minimum not reached, this
is not mentionned anywhere in Windows installation / troubleshooting
documentation)
- clean up API docs root
- clean up app template links, add `Learn Flutter` link
- update get started links
- replace `flutter.dev/docs` with `docs.flutter.dev`
- fix embedder descriptions
- fix broken API `docs.flutter.io` links
- http → https 
- remove `/install` from `/get-started` links
- fix Android Studio link

---

### Implements uniform-by-name for web (#176980)
- **Author**: gaaclarke
- **Date**: 2025-10-30
- **Link**: https://github.com/flutter/flutter/commit/2c9e69f0db82915c0486dc513175f0434c115928

fixes https://github.com/flutter/flutter/issues/176417 (for web)

Now on the web the `FragmentShader.getUniformFloat(String name, [int?
index])` can be used.

---

### Update .ci.yaml in flutter/flutter to use 15.5 (#177669)
- **Author**: Elijah Okoroh
- **Date**: 2025-10-30
- **Link**: https://github.com/flutter/flutter/commit/fdeb7f5a6e11d802f0a6bae5bfc93790101c6a52

Update .ci.yaml in flutter/flutter to use 15.5

*List which issues are fixed by this PR. You must list at least one
issue. An issue is not required if the PR fixes something trivial like a
typo.*

Fixes #177394

*If you had to change anything in the [flutter/tests] repo, include a
link to the migration guide as per the [breaking change policy].*

---

### impeller: allow setting image sampler uniforms by name (#176749)
- **Author**: gaaclarke
- **Date**: 2025-10-29
- **Link**: https://github.com/flutter/flutter/commit/29e46fa49b13793ab19a51d24df68f06c66a6e03

follow up to https://github.com/flutter/flutter/pull/176728 which allows
setting image samplers too.

---

### [web] Add GEMINI.md for web engine customizations (#177413)
- **Author**: Harry Terkelsen
- **Date**: 2025-10-29
- **Link**: https://github.com/flutter/flutter/commit/bd2f9f407480752a074fcb4edf19af8f90ce9bc6

Adds a `GEMINI.md` for the Flutter Web engine to assist Gemini code
assistant in building the web engine and running tests.

---

### Refactor OverlayPortal semantics (#173005)
- **Author**: Qun Cheng
- **Date**: 2025-10-29
- **Link**: https://github.com/flutter/flutter/commit/ccf6466b14e144971a7d65983bdd16459d65a62a

Fixes https://github.com/flutter/flutter/issues/163576
Fixes https://github.com/flutter/flutter/issues/175184

This PR refactored the grafting part on `OverlayPortal`. Originally, the
semantics tree of `OverlayPortal` was constructed/grafted in render
object phase to make sure the correctness of the traversal order.
However this resulted wrong hit-test order and the issue surfaced on
web. With the fact that on web we are not able to graft/correct hit-test
order tree, this PR:
* Reverts the original grafting of the `OverlayPortal` so the hit-test
order is always correct.
* Then, we adds the grafting and updates the traversal order when we
send `childrenInTraversalOrder` to engine.
* Updating `childrenInTraversalOrder` causes it have different length
from the length of `childrenInHitTestOrder` and wrong hit-test transform
of the `OverlayPortal` children because when the transform is
calculated, it assumes a correct traversal order. To fix these issues,
this PR also:
  * recalculates the transform for `OverlayPortal` children.
  * adds `hitTestTransform` property and pass it to Android engine.
* skip grafting for web because it assumes the same length of
`childrenInTraversalOrder` and `childrenInHitTestOrder`.
* added grafting by using `ARIA-owns` in web engine to fix the traversal
order.

---

### [web] Delete unused canvaskit utils (#177684)
- **Author**: Mouad Debbar
- **Date**: 2025-10-29
- **Link**: https://github.com/flutter/flutter/commit/0afe64e86a089c15c687295837a91e0cb45bde13

Closes https://github.com/flutter/flutter/issues/73492

---

### [web] Move webparagraph tests to their right location (#177739)
- **Author**: Mouad Debbar
- **Date**: 2025-10-29
- **Link**: https://github.com/flutter/flutter/commit/53925c1283d85da44230905e7926a0504edb66aa

Many failures happening in [`Linux linux_web_engine_tests

`](https://ci.chromium.org/ui/p/flutter/builders/luci.flutter.prod/Linux%20linux_web_engine_tests)
due to `ui/web_paragraph/font_collection_test.dart` being misplaced.

This PR moves the test file to the correct directory so it runs with the
correct test suite.

---

### [web] Deprecate --pwa-strategy (#177613)
- **Author**: Mouad Debbar
- **Date**: 2025-10-29
- **Link**: https://github.com/flutter/flutter/commit/c0655958429092f820add31426c01cd525810346

- Hide the `--pwa-strategy` flag.
- Add deprecation note to the help text.
- Print deprecation warning if passed explicitly.

Towards https://github.com/flutter/flutter/issues/156910

---

### Set the font weight variation axis based on the text style's FontWeight (#175771)
- **Author**: Jason Simmons
- **Date**: 2025-10-27
- **Link**: https://github.com/flutter/flutter/commit/e090117bde419536e8c95710b961fcbf5893fe01

This makes it possible for applications to set a FontWeight and get the
expected result for both variable fonts and fonts that provide separate
assets for each weight.

See https://github.com/flutter/flutter/issues/148026

---

### [web] Use SkPathBuilder because SkPath is becoming immutable (#177343)
- **Author**: Mouad Debbar
- **Date**: 2025-10-24
- **Link**: https://github.com/flutter/flutter/commit/37590335c4ad1bb1f77e941e174c7a9660710a8a

Skia is working on making `SkPath` immutable:
https://skia-review.googlesource.com/c/skia/+/1075478

In Flutter Web's CanvasKit renderer, we use `SkPath` as a mutable
object, which made the [Skia
roll](https://github.com/flutter/flutter/pull/177184) fail. To fix this,
we should start using `SkPathBuilder` instead.

Remaining work:
- [x] Figure out the deletion/disposal of `SkPath`s generated from
`.snapshot()` calls.
- [ ] `LazyPath` should be restructured to better accommodate a world of
immutable paths and path builders (coming in a future PR).

---

### Implements engine-side declarative pointer event handling for semantics. (#176974)
- **Author**: zhongliugo
- **Date**: 2025-10-23
- **Link**: https://github.com/flutter/flutter/commit/26766ac86de8f7e59d615de5d55a95c5639be0de

Implements engine-side declarative pointer event handling for semantics.

Framework-side to be implemented in next PR.

Fixes flutter/flutter#149001.

**Before change**
https://dialog-dismiss-before.web.app/

Click on the "Show Dialog" button.
Click anywhere inside the dialog that is not a form field.
Observe the dialog being dismissed. 

**After change**
https://dialog-dimiss-after.web.app/

Click on the "Show Dialog" button.
Click anywhere inside the dialog that is not a form field.
Observe the dialog not dismissed.

---

### Change Flutter APIs to use spans (#177272)
- **Author**: Kaylee Lubick
- **Date**: 2025-10-23
- **Link**: https://github.com/flutter/flutter/commit/96fe3e27c7883e9271e15f3b6dfb24cdb90f495b

Some old APIs are currently guarded by `SK_SUPPORT_UNSPANNED_APIS` and
Skia plans to delete them (for example in this
[CL](https://skia-review.googlesource.com/c/skia/+/1073616)). This
updates Flutter calls to use the new APIs (by wrapping the pointers and
counts together) and removes the define to avoid backsliding.

---

### Delete stray 'text' file (#177355)
- **Author**: Harry Terkelsen
- **Date**: 2025-10-22
- **Link**: https://github.com/flutter/flutter/commit/c8102faf0b8cbd5d7b151f63e487498cc72d31fd

A stray file was added to the repo in error. This PR deletes it.

---

### [web] Self-cleaning service worker (#176834)
- **Author**: Mouad Debbar
- **Date**: 2025-10-17
- **Link**: https://github.com/flutter/flutter/commit/f94a9421865f753f7beba56ede6d39c25a0ff38b

Introduce a self-cleaning service worker to replace the old one.

Previous attempts (https://github.com/flutter/flutter/pull/170918,
https://github.com/flutter/flutter/pull/173609) had (accidentally?)
disabled the loading of the service worker in `flutter.js`. This PR
preserves the logic for loading the service worker, and it prints a
deprecation warning.

Towards https://github.com/flutter/flutter/issues/156910
Closes https://github.com/flutter/flutter/issues/106225

---

### [web][a11y] Fix the semantics tree reconstruction logic when a subtree is reparented to another node.  (#177069)
- **Author**: Hannah Jin
- **Date**: 2025-10-17
- **Link**: https://github.com/flutter/flutter/commit/16ae36ce20bbbe0543e70b2be5564f2dd595f06d

issue fix: https://github.com/flutter/flutter/issues/175180 
The bug was like this:
1.  a tree like 1--2--3--4
2. remove node 2 and reattach node 3 to 1, the tree is now 1--3--4, it's
correct on the framework side.
3. on the web side, the tree reconstruction logic is wrong and the tree
become 1---3, the node 4 is removed wrongly.


When a node is detached from the tree, but its children node is attached
to a new parent, we need to stop searching the subtree and stop removing
the reparented subtree!
So we need a DFS function that can skip subtree but wont stop the whole
searching.

---

### [web] Fix focus issues in newer versions of Chrome (#176938)
- **Author**: Mouad Debbar
- **Date**: 2025-10-15
- **Link**: https://github.com/flutter/flutter/commit/f0d69e2d9ea261a69245939a2779ec57fcabf865

Deconstruct https://github.com/flutter/flutter/pull/170760 to land more
pieces of it.

---

### impeller: allows access of float uniforms by name (#176728)
- **Author**: gaaclarke
- **Date**: 2025-10-13
- **Link**: https://github.com/flutter/flutter/commit/d04705c92f27a57793adc699dc54dfd2ac58d116

fixes https://github.com/flutter/flutter/issues/176417

This fixes the linked issue in so far as it is possible today. This opts
for the runtime lookup of bindings since it avoids all sort of messy
issues when dealing with codegen. This doesn't stop us from doing
codegen in the future.

This also adds tests for hot reload cases that would fail in the past,
like inserting new uniforms.

## Limitations
1) It doesn't handle component names like ".r" or ".x". This is possible
if we want.
1) It doesn't handle nested structs. This isn't possible with the
current shader metadata and may be a limitation with glsl?

## Features
1) Slots can be cached to amortize the cost of looking up the bindings
1) Works with hot reload (tested inserting a uniform before one accessed
by name)

## Followup work
I plan on filing the following issues:
1) Map postfixes like ".r" ".z" to offsets so a uniform can be "foo.z"
1) Support nested structs so a uniform name can be "foo.bar"
1) Support codegen for uniforms to get compile-time uniform name support

## Example
```dart
ShaderBuilder(
  assetKey: 'shaders/grayscale.frag',
  (context, shader, _) {
    Color color = Colors.red;
    shader.getUniformFloat('uColor', 0).set(color.r);
    shader.getUniformFloat('uColor', 1).set(color.g);
    shader.getUniformFloat('uColor', 2).set(color.b);
    return BackdropFilter(
      filter: ImageFilter.shader(shader),
      child: Container(
        color: Colors.transparent,
      ),
    );
  },
),
```

---

### [web] Match the behavior of other platforms in Web Locale.toString if the country code is an empty string (#176862)
- **Author**: Jason Simmons
- **Date**: 2025-10-13
- **Link**: https://github.com/flutter/flutter/commit/8e99f3e8987d5c5af53028c01340cd5e2f8f221a

Fixes https://github.com/flutter/flutter/issues/176666

---

### [WebParagraph] Support for more styles, placeholders, decorations, etc (#172853)
- **Author**: Rusino
- **Date**: 2025-10-10
- **Link**: https://github.com/flutter/flutter/commit/cce24b8a9d3e5d1929641d67b573b3c4f4cccab0

This is the second version of WebParagraph. It includes pretty much all
SkParagraph functionality except struts and justifications (eventually
they will be implemented, too).

Part of https://github.com/flutter/flutter/issues/172561

---------

Co-authored-by: Mouad Debbar <mdebbar@google.com>

---

### Add saturation ColorFilter. (#176464)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-10-08
- **Link**: https://github.com/flutter/flutter/commit/fc8f60345a26348d0a738f472b7bc051077ff35a

Closes https://github.com/flutter/flutter/issues/166589

This PR is a continuation of
https://github.com/flutter/flutter/pull/167898, which was closed due to
the lack of web implementation. Thanks to @lukepighetti and
@benthillerkus for their work on the closed PR.

### Description

- Adds `ColorFilter.saturation`



https://github.com/user-attachments/assets/67d8acf0-35d0-42de-a24b-f24eed14e9a8

---

### Adds dart ui API for setting application level locale (#175100)
- **Author**: chunhtai
- **Date**: 2025-09-30
- **Link**: https://github.com/flutter/flutter/commit/f86835076b98cf1581d6364ebbaccb09648d4bbc



---

### Web semantics: Fix email field selection/cursor by using type="text" + inputmode="email" (#175876)
- **Author**: zhongliugo
- **Date**: 2025-09-30
- **Link**: https://github.com/flutter/flutter/commit/ef611a7e4cdbd93a7b61a8cc5214f80e95e4f07f

**What/Why**
On Flutter Web with semantics enabled, <input type="email"> can reject
selection APIs in some browsers, causing:
cursor to not advance while typing,
selection to fail (and selected text not deletable),
and, in some cases, InvalidStateError exceptions.
This PR updates the semantics editing element for email fields to keep
selection/cursor APIs working while preserving email UX.

**How**
In
engine/src/flutter/lib/web_ui/lib/src/engine/semantics/text_field.dart:
Use type="text" for SemanticsInputType.email
Add inputmode="email" (keeps email keyboard layout/hints)
Add autocomplete="email" (preserves autofill)
Add autocapitalize="none" (prevents unwanted capitalization)
Remove the attributes when not email
Rationale: type="text" avoids browser selection restrictions;
inputmode="email" preserves the expected email keyboard; autofill and
capitalization behavior is retained/optimized.

**Before/After**
Before the change
https://email-0923-before.web.app/
After the change
https://email-0923.web.app/

**Impact**
Cursor now advances correctly while typing in email fields under
semantics.
Text can be selected and deleted normally.
Avoids InvalidStateError crashes with accessibility semantics enabled.

**Tests/Verification**
Manually verified on Chrome and safari:
Typing in email fields advances cursor correctly
Drag-select, double-click select, and Cmd/Ctrl+A work
Deleting selected text works
No exceptions thrown with semantics enabled
Autofill prompts continue to appear when saved emails are available.
Mobile keyboards (iOS/Android) show email-optimized layout via
inputmode="email".

**Fixed issues**
Fixes flutter/flutter#173239

---

### [web] Bump Firefox to 143.0 (#176110)
- **Author**: Mouad Debbar
- **Date**: 2025-09-30
- **Link**: https://github.com/flutter/flutter/commit/3fb9ae79f555d3883dd2cc7e14386b77c2658da5



---

### Update the test package for the web engine unit test bits. (#176241)
- **Author**: Jackson Gardner
- **Date**: 2025-09-29
- **Link**: https://github.com/flutter/flutter/commit/fbe5627110e54eb99b3d6b8fbb81f101e827cb63

`js_util` is now deprecated, and these older versions of the test
package still use it. We need to update it to unblock the dart ->
flutter roll.

---

### [web] Remove mention of non-existent `canvaskit_lock.yaml` (#176108)
- **Author**: Mouad Debbar
- **Date**: 2025-09-26
- **Link**: https://github.com/flutter/flutter/commit/55dec6355d9d34e7bc9d14da05a9f5d05c712b29

`canvaskit_lock.yaml` has been removed in
[2023](https://github.com/flutter/engine/pull/40293).

---

### [a11y] Add `expanded` flag support to Android. (#174981)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-09-27
- **Link**: https://github.com/flutter/flutter/commit/c6ffbdf7ea8d7fd946b150ef49ffdd400e96432d

Closes https://github.com/flutter/flutter/issues/92040

- Adds `expanded` semantics flag support to Android
- Adds `onExpand` and `onCollapse` semantics actions
- Updates `robolectric` library
- Adds java and dart tests

#### Why were `onExpand` and `onCollapse` actions added?
It turned out that TalkBack doesn't announce the `expanded` state if
`expand/collapse` action is not set for the accessibility node.

#### Why was the `robolectric` library updated?

The `expanded` state support in Android was introduced in API 36. The
`roboelectric: 4.14.1` doesn't support API 36. To run tests for a newly
added functionality `roboelectric` library was updated to `4.16`, which
supports the latest Android version
(https://github.com/robolectric/robolectric/releases/tag/robolectric-4.16).

In case you think it would be better to update the `roboelectric` in a
separate PR, please let me know.

<br/>
<details>
<summary>Example Source Code</summary>

```dart

import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final _controller = ExpansibleController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 24,
          children: [
            Text('Expansible Example'),
            ListenableBuilder(
              listenable: _controller,
              builder: (context, child) {
                return Semantics(
                  expanded: _controller.isExpanded,
                  onExpand: () {
                    print(' \n onExpand \n ');
                    _controller.expand();
                  },
                  onCollapse: () {
                    print(' \n onCollapse \n ');
                    _controller.collapse();
                  },
                  child: child,
                );
              },
              child: Expansible(
                headerBuilder: (context, _) => ListTile(
                  tileColor: Colors.blue.shade100,
                  leading: Text(
                    'Expansible',
                    style: TextStyle(fontSize: 20),
                  ),
                  trailing: Icon(
                    _controller.isExpanded
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                    semanticLabel: _controller.isExpanded
                        ? 'Arrow Up icon'
                        : 'Arrow Down icon',
                  ),
                ),
                bodyBuilder: (context, _) {
                  return Container(
                    color: Colors.blue,
                    height: 200,
                    width: 200,
                  );
                },
                controller: _controller,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

</details>



https://github.com/user-attachments/assets/256c4182-a1e3-44fc-b028-5e6c9ec05ad7

---

### web_ui: avoid crash for showPerformanceOverlay; log 'not supported' once (#173518)
- **Author**: Md. Murad Hossin
- **Date**: 2025-09-25
- **Link**: https://github.com/flutter/flutter/commit/b1a28bc065b0acc50bc2284be87a9a708bd7aa85

Fixes flutter/flutter#172405

On Flutter Web, calling `MaterialApp(showPerformanceOverlay: true)`
reaches
`SceneBuilder.addPerformanceOverlay`, which previously threw
`UnimplementedError`
and crashed apps. This change makes the method a no-op on Web and logs a
one-time
warning:

  "showPerformanceOverlay is not supported on Flutter Web. Use DevTools
   Performance (Timeline) instead."

Rationale: Avoid crashes and guide developers to the supported tooling
on Web.

Testing:
- Relied on CI for web_ui builds and tests.
- (Manual reproduction before fix) Enabling `showPerformanceOverlay` on
Web produced
  UnimplementedError from `canvaskit/layer_scene_builder.dart`.

---------

Co-authored-by: Mouad Debbar <mdebbar@google.com>

---

### [web] Fix assertion thrown when hot restarting during animation (#175856)
- **Author**: Mouad Debbar
- **Date**: 2025-09-23
- **Link**: https://github.com/flutter/flutter/commit/6c5df591ab4a9ee736bab75770f28cc95145bfac

Fixes https://github.com/flutter/flutter/issues/140684
Fixes https://github.com/flutter/flutter/issues/175260

---

### [web] Cleanup opportunities post renderer unification (#174659)
- **Author**: Mouad Debbar
- **Date**: 2025-09-22
- **Link**: https://github.com/flutter/flutter/commit/c0e7d716c57cf23d12762bbb624f9322edbdc2a6

- `injectClientICUIfNeeded` as a method on `SkParagraphBuilder` for
convenience.
- Move `CanvasKitVariant` outside of `canvaskit/` because it's needed
outside of that folder.
- Make `resourceCacheMaxBytes` a method on all renderers, not only
CanvasKit.
- Some optimizations in `OcclusionMap`.
- Remove unused CanvasKit test utils.

---

### Delete unused web_unicode library (#174896)
- **Author**: Mouad Debbar
- **Date**: 2025-09-19
- **Link**: https://github.com/flutter/flutter/commit/f5fceab5e9418907963e7627e290c45eaddf4cc3

The `web_unicode` library was used by the HTML renderer which doesn't
exist anymore.

Depends on https://github.com/flutter/flutter/pull/174967

---

### [reland][web] Refactor renderers to use the same frontend code #174588 (#175392)
- **Author**: Harry Terkelsen
- **Date**: 2025-09-17
- **Link**: https://github.com/flutter/flutter/commit/2e51c3f343fb70a14bfd1331af22f88ecc952818

Refactors the renderer code so both renderers (Skwasm and CanvasKit) use
the same SceneBuilder and platform view embedding code. This change is
discussed in a design doc here:
https://flutter.dev/go/web-renderer-unification

Fixes https://github.com/flutter/flutter/issues/172311
Fixes https://github.com/flutter/flutter/issues/172308
Fixes https://github.com/flutter/flutter/issues/142072

---

### [web] Fix errors when using image filters with default values. (#175122)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-09-17
- **Link**: https://github.com/flutter/flutter/commit/b392036b54bc8985a66c6e429069de58355b7aa8

Fixes https://github.com/flutter/flutter/issues/174583

- Fix WASM crash when image filter is null
- Adds support for dilate and erode image filters with default values to
CanvasKit
- Adds new tests to verify that image filters with default values can be
used without any issues/crashes

---

### [web] Remove unused `sceneHost` property (#174997)
- **Author**: Mouad Debbar
- **Date**: 2025-09-17
- **Link**: https://github.com/flutter/flutter/commit/6b25ec9609d7c8af314ff948afc456287f61885c



---

### chore: move engine docs out of engine/ and into docs/ (#175195)
- **Author**: John "codefu" McDole
- **Date**: 2025-09-16
- **Link**: https://github.com/flutter/flutter/commit/e068a3e6c4c1dd57a5db474c30eb1988f794bee7

Moving docs to be co-located with other docs + updating links. This has
the benefit of not including docs in engine content hash semantics.

---

### [web] Fix image and color filters equality in SkWASM. (#175230)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-09-11
- **Link**: https://github.com/flutter/flutter/commit/ed6e6387566140f97fd12c74380ab068171f75cf

Closes https://github.com/flutter/flutter/issues/173968

- Adds equality support to `ImageFilter`s in SkWASM
- Adds equality support to `ColorFilter`s in SkWASM
- Fixes test to not use const objects in the equality checks

---

### [web] Minor simplification in flutter.js loader (#174963)
- **Author**: Mouad Debbar
- **Date**: 2025-09-05
- **Link**: https://github.com/flutter/flutter/commit/e6af6f9a0c2fe109d0d7cd1fd4f60d314e924cb6



---

### fix(Semantics): Ensure semantics properties take priority over button's (#174473)
- **Author**: Pedro Massango
- **Date**: 2025-09-04
- **Link**: https://github.com/flutter/flutter/commit/00e428a200395cf45b287f13a1f781009c098105

Fixes https://github.com/flutter/flutter/issues/157689

Flutter packages PR counterpart:
- https://github.com/flutter/packages/pull/9815

---

### Reapply "Add set semantics enabled API and wire iOS a11y bridge" (#174163)
- **Author**: chunhtai
- **Date**: 2025-08-29
- **Link**: https://github.com/flutter/flutter/commit/03195e699001710fcfbc5af7f6efc8ec1127238d



---

### [WebParagraph] More plumbing towards making it usable in Flutter apps (#174587)
- **Author**: Mouad Debbar
- **Date**: 2025-08-28
- **Link**: https://github.com/flutter/flutter/commit/b8cd9aff206930a6c7f557813eae95a952533ef7

- Introduce a `WebFontCollection`
([copied](https://github.com/flutter/flutter/blob/a488d104f28d36785f708118ea5bf57e1c51d6e0/engine/src/flutter/lib/web_ui/lib/src/engine/text/font_collection.dart)
from the HTML renderer with minor tweaks).
- Teach `CkCanvas.drawParagraph` how to draw a `WebParagraph`.
- Remove several text-related features from CanvasKit/Skia that we don't
need anymore.

Part of https://github.com/flutter/flutter/issues/172561

---------

Co-authored-by: gemini-code-assist[bot] <176961590+gemini-code-assist[bot]@users.noreply.github.com>

---

### [web] Refactor renderers to use the same frontend code (#174588)
- **Author**: Harry Terkelsen
- **Date**: 2025-08-28
- **Link**: https://github.com/flutter/flutter/commit/111f5a45f00b9c03dc68e9bc451b4fa2d524d34a

Refactors the renderer code so both renderers (Skwasm and CanvasKit) use
the same SceneBuilder and platform view embedding code. This change is
discussed in a design doc here:
https://flutter.dev/go/web-renderer-unification

Fixes https://github.com/flutter/flutter/issues/172311
Fixes https://github.com/flutter/flutter/issues/172308
Fixes https://github.com/flutter/flutter/issues/142072

---

### [web] Raster Pictures at full screen size in Skwasm (#174456)
- **Author**: Harry Terkelsen
- **Date**: 2025-08-27
- **Link**: https://github.com/flutter/flutter/commit/53a4cde961d4c8d95e79535955307b3f5ffbff3c

Skwams currently rasters images at their `cullRect` size, and resizes
the `bitmaprenderer` canvas that will display the bitmap to the
`cullRect` size. It is unclear if the speed-up from the smaller bitmap
creation outweighs the cost of resizing and recreating the
`bitmaprenderer` canvas.

To prepare for the web renderer unification and unify the rasterization
step between the two renderers, this change makes it so Skwasm rasters
the pictures at the full screen size, and no longer needs to resize the
`bitmaprenderer` canvases unless the screen size changes.

Part of https://github.com/flutter/flutter/issues/172311

---

### [web] Add test that pictures are not rasterized when clipped out (#174452)
- **Author**: Harry Terkelsen
- **Date**: 2025-08-26
- **Link**: https://github.com/flutter/flutter/commit/93d5ace65fb68459f51302e0b2bded52a629330d

Adds a test that checks that pictures are not composited if they are
clipped out (or not in the frame) in the final scene. This is important
to test since we have benchmarks that depend on this behavior being
implemented properly.

Part of the web renderer unification. See
https://github.com/flutter/flutter/issues/172311

---

### [web] Migrate non-CanvasKit-specific tests to ui/ (#174396)
- **Author**: Harry Terkelsen
- **Date**: 2025-08-25
- **Link**: https://github.com/flutter/flutter/commit/5550f4095607fd13bf56198f6bc0a25a4b59bfa5

There are many tests under `canvaskit/` which test general rendering and
UI primitives and these tests aren't specific to the CanvasKit
implementation details. This change moves them to `ui/` so all renderers
can test against them.

Part of the refactoring to unify CanvasKit and Skwasm rendering
front-ends. See https://github.com/flutter/flutter/issues/172311

---

### [web] Refactor LayerScene out of CanvasKit (#174375)
- **Author**: Harry Terkelsen
- **Date**: 2025-08-25
- **Link**: https://github.com/flutter/flutter/commit/1110406d58c8168e57b3cf3c7204d71ffe41006a

Moves the `LayerSceneBuilder` code out of CanvasKit and into a
higher-level directory under `engine/`. This is in preparation for the
code to be shared between the CanvasKit and Skwasm renderers.

See https://github.com/flutter/flutter/issues/172311

---

### [skwasm] Port to `DisplayList` objects (#172314)
- **Author**: Jackson Gardner
- **Date**: 2025-08-25
- **Link**: https://github.com/flutter/flutter/commit/3340caed81328f111a659fc66632e1bebaf8658c

This PR refactors the skwasm renderer to use `DisplayList` objects as
its main model objects instead of using Skia objects directly. Then, at
render time, we dispatch the display list commands to the skia surface.
This is a preparatory step for impeller on web.
* Some build rules were reworked in order to allow `DisplayList` to
compile via emscripten
* Some pieces of the display list library were further refactored to
allow us to compile it without actually building and linking the
impeller shaders. The two major classes that needed to be separated out
were `DlRuntimeEffect` and the text drawing system.
* `SkPath` and `SkImage` are still used as the main model objects in
skwasm. As of right now, `DisplayList` just thinly wraps these objects,
so this is the minimal possible change for now. I will have to refactor
this somewhat further when preparing for actual impeller adoption.
* Several special cased code paths in skwasm were removed, as they are
taken care of by `DisplayList` itself. This includes shadow drawing,
determining when to enable dithering, and determining the right clamp
value for filters.

---

### [web] Expose rasterizers in Renderer (#174308)
- **Author**: Harry Terkelsen
- **Date**: 2025-08-22
- **Link**: https://github.com/flutter/flutter/commit/7d6d410dd3649d4a861d715cd9ce513c1c7a2a25

This is a small tweak to the Renderer API that exposes a `Rasterizer`
and a map of `View` to `ViewRasterizer` in the `Renderer`. The
`Renderer` handles creating and disposing the `ViewRasterizer`s in
response to `View`s being created and disposed.

This is a step towards https://github.com/flutter/flutter/issues/172311

---

### Update some semantics flags updated to use enum (engine, framework, web) (#170696)
- **Author**: Hannah Jin
- **Date**: 2025-08-22
- **Link**: https://github.com/flutter/flutter/commit/798ff5908ee427e96e0fd8428fe4e489521335ac

issue: https://github.com/flutter/flutter/issues/166101,


new Updates :
Add new enum Tristate and CheckedState in  for 7 flags.
For CheckState, it used to use 3 bools (hasCheck, isChecked,
isCheckStateMixed) to represent check states, replace them with a
CheckState enum.
For other 6 flags, each has 2 bools (hasXXState and isXX), replace them
with a Tristate enum.

This will be a breaking changes to the SemanticsFlags class , which was
added in April in https://github.com/flutter/flutter/issues/166101 and
https://github.com/flutter/flutter/pull/167771 , will write a breaking
change doc for this PR

---

### `_downloadArtifacts` (Web SDK) uses content-aware hashing in post-submit (#174236)
- **Author**: Matan Lurey
- **Date**: 2025-08-22
- **Link**: https://github.com/flutter/flutter/commit/6c7d6429bdbd87343c4e79ac133bedd3cf32a1cf

Towards https://github.com/flutter/flutter/issues/174225.

Will need to get cherry-picked into 3.35 and 3.36.

---

### [web] Delete unused utils (#174160)
- **Author**: Mouad Debbar
- **Date**: 2025-08-21
- **Link**: https://github.com/flutter/flutter/commit/d2ac0210ee05a56415bf309a41722d0a10eacfdb



---

### [web] Fix error in ClickDebouncer when using VoiceOver (#174046)
- **Author**: Mouad Debbar
- **Date**: 2025-08-19
- **Link**: https://github.com/flutter/flutter/commit/8df5257785eafe93aac2b367f819aa71e21c297a

When using VoiceOver, clicking the button through `ctrl+opt+space`
causes the browser to send `pointerdown`, `pointerup` and `click` events
successively within the same event loop. This case wasn't handled
correct by the recent `ClickDebouncer` change here:
https://github.com/flutter/flutter/pull/172995

More details:

We currently wait until the end of the event loop to set the
`ClickDebouncer`'s state. When other events arrive before the end of the
event loop, they expect the `state` to already be set.

The fix is to set the `state` immediately to allow events to be queued
right away, but still keep the debouncing delayed until the end of the
event loop so that Safari continues to work correctly (issue:
https://github.com/flutter/flutter/issues/172180)

Fixes https://github.com/flutter/flutter/issues/173741

---

### Reapply "Add set semantics enabled API and wire iOS a11y bridge (#161… (#171198)
- **Author**: chunhtai
- **Date**: 2025-08-19
- **Link**: https://github.com/flutter/flutter/commit/3e4d1716642b529562152199646da6817b104815

…265)"

This reverts commit cc04ca4e5594fe9cd87adde34a5eedf14221fc3b.

---

### [web] Cleanup usages of deprecated `routeUpdated` message (#173782)
- **Author**: Mouad Debbar
- **Date**: 2025-08-14
- **Link**: https://github.com/flutter/flutter/commit/62904ba72aa397142116ce40a67be12ab5792617

This is a follow up to https://github.com/flutter/flutter/pull/173652

Closes https://github.com/flutter/flutter/issues/50836

---

### [web] Popping a nameless route should preserve the correct route name (#173652)
- **Author**: Mouad Debbar
- **Date**: 2025-08-13
- **Link**: https://github.com/flutter/flutter/commit/f83d8cfd3a93aec687a162dda69505ff54479342

Fixes https://github.com/flutter/flutter/issues/173356

---

### [web] Fallback to CanvasKit when WebGL is not available (#173629)
- **Author**: Mouad Debbar
- **Date**: 2025-08-12
- **Link**: https://github.com/flutter/flutter/commit/f63cb75520d25943e5824c552b9632255aa58c33

Fixes https://github.com/flutter/flutter/issues/173401

---

### [WebParagraph] Fix a property name on newer Chrome versions (#173477)
- **Author**: Mouad Debbar
- **Date**: 2025-08-08
- **Link**: https://github.com/flutter/flutter/commit/6bedb9bd991bc982cb35a4706fe5a950f24812d5



---

### Add radius clamping to web `RSuperellipse` (#172254)
- **Author**: Tong Mu
- **Date**: 2025-08-05
- **Link**: https://github.com/flutter/flutter/commit/de3dedaa7448960ef0bcf5f18c747bd707d71f12

This PR fixes rendering errors on Web when the provided corner radii sum
up larger than the size. It implements radius scaling using the same
algorithm as in [the C++
implementation](https://github.com/flutter/flutter/blob/b2d4210b3795413c2360968b685743a6df60ff50/engine/src/flutter/impeller/geometry/rounding_radii.cc).

Before: (error emerges for r>100, since the height is 200)
<img width="664" height="509" alt="image"
src="https://github.com/user-attachments/assets/eb526338-84d9-4eca-975b-d44bee0c11ac"
/>

After: (it stays this way for r>100)
<img width="611" height="471" alt="image"
src="https://github.com/user-attachments/assets/08ca2499-d5f7-47e1-9ecf-29f60c968016"
/>

It also fixes a bug that uses an incorrect starting point. 

Both changes are backed by the new test cases in
`rounded_superellipse_border_test.dart`.

---

### [web] Fix potential race condition in ClickDebouncer (#173294)
- **Author**: Mouad Debbar
- **Date**: 2025-08-05
- **Link**: https://github.com/flutter/flutter/commit/59fc766c6fdfd03d0983fc95ce8b76793a300dd5

Based on Gemini's comment:
https://github.com/flutter/flutter/pull/173072#discussion_r2246216031

---

### [web] Add Intl.Locale to parse browser languages. (#172964)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-08-04
- **Link**: https://github.com/flutter/flutter/commit/a128ccbe9441792b6096c6ea50b3762c7dcfedee

Closes https://github.com/flutter/flutter/issues/130174

### Description
- Adds `DomLocale` extension type for
[`Intl.Locale`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/Locale)
- Replaces manual browser language parsing with `DomLocale` usage
- Adds tests to cover new functionality

---

### [engine] Null aware elements clean-ups (#173075)
- **Author**: Jamil Saadeh
- **Date**: 2025-08-01
- **Link**: https://github.com/flutter/flutter/commit/6feaa2c63278c059a7ec7cab98a1aa9f54ce5aa0



---

### [web] ClickDebouncer workaround for iOS Safari click behavior (#172995)
- **Author**: Mouad Debbar
- **Date**: 2025-07-31
- **Link**: https://github.com/flutter/flutter/commit/b20149bf11b833622e9ae493cc1d9610f69903a1

It turns out iOS Safari in some cases tracks timers that are scheduled
from within a `pointerdown` listener, and it delays the `click` event
until those timers have expired (with a max waiting time of 350ms or
so).

The `ClickDebouncer` sets a timer of 200ms to see if a `click` event is
received by then. But because of the Safari behavior explained above,
the `click` event will always arrive right after the `ClickDebouncer`'s
timer, so we always misattribute the `click` event.

Fixes https://github.com/flutter/flutter/issues/172180

---

### [web] Text editing test accepts both behaviors in Firefox (#172767)
- **Author**: Mouad Debbar
- **Date**: 2025-07-31
- **Link**: https://github.com/flutter/flutter/commit/5b78ecca51f0f37ce2ac2deec77cb8473b8a9e58

Fixes https://github.com/flutter/flutter/issues/172713

---

### [web] Remove outdated comment about HTML renderer (#172877)
- **Author**: Mouad Debbar
- **Date**: 2025-07-31
- **Link**: https://github.com/flutter/flutter/commit/7a5d1ab2e2082976bc0495b4ce311311c3b358e3



---

### Migrate to null aware elements - Part 4 (#172322)
- **Author**: Jamil Saadeh
- **Date**: 2025-07-30
- **Link**: https://github.com/flutter/flutter/commit/d6a4ace89195d530b07206942944c7a0f3744145



---

### [web] Fix empty first frame in multiview mode (#172493)
- **Author**: Mouad Debbar
- **Date**: 2025-07-25
- **Link**: https://github.com/flutter/flutter/commit/c1c38adec6c53fe90240cae3accf70c79871ef27

The issue was caused by a stale `EngineFlutterView.physicalSize` that
happened to be `Size(0, 0)` making rendering a no-op in the first frame.

Fixes https://github.com/flutter/flutter/issues/172397

---

### WebParagraph initial commit (#167559)
- **Author**: Rusino
- **Date**: 2025-07-21
- **Link**: https://github.com/flutter/flutter/commit/70cdc0c933d6b84817d216891953b6eb56e22007

This is the current (initial) state of WebParagraph project which is an
implementation of SkParagraph
on top of TextCluster
(https://github.com/fserb/canvas2D/blob/master/spec/enhanced-textmetrics.md).

Multilined text, mixed LTR/RTL text supported.

---------

Co-authored-by: Mouad Debbar <mdebbar@google.com>

---

### [web] Add tests for unified platform view embedding behavior (#172313)
- **Author**: Harry Terkelsen
- **Date**: 2025-07-17
- **Link**: https://github.com/flutter/flutter/commit/b2d4210b3795413c2360968b685743a6df60ff50

Adds tests for expected behavior of platform view embedding for the
unified renderer frontend.

We currently skip the tests for the renderer which doesn't yet comport
to the expected unified behavior. See [this
doc](https://docs.google.com/document/d/1-BYZO_oAOJkS_spmELqCmnPQIEUibT3Sj2GhIL3luow/edit?tab=t.0)
for an overview of the different behaviors and the expected behavior of
the unified platform view embedder.

This adds tests for https://github.com/flutter/flutter/issues/172308, a
follow-up PR will unify the platform view embedder behavior and unskip
the tests for the misbehaving renderer.

---

### [skwasm] Decrease reliance on finalizers/GC (#172187)
- **Author**: Jackson Gardner
- **Date**: 2025-07-16
- **Link**: https://github.com/flutter/flutter/commit/97ad45a3791e28d59e1b7487888f07de303a495f

Some changes which make Skwasm less dependent on GC cycles to free its
native resources:
* Explicitly clean up pictures clipped by the scene view
* Free native `ParagraphBuilder` when `build()` is called
* Restructure `TextStyle`, `ParagraphStyle`, `StrutStyle` and
`LineMetrics` so that they don't persistently hang on to native objects
beyond a paragraph build cycle.

This addresses https://github.com/flutter/flutter/issues/170889

---

### [web] Remove all usages of js_util. (#171871)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-07-16
- **Link**: https://github.com/flutter/flutter/commit/66281ce5206d6af6208deebac9dc06fdd6d5f88b

Closes https://github.com/flutter/flutter/issues/143396

### Description
- Removes `js_util` library usage across the codebase

In order to get rid of `dart.library.js_util` in
[`kIsWeb`](https://github.com/flutter/flutter/blob/e8d56b25c039666e1040c22ac36cfa3550be58cf/packages/flutter/lib/src/foundation/constants.dart#L83)
constant the dart analyzer has to be updated first. For now, the
`dart.library.js_util` value is hardcoded in the source code:
https://github.com/dart-lang/sdk/blob/1a88edceb75f70490827ef845586bf549d5f05b0/pkg/analyzer/lib/src/dart/constant/evaluation.dart#L2908-L2915.
So we either have to update this value or wait for the
https://github.com/dart-lang/sdk/issues/50045 fix.

---

### [web] Delete unused files in the engine (#172035)
- **Author**: Harry Terkelsen
- **Date**: 2025-07-14
- **Link**: https://github.com/flutter/flutter/commit/f58c4cf38591b95fe85fffd1afef079a1b1338bc

Delete unused files.

---

### Add RSuperellipse support to Web (global cache) (#171489)
- **Author**: Tong Mu
- **Date**: 2025-07-11
- **Link**: https://github.com/flutter/flutter/commit/dcae0c4ca0c3ee3317ed3198a2141184e949fb03

This PR adds `RSuperellipse` support to Web, so that these ops will
actually draw `RSuperellipse`s instead of falling back to `RRect`s,
except for platform views.
* (I was told in some earlier comments that RSuperellipses should fall
back to RRects for platform views but I can't remember where for now. If
reviewers think otherwise I can implement them right away or make this a
TODO in the future.)

The `RSuperellipse`s are drawn after being converted to paths. The
algorithm is nothing new, but already used in
`round_superellipse_param.cc`.

For performance optimization, `RSuperellipse`s that have uniform radii
will have their paths cached in a global cache after offset
normalization.

This PR does not add any new public APIs. (Although, I'm planning to
also implement this to the main `dart:ui` in the future to support
non-Impeller-nor-Web platforms, which will need
`RSuperellipse.toPathOffset` public.)

Fixes https://github.com/flutter/flutter/issues/163718

---

### [Web] Implement disabling interactive selection (#171935)
- **Author**: Loïc Sharma
- **Date**: 2025-07-11
- **Link**: https://github.com/flutter/flutter/commit/595bf3fd086fd5530fa1d55f387a56e425e0272c

This updates Flutter Web to ignore copy/paste/selections if
`enableInteractiveSelection` is `false` in a text field.

Part of https://github.com/flutter/flutter/issues/157611

## Scenarios tested

1. Click/tap on text: cursor should not move.
2. Double click/tap on text: text should not be selected
3. Triple click/tap on text: text should not be selected
4. Move cursor back (`Left arrow`): cursor should move back
5. Move cursor forward (`Right arrow`): cursor should move forward
8. Select previous word (`Shift+Left arrow`): text should not be
selected, cursor moves to previous word
9. Select previous word (`Shift+Right arrow`): text should not be
selected, cursor moves the next word
7. Select all shortcut (`Ctrl+A` or `Apple+A`): text should not be
selected. ⚠️ With this fix, Flutter Web moves the cursor to the end of
the text field.
8. Copy shortcut (`Ctrl+C` or `Apple+C`): clipboard should not be
updated
9. Paste shortcut (`Ctrl+V` or `Apple+V`): clipboard should not be
pasted
10. Right-click > Copy: clipboard should not be updated
11. Right-click > Paste: clipboard should not be pasted

## Browsers tested

macOS: Chrome, Firefox, Safari

## Example app

```dart
import 'package:flutter/material.dart';

void main() {
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: TextField(
            enableInteractiveSelection: false,
          ),
        ),
      ),
    ),
  );
}
```

---

### [Web a11y]Update table cell to use LabelRepresentation.sizedSpan  (#172013)
- **Author**: Hannah Jin
- **Date**: 2025-07-11
- **Link**: https://github.com/flutter/flutter/commit/2a3b048a53bd8cda1482d4892340710252feb438

fix: https://github.com/flutter/flutter/issues/171991

for a table cell leaf node
LabelRepresentation.ariaLabel will be ignored, 
LabelRepresentation.domText can focus on the text but the rect is wrong,
LabelRepresentation.sizedSpan works very well,

---

### Run tests on either macOS 14 or 15 (#171076)
- **Author**: Victoria Ashworth
- **Date**: 2025-07-11
- **Link**: https://github.com/flutter/flutter/commit/23b81a714d347d08bf4bbb93d9853cb0cd2a50c4

In preparation of upgrading the remaining bots to macOS 15, allow tests
to use any version of macOS 14 or 15.

---

### [web] Refactor clipboard. (#171427)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-07-11
- **Link**: https://github.com/flutter/flutter/commit/fa4a2c10985e5e070533a9c09af1f0ad92086ab3

Closes https://github.com/flutter/flutter/issues/48581
Closes https://github.com/flutter/flutter/issues/157484

### Description
This PR refactors the clipboard implementation in the web engine.

- Enables `ClipboardAPI*` strategies for all browsers
- Adds check for `format` in `getDataMethodCall` to match
implementations on other platforms

https://github.com/flutter/flutter/blob/975f6d8bef99eb3699c7560962eb96480b6ccf07/engine/src/flutter/shell/platform/android/io/flutter/plugin/platform/PlatformPlugin.java#L554
https://github.com/flutter/flutter/blob/975f6d8bef99eb3699c7560962eb96480b6ccf07/engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformPlugin.mm#L410

- Removes `ExecCommand*` strategies
- Removes deprecated `execCommand` method from `DomDocument`

The demo app with refactored clipboard is available at:
https://flutter-clipboard-playground.web.app

---

### [web] Add frame number support. (#171592)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-07-10
- **Link**: https://github.com/flutter/flutter/commit/43657f3baa17bc1df6cc15da8b0fea2290c2c4fd

Fixes https://github.com/flutter/flutter/issues/170972

### Description
- Adds `frameData` with `frameNumber` value to `FrameService`
- Adds non-mock `frameData` to `EngineFlutterWindow` and
`EnginePlatformDispatcher`
- Adds `frameNumber` value to `FrameTimingRecorder`'s recorded timings

---

### Bump Dart to 3.8 and reformat (#171703)
- **Author**: Kate Lovett
- **Date**: 2025-07-07
- **Link**: https://github.com/flutter/flutter/commit/a04fb324be734cf18811c30c06baf9bf07b3bab3

Bumps the Dart version to 3.8 across the repo (excluding
engine/src/flutter/third_party) and applies formatting updates from Dart
3.8.

---

### Add semantics role for form (#170709)
- **Author**: Hannah Jin
- **Date**: 2025-07-03
- **Link**: https://github.com/flutter/flutter/commit/8edb61af1ae440b93da82320d4bf37052467b1d4

fix: [#161628](https://github.com/flutter/flutter/issues/161628)

---

### Adds semantics locale support for web (#171196)
- **Author**: chunhtai
- **Date**: 2025-07-02
- **Link**: https://github.com/flutter/flutter/commit/2b6b9d12589875842e64f4b78fd0f11337755aaa



---

### feat(web): Add navigation focus handler for assistive technology focus restoration (#170046)
- **Author**: zhongliugo
- **Date**: 2025-06-30
- **Link**: https://github.com/flutter/flutter/commit/bb784b983b6e0e5f9391080ff159aa2381266376

**Description**
This pull request adds a navigation focus handler to the Flutter web
engine that bridges assistive technology activations with Flutter's
focus tracking system. The listener intercepts screen reader activations
(VoiceOver, NVDA, JAWS, etc.) and forces DOM focus on the activated
elements, ensuring they integrate properly with Flutter's navigation
focus restoration.

**Before**
When using VoiceOver or other screen readers to navigate between pages
in a Flutter web app, focus restoration would fail because assistive
technology activations don't naturally trigger the DOM focus events that
Flutter's navigation system expects. Users would lose their navigation
context, with focus jumping to default elements instead of returning to
the previously activated button.

**Before behavior demo**
https://focus-demo-0529-before.web.app
On mac os, Use command + F5 to activate voice over. 
Use control + option + arrow right to focus on "Go to page two" button. 
Use control + option +  space to click the "Go to page two" button. 
Then in page two, use control + option + arrow right to focus on "Back
to page one" button.
The focus will be on "Page one" heading instead of "Go to page two"
button. This is not expected

**After**
Screen reader users can now navigate between pages and have their focus
properly restored to the previously activated element (e.g., "Go to Page
Two" button) when returning to a previous page, providing a consistent
and accessible navigation experience across all assistive technologies.

**After behavior demo**
https://focus-demo-0529-after.web.app
On mac os, Use command + F5 to activate voice over. 
Use control + option + arrow right to focus on "Go to page two" button. 
Use control + option +  space to click the "Go to page two" button. 
Then in page two, use control + option + arrow right to focus on "Back
to page one" button.
The focus will be on "Go to page two" button. This is expected.

**Issue Fixed**
This PR addresses GitHub Issue #140483, which reports that VoiceOver
focus restoration doesn't work in Flutter web applications during
navigation.

---

### License cpp jun24 (#171088)
- **Author**: gaaclarke
- **Date**: 2025-06-25
- **Link**: https://github.com/flutter/flutter/commit/091f0ff99eca810d532eb9480b357ad6373928db

additions:
- root package files need a header
- added ci step
- performance increases (executes in like 15s now)
- added README.md to the data directory
- cleaned up --v=1 log

---

### [web] More granular configuration of the test environment (#168767)
- **Author**: Mouad Debbar
- **Date**: 2025-06-24
- **Link**: https://github.com/flutter/flutter/commit/caf0c82b826da7b185670c766c20e10846a60031

There's today a single boolean `debugEmulateFlutterTesterEnvironment`
that determines certain behaviors in the engine to emulate how the
Flutter Tester runs (more details at
https://github.com/flutter/flutter/issues/145779).

With this PR:
- Run all engine unit tests in production mode by default.
- Give tests more granular control over which test behaviors to
enable/disable (e.g. Ahem font).
- Keep it easy for framework tests to enable all emulation behaviors.

Fixes https://github.com/flutter/flutter/issues/145779

---

### rename from announce to supportsAnnounce on engine (#170618)
- **Author**: ash2moon
- **Date**: 2025-06-23
- **Link**: https://github.com/flutter/flutter/commit/4fb1042870e5bff06c1cec3d161272f269214893

Part of https://github.com/flutter/flutter/issues/165510

⤴️ Original PR: https://github.com/flutter/flutter/pull/169685
⤵️ Child PR: https://github.com/flutter/flutter/pull/168992

This is a renaming of the announce to `supportsAnnounce`. See more info
in this comment thread:
https://github.com/flutter/flutter/pull/168992#discussion_r2146068546

---

### Rename `entryPointBaseUrl` to `entrypointBaseUrl` (#170166)
- **Author**: Tirth
- **Date**: 2025-06-18
- **Link**: https://github.com/flutter/flutter/commit/9bfb92e6f89b7a871ce4e868d087b153103bea16



---

### Reland lazy path and object arenas (#170303)
- **Author**: Jackson Gardner
- **Date**: 2025-06-16
- **Link**: https://github.com/flutter/flutter/commit/dbb105a74d76d890cfd092c0a50b93e7549d1c7b

This PR is an attempt to reland
https://github.com/flutter/flutter/pull/168996

There were some issues that cropped up in the `web_long_running_test`
shards. However, it turns out that these tests don't actually run in
presubmit on any PR that has any engine changes, which is not ideal. I
modified the long running tests to run in presubmit, but this had issues
because apparently a big chunk of these integration tests actually are
trying to download canvaskit from CDN. I changed almost all of the tests
to use local canvaskit (which should make them more reliable and
hermetic). There is one test whose job is to actually test the CDN
itself, and I am leaving that disabled in presubmit for PRs that have
engine changes (since the engine artifacts won't be uploaded to CDN yet)
but the rest of them are all running and passing now.

Also, I fixed the underlying issue that was exposed by the long running
tests, which is that the CanvasKit path clipping stuff in the layer
visitor needs to be aware of LazyPath.

---

### [web] Add Paint dithering. (#170362)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-06-13
- **Link**: https://github.com/flutter/flutter/commit/a7c06212410c2e499d22567624745e76edf8832e

Fixes https://github.com/flutter/flutter/issues/168798
Closes https://github.com/flutter/flutter/issues/134250

### Description
- Adds `Paint` dithering for gradient shaders in `canvaskit`
- Adds `Paint` dithering for gradient shaders in `skwasm`

### CanvasKit
| Before | After |
| - | - |
| <img width="739" alt="canvaskit_bug"
src="https://github.com/user-attachments/assets/cf15e6ff-e0ab-4bce-9db1-653271f5adc8"
/> | <img width="739" alt="canvaskit_fix"
src="https://github.com/user-attachments/assets/3aba09a5-f27a-4c17-a596-44b53961373e"
/> |

### SkWASM
| Before | After |
| - | - |
| <img width="739" alt="skwasm_bug"
src="https://github.com/user-attachments/assets/fe882450-f656-4a1b-9811-fdded5e4a737"
/> | <img width="739" alt="skwasm_fix"
src="https://github.com/user-attachments/assets/86bf2cf9-d743-453b-9d7a-600e293bf8f1"
/> |

<details>
<summary>Sample Source Code</summary>

```dart
import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      height: 400,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: const [Color(0xff324958), Color(0xff26323a)],
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
        ),
      ),
    );
  }
}

```

</details>

---

### Fix `Semantics.identifier` on TextField not working on web (#170395)
- **Author**: Renzo Olivares
- **Date**: 2025-06-12
- **Link**: https://github.com/flutter/flutter/commit/cf127960013a443d3c14672fff6d1c70f657432c

Fixes #155323

Before this change the `identifier` would not be updated even if marked
dirty for a `SemanticRole` that had no `SemanticBehavior`s. After this
change an `identifier` marked dirty is now updated even if the
`SemanticRole` has no `SemanticBehavior`s.

---

### [canvaskit] Manually trigger `input` event in text editing tests for Safari (#170022)
- **Author**: Harry Terkelsen
- **Date**: 2025-06-11
- **Link**: https://github.com/flutter/flutter/commit/f59e8e58852c6e06c34d6fd5cf36baf9ac4cfa1a

Manually trigger an `input` event to trigger the `handleChange` handler
in the text input element. In Safari for MacOS 15.5, this workaround is
now required.

Fixes https://github.com/flutter/flutter/issues/169282

---

### Dispose ImmutableBuffer at web_ui.instantiateImageCodecFromBuffer and web_ui.instantiateImageCodecWithSize (#161488)
- **Author**: Koji Wakamiya
- **Date**: 2025-06-07
- **Link**: https://github.com/flutter/flutter/commit/f4bd508c28a92f2e85422f454cf1a393eebed843

fix https://github.com/flutter/flutter/issues/150016

Fixed `instantiateImageCodecFromBuffer` and
`instantiateImageCodecWithSize` and added tests.

doc

> The buffer will be disposed by this method once the codec has been
created, so the caller must relinquish ownership of the buffer when they
call this method.

*
https://api.flutter.dev/flutter/dart-ui/instantiateImageCodecFromBuffer.html
*
https://api.flutter.dev/flutter/dart-ui/instantiateImageCodecWithSize.html

ui


https://github.com/flutter/flutter/blob/bd1ebf2e1498bd022808f8b237654ce42ae537be/engine/src/flutter/lib/ui/painting.dart#L2484-L2504

https://github.com/flutter/flutter/blob/bd1ebf2e1498bd022808f8b237654ce42ae537be/engine/src/flutter/lib/ui/painting.dart#L2541-L2558

web_ui


https://github.com/flutter/flutter/blob/bd1ebf2e1498bd022808f8b237654ce42ae537be/engine/src/flutter/lib/web_ui/lib/painting.dart#L640-L679

---

### [a11y] Semanctis flag refactor step 4: web and updateNode (#168852)
- **Author**: Hannah Jin
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/7769f98c33c5858bd7fca6f914374f2d01bd4e9b

issue: https://github.com/flutter/flutter/issues/166101, overall goal is
to update semantics flag to be a struct/class to support more than 32
flags.

step 1: https://github.com/flutter/flutter/pull/167421 Update
semantics_node.h and dart:ui
step 2: https://github.com/flutter/flutter/pull/167738 Update Embedder
part to use a struct instead of a int bit mask.
step 3: https://github.com/flutter/flutter/pull/167771 Update Framework
use the SemanticsFlags class instead of bitmask
step 4 (this PR) Update web engine to use the new class and update
SemanticsUpdateBuilder.updateNode to pass a list of bools instead of
bitmask

TODO:

flutter_tester
use the SemanticsFlags class instead of bitmask


[apicheck_test.dart](https://github.com/flutter/flutter/pull/167421/files#diff-69aefaacf1041f639974044962123bfae0756ce86032ac1f26256099425d7a5a)
Add this test back

---

### Fix VoiceOver tab activation by adding tappable behavior to SemanticTab (#170076)
- **Author**: zhongliugo
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/ea83a6a072990acc34c482d8e90f4d2bef713344

## Description
This pull request fixes VoiceOver tab activation by adding tappable
behavior to the SemanticTab class in the Flutter web engine. The fix
ensures that tabs can be properly activated using assistive technology
commands like VoiceOver's ctrl-option-space, making tab navigation fully
accessible for screen reader users.

## Before
When using VoiceOver to navigate tabs in a Flutter web app, users were
unable to activate tabs using the standard VoiceOver activation command
(ctrl-option-space). The SemanticTab class was missing the Tappable
semantic behavior that enables assistive technology interaction, causing
screen readers to treat tabs as non-interactive elements despite having
tap handlers in the Flutter framework.

**Before behavior:**
https://tab-0605-before.web.app/
- Navigate to a tab using VoiceOver (ctrl-option-arrow)
- Attempt to activate the tab with ctrl-option-space
- Tab does not respond to activation command
- Users cannot switch between tabs using assistive technology

## After
VoiceOver and other screen reader users can now properly activate tabs
using standard assistive technology commands. Tabs respond correctly to
ctrl-option-space and other activation gestures, providing full keyboard
accessibility for tab navigation.

**After behavior:**
https://tab-0605-after.web.app/
- Navigate to a tab using VoiceOver (ctrl-option-arrow)
- Activate the tab with ctrl-option-space
- Tab switches correctly, displaying the associated tab panel
- Consistent behavior across all assistive technologies

## Changes Made
- Added `addTappable()` call to `SemanticTab` constructor in `tabs.dart`
- Added test case "tab with tap action" to verify DOM elements receive
the `flt-tappable` attribute
- Ensures tabs with `hasTap: true` are properly marked as interactive
for assistive technologies

## Testing
Added unit test that verifies:
- Tabs with tap actions receive the `flt-tappable` DOM attribute
- SemanticTab properly integrates with the existing tappable behavior
system

## Issue Fixed
This PR addresses GitHub Issue #169279, which reports that VoiceOver
doesn't allow users to click tabs in Flutter web applications.

---

### Add landmark roles (#168931)
- **Author**: Qun Cheng
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/39ce6155300cec9808570b8dc7fd5df5f1635a1a

This PR is to add ARIA landmark roles to `SemanticsRole`: complementary,
contentInfo, main, navigation and region.

I skipped `sectionhead` because it is an abstract role based on the [MDN
docs](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/sectionhead_role#:~:text=The%20structural%20sectionhead%20role%20is%20an%20abstract%20role%20for%20the%20subclass%20roles%20that%20identify%20the%20labels%20or%20summaries%20of%20the%20sections%20they%20label.%20The%20role%20must%20not%20be%20used.)
.

Fixes https://github.com/flutter/flutter/issues/162138

---

### [engine/web] Migrate many things to switch expressions (#170096)
- **Author**: Kevin Moore
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/8a41339418df9943583e72029813ea76d33587bf



---

### Lazy paths and frame object arenas (#168996)
- **Author**: Jackson Gardner
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/a11524896eaecaa2a6a44c14cdb65aa31492e479

The lifecycle of `Path` objects are currently not managed by the user.
That is to say, there is no `dispose` method on path objects and
therefore no explicit way to detect when the user is done with the path
object and the native-side object can be exposed. As of right now, we
use `FinalizationRegistry` to clean up the native-side objects when the
dart-side objects are garbage collected. However, this has a number of
issues:
* Adding objects to the finalization registry actually ends up
prolonging their lifetime in V8, since the V8 garbage collector will
only collect them in a major GC and not a minor GC once they are
registered with the finalization registry. See the following Chrome bug:
https://issues.chromium.org/issues/340777103
* We can run into OOM issues where the linear memory of canvaskit/skwasm
exceeds 2GB if the collection of paths go on too long.
* Even if the paths do get collected by the GC, they often happen
infrequently enough that paths over many frames have accumulated and are
being collected all at once. This gap can often be dozens or hundreds of
frames long, and when collection does occur it is freeing a lot of paths
at once, which causes a janky frame. I have seen this take upwards of
800ms on my M1 Macbook Pro.

There are some more details in
https://github.com/flutter/flutter/issues/153678

This PR alleviates this issue by creating a `LazyPath` object. This
object is added to an arena that explicitly collects the underlying
native objects at the end of each frame. The object also tracks the API
calls made to it so that if it is actually used across a frame boundary
that we can recreate the native object if it was freed.

Running our benchmarks, this has a non-trivial performance cost to
building and using these paths (30-50% in a microbenchmark, 3-6% in a
broader full app benchmark). However, as a team we've decided that this
cost is worth it to avoid OOM issues as well as the non-deterministic
jank associated with large collections of these objects.

---

### [web] Allow overriding platformViewRegistry for testing. (#170144)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/ed275039e174b0916816a2889f21bad54a61af56

Closes https://github.com/flutter/flutter/issues/170143

### Description
- Adds `debugOverridePlatformViewRegistry` function to allow
`platformViewRegistry` overriding in tests
- Adds tests for the new functionality

---

### Remove AlarmClock from BrowserImageDecoder (#161481)
- **Author**: Koji Wakamiya
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/de805531741f9b9a56b7ee65bafa37b502be788d

PR derived from https://github.com/flutter/flutter/pull/159945.

Since `ui.Codec` is now disposed of externally, the close processing of
the resource by AlarmClock is no longer necessary. This fix works in
combination with #159945 and is stabilized by #161132.

---

### [Engine][Web] Fixed fallback font loading process (#166212)
- **Author**: Koji Wakamiya
- **Date**: 2025-06-06
- **Link**: https://github.com/flutter/flutter/commit/2c9d898e2f01ccea157d559181d4acaa82388200

fix https://github.com/flutter/flutter/issues/165299

Fixes a problem where the drawing does not render as expected if the
value of `maxCodePointsCovered` is greater for an unsuitable language
than for a font suitable for that language.

| before | after |
| :---:  | :---: |
| <img
src="https://github.com/user-attachments/assets/137dc021-31ce-41a7-b7a9-843abd88b738"
width="300" /> | <img
src="https://github.com/user-attachments/assets/fbfcc982-623a-4fe9-87a6-bf5bd7c88ebd"
width="300" /> |

---

### Fix typos: canvakit--> canvaskit (#169868)
- **Author**: Hannah Jin
- **Date**: 2025-06-03
- **Link**: https://github.com/flutter/flutter/commit/afd5927b36b51b36c315ec8ffd446d62faae550d



---

### [Web][Engine] Fix composingBaseOffset and composingExtentOffset value when input japanese text (#161593)
- **Author**: Koji Wakamiya
- **Date**: 2025-06-04
- **Link**: https://github.com/flutter/flutter/commit/03dbf1a99c0a9d845eeba8dd26eb4e8bbcedbc49

fix https://github.com/flutter/flutter/issues/159671

When entering Japanese text and operating `shift + ← || → || ↑ || ↓`
while composing a character, `setSelectionRange` set (0,0) and the
composing text is disappeared. For this reason, disable shit + arrow
text shortcuts on web platform.

### Movie

fixed


https://github.com/user-attachments/assets/ad0bd199-92a5-4e1f-9f26-0c23981c013d

master branch


https://github.com/user-attachments/assets/934f256e-189b-4916-bb91-a49be60f17b3

---

### Add announce support to the engine (#169685)
- **Author**: ash2moon
- **Date**: 2025-06-02
- **Link**: https://github.com/flutter/flutter/commit/694600a9f86b191688c4697c22701e60acabbfe0

Partly of https://github.com/flutter/flutter/issues/165510

⤵️ Child PR: https://github.com/flutter/flutter/pull/168992

Partly re-lands https://github.com/flutter/flutter/pull/165531
The PR was originally reverted due to an issue with an internal Google
test. I split re-land PR into two separate ones so that we can
individually revert in case it fails again.

---

### [Web][Engine] Update MediaQuery in response to semanticsEnabled (#166836)
- **Author**: Koji Wakamiya
- **Date**: 2025-06-02
- **Link**: https://github.com/flutter/flutter/commit/d064c95c1065e71ea397aa40767c2fa828d07036

fix https://github.com/flutter/flutter/issues/134980

Calling
`EnginePlatformDispatcher.instance.invokeOnAccessibilityFeaturesChanged();`
after `EnginePlatformDispatcher.instance.configuration =
newConfiguration` to notify update configuration event to `MediaQuery`.

before


https://github.com/user-attachments/assets/89969cc7-f9fa-4ac0-8ce0-d026d5676f27

after


https://github.com/user-attachments/assets/8a284d42-e344-4039-8569-8567956326b7

<details>

<summary>Example Code</summary>

```dart
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

void main() {
  runApp(const MaterialApp(home: MyHomePage()));
}

class MyHomePage extends StatelessWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                SemanticsBinding.instance.ensureSemantics();
              },
              child: const Text('Enable a11y'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Should stay visible'),
                    action: SnackBarAction(label: 'Action', onPressed: () {}),
                  ),
                );
              },
              child: const Text('Show snackbar'),
            ),
            const SizedBox(height: 24),
            Text(
              'MediaQuery.accessibleNavigationOf(context): ${MediaQuery.accessibleNavigationOf(context)}',
            ),
            Text(
              'SemanticsBinding.instance.semanticsEnabled: ${SemanticsBinding.instance.semanticsEnabled}',
            ),
            Text(
              'SemanticsBinding.instance.platformDispatcher.semanticsEnabled: ${SemanticsBinding.instance.platformDispatcher.semanticsEnabled}',
            ),
            Text(
              'SemanticsBinding.instance.accessibilityFeatures: ${SemanticsBinding.instance.accessibilityFeatures}',
            ),
          ],
        ),
      ),
    );
  }
}
```

</details>

---

### Removes elevation and thickness from semantics r2 (#169382)
- **Author**: chunhtai
- **Date**: 2025-05-30
- **Link**: https://github.com/flutter/flutter/commit/3c28bb7a2437dea488ecdeb42ce2ed0e864a0aab



---

### Add dynamic module loader to flutter wasm entrypoint script. (#169313)
- **Author**: Nate Biggs
- **Date**: 2025-05-28
- **Link**: https://github.com/flutter/flutter/commit/f5f9f351f0f80d6097d1ae179d947395ffc20078

Adds support for loading dynamic module files to the Flutter wasm
entrypoint script. The Dart SDK already tries to import this function
when dynamic modules are enabled.

---

### Split hint from label and expose it via aria-description or aria-describedby (#169157)
- **Author**: zhongliugo
- **Date**: 2025-05-27
- **Link**: https://github.com/flutter/flutter/commit/768932e972999a3c926bf2af212b821b80208ea1

**Summary**
This PR improves web accessibility in Flutter by separating hint from
label in the semantics engine and exposing them via ARIA attributes. The
hint is set using aria-description (or aria-describedby as a fallback
for browsers that do not support aria-description).

**Details**
Hint separation:
The hint is exposed via aria-description if supported, or via
aria-describedby with a hidden node as a fallback.
Browser compatibility:
Uses feature detection to choose between aria-description and
aria-describedby.
Test coverage:
Added/updated tests to verify correct ARIA attribute behavior and
fallback logic.

**How to verify**
All relevant tests pass (semantics_test.dart, semantics_text_test.dart).

**Motivation**
This change brings Flutter web closer to accessibility best practices
and ARIA standards, improving the experience for users of assistive
technologies.

**Before/After Change**
before: https://before-change-hint.web.app/
after: https://after-change-hint.web.app/ 
after(fallback to aria-describedby):
https://after-change-hint-fallback.web.app/

**Issues fixed**
https://github.com/flutter/flutter/issues/162140

**Note**
Some focus-related tests (e.g., incrementable sends focus events) are
failing, but these failures are also present on the main branch and are
unrelated to the ARIA label/hint changes in this PR.

---

### [skwasm] Add the capability of dumping live object counts in debug mode. (#168389)
- **Author**: Jackson Gardner
- **Date**: 2025-05-16
- **Link**: https://github.com/flutter/flutter/commit/8ae7b522dc0fcc112ceebf131af7fb979aa92ce8

This adds a debugging utility that allows us to dump counts of the live
skwasm objects in debug mode. This is useful for understanding memory
leaks.

This is not code that runs in production or affects end users, so I'm
not bothering to write specific unit tests for this functionality.

---------

Co-authored-by: Kevin Moore <kevmoo@users.noreply.github.com>

---

### [a11y] Semanctis flag refactor step 3: framework part (#167771)
- **Author**: Hannah Jin
- **Date**: 2025-05-13
- **Link**: https://github.com/flutter/flutter/commit/30924e2d6d10fac55112f6dc35b41def63f6f1b5

issue: https://github.com/flutter/flutter/issues/166101, overall goal is
to update semantics flag to be a struct/class to support more than 32
flags.

step 1: https://github.com/flutter/flutter/pull/167421 Update
semantics_node.h and dart:ui
step 2: https://github.com/flutter/flutter/pull/167738 Update Embedder
part to use a struct instead of a int bit mask.
step 3:(this PR) Update Framework use the SemanticsFlags class instead
of bitmask

TODO:
web engine
use the new class

SemanticsUpdateBuilder.updateNode
pass a list of bools instead of bitmask

flutter_tester
use the SemanticsFlags class instead of bitmask


[apicheck_test.dart](https://github.com/flutter/flutter/pull/167421/files#diff-69aefaacf1041f639974044962123bfae0756ce86032ac1f26256099425d7a5a)
Add this test back

---

### Use live region in error text input decorator for Android (#165531)
- **Author**: ash2moon
- **Date**: 2025-05-13
- **Link**: https://github.com/flutter/flutter/commit/f3a180656274819d6b5dfaba392aa1fd6198fcf9

Resolves partly https://github.com/flutter/flutter/issues/165510


**Context:** This issue originates from
https://github.com/flutter/flutter/issues/99715, where it was reported
that `liveRegion` alone was insufficient for announcing form validation
errors. While `liveRegion` announces the first error encountered,
subsequent submissions with the same error message on Android would not
trigger a re-announcement.

**Original Solution:** Pull request
https://github.com/flutter/flutter/pull/123373 addressed this by
implementing the `announce` event to ensure error messages were
consistently announced, even for repeated submissions.

**Native Android Behavior (Jetpack Compose):** In native Android
development using Jetpack Compose, setting the `isError` property of a
`TextField` to `true` triggers Talkback to announce "Error invalid
input." This announcement occurs *only* on the initial change to the
error state. Subsequent errors, even if the `isError` property remains
`true`, are not re-announced. This behavior closely mirrors the
functionality of `liveRegion`, with the key difference being that
`liveRegion` also announces the specific error text, in addition to the
general error state. Testing in a native Jetpack Compose application
confirms this behavior and provides a valuable comparison point against
the current Flutter form example.

**Suggested Action:** **Fork** the behavior in
https://github.com/flutter/flutter/pull/123373. Reinstate the use of
`liveRegion` for error announcements within `widgets/Form` for Android
and keep other platforms the same.

---

### [web] Fix multiline input selection in Chrome. (#168217)
- **Author**: Kostia Sokolovskyi
- **Date**: 2025-05-13
- **Link**: https://github.com/flutter/flutter/commit/f50c6c0fc4f7444adbd59a924521a5ead4ff5679

Fixes https://github.com/flutter/flutter/issues/167805
Fixes https://github.com/flutter/flutter/issues/162698

### Description

First of all, I would like to thank @jezell for posting their fix of
this selection issue:
https://github.com/singerdmx/flutter-quill/issues/2450#issuecomment-2754652065

The issue with selection is happening because in Chrome `pointermove`
event and its coalesced events have some different targets. @mdebbar
already spotted this behavior some time ago and even filed a Chrome bug:
https://github.com/flutter/engine/pull/56949#discussion_r1871750266

This jsfiddle allows reproducing the bug:
https://jsfiddle.net/knevercode/y2hpfmrb/2/

On the following recording, you can see the events' targets and their
bounding boxes.
<video
src="https://github.com/user-attachments/assets/82af8d86-2cfe-4e36-a977-46ffa58facdb"/>

Those coalesced events have their `offsetX` and `offsetY` values
relative to the dummy `div` target. So to fix that, we have to translate
those values to be relative to the actual target.

This PR does exactly this in `_computeOffsetForInputs` when
`event.target != eventTarget` .

| Before | After |
| - | - |
| https://chrome-input-selection-bug.web.app |
https://chrome-input-selection-fix.web.app |
| <video
src="https://github.com/user-attachments/assets/1e10b43a-ff4f-46e8-8977-ee435f9d78fb"/>
| <video
src="https://github.com/user-attachments/assets/a997bfd0-8361-4bb3-910c-58cfc6b5d426"/>
|

---

### [web] more cleanup of unused APIs (#168524)
- **Author**: Kevin Moore
- **Date**: 2025-05-09
- **Link**: https://github.com/flutter/flutter/commit/4cad7a78e82a860571c07534c28dbfb1130d7088

One API only existed for tests.
Also removed an unused class

---

### Remove unnecessary setAriaRole('dialog') fallback in SemanticRoute class (#168345)
- **Author**: zhongliugo
- **Date**: 2025-05-08
- **Link**: https://github.com/flutter/flutter/commit/76747c0ecef6b24087f451f64142c7d053bd71a4

**Description**
This pull request removes the unnecessary setAriaRole('dialog') fallback
in the SemanticRoute class within the Flutter web engine. This line was
an old fallback and is no longer needed

**Before**
https://dialog-0505-before.web.app/

**After**
https://dialog-050502-after.web.app/

**Issue Fixed**
This PR addresses GitHub Issue #168247, which proposes reconsidering the
application of role="dialog" to arbitrary routes.

---

### [web] drop more use of deprecated JS functions (#166157)
- **Author**: Kevin Moore
- **Date**: 2025-05-07
- **Link**: https://github.com/flutter/flutter/commit/3ff039415e2f4cb9d1042ce81070b4673c3f896f



---

### [skwasm] Dispose underlying picture recorder when ending recording. (#168384)
- **Author**: Jackson Gardner
- **Date**: 2025-05-06
- **Link**: https://github.com/flutter/flutter/commit/51ff96b9ac5bea0df1a831126dc8948e91ed46c4

The picture recorder doesn't have an explicit disposal function, so
instead we should dispose it when `endRecording` is called.

This addresses https://github.com/flutter/flutter/issues/168190

---

### Skwasm heavy (#166619)
- **Author**: Jackson Gardner
- **Date**: 2025-05-05
- **Link**: https://github.com/flutter/flutter/commit/2b5ef64fc4198f6ec541774b1127eafea220107b

This produces a build of Skwasm that works on Firefox and Safari. This
means we use `SkAnimatedImage` for animated gifs and webps and use
builtin ICU data in Skia.

I have unit test suites for Safari and Firefox with dart2wasm and both
`ui` and `engine` test sets. However, there are a few issues with
running these on CI:
* Safari+dart2wasm doesn't work yet until the CI bots are upgraded to
macOS 15, so these have been disabled on CI for now (but you can run the
unit test suite locally).
* Firefox+ui doesn't work because our Linux bots have no GPU and
therefore no WebGL2 support, so that one is disabled. Firefox+dart2wasm
with the `engine` suite is enabled on CI though.

I did make some changes to the host page for our unit test harness so
that Safari actually works though. Even though we're not running on CI,
you can still run locally if you have macOS 15.

---

### [WebParagraph] Initial wiring for the experimental WebParagraph implementation (#167763)
- **Author**: Mouad Debbar
- **Date**: 2025-05-02
- **Link**: https://github.com/flutter/flutter/commit/f454856afce9e283b7f088d72a93652be38670c3

In this PR:
- `felt build --experimental-webparagraph` builds a 3rd variant of
CanvasKit to be used for `WebParagraph`.
- `felt test --suite=chrome-dart2js-experimental-webparagraph-ui` runs
`test/ui/` tests against `WebParagraph`.
- `felt test --suite=chrome-dart2js-experimental-webparagraph-ui` runs
Chrome with the extra flag:
    - `--enable-experimental-web-platform-features`

In the future:
- Upgrade to Chrome@133.0.6943.53 or above.
- Actual implementation and tests of WebParagraph coming in
https://github.com/flutter/flutter/pull/167559
- Run the `chrome-dart2js-experimental-webparagraph-ui` suite in CI.
- Trim the new experimental build of CK to realize the reduction in
size.

---

### Removes semantics role search box (#167290)
- **Author**: chunhtai
- **Date**: 2025-04-30
- **Link**: https://github.com/flutter/flutter/commit/b47c298320434bd369f5139fecf9500f1b97fa95



---

### [web] denull some of text_editing.dart (#166595)
- **Author**: Yegor
- **Date**: 2025-04-28
- **Link**: https://github.com/flutter/flutter/commit/c790bb111addb91491cce8eb71d0200e45ad1a17

According to
https://github.com/flutter/flutter/blob/485d6b8ae388bd16186e78c37d21d6f505d155e2/packages/flutter/lib/src/services/text_input.dart#L1086,
the framework never sends null values for any of the fields. So there's
no need for the engine to do all the null handling.

---------

Co-authored-by: Mouad Debbar <mouad.debbar@gmail.com>

---

### web: Use aria-current as fallback for aria-selected (#167672)
- **Author**: zhongliugo
- **Date**: 2025-04-25
- **Link**: https://github.com/flutter/flutter/commit/f01be78706671c7c42b22e27a22f4d4ae99089b6



---

### [a11y] Semanctis flag refactor step 1:  engine part  (#167421)
- **Author**: Hannah Jin
- **Date**: 2025-04-22
- **Link**: https://github.com/flutter/flutter/commit/46144a2f4d9b611ac8ea1594ccdbd9f5cbd8ed3a

issue: https://github.com/flutter/flutter/issues/166101 


**step 1:** Add struct SemanticsFlags in semantics_node.h and class
SemanticsFlags in dart:ui, it's still a bitmask in embedder and
framework.


TODO: 
Other parts will be in other following  PRs
* Embedder 
add a struct FlutterSemanticsFlags
add FlutterSemanticsFlags* to FlutterSemanticsNode2

* web engine
 use the new class

* SemanticsUpdateBuilder.updateNode
pass a list of bools instead of bitmask

* Framework
use the SemanticsFlags class instead of bitmask

* flutter_tester
use the SemanticsFlags class instead of bitmask
*
[apicheck_test.dart](https://github.com/flutter/flutter/pull/167421/files#diff-69aefaacf1041f639974044962123bfae0756ce86032ac1f26256099425d7a5a)
 Add this test back


*Replace this paragraph with a description of what this PR is changing
or adding, and why. Consider including before/after screenshots.*

*List which issues are fixed by this PR. You must list at least one
issue. An issue is not required if the PR fixes something trivial like a
typo.*

*If you had to change anything in the [flutter/tests] repo, include a
link to the migration guide as per the [breaking change policy].*

---

### [web] close input connection when window/iframe loses focus (#166804)
- **Author**: Yegor
- **Date**: 2025-04-18
- **Link**: https://github.com/flutter/flutter/commit/7ca63fadd7743f5cdaeab68a7f78704f947c1821

Fixes https://github.com/flutter/flutter/issues/155265

This includes 2 fixes:

* When the window/iframe loses focus, close the text input connection
instead of grabbing the focus again.
* Do not enable semantics using the placeholder when moving focus using
the "Tab" key.

Bonus: remove the no longer necessary `ViewFocusBinding.isEnabled`
(doesn't fix any issues, just a clean-up).

---------

Co-authored-by: Mouad Debbar <mdebbar@google.com>

---

### [Web] Remove `webOnlyUniformRadii` from `RRect` (#167237)
- **Author**: Tong Mu
- **Date**: 2025-04-15
- **Link**: https://github.com/flutter/flutter/commit/aef4718b39569939ec0052c44819cd01176234ca

This variable was added in https://github.com/flutter/engine/pull/15970
(for the HTML renderer I guess?) and is apparently no long used
anywhere.

---

### [skwasm] Use `queueMicrotask` instead of `postMessage` when single-threaded (#166997)
- **Author**: Jackson Gardner
- **Date**: 2025-04-14
- **Link**: https://github.com/flutter/flutter/commit/2f6cdc3fe108efe37e90a9868c8a19ace37f0aca

It turns out `postMessage` is quite a bit more expensive than
`queueMicrotask`. Before dynamic threading, this is what we actually
did, and perf regressed when we started using `postMessage` instead.

This fixes https://github.com/flutter/flutter/issues/166905

---

### Reland "SliverEnsureSemantics (#165589)" (#166889)
- **Author**: Renzo Olivares
- **Date**: 2025-04-10
- **Link**: https://github.com/flutter/flutter/commit/fc12bec5eca277239e322451967fcc028addacd7

This reverts commit 2fc716d, and updates the cross-axis size of the
`_scrollOverflowElement` to be 1px (non-zero), so it is taken into
account by the scrollable elements scrollHeight.

Fixes #160217

---

### [web:skwasm] be consistent about handling imbalanced layer push/pop sequence (#166887)
- **Author**: Yegor
- **Date**: 2025-04-10
- **Link**: https://github.com/flutter/flutter/commit/ac1d8613fc9a9977d5ea22e3084c532664ef34ea

Skwasm was the only renderer that enforced that the root layer cannot be
popped. However, canvaskit and the native engines all allow popping the
root layer. It's just a noop.

Also, `EngineSceneBuilder` called `currentBuilder.build()` before
checking if the layer that's being popped is a root layer. This means
skwasm would call `rootLayer.build()` twice when push/pop are
unbalanced. It is called once on the last `pop()` on the root layer.
Then it is called again in `EngineSceneBuilder.build`.

Not a guarantee, but this may help reduce the skwasm error rates from
DevTools that look like this:

```
org-dartlang-sdk:///dart-sdk/lib/_internal/wasm/lib/error_utils.dart 130:15 | _throwIndexError
org-dartlang-sdk:///dart-sdk/lib/_internal/wasm/lib/error_utils.dart 24:7 | checkIndexBCE
org-dartlang-sdk:///lib/_engine/engine/scene_builder.dart 458:53 | pop
file:///b/s/w/ir/x/w/rc/flutter/packages/flutter/lib/src/rendering/layer.dart 1520:13 | addToScene
file:///b/s/w/ir/x/w/rc/flutter/packages/flutter/lib/src/rendering/layer.dart 721:5 | _addToSceneWithRetainedRendering
file:///b/s/w/ir/x/w/rc/flutter/packages/flutter/lib/src/rendering/layer.dart 1519:5 | addToScene
file:///b/s/w/ir/x/w/rc/flutter/packages/flutter/lib/src/rendering/layer.dart 721:5 | _addToSceneWithRetainedRendering
```

---

### Migrate in-comment links of the flutter/engine repository to the flutter/flutter repository (#166790)
- **Author**: Tong Mu
- **Date**: 2025-04-10
- **Link**: https://github.com/flutter/flutter/commit/97b5264fcc2c662c173b7386281031fdd83abf20

This PR migrates almost all in-comment links that points to the main
branch of flutter/engine repository to the flutter/flutter repository,
ensuring that such links are always up to date.

I've manually verified that all links are valid. There are a few cases
where the migration is not so trivial and I had to look up for the
updated location or line number, but I'm pretty sure the new value is
correct.

The only place that I don't know how to migrate is two links in
[Upgrading-pre-1.12-Android-projects.md](https://github.com/flutter/flutter/blob/master/docs/platforms/android/Upgrading-pre-1.12-Android-projects.md)
pointing to
`https://github.com/flutter/engine/blob/main/shell/platform/android/io/flutter/app/FlutterActivity.java`,
which I guess no longer exists.

There are still many links that point to a specific branch or revision
of the engine repo. I don't think we need to migrate these links, since
they're probably not meant to be kept up to date.

---

### SliverEnsureSemantics (#165589)
- **Author**: Renzo Olivares
- **Date**: 2025-04-08
- **Link**: https://github.com/flutter/flutter/commit/3fa9b387052363e413b906da08c1b1d2d4140dfb

Currently when using a `CustomScrollView`, screen readers cannot list or
move focus to elements that are outside the current Viewport and cache
extent because we do not create semantic nodes for these elements.

This change introduces `SliverEnsureSemantics` which ensures its sliver
child is included in the semantics tree, whether or not it is currently
visible on the screen or within the cache extent. This way screen
readers are aware the elements are there and can navigate to them /
create accessibility traversal menus with this information.
* Under the hood a new flag has been added to `RenderSliver` called
`ensureSemantics`. `RenderViewportBase` uses this in its
`visitChildrenForSemantics` to ensure a sliver is visited when creating
the semantics tree. Previously a sliver was not visited if it was not
visible or within the cache extent. `RenderViewportBase` also uses this
in `describeSemanticsClip` and `describeApproximatePaintClip` to ensure
a sliver child that wants to "ensure semantics" is not clipped out if it
is not currently visible in the viewport or outside the cache extent.
* `RenderSliverMultiBoxAdaptor.semanticBounds` now leverages its first
child as an anchor for assistive technologies to be able to reach it if
the Sliver is a child of `SliverEnsureSemantics`. If not it will still
be dropped from the semantics tree.
* `RenderProxySliver` now considers child overrides of `semanticBounds`.

On the engine side we move from using a joystick method to scroll with
`SemanticsAction.scrollUp` and `SemanticsAction.scrollDown` to using
`SemanticsAction.scrollToOffset` completely letting the browser drive
the scrolling with its current dom scroll position "scrollTop" or
"scrollLeft". This is possible by calculating the total quantity of
content under the scrollable and sizing the scroll element based on
that.

<details open><summary>Code sample</summary>

```dart
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Flutter code sample for [SliverEnsureSemantics].

void main() => runApp(const SliverEnsureSemanticsExampleApp());

class SliverEnsureSemanticsExampleApp extends StatelessWidget {
  const SliverEnsureSemanticsExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: SliverEnsureSemanticsExample());
  }
}

class SliverEnsureSemanticsExample extends StatefulWidget {
  const SliverEnsureSemanticsExample({super.key});

  @override
  State<SliverEnsureSemanticsExample> createState() =>
      _SliverEnsureSemanticsExampleState();
}

class _SliverEnsureSemanticsExampleState
    extends State<SliverEnsureSemanticsExample> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.inversePrimary,
        title: const Text('SliverEnsureSemantics Demo'),
      ),
      body: Center(
        child: CustomScrollView(
          semanticChildCount: 106,
          slivers: <Widget>[
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 0,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Semantics(
                            header: true,
                            headingLevel: 3,
                            child: Text(
                              'Steps to reproduce',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                          const Text('Issue description'),
                          Semantics(
                            header: true,
                            headingLevel: 3,
                            child: Text(
                              'Expected Results',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                          Semantics(
                            header: true,
                            headingLevel: 3,
                            child: Text(
                              'Actual Results',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                          Semantics(
                            header: true,
                            headingLevel: 3,
                            child: Text(
                              'Code Sample',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                          Semantics(
                            header: true,
                            headingLevel: 3,
                            child: Text(
                              'Screenshots',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                          Semantics(
                            header: true,
                            headingLevel: 3,
                            child: Text(
                              'Logs',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverFixedExtentList(
              itemExtent: 44.0,
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) {
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text('Item $index'),
                    ),
                  );
                },
                childCount: 50,
                semanticIndexOffset: 1,
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 51,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Semantics(
                        header: true,
                        child: const Text('Footer 1'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 52,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Semantics(
                        header: true,
                        child: const Text('Footer 2'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 53,
                  child: Semantics(link: true, child: const Text('Link #1')),
                ),
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 54,
                  child: OverflowBar(
                    children: <Widget>[
                      TextButton(
                        onPressed: () {},
                        child: const Text('Button 1'),
                      ),
                      TextButton(
                        onPressed: () {},
                        child: const Text('Button 2'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 55,
                  child: Semantics(link: true, child: const Text('Link #2')),
                ),
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverSemanticsList(
                sliver: SliverFixedExtentList(
                  itemExtent: 44.0,
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      return Semantics(
                        role: SemanticsRole.listItem,
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text('Second List Item $index'),
                          ),
                        ),
                      );
                    },
                    childCount: 50,
                    semanticIndexOffset: 56,
                  ),
                ),
              ),
            ),
            SliverEnsureSemantics(
              sliver: SliverToBoxAdapter(
                child: IndexedSemantics(
                  index: 107,
                  child: Semantics(link: true, child: const Text('Link #3')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// A sliver that assigns the role of SemanticsRole.list to its sliver child.
class SliverSemanticsList extends SingleChildRenderObjectWidget {
  const SliverSemanticsList({super.key, required Widget sliver})
    : super(child: sliver);

  @override
  RenderSliverSemanticsList createRenderObject(BuildContext context) =>
      RenderSliverSemanticsList();
}

class RenderSliverSemanticsList extends RenderProxySliver {
  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.role = SemanticsRole.list;
  }
}
```
</details>

Fixes: #160217

---

