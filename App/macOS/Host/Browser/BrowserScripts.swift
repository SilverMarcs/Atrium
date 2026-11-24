import Foundation

/// The JavaScript an agent's browser runs. Reading the page and finding
/// elements run in Atrium's own content world, so the page can't see or
/// change the element references they keep; the console and network hooks
/// run in the page's world, where its errors and requests happen.
nonisolated enum BrowserScripts {
    static let consoleHandler = "atriumConsole"
    static let networkHandler = "atriumNetwork"

    /// Notes when the page last changed, so actions can wait for it to settle.
    /// Runs in Atrium's world at document start.
    static let changes = """
        globalThis.__atriumChanged = Date.now();
        new MutationObserver(() => { globalThis.__atriumChanged = Date.now(); })
          .observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        """

    /// Milliseconds since the page last changed.
    static let quietFor = "return Date.now() - (globalThis.__atriumChanged || 0);"

    /// Outlines the page as roles and names, one element per line, giving
    /// each element an agent can act on a reference such as `e12`. Takes
    /// `maxLength` and `viewportOnly`; returns `{outline, truncated, above, below}`.
    static let snapshot = """
        const refs = new Map();
        globalThis.__atriumRefs = refs;
        const lines = [];
        let length = 0, truncated = false, nextRef = 1, above = 0, below = 0;

        const clean = (text, max = 100) => {
          const t = (typeof text === 'string' ? text : '').replace(/\\s+/g, ' ').trim();
          return t.length > max ? t.slice(0, max - 1) + '…' : t;
        };
        const quote = (text) => JSON.stringify(text);
        const emit = (depth, line) => {
          if (truncated) return;
          const text = '  '.repeat(depth) + '- ' + line;
          if (length + text.length > maxLength) { truncated = true; return; }
          length += text.length + 1;
          lines.push(text);
        };
        // Text beside other content merges into one line per run.
        let lastText = null;
        const emitText = (depth, text) => {
          if (!text || truncated) return;
          if (lastText && lastText.depth === depth && lastText.index === lines.length - 1) {
            const merged = clean(lastText.text + ' ' + text, 300);
            length += merged.length - lastText.text.length;
            lines[lastText.index] = '  '.repeat(depth) + '- text: ' + merged;
            lastText.text = merged;
            return;
          }
          emit(depth, 'text: ' + clean(text, 300));
          if (!truncated) lastText = { depth, index: lines.length - 1, text: clean(text, 300) };
        };

        // Where an element is against the visible part of the page: -1 above or left, 1 below or right, 0 on screen.
        const place = (el) => {
          const r = el.getBoundingClientRect();
          const win = el.ownerDocument.defaultView;
          if (r.bottom <= 0 || r.right <= 0) return -1;
          if (r.top >= win.innerHeight || r.left >= win.innerWidth) return 1;
          return 0;
        };

        const inputRole = (el) => {
          switch ((el.getAttribute('type') || 'text').toLowerCase()) {
            case 'hidden': return null;
            case 'button': case 'submit': case 'reset': case 'image': return 'button';
            case 'file': return 'filechooser';
            case 'checkbox': return el.getAttribute('switch') !== null ? 'switch' : 'checkbox';
            case 'radio': return 'radio';
            case 'range': return 'slider';
            case 'number': return 'spinbutton';
            case 'search': return 'searchbox';
            default: return el.list ? 'combobox' : 'textbox';
          }
        };
        const implicitRole = (el) => {
          switch (el.localName) {
            case 'a': case 'area': return el.hasAttribute('href') ? 'link' : null;
            case 'button': case 'summary': return 'button';
            case 'input': return inputRole(el);
            case 'textarea': return 'textbox';
            case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
            case 'option': return 'option';
            case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
            case 'img': return el.getAttribute('alt') === '' ? null : 'img';
            case 'nav': return 'navigation';
            case 'main': return 'main';
            case 'header': return el.closest('article, aside, main, nav, section') ? null : 'banner';
            case 'footer': return el.closest('article, aside, main, nav, section') ? null : 'contentinfo';
            case 'aside': return 'complementary';
            case 'form': return 'form';
            case 'dialog': return 'dialog';
            case 'ul': case 'ol': return 'list';
            case 'li': return 'listitem';
            case 'table': return 'table';
            case 'tr': return 'row';
            case 'th': return 'columnheader';
            case 'td': return 'cell';
            case 'iframe': return 'iframe';
            case 'canvas': return 'canvas';
            case 'video': return 'video';
            default: return el.isContentEditable && !el.parentElement?.isContentEditable ? 'textbox' : null;
          }
        };
        const actionable = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'switch', 'combobox', 'filechooser',
          'listbox', 'option', 'slider', 'spinbutton', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'treeitem', 'canvas', 'video']);
        // Roles whose name is their text, so their children aren't listed again.
        const namedByContent = new Set(['link', 'button', 'heading', 'tab', 'menuitem', 'menuitemcheckbox',
          'menuitemradio', 'option', 'treeitem', 'cell', 'columnheader', 'listitem', 'clickable', 'switch', 'checkbox', 'radio']);
        const interactiveSelector = 'a[href], button, input, select, textarea, [role=button], [role=link], [contenteditable=""], [contenteditable=true], [tabindex]:not([tabindex="-1"])';
        const leafRoles = new Set(['textbox', 'searchbox', 'combobox', 'img', 'slider', 'spinbutton', 'filechooser', 'canvas', 'video']);

        const name = (el, role) => {
          const labelledBy = el.getAttribute('aria-labelledby');
          if (labelledBy) {
            const text = labelledBy.split(/\\s+/).map(id => el.ownerDocument.getElementById(id)?.textContent || '').join(' ');
            if (clean(text)) return clean(text);
          }
          const label = el.getAttribute('aria-label');
          if (clean(label)) return clean(label);
          if (el.localName === 'img' || (el.localName === 'input' && el.type === 'image')) return clean(el.getAttribute('alt') || el.getAttribute('title'));
          if (['input', 'textarea', 'select'].includes(el.localName)) {
            // A label wrapping its control names it by its own text, not the control's.
            const labels = [...(el.labels || [])].map(l => [...l.childNodes]
              .filter(n => n !== el && !(n.nodeType === Node.ELEMENT_NODE && n.contains(el))).map(n => n.textContent).join(' ')).join(' ');
            if (clean(labels)) return clean(labels);
            if (['button', 'submit', 'reset'].includes(el.type)) return clean(el.value || el.type);
            return clean(el.getAttribute('placeholder') || el.getAttribute('title'));
          }
          if (role === 'iframe') return clean(el.getAttribute('title') || el.getAttribute('src'));
          if (namedByContent.has(role) && !el.querySelector(interactiveSelector)) return clean(el.innerText || el.textContent);
          return clean(el.getAttribute('title'));
        };

        const states = (el, role) => {
          const out = [];
          if (role === 'heading') out.push('level=' + (el.getAttribute('aria-level') || el.localName.slice(1)));
          const checked = el.getAttribute('aria-checked') ?? (['checkbox', 'radio', 'switch'].includes(role) && el.localName === 'input' ? String(el.checked) : null);
          if (checked === 'true') out.push('checked'); else if (checked === 'mixed') out.push('mixed');
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') out.push('disabled');
          const expanded = el.getAttribute('aria-expanded');
          if (expanded) out.push('expanded=' + expanded);
          if (el.getAttribute('aria-selected') === 'true' || (el.localName === 'option' && el.selected)) out.push('selected');
          if (el.getAttribute('aria-current') && el.getAttribute('aria-current') !== 'false') out.push('current');
          if (el.getAttribute('aria-invalid') === 'true' || (el.willValidate && el.validity && !el.validity.valid && el.matches(':user-invalid'))) out.push('invalid');
          if (el.required || el.getAttribute('aria-required') === 'true') out.push('required');
          if (el === el.ownerDocument.activeElement && el.localName !== 'body') out.push('focused');
          if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider'].includes(role)) {
            if (el.localName === 'select') {
              out.push('value=' + quote(clean([...el.selectedOptions].map(o => o.text).join(', '))));
            } else if (el.type === 'password') {
              if (el.value) out.push('value=' + quote('•'.repeat(Math.min(el.value.length, 8))));
            } else {
              const value = el.isContentEditable ? el.innerText : el.value;
              if (value) out.push('value=' + quote(clean(value, 200)));
            }
          }
          if (role === 'filechooser' && el.files?.length) out.push('files=' + quote([...el.files].map(f => f.name).join(', ')));
          if (role === 'link') {
            const href = el.getAttribute('href') || '';
            if (href && !href.startsWith('javascript:')) out.push('href=' + quote(clean(href, 120)));
          }
          return out;
        };

        const isHidden = (el) => {
          if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return true;
          if (el.checkVisibility) return !el.checkVisibility({ visibilityProperty: true });
          return getComputedStyle(el).display === 'none';
        };
        const skipped = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'svg', 'audio', 'br', 'hr']);

        const children = (node) => {
          if (node.localName === 'slot') return node.assignedNodes({ flatten: true });
          if (node.shadowRoot) return node.shadowRoot.childNodes;
          return node.childNodes;
        };

        // A label's text already names its control, so only its elements are listed.
        const walk = (node, depth, skipText = false) => {
          for (const child of children(node)) {
            if (truncated) return;
            if (child.nodeType === Node.TEXT_NODE) {
              if (skipText) continue;
              if (viewportOnly && child.parentElement && place(child.parentElement) !== 0) continue;
              emitText(depth, clean(child.textContent, 300));
              continue;
            }
            if (child.nodeType !== Node.ELEMENT_NODE) continue;
            const el = child;
            if (skipped.has(el.localName) && !(el.localName === 'svg' && el.getAttribute('aria-label'))) continue;
            if (isHidden(el)) continue;
            let role = el.getAttribute('role')?.split(' ')[0] || implicitRole(el);
            if (role === 'presentation' || role === 'none') role = null;
            if (el.localName === 'svg') role = 'img';
            // Page code often makes plain elements clickable; a pointer
            // cursor that starts on this element shows it.
            if (!role && el.localName !== 'label' && getComputedStyle(el).cursor === 'pointer'
                && (!el.parentElement || getComputedStyle(el.parentElement).cursor !== 'pointer')) role = 'clickable';
            if (!role) { walk(el, depth, skipText || (el.localName === 'label' && !!el.control)); continue; }

            const label = name(el, role);
            const isActionable = actionable.has(role) || role === 'clickable' || role === 'iframe';
            const leaf = (namedByContent.has(role) && label && !el.querySelector(interactiveSelector))
              || leafRoles.has(role) || el.localName === 'select';
            if (viewportOnly && (leaf || isActionable)) {
              const where = place(el);
              if (where !== 0) {
                if (isActionable) { if (where < 0) above++; else below++; }
                if (leaf) continue;
              }
            }
            let line = role + (label ? ' ' + quote(label) : '');
            const extra = states(el, role);
            if (isActionable) {
              const ref = 'e' + nextRef++;
              refs.set(ref, el);
              extra.push('ref=' + ref);
            }
            if (extra.length) line += ' [' + extra.join('] [') + ']';
            if (role === 'iframe') {
              let doc = null;
              try { doc = el.contentDocument; } catch {}
              emit(depth, line + (doc ? '' : ' (another site; not readable)'));
              if (doc?.body) walk(doc.body, depth + 1);
              continue;
            }
            emit(depth, line);
            if (leaf || truncated) continue;
            const index = lines.length - 1;
            walk(el, depth + 1);
            // A layout container with nothing in it says nothing.
            if (lines.length - 1 === index && !label && !extra.length) {
              length -= lines.pop().length + 1;
              lastText = null;
            }
          }
        };

        walk(document.body || document.documentElement, 0);
        return { outline: lines.join('\\n'), truncated, above, below };
        """

    /// Finds the element by `ref` from the latest snapshot or a CSS
    /// `selector`, scrolls it into view, and returns where it is in the
    /// visible page: `{x, y, width, height, covered, tag, type, editable}`.
    static let locate = """
        let el;
        if (ref) {
          el = globalThis.__atriumRefs?.get(ref);
          if (!el) throw new Error(`No element ${ref} on this page: take a new snapshot.`);
          if (!el.isConnected) throw new Error(`${ref} is no longer on the page: take a new snapshot.`);
        } else {
          el = document.querySelector(selector);
          if (!el) throw new Error(`Nothing matches ${selector}.`);
        }
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        // Elements in a same-site frame are placed by their frame too.
        let r = el.getBoundingClientRect(), x = r.left, y = r.top;
        for (let win = el.ownerDocument.defaultView; win && win !== window && win.frameElement; win = win.parent) {
          const f = win.frameElement.getBoundingClientRect();
          x += f.left; y += f.top;
        }
        let covered = null;
        if (r.width && r.height) {
          const top = el.ownerDocument.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          if (top && top !== el && !el.contains(top) && !top.contains(el)) {
            covered = '<' + top.localName + (top.id ? '#' + top.id : '') + (top.className && typeof top.className === 'string' ? '.' + top.className.trim().split(/\\s+/).slice(0, 2).join('.') : '') + '>';
          }
        }
        return { x, y, width: r.width, height: r.height, covered, tag: el.localName, type: el.type || '',
                 editable: el.isContentEditable || (['input', 'textarea'].includes(el.localName) && !['checkbox', 'radio', 'file', 'submit', 'button', 'range'].includes(el.type)) };
        """

    /// What clicks and keys can't do well: choosing `<select>` options,
    /// selecting a field's text before it's replaced, opening a hidden file
    /// chooser, hovering and dragging by page events. Takes `action`, the
    /// element by `ref` or `selector`, `values`, and for drag `to` by
    /// `toRef` or `toSelector`. Returns a note or null.
    static let helper = """
        const find = (r, s) => {
          const el = r ? globalThis.__atriumRefs?.get(r) : (s ? document.querySelector(s) : null);
          if (!el && (r || s)) throw new Error(`No element ${r || s}: take a new snapshot.`);
          return el;
        };
        const el = find(ref, selector);
        const view = (t) => t.ownerDocument.defaultView;
        const center = (t) => { const r = t.getBoundingClientRect(); return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }; };
        const fire = (t, type, init) => {
          const Ctor = type.startsWith('pointer') ? view(t).PointerEvent : type.startsWith('drag') || type === 'drop' ? view(t).DragEvent : view(t).MouseEvent;
          t.dispatchEvent(new Ctor(type, { bubbles: !type.endsWith('enter') && !type.endsWith('leave'), cancelable: true, composed: true,
            view: view(t), pointerId: 1, pointerType: 'mouse', isPrimary: true, ...init }));
        };
        switch (action) {
        case 'select': {
          if (el.localName !== 'select') throw new Error('select works on a <select>; click a custom dropdown open, then click its option.');
          const wanted = values.map(String);
          const options = [...el.options];
          const missing = wanted.filter(w => !options.some(o => o.value === w || o.text.trim() === w));
          if (missing.length) throw new Error('No option ' + missing.map(m => JSON.stringify(m)).join(', ') + '. Options: ' + options.map(o => JSON.stringify(o.text.trim())).join(', '));
          el.focus();
          for (const o of options) o.selected = wanted.includes(o.value) || wanted.includes(o.text.trim());
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return null;
        }
        case 'selectText': {
          if (el.select) el.select(); else el.ownerDocument.getSelection().selectAllChildren(el);
          return null;
        }
        case 'openFileChooser': {
          const input = el.localName === 'input' && el.type === 'file' ? el : el.querySelector('input[type=file]');
          if (!input) return 'none';
          input.click();
          return 'opened';
        }
        case 'contextmenu': {
          const at = center(el);
          fire(el, 'pointerdown', { ...at, button: 2, buttons: 2 });
          fire(el, 'mousedown', { ...at, button: 2, buttons: 2 });
          fire(el, 'pointerup', { ...at, button: 2 });
          fire(el, 'mouseup', { ...at, button: 2 });
          fire(el, 'contextmenu', { ...at, button: 2 });
          return null;
        }
        case 'caretToEnd': {
          if (el.setSelectionRange && typeof el.value === 'string') { try { el.setSelectionRange(el.value.length, el.value.length); } catch {} }
          else if (el.isContentEditable) { const s = el.ownerDocument.getSelection(); s.selectAllChildren(el); s.collapseToEnd(); }
          return null;
        }
        case 'hover': {
          const at = center(el);
          for (const type of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove']) fire(el, type, at);
          return null;
        }
        case 'drag': {
          const target = find(toRef, toSelector);
          const from = center(el), to = center(target);
          const data = new DataTransfer();
          fire(el, 'pointerdown', { ...from, buttons: 1 });
          fire(el, 'mousedown', { ...from, buttons: 1 });
          fire(el, 'dragstart', { ...from, dataTransfer: data });
          const steps = 8;
          for (let i = 1; i <= steps; i++) {
            const at = { clientX: from.clientX + (to.clientX - from.clientX) * i / steps, clientY: from.clientY + (to.clientY - from.clientY) * i / steps, buttons: 1 };
            const over = el.ownerDocument.elementFromPoint(at.clientX, at.clientY) || target;
            fire(over, 'pointermove', at);
            fire(over, 'mousemove', at);
            fire(over, 'dragover', { ...at, dataTransfer: data });
          }
          fire(target, 'dragenter', { ...to, dataTransfer: data });
          fire(target, 'dragover', { ...to, dataTransfer: data });
          fire(target, 'drop', { ...to, dataTransfer: data });
          fire(el, 'dragend', { ...to, dataTransfer: data });
          fire(target, 'pointerup', to);
          fire(target, 'mouseup', to);
          return null;
        }
        }
        throw new Error(`Unknown action ${action}.`);
        """

    /// Whether the page meets what an agent waits for. Takes `text`,
    /// `textGone`, `selector` and `selectorGone`; returns true once all hold.
    static let check = """
        const body = document.body?.innerText || '';
        const visible = (s) => [...document.querySelectorAll(s)].some(e => e.checkVisibility ? e.checkVisibility() : e.offsetParent !== null);
        if (text && !body.includes(text)) return false;
        if (textGone && body.includes(textGone)) return false;
        if (selector && !visible(selector)) return false;
        if (selectorGone && visible(selectorGone)) return false;
        return true;
        """

    /// Tells Atrium about everything the page logs, its uncaught errors,
    /// what it fetches and what fails to load. Runs in the page's world.
    static let page = """
        (() => {
          // Every frame runs this, so request IDs carry the frame's own prefix.
          const frame = Math.random().toString(36).slice(2, 8);
          let next = 0;
          const nextID = (kind) => frame + '-' + kind + (++next);
          const post = (handler, message) => { try { window.webkit.messageHandlers[handler].postMessage(message); } catch {} };
          const describe = (parts) => parts.map(p => {
            if (typeof p === 'string') return p;
            if (p instanceof Error) return p.stack || String(p);
            try { return JSON.stringify(p); } catch { return String(p); }
          }).join(' ').slice(0, 2000);
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[level];
            console[level] = function (...parts) {
              post('\(consoleHandler)', { level: level === 'warn' ? 'warning' : level, text: describe(parts) });
              return original.apply(this, parts);
            };
          }
          addEventListener('error', e => {
            const t = e.target;
            if (t && t !== window && (t.src || t.href)) {
              post('\(networkHandler)', { phase: 'end', id: nextID('res'), method: 'GET', url: t.src || t.href, kind: t.localName, status: 0, error: 'failed to load' });
            } else {
              post('\(consoleHandler)', { level: 'error', text: (e.error?.stack || e.message) + (e.filename ? ` (${e.filename}:${e.lineno})` : '') });
            }
          }, true);
          addEventListener('unhandledrejection', e => post('\(consoleHandler)', { level: 'error', text: 'Unhandled rejection: ' + (e.reason?.stack || e.reason) }));

          const textual = (type) => !type || /json|text|xml|javascript|graphql|x-www-form-urlencoded/.test(type);
          const bodyText = (body) => {
            if (body == null) return null;
            if (typeof body === 'string') return body.slice(0, 4000);
            if (body instanceof URLSearchParams) return body.toString().slice(0, 4000);
            if (body instanceof FormData) return [...body.entries()].map(([k, v]) => k + '=' + (typeof v === 'string' ? v : '[file ' + v.name + ']')).join('&').slice(0, 4000);
            return '[' + (body.constructor?.name || 'binary') + ']';
          };
          const originalFetch = window.fetch;
          window.fetch = async function (input, init) {
            const id = nextID('f');
            const request = input instanceof Request ? input : null;
            const method = (init?.method || request?.method || 'GET').toUpperCase();
            const url = new URL(request ? request.url : String(input), location.href).href;
            const started = performance.now();
            post('\(networkHandler)', { phase: 'start', id, method, url, kind: 'fetch', requestBody: bodyText(init?.body) });
            try {
              const response = await originalFetch.apply(this, arguments);
              const type = response.headers.get('content-type') || '';
              let responseBody = null;
              if (textual(type)) { try { responseBody = (await response.clone().text()).slice(0, 8000); } catch {} }
              post('\(networkHandler)', { phase: 'end', id, method, url, kind: 'fetch', status: response.status, type,
                duration: Math.round(performance.now() - started), responseBody });
              return response;
            } catch (error) {
              post('\(networkHandler)', { phase: 'end', id, method, url, kind: 'fetch', status: 0, error: String(error), duration: Math.round(performance.now() - started) });
              throw error;
            }
          };
          const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (method, url) {
            this.__atrium = { id: nextID('x'), method: String(method).toUpperCase(), url: new URL(url, location.href).href };
            return open.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function (body) {
            const info = this.__atrium;
            if (info) {
              const started = performance.now();
              post('\(networkHandler)', { phase: 'start', ...info, kind: 'xhr', requestBody: bodyText(body) });
              this.addEventListener('loadend', () => {
                const type = this.getResponseHeader('content-type') || '';
                let responseBody = null;
                if (textual(type) && (this.responseType === '' || this.responseType === 'text')) responseBody = String(this.responseText).slice(0, 8000);
                post('\(networkHandler)', { phase: 'end', ...info, kind: 'xhr', status: this.status, type,
                  duration: Math.round(performance.now() - started), responseBody, error: this.status === 0 ? 'network error' : null });
              });
            }
            return send.apply(this, arguments);
          };
          // Other loads, such as scripts, styles and images, that answered with an error.
          try {
            new PerformanceObserver(list => {
              for (const entry of list.getEntries()) {
                if (entry.initiatorType === 'fetch' || entry.initiatorType === 'xmlhttprequest') continue;
                if (entry.responseStatus >= 400) {
                  post('\(networkHandler)', { phase: 'end', id: nextID('r'), method: 'GET', url: entry.name, kind: entry.initiatorType, status: entry.responseStatus,
                    duration: Math.round(entry.duration) });
                }
              }
            }).observe({ type: 'resource', buffered: true });
          } catch {}
        })();
        """
}
