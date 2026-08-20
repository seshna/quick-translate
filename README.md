# Quick Translate for Omarchy

A fast, keyboard-first translation overlay for [Omarchy](https://omarchy.org/).
It starts with English → Japanese, remembers your selected language pair, and
keeps text only for the current Omarchy Shell session.

![Quick Translate overlay preview](preview.png)

## Install

Install from a public Git repository:

    omarchy plugin add https://github.com/seshna/quick-translate.git --enable

The overlay can then be opened from a terminal:

    omarchy-shell shell toggle shaun.quick-translate '{}'

It also adds a translate icon to the right side of the Omarchy bar. Open the
overlay and select the gear icon to hide that bar button or change shortcuts.

To add the suggested Super+Shift+T binding, add this to
~/.config/hypr/bindings.lua and reload Hyprland:

    o.bind("SUPER + SHIFT + T", "Quick Translate",
      "omarchy-shell shell toggle shaun.quick-translate '{}'")

If you already use that shortcut, choose another binding or unbind the existing
one first.

## Remove

Disable and remove the plugin with:

    omarchy plugin remove shaun.quick-translate

## Features

- Searchable, explicit From and To language selectors
- Multiline input and read-only translated output
- English → Japanese by default; selected languages save immediately
- Copy translation, or copy source and translation together
- Clear both text boxes and undo the clear
- A matching Omarchy bar launcher that can be hidden from Setup
- Reconfigurable action shortcuts, recorded directly from the keyboard
- Optional shortcut hints on the main page, and `Ctrl+?` to open Setup
- Up to 5,000 input characters.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+Enter | Translate (configurable) |
| Ctrl+U | Swap languages and both text boxes (configurable) |
| Ctrl+Y | Copy the translation (configurable) |
| Ctrl+Shift+Y | Copy source, two newlines, then translation (configurable) |
| Ctrl+Shift+K | Clear both text boxes (configurable) |
| Ctrl+Z | Undo the most recent Clear (configurable) |
| Ctrl+? | Open Setup |
| Escape | Close the overlay |


## Privacy and network use

Translation requests use Google’s unofficial no-key endpoint, the same endpoint
used by [GTT](https://github.com/eeeXun/gtt). The endpoint may change, rate
limit, or become unavailable without notice. Entered text is sent to Google in
an HTTPS request body, so do not use this plugin for sensitive content.

Only the language pair is persisted under the XDG state directory, normally:

    ~/.local/state/omarchy/quick-translate/preferences.json

The preferences file is written atomically with permissions 0600. Source and
translated text are never written to disk by the plugin.

## Requirements

- Omarchy / Omarchy Shell with third-party plugin support
- Python 3 (standard library only)
- wl-copy from wl-clipboard for clipboard actions
- Internet access for translation

## Development

Validate the manifest and run the test suite from the plugin directory:

    omarchy plugin validate .
    python3 -m unittest discover -s tests -v

To reload a local edit while Omarchy Shell is running:

    omarchy-shell shell rescanPlugins

## License

MIT. See [LICENSE](LICENSE).
