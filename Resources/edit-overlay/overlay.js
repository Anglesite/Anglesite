"use strict";
(() => {
  // src/selector.ts
  var MAX_TEXT_HINT = 80;
  function elementInfoFor(element) {
    return {
      ...leafInfoFor(element),
      ancestors: collectAncestors(element)
    };
  }
  function leafInfoFor(el) {
    const info = {
      tag: el.tagName,
      classes: classesOf(el),
      nthChild: positionAmongSiblings(el)
    };
    if (el.id) info.id = el.id;
    const dataAnglesiteId = el.getAttribute("data-anglesite-id");
    if (dataAnglesiteId) info.dataAnglesiteId = dataAnglesiteId;
    const dataTestId = el.getAttribute("data-testid");
    if (dataTestId) info.dataTestId = dataTestId;
    const role = el.getAttribute("role");
    if (role) info.role = role;
    const ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel) info.ariaLabel = ariaLabel;
    const text = condenseText(el.textContent ?? "");
    if (text) info.textContent = text;
    return info;
  }
  function ancestorInfoFor(el) {
    const info = {
      tag: el.tagName,
      nthChild: positionAmongSiblings(el)
    };
    if (el.id) info.id = el.id;
    const classes = classesOf(el);
    if (classes.length > 0) info.classes = classes;
    const role = el.getAttribute("role");
    if (role) info.role = role;
    const ariaLabel = el.getAttribute("aria-label");
    if (ariaLabel) info.ariaLabel = ariaLabel;
    return info;
  }
  function collectAncestors(element) {
    const chain = [];
    let cur = element.parentElement;
    while (cur && cur.tagName !== "HTML") {
      chain.push(cur);
      cur = cur.parentElement;
    }
    return chain.reverse().map(ancestorInfoFor);
  }
  function classesOf(el) {
    return Array.from(el.classList);
  }
  function positionAmongSiblings(el) {
    if (!el.parentElement) return 1;
    return Array.from(el.parentElement.children).indexOf(el) + 1;
  }
  function condenseText(raw) {
    const normalized = raw.replace(/\s+/g, " ").trim();
    if (normalized.length <= MAX_TEXT_HINT) return normalized;
    return normalized.slice(0, MAX_TEXT_HINT) + "\u2026";
  }

  // src/messages.ts
  var editCounter = 0;
  function nextEditID() {
    editCounter += 1;
    return `e-${Date.now().toString(36)}-${editCounter}`;
  }
  function postEdit(message, win = window) {
    const handler = win.webkit?.messageHandlers?.anglesite;
    if (!handler) return false;
    handler.postMessage(message);
    return true;
  }
  function postPlacementPick(message, win = window) {
    const handler = win.webkit?.messageHandlers?.anglesite;
    if (!handler) return false;
    handler.postMessage(message);
    return true;
  }
  function postGoalElementPick(message, win = window) {
    const handler = win.webkit?.messageHandlers?.anglesite;
    if (!handler) return false;
    handler.postMessage(message);
    return true;
  }
  function installReplyHandler(win = window) {
    const pending = /* @__PURE__ */ new Map();
    win.anglesite = win.anglesite ?? {};
    win.anglesite._handleReply = (reply) => {
      const handler = pending.get(reply.id);
      if (!handler) return;
      pending.delete(reply.id);
      handler(reply);
    };
    return {
      awaitReply: (id, handler) => {
        pending.set(id, handler);
      }
    };
  }

  // src/toast.ts
  var TOAST_CLASS = "anglesite-toast";
  function showToast(text, durationMs = 4e3) {
    ensureStyles();
    const el = document.createElement("div");
    el.className = TOAST_CLASS;
    el.textContent = text;
    const existing = document.querySelectorAll(`.${TOAST_CLASS}`).length;
    el.style.bottom = `${16 + existing * 56}px`;
    document.body.appendChild(el);
    setTimeout(() => {
      el.remove();
    }, durationMs);
  }
  var stylesInstalled = false;
  function ensureStyles() {
    if (stylesInstalled) return;
    stylesInstalled = true;
    const style = document.createElement("style");
    style.setAttribute("data-anglesite-toast", "");
    style.textContent = `
.${TOAST_CLASS} {
  position: fixed;
  right: 16px;
  bottom: 16px;
  max-width: 360px;
  padding: 10px 14px;
  background: rgba(20, 20, 24, 0.92);
  color: #fff;
  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
  z-index: 2147483647;
  pointer-events: none;
}
`;
    document.head.appendChild(style);
  }

  // src/visible-elements.ts
  var MAX_ELEMENTS = 50;
  var MAX_TEXT = 120;
  var SCROLL_DEBOUNCE_MS = 200;
  var MUTATION_DEBOUNCE_MS = 500;
  var RESIZE_DEBOUNCE_MS = 200;
  var INSTALLED_FLAG = "__anglesiteVisibleElementsInstalled";
  function categoryOf(el) {
    const tag = el.tagName;
    if (/^H[1-6]$/.test(tag)) return 0;
    if (tag === "IMG") return 1;
    if (tag === "A" && isInsideNav(el)) return 2;
    if (isInteractive(el)) return 3;
    return -1;
  }
  function isInsideNav(el) {
    let cur = el.parentElement;
    while (cur) {
      if (cur.tagName === "NAV") return true;
      if (cur.getAttribute("role") === "navigation") return true;
      cur = cur.parentElement;
    }
    return false;
  }
  var INTERACTIVE_TAGS = /* @__PURE__ */ new Set(["BUTTON", "INPUT", "SELECT", "TEXTAREA", "SUMMARY", "A"]);
  var INTERACTIVE_ROLES = /* @__PURE__ */ new Set([
    "button",
    "link",
    "checkbox",
    "radio",
    "switch",
    "menuitem",
    "tab",
    "option"
  ]);
  function isInteractive(el) {
    if (INTERACTIVE_TAGS.has(el.tagName)) return true;
    const role = el.getAttribute("role");
    if (role && INTERACTIVE_ROLES.has(role)) return true;
    return false;
  }
  var CANDIDATE_SELECTOR = "h1, h2, h3, h4, h5, h6, img, a, button, input, select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=switch], [role=menuitem], [role=tab], [role=option]";
  function findCandidates(root = document) {
    return Array.from(root.querySelectorAll(CANDIDATE_SELECTOR));
  }
  var idMap = /* @__PURE__ */ new WeakMap();
  var idCounter = 0;
  function idFor(el) {
    const fromAttr = el.getAttribute("data-anglesite-id");
    if (fromAttr) return fromAttr;
    const existing = idMap.get(el);
    if (existing) return existing;
    idCounter += 1;
    const generated = `v-${idCounter.toString(36)}`;
    idMap.set(el, generated);
    return generated;
  }
  function condenseText2(raw) {
    const normalized = raw.replace(/\s+/g, " ").trim();
    if (normalized.length <= MAX_TEXT) return normalized;
    return normalized.slice(0, MAX_TEXT - 1) + "\u2026";
  }
  function shape(el, pagePath) {
    const rect = el.getBoundingClientRect();
    const text = condenseText2(el.textContent ?? "");
    const role = el.getAttribute("role") ?? void 0;
    const isImg = el.tagName === "IMG";
    const src = isImg ? el.getAttribute("src") ?? void 0 : void 0;
    const alt = isImg ? el.getAttribute("alt") ?? void 0 : void 0;
    const ariaLabel = el.getAttribute("aria-label") ?? void 0;
    const out = {
      id: idFor(el),
      tag: el.tagName,
      selector: elementInfoFor(el),
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      pagePath
    };
    if (text) out.text = text;
    if (src) out.src = src;
    if (alt) out.alt = alt;
    if (ariaLabel) out.ariaLabel = ariaLabel;
    if (role) out.role = role;
    return out;
  }
  function collectVisibleElements(candidates, pagePath) {
    const tagged = candidates.map((el) => ({ el, cat: categoryOf(el) })).filter((x) => x.cat >= 0);
    tagged.sort((a, b) => a.cat - b.cat);
    const capped = tagged.slice(0, MAX_ELEMENTS);
    return capped.map(({ el }) => shape(el, pagePath));
  }
  function postVisibleElements(report, win = window) {
    const handler = win.webkit?.messageHandlers?.anglesite;
    if (!handler) return false;
    handler.postMessage(report);
    return true;
  }
  function installVisibleElementsReporter() {
    const win = window;
    if (win[INSTALLED_FLAG]) return;
    if (typeof IntersectionObserver === "undefined") return;
    win[INSTALLED_FLAG] = true;
    const visible = /* @__PURE__ */ new Set();
    const observed = /* @__PURE__ */ new Set();
    let lastEmittedKey = "";
    const observer = new IntersectionObserver((entries) => {
      let changed = false;
      for (const entry of entries) {
        if (entry.isIntersecting) {
          if (!visible.has(entry.target)) {
            visible.add(entry.target);
            changed = true;
          }
        } else if (visible.delete(entry.target)) {
          changed = true;
        }
      }
      if (changed) emit();
    });
    function reconcileObservations() {
      const candidates = new Set(findCandidates());
      for (const el of candidates) {
        if (!observed.has(el)) {
          observer.observe(el);
          observed.add(el);
        }
      }
      for (const el of [...observed]) {
        if (!candidates.has(el)) {
          observer.unobserve(el);
          observed.delete(el);
          visible.delete(el);
        }
      }
    }
    function emit() {
      if (visible.size === 0) return;
      const elements = collectVisibleElements(Array.from(visible), location.pathname);
      if (elements.length === 0) return;
      const key = elements.map((e) => e.id).sort().join(",");
      if (key === lastEmittedKey) return;
      lastEmittedKey = key;
      const report = { type: "anglesite:visible-elements", elements };
      postVisibleElements(report);
    }
    reconcileObservations();
    let scrollTimer;
    window.addEventListener("scroll", () => {
      if (scrollTimer !== void 0) clearTimeout(scrollTimer);
      scrollTimer = setTimeout(() => {
        scrollTimer = void 0;
        emit();
      }, SCROLL_DEBOUNCE_MS);
    }, { passive: true, capture: true });
    let resizeTimer;
    window.addEventListener("resize", () => {
      if (resizeTimer !== void 0) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        resizeTimer = void 0;
        reconcileObservations();
        emit();
      }, RESIZE_DEBOUNCE_MS);
    }, { passive: true });
    let mutationTimer;
    const mutationObserver = new MutationObserver(() => {
      if (mutationTimer !== void 0) clearTimeout(mutationTimer);
      mutationTimer = setTimeout(() => {
        mutationTimer = void 0;
        reconcileObservations();
        lastEmittedKey = "";
        emit();
      }, MUTATION_DEBOUNCE_MS);
    });
    mutationObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["src", "alt", "role", "aria-label", "data-anglesite-id"]
    });
  }

  // src/overlay.ts
  var HOVER_CLASS = "anglesite-hover";
  var GOAL_PICK_HOVER_CLASS = "anglesite-goal-pick-hover";
  var EDITABLE_CLASS = "anglesite-editing";
  var IMAGE_DROP_TARGET_CLASS = "anglesite-image-drop-target";
  var IMAGE_DROP_ACTIVE_CLASS = "anglesite-image-drop-active";
  var IMAGE_DROP_HINT_ATTRIBUTE = "data-anglesite-image-drop-hint";
  var INSTALLED_FLAG2 = "__anglesiteOverlayInstalled";
  var STYLE_TAG_MARKER = "data-anglesite-overlay";
  var EDITABLE_TAG = /^(H[1-6]|P|SPAN|A|LI|EM|STRONG|BLOCKQUOTE|FIGCAPTION|CAPTION|LABEL|DT|DD)$/;
  function isEditableText(el) {
    return EDITABLE_TAG.test(el.tagName);
  }
  function installStyles() {
    if (document.head.querySelector(`style[${STYLE_TAG_MARKER}]`)) return;
    const style = document.createElement("style");
    style.setAttribute(STYLE_TAG_MARKER, "");
    style.textContent = [
      `.${HOVER_CLASS} { outline: 2px solid rgba(0, 122, 255, 0.8); outline-offset: 2px; cursor: text; }`,
      `.${EDITABLE_CLASS} { outline: 2px solid rgba(0, 122, 255, 1); outline-offset: 2px; background: rgba(0, 122, 255, 0.05); }`,
      // Distinct color from HOVER_CLASS (blue) on purpose: goal-element pick mode can hover any
      // element, including ones that also qualify for ordinary click-to-edit hover, and the two
      // modes' feedback must stay visually distinguishable.
      `.${GOAL_PICK_HOVER_CLASS} { outline: 2px dashed rgba(255, 149, 0, 0.9); outline-offset: 2px; cursor: pointer; }`,
      // !important here (unlike HOVER_CLASS/EDITABLE_CLASS above): site stylesheets commonly reset
      // `img { outline: none }`, and the drop-target ring needs to survive that.
      `.${IMAGE_DROP_TARGET_CLASS} { outline: 3px dashed rgba(0, 122, 255, 0.9) !important; outline-offset: 4px !important; filter: brightness(0.9) !important; }`,
      `.${IMAGE_DROP_ACTIVE_CLASS} { outline-style: solid !important; filter: brightness(1.05) !important; cursor: copy; }`,
      `[${IMAGE_DROP_HINT_ATTRIBUTE}] { position: fixed; z-index: 2147483647; left: 50%; top: 16px; transform: translateX(-50%); padding: 8px 12px; border-radius: 9px; background: rgba(28, 28, 30, 0.92); color: white; font: 600 13px/1.25 -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 4px 18px rgba(0, 0, 0, 0.25); pointer-events: none; }`
    ].join("\n");
    document.head.appendChild(style);
  }
  function attachHover() {
    let hovered = null;
    document.addEventListener("mouseover", (ev) => {
      const target = ev.target;
      if (!target || target.nodeType !== 1 || !isEditableText(target)) {
        if (hovered) {
          hovered.classList.remove(HOVER_CLASS);
          hovered = null;
        }
        return;
      }
      if (hovered && hovered !== target) hovered.classList.remove(HOVER_CLASS);
      target.classList.add(HOVER_CLASS);
      hovered = target;
    });
    document.addEventListener("mouseout", (ev) => {
      const target = ev.target;
      if (target?.classList.contains(HOVER_CLASS)) target.classList.remove(HOVER_CLASS);
      if (hovered === target) hovered = null;
    });
  }
  function attachClickToEdit(awaitReply) {
    document.addEventListener("click", (ev) => {
      const target = ev.target;
      if (!target || target.nodeType !== 1 || !isEditableText(target)) return;
      if (target.isContentEditable) return;
      ev.preventDefault();
      target.classList.remove(HOVER_CLASS);
      const originalInfo = elementInfoFor(target);
      target.contentEditable = "true";
      target.classList.add(EDITABLE_CLASS);
      target.focus();
      const originalText = target.textContent ?? "";
      const finish = () => {
        target.contentEditable = "false";
        target.classList.remove(EDITABLE_CLASS);
        const newText = target.textContent ?? "";
        if (newText === originalText) return;
        const id = nextEditID();
        const msg = {
          id,
          type: "anglesite:apply-edit",
          path: location.pathname,
          selector: originalInfo,
          op: "replace-text",
          value: newText
        };
        const ok = postEdit(msg);
        if (!ok) {
          target.textContent = originalText;
          showToast("Not running inside the Anglesite app");
          return;
        }
        awaitReply(id, (reply) => {
          if (reply.status === "applied") return;
          target.textContent = originalText;
          showToast(reply.detail ?? reply.message ?? reply.reason ?? "Edit failed");
        });
      };
      target.addEventListener("blur", finish, { once: true });
    });
  }
  function installPlacementPickMode(win = window) {
    let active = false;
    const handler = (ev) => {
      if (!active) return;
      const target = ev.target;
      if (!target || target.nodeType !== 1) return;
      ev.preventDefault();
      ev.stopPropagation();
      postPlacementPick(
        {
          id: nextEditID(),
          type: "anglesite:pick-placement",
          path: location.pathname,
          selector: elementInfoFor(target)
        },
        win
      );
    };
    document.addEventListener("click", handler, { capture: true });
    const anglesiteWin = win;
    anglesiteWin.anglesite = anglesiteWin.anglesite ?? {};
    const controls = {
      enter: () => {
        active = true;
      },
      exit: () => {
        active = false;
      }
    };
    anglesiteWin.anglesite._enterPlacementMode = controls.enter;
    anglesiteWin.anglesite._exitPlacementMode = controls.exit;
    return controls;
  }
  function installGoalPickMode(win = window) {
    let active = false;
    let hovered = null;
    const clearHover = () => {
      hovered?.classList.remove(GOAL_PICK_HOVER_CLASS);
      hovered = null;
    };
    document.addEventListener("mouseover", (ev) => {
      if (!active) return;
      const target = ev.target;
      if (!target || target.nodeType !== 1) return;
      if (hovered && hovered !== target) hovered.classList.remove(GOAL_PICK_HOVER_CLASS);
      target.classList.add(GOAL_PICK_HOVER_CLASS);
      hovered = target;
    });
    document.addEventListener("mouseout", (ev) => {
      if (!active) return;
      const target = ev.target;
      if (target === hovered) clearHover();
    });
    const clickHandler = (ev) => {
      if (!active) return;
      const target = ev.target;
      if (!target || target.nodeType !== 1) return;
      ev.preventDefault();
      ev.stopPropagation();
      clearHover();
      postGoalElementPick(
        {
          id: nextEditID(),
          type: "anglesite:pick-goal-element",
          path: location.pathname,
          selector: elementInfoFor(target)
        },
        win
      );
    };
    document.addEventListener("click", clickHandler, { capture: true });
    const anglesiteGoalWin = win;
    anglesiteGoalWin.anglesite = anglesiteGoalWin.anglesite ?? {};
    const controls = {
      enter: () => {
        active = true;
      },
      exit: () => {
        active = false;
        clearHover();
      }
    };
    anglesiteGoalWin.anglesite._enterGoalPickMode = controls.enter;
    anglesiteGoalWin.anglesite._exitGoalPickMode = controls.exit;
    return controls;
  }
  function attachImageDrop(awaitReply) {
    let dragIsFile = false;
    let dragDepth = 0;
    let activeTarget = null;
    const imageTargets = () => Array.from(document.querySelectorAll("img"));
    const isFileDrag = (dataTransfer) => {
      if (!dataTransfer) return false;
      if (Array.from(dataTransfer.types).includes("Files")) return true;
      return Array.from(dataTransfer.items).some((item) => item.kind === "file");
    };
    const setActiveTarget = (target) => {
      if (activeTarget === target) return;
      activeTarget?.classList.remove(IMAGE_DROP_ACTIVE_CLASS);
      target?.classList.add(IMAGE_DROP_ACTIVE_CLASS);
      activeTarget = target;
    };
    const showTargets = () => {
      const targets = imageTargets();
      for (const target of targets) target.classList.add(IMAGE_DROP_TARGET_CLASS);
      let hint = document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`);
      if (!hint) {
        hint = document.createElement("div");
        hint.setAttribute(IMAGE_DROP_HINT_ATTRIBUTE, "");
        document.body.appendChild(hint);
      }
      hint.textContent = targets.length > 0 ? "Drop onto a highlighted image to replace it" : "Drop anywhere to add this page's first image";
    };
    const clearTargets = () => {
      setActiveTarget(null);
      for (const target of imageTargets()) target.classList.remove(IMAGE_DROP_TARGET_CLASS);
      document.querySelector(`[${IMAGE_DROP_HINT_ATTRIBUTE}]`)?.remove();
      dragIsFile = false;
      dragDepth = 0;
    };
    const imageAtEvent = (ev) => {
      const element = ev.target instanceof Element ? ev.target : null;
      return element?.closest("img");
    };
    document.addEventListener("dragenter", (ev) => {
      if (!isFileDrag(ev.dataTransfer)) return;
      const wasFileDrag = dragIsFile;
      dragIsFile = true;
      dragDepth += 1;
      if (!wasFileDrag) showTargets();
      ev.preventDefault();
    });
    document.addEventListener("dragover", (ev) => {
      if (!dragIsFile) {
        if (!isFileDrag(ev.dataTransfer)) return;
        dragIsFile = true;
        showTargets();
      }
      const target = imageAtEvent(ev);
      setActiveTarget(target);
      ev.preventDefault();
      const acceptsDrop = target !== null || imageTargets().length === 0;
      if (ev.dataTransfer) ev.dataTransfer.dropEffect = acceptsDrop ? "copy" : "none";
    });
    const replaceImage = (target, file) => {
      const savedSrc = target.src;
      const savedSrcset = target.getAttribute("srcset");
      const blobURL = URL.createObjectURL(file);
      target.src = blobURL;
      target.removeAttribute("srcset");
      const id = nextEditID();
      let settled = false;
      const revertWithToast = (text) => {
        if (settled) return;
        settled = true;
        target.src = savedSrc;
        if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
        else target.removeAttribute("srcset");
        URL.revokeObjectURL(blobURL);
        showToast(text);
      };
      const settleOnReply = (reply) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutHandle);
        if (reply.status === "applied" && reply.result) {
          target.src = reply.result.src;
          if (reply.result.srcset !== void 0) {
            target.setAttribute("srcset", reply.result.srcset);
          } else {
            target.removeAttribute("srcset");
          }
          URL.revokeObjectURL(blobURL);
        } else {
          target.src = savedSrc;
          if (savedSrcset !== null) target.setAttribute("srcset", savedSrcset);
          else target.removeAttribute("srcset");
          URL.revokeObjectURL(blobURL);
          showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image edit failed");
        }
      };
      const timeoutHandle = setTimeout(() => {
        revertWithToast("Image edit timed out");
      }, 3e4);
      awaitReply(id, settleOnReply);
      const reader = new FileReader();
      reader.onload = () => {
        const dataURL = reader.result;
        if (typeof dataURL !== "string") {
          revertWithToast("Couldn't read the dropped file");
          return;
        }
        const msg = {
          id,
          type: "anglesite:apply-edit",
          path: location.pathname,
          selector: elementInfoFor(target),
          op: "replace-image-src",
          value: { filename: file.name, mimeType: file.type, dataURL }
        };
        const ok = postEdit(msg);
        if (!ok) {
          clearTimeout(timeoutHandle);
          revertWithToast("Not running inside the Anglesite app");
        }
      };
      reader.onerror = () => revertWithToast("Couldn't read the dropped file");
      reader.readAsDataURL(file);
    };
    const insertNewImage = (file) => {
      const element = document.createElement("img");
      const blobURL = URL.createObjectURL(file);
      element.src = blobURL;
      document.body.appendChild(element);
      const id = nextEditID();
      let settled = false;
      const revertWithToast = (text) => {
        if (settled) return;
        settled = true;
        element.remove();
        URL.revokeObjectURL(blobURL);
        showToast(text);
      };
      const settleOnReply = (reply) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutHandle);
        if (reply.status === "applied" && reply.result) {
          element.src = reply.result.src;
          if (reply.result.srcset !== void 0) element.setAttribute("srcset", reply.result.srcset);
          URL.revokeObjectURL(blobURL);
        } else {
          element.remove();
          URL.revokeObjectURL(blobURL);
          showToast(reply.detail ?? reply.message ?? reply.reason ?? "Image insert failed");
        }
      };
      const timeoutHandle = setTimeout(() => {
        revertWithToast("Image insert timed out");
      }, 3e4);
      awaitReply(id, settleOnReply);
      const reader = new FileReader();
      reader.onload = () => {
        const dataURL = reader.result;
        if (typeof dataURL !== "string") {
          revertWithToast("Couldn't read the dropped file");
          return;
        }
        const msg = {
          id,
          type: "anglesite:apply-edit",
          path: location.pathname,
          op: "insert-image",
          value: { filename: file.name, mimeType: file.type, dataURL }
        };
        const ok = postEdit(msg);
        if (!ok) {
          clearTimeout(timeoutHandle);
          revertWithToast("Not running inside the Anglesite app");
        }
      };
      reader.onerror = () => revertWithToast("Couldn't read the dropped file");
      reader.readAsDataURL(file);
    };
    document.addEventListener("drop", (ev) => {
      const file = ev.dataTransfer?.files[0];
      if (!file) {
        if (dragIsFile) {
          ev.preventDefault();
          clearTargets();
          showToast("Couldn't read the dropped file");
        }
        return;
      }
      ev.preventDefault();
      const target = imageAtEvent(ev);
      const hadTargets = imageTargets().length > 0;
      const isImageFile = file.type.startsWith("image/");
      clearTargets();
      if (!target) {
        if (!hadTargets && isImageFile) {
          insertNewImage(file);
          return;
        }
        showToast(!hadTargets ? "Drop an image file anywhere to add this page's first image" : isImageFile ? "Drop onto a highlighted image to replace it" : "Drop an image file onto a highlighted image to replace it");
        return;
      }
      if (!isImageFile) {
        showToast("Choose an image file to replace this image");
        return;
      }
      replaceImage(target, file);
    });
    document.addEventListener("dragleave", () => {
      if (!dragIsFile) return;
      dragDepth = Math.max(0, dragDepth - 1);
      if (dragDepth === 0) clearTargets();
    });
    document.addEventListener("dragend", clearTargets);
  }
  function install() {
    const win = window;
    if (win[INSTALLED_FLAG2]) return;
    win[INSTALLED_FLAG2] = true;
    installStyles();
    const { awaitReply } = installReplyHandler();
    attachHover();
    attachClickToEdit(awaitReply);
    attachImageDrop(awaitReply);
    installVisibleElementsReporter();
    installPlacementPickMode(window);
    installGoalPickMode(window);
  }

  // src/component-canvas.ts
  var HARNESS_PREFIX = "/_anglesite/component/";
  var RING_CLASS = "anglesite-canvas-ring";
  var SCRUB_STYLE_ID = "anglesite-scrub";
  var INSTALLED_FLAG3 = "__anglesiteComponentCanvasInstalled";
  var REPORTED_PROPERTIES = [
    "display",
    "position",
    "width",
    "height",
    "margin-top",
    "margin-right",
    "margin-bottom",
    "margin-left",
    "padding-top",
    "padding-right",
    "padding-bottom",
    "padding-left",
    "font-family",
    "font-size",
    "font-weight",
    "line-height",
    "color",
    "background-color",
    "border-radius"
  ];
  function isHarnessPage() {
    return location.pathname.startsWith(HARNESS_PREFIX);
  }
  function sourceLoc(el) {
    let node = el;
    while (node && node !== document.body) {
      const loc = node.getAttribute("data-astro-source-loc");
      const file = node.getAttribute("data-astro-source-file");
      if (loc && file) {
        const [line, column] = loc.split(":").map(Number);
        return { file, line: line ?? 0, column: column ?? 0 };
      }
      node = node.parentElement;
    }
    return null;
  }
  function installComponentCanvas() {
    if (!isHarnessPage()) return;
    const win = window;
    if (win[INSTALLED_FLAG3]) return;
    win[INSTALLED_FLAG3] = true;
    document.addEventListener("click", onClick, true);
    window.anglesiteCanvas = {
      highlight(line, column) {
        clearRing();
        const el = findByLoc(line, column);
        if (el) drawRing(el);
      },
      clear: clearRing,
      scrub,
      clearScrub,
      dropTargetAt
    };
  }
  function containsUnsafeCssBreak(value) {
    return value.includes("{") || value.includes("}");
  }
  function scrub(selector, property, value) {
    if (containsUnsafeCssBreak(selector) || containsUnsafeCssBreak(property) || containsUnsafeCssBreak(value)) {
      return;
    }
    let style = document.getElementById(SCRUB_STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = SCRUB_STYLE_ID;
      document.head.appendChild(style);
    }
    style.textContent = `${selector} { ${property}: ${value}; }`;
  }
  function clearScrub() {
    document.getElementById(SCRUB_STYLE_ID)?.remove();
  }
  function findByLoc(line, column) {
    const candidates = Array.from(document.querySelectorAll(`[data-astro-source-loc^="${line}:"]`));
    if (candidates.length === 0) return null;
    let best = null;
    let bestColumn = Infinity;
    for (const el of candidates) {
      const loc = el.getAttribute("data-astro-source-loc") ?? "";
      const col = Number(loc.split(":")[1]);
      if (!Number.isNaN(col) && col >= column && col < bestColumn) {
        bestColumn = col;
        best = el;
      }
    }
    return best ?? candidates[0] ?? null;
  }
  function dropTargetAt(x, y) {
    const el = document.elementFromPoint(x, y);
    if (!el) return null;
    const loc = sourceLoc(el);
    if (!loc) return null;
    const rect = (sourceLocElement(el) ?? el).getBoundingClientRect();
    const relativeY = y - rect.top;
    const zone = relativeY < rect.height / 3 ? "before" : relativeY > rect.height * 2 / 3 ? "after" : "into";
    return { ...loc, zone };
  }
  function sourceLocElement(el) {
    let node = el;
    while (node && node !== document.body) {
      if (node.hasAttribute("data-astro-source-loc")) return node;
      node = node.parentElement;
    }
    return null;
  }
  function onClick(event) {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    event.preventDefault();
    event.stopPropagation();
    const loc = sourceLoc(target);
    post({
      type: "anglesite:canvas-selection",
      file: loc?.file ?? null,
      line: loc?.line ?? null,
      column: loc?.column ?? null
    });
    reportComputedStyles(target);
    clearRing();
    drawRing(target);
  }
  function reportComputedStyles(el) {
    const computed = getComputedStyle(el);
    const styles = {};
    for (const property of REPORTED_PROPERTIES) {
      styles[property] = computed.getPropertyValue(property);
    }
    post({ type: "anglesite:computed-styles", styles });
  }
  function drawRing(el) {
    const rect = el.getBoundingClientRect();
    const ring = document.createElement("div");
    ring.className = RING_CLASS;
    ring.style.cssText = `position:absolute;pointer-events:none;z-index:2147483646;border:2px solid #0a84ff;border-radius:2px;left:${rect.left + scrollX - 2}px;top:${rect.top + scrollY - 2}px;width:${rect.width}px;height:${rect.height}px;`;
    document.body.appendChild(ring);
  }
  function clearRing() {
    document.querySelectorAll(`.${RING_CLASS}`).forEach((n) => n.remove());
  }
  function post(msg) {
    window.webkit?.messageHandlers?.anglesite?.postMessage(msg);
  }

  // src/index.ts
  function boot() {
    if (isHarnessPage()) {
      installComponentCanvas();
    } else {
      install();
    }
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
  } else {
    boot();
  }
})();
