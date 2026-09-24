# Keyboard shortcuts

`config/keyboard_shortcuts.json` is the source for application command bindings
and the server-rendered `?` reference. Use `KeyboardEvent.key` names; `Mod` means
Command or Control. Printable symbols use their actual character, such as `?`.

Page controllers register a named scope in `connect()` using `registerShortcuts`
and release it in `disconnect()`. They dispatch semantic command IDs returned by
`commandFor(scope, event)`, not literal keys. The registration follows Stimulus
mount/unmount, including Turbo replacements, rather than the current URL.

The layout's Stimulus dispatcher handles keyboard events in two phases:

- Capture: the global help command and an active exclusive surface (presentation
  mode). The presenter retains control-specific behavior and layered Escape.
- Bubble: ordinary page commands, after focused widgets can prevent the event.
  These ignore text entry, composition, and open overlays. A scope may explicitly
  allow its own popovers through `overlays`, as comment navigation does.

Dialogs always block page commands. The help uses `showModal()` for native focus
containment, Escape, and focus restoration. Global help remains available above
other surfaces, except while typing. Only the first page handler that prevents
the event handles it; co-mounted scopes should not bind conflicting commands.

Focused widgets use `local: true` scopes and call `commandFor` from their existing
local Stimulus action or widget handler. They are never globally registered.
`native: true` entries document browser behavior without intercepting it.

Not every keystroke is an application command: ProseMirror owns its editing
keymap, diagram pan/zoom owns its canvas controls, and the voice controller owns
its press/hold/release gesture. Voice help comes from the user's actual setting;
voice checks the same overlay policy before recording. Keep these local rather
than routing text editing or gesture state through a page-wide command bus.

When adding a command, add its binding and description to the catalog, implement
the semantic command in the owning controller, and test the interaction in its
scope. Navigation system specs cover catalog remapping, Turbo replacement,
composition, focus, widget precedence, and presentation isolation. Request specs
assert that help and runtime receive the same catalog.
