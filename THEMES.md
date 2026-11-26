# Making an EasyBoard theme

A theme is a folder with a `theme.xml` in it, plus any pictures, fonts, icons and QML files it uses.
Themes live in the `themes` folder inside EasyBoard's config folder:

| System  | Themes folder |
|---------|---------------|
| Linux   | `~/.config/easyboard/themes/` |
| Windows | `%LOCALAPPDATA%\EasyBoard\themes\` |
| macOS   | `~/Library/Application Support/com.MrRedstonia.EasyBoard/themes/` |

The Themes page links to the folder ("themes folder" in the text at the top).

**Installing a theme**
* Click **+** on the Themes page (or drop the file onto the page) and choose a `.zip` file. The zip
  holds `theme.xml` either at the top or inside one folder. The theme is unpacked into the themes
  folder; a theme with the same folder name is replaced.
* Or copy the theme's folder into the themes folder yourself. It shows up the next time you open the
  Themes page.

**While a theme is in use**, Settings > Appearance turns off "App follows system theme", "Tint the app
with the accent color" and "Use a picture as the background": the theme decides those. Pick **Default**
on the Themes page to go back to EasyBoard's own look.

**Built-in themes** (Kitty, Liquid Glass, Starry Night) carry a `.builtin` file. EasyBoard rewrites them
when it is updated. To change one, copy its folder under a new name and edit the copy (or delete the
`.builtin` file, so EasyBoard leaves that folder alone from then on).

> Only install themes from people you trust: a theme's QML files run JavaScript inside EasyBoard.

---

## theme.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<theme name="Ocean" author="Your name" version="1.0" description="Shown when you hover the theme."
       thumbnail="thumbnail.png">

  <!-- dark="true" for a dark theme (text, borders and shading follow it) -->
  <colors dark="true" accent="#3fb6ff" window="#0b1a2a" text="#e6f3ff" ... />

  <font family="Nunito" file="fonts/Nunito.ttf" size="14"/>

  <background color="#0b1a2a" image="waves.jpg" mode="behind" blur="0.2" opacity="1" brightness="0.8"/>

  <sidebar position="left" width="50" expandedWidth="190" radius="12" iconSize="26"/>
  <layout radius="18"/>
  <animations speed="1"/>

  <tiles radius="18" glyph="♥" glyphSize="56" glyphOpacity="0.35"/>
  <tilecolor name="red" primary="#FC3232" secondary="#F25959"/>

  <icon name="home" file="icons/home.svg"/>
  <hide element="board.stop"/>
  <order area="sidebar" items="toggle, board, library, studio, routing, |, themes, settings"/>
  <element slot="background" file="Waves.qml"/>
</theme>
```

Everything except `<theme name="...">` is optional; what a theme leaves out keeps EasyBoard's normal look.
File paths are relative to the theme folder and can't point outside it.

### `<theme>`
| Attribute     | Meaning |
|---------------|---------|
| `name`        | Name on the Themes page. |
| `author`      | Shown under the name. |
| `version`     | Your own version number. |
| `description` | Shown when you hover the theme. |
| `thumbnail`   | A picture for the theme's card on the Themes page (about 480×240, shown with rounded corners). Without it, a small sketch of the app is drawn from the theme's colors. `preview` works too. |

### `<colors>`
Colors are `#rrggbb`, or `#aarrggbb` with transparency in front (`#80ffffff` = half-transparent white).

| Attribute         | Used for |
|-------------------|----------|
| `dark`            | `true` / `false`: the theme is dark or light. |
| `accent`          | Selected things, highlighted buttons, sliders, links. |
| `highlightedText` | Text on the accent color. |
| `window`          | Base color of the window, cards and pop-ups. |
| `background`      | The window's own background (defaults to `window`). |
| `text`            | All text and icons. |
| `base`            | Text fields and lists. |
| `button`          | Qt's button color (used by a few built-in controls). |
| `control`         | Fill of EasyBoard's buttons and drop-downs (slightly lighter on hover, darker when pressed). |
| `controlBorder`   | Border of buttons, drop-downs and the Colors button. |
| `border`          | Other borders: tiles, the big boxes and the menus. |
| `selection`       | The row under the mouse in drop-down menus (default: the accent); with `<controls glass="true">` also the fill of highlighted buttons. |
| `menu`            | Background of drop-down menus (see-through over glass in a glass theme). |
| `glyph`           | Color of icons and small glyphs that would otherwise use the text color (undo / redo, speaker, `+`, `✕`, the crop handles' ridges, …). |
| `sidebar`         | The sidebar. |
| `panel`           | The add / edit sound panel. |
| `board`           | The big boxes on the Soundboard, App routing and Themes pages. |
| `tooltip`         | Tooltips. |

### `<font>`
| Attribute | Meaning |
|-----------|---------|
| `file`    | A `.ttf` / `.otf` file in the theme, used for the whole app. |
| `family`  | A font installed on the computer (used when there is no `file`). |
| `size`    | Base text size in pixels. Titles and some labels keep their own sizes. |

Check a font's license before you share it in a theme.

### `<background>`
| Attribute    | Meaning |
|--------------|---------|
| `color`      | Background color (same as `background` in `<colors>`). |
| `image`      | A picture. |
| `mode`       | `board`: only inside the Soundboard's box ("In soundboard section only"). `behind` (default, "In the background"): behind the pages; the sidebar, panel and every control (buttons, fields, switches, sliders, …) stay solid. `all` ("Behind UI elements"): also behind the sidebar, panel, controls, menus and pop-ups (give them see-through colors in `<colors>`). |
| `blur`       | 0 to 1. |
| `opacity`    | 0 to 1. |
| `brightness` | 0 to 2 (1 = unchanged). |
| `textShadow` | `true`: a small shadow under all text, for reading on top of a busy background. |

### `<glass>` – clear or frosted glass
Puts real frosted glass under the sidebar, the add / edit panel, the big boxes and the drop-down menus:
they blur (and slightly magnify) whatever is behind them. Give those surfaces see-through colors in
`<colors>` (`sidebar`, `panel`, `board`), and a background with some detail to blur (`mode="all"`).

| Attribute    | Meaning |
|--------------|---------|
| `blur`       | 0 to 1 (default 0.8). |
| `tint`       | Frost color laid over the blur (default `#26ffffff`). |
| `rim`        | The glossy edge (default `#80ffffff`). |
| `highlight`  | Light along the top and the inner edge (default `#33ffffff`). |
| `shade`      | Shade towards the bottom (default none). |
| `saturation` | −1 to 1: more (or less) colorful behind the glass (default 0.3). |
| `brightness` | −1 to 1 (default 0). |
| `lens`       | 1 to 1.5: magnifies what's behind, like thick glass (default 1 = off). |
| `refraction` | 0 to 60: a band this many pixels wide along the edge bends what's behind, like light through the rim of a lens (default 0). With `blur="0"` and a transparent `tint` this gives *clear* glass, like Apple's "Clear" Liquid Glass: no blur, no frost, no border line. |
| `edgeScale`  | 0.5 to 1: how strongly the edge bends (smaller pulls in more from just outside; default 0.85). |
| `edgeBrightness` / `edgeSaturation` | −1 to 1: the bent edge a little brighter / more colorful (defaults 0.08 / 0.5). |

With `<glass>` the scroll bars and tooltips are glass too (a theme's own `tooltip` part wins), and
focused / open controls get no highlight border.

Glass costs a little GPU time per surface; it's made to be cheap, but keep animated backgrounds simple.

### `<sidebar>`
| Attribute       | Meaning |
|-----------------|---------|
| `position`      | `left`, `right`, or `bottom`: no sidebar, but a floating dock along the bottom (the pages in one round pill, the expand button as its own round button beside it). |
| `width`         | Width when collapsed, 40 to 120 (default 50). |
| `expandedWidth` | Width when expanded, 120 to 400 (default 190). |
| `radius`        | Corner radius of the sidebar buttons, 0 to 20. |
| `iconSize`      | Icon size, 12 to 36 (default 26). |
| `iconColor`     | Color of the sidebar / dock icons (default: the text color). |
| `activeColor`   | Fill behind the open page's button (default: the accent). |
| `hoverColor`    | Fill under the mouse. |
| `hoverScale`    | 1 to 1.5: buttons grow this much under the mouse (default 1). |
| `tooltips`      | `false`: no tooltips on the sidebar / dock buttons. |
| `labels`        | `false`: never show page names next to the icons; the sidebar / dock always stays collapsed. (Hiding `sidebar.toggle` does the same.) |
| `slide`         | `true` (dock): one circle marks the open page and slides over, stretching like a drop of liquid, when you open another. |

### `<layout>`
| Attribute | Meaning |
|-----------|---------|
| `radius`  | Corner radius of the big boxes (Soundboard, App routing, Themes). |
| `search`  | `center`: the Soundboard's search field sits in the middle of the header. |
| `pageWidth` | Width of the Sound editor and App routing pages: `full`, or a maximum in pixels (default 920). |
| `pageAlign` | `left` (default) or `center`: where those pages sit when they're narrower than the window. |
| `boardButtons` | `dock`: with `<sidebar position="bottom">`, Loop / Stop become two round glyph buttons in the bottom-left corner, next to the dock. |

### `<controls>`
| Attribute | Meaning |
|-----------|---------|
| `radius`  | Corner radius of buttons, drop-downs, text fields and the small square buttons; `999` makes them fully round. |
| `glass`   | `true`: frosted glass (`<glass>`) under every button, drop-down and field too, not only the big surfaces. |
| `hoverScale` | 1 to 1.2: controls grow this much under the mouse. |
| `pressScale` | 0.8 to 1: controls sink to this size while pressed. |
| `tooltips` | `false`: no tooltips on small icon buttons (App routing's `+` and `✕`). |
| `menuAnimation` | `true`: menus open like a drop of liquid (they fall open from the top, stretch a touch past their size and spring back, while fading in) and fade out. |

### `<depth>` – a raised, 3D look
| Attribute | Meaning |
|-----------|---------|
| `shadow`  | 0 to 1: soft shadows under tiles, boxes, menus, buttons, fields and the dock. |
| `sheen`   | 0 to 1: light on top of them (bright at the top, fading down) with a thin bright inner edge. |
| `waveShadow` | 0 to 1: a drop shadow under the lines of the sound editor's waveform (for light backgrounds). |

### `<animations>`
| Attribute | Meaning |
|-----------|---------|
| `speed`   | 1 = normal, 2 = twice as fast, 0.5 = half as fast, 0 = no animation. Applies to EasyBoard's own transitions (like the sidebar) and is available to your QML as `Window.window.animSpeed`. |

### `<tiles>` and `<tilecolor>` – sound tiles
`<tiles>` sets how every sound tile looks:

| Attribute      | Meaning |
|----------------|---------|
| `radius`       | Corner radius of the tiles (default 18). |
| `glyph`        | Text shown on a sound without a picture (default `♪`); any character or emoji. |
| `glyphFile`    | A picture (SVG, PNG, …) to show instead of the text glyph. |
| `glyphSize`    | Size of the glyph in pixels (default 56). |
| `glyphOpacity` | 0 to 1 (default 0.35). |
| `uniform`      | `true`: every tile looks like a tile without a color (`<tilecolor name="default">`), whatever color the sound has. |
| `glass`        | `true`: glass (`<glass>`) under every tile too. |
| `align`        | `left` (default) or `center`: where the columns of tiles sit in the Soundboard's box. |
| `width`        | Tile width in pixels, up to 360 (default 190); the height follows. |
| `pictures`     | `false`: no picture square on the tiles, just the name (shorter tiles). |
| `ids`          | `false`: never show the sound IDs on the tiles, whatever the setting says. |
| `hoverScale`   | 1 to 1.3: tiles grow this much under the mouse. |
| `editButton`   | `false`: no pencil on hover (right-click still edits). |
| `selectButton` | `false`: the round select button doesn't appear on plain hover (it still shows while you're selecting). |

`<tilecolor>` restyles one of the tile colors you can pick for a sound (one element per color). The sound
keeps its color; the theme only decides how that color looks.

| Attribute   | Meaning |
|-------------|---------|
| `name`      | `default` (sounds without a color), `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`, `magenta`, `pink`, `lightgreen`, `lightblue`. |
| `primary`   | The tile itself. Also used for the color's dot in the editor and in the Colors filter. |
| `secondary` | The square behind the picture / glyph. |
| `text`      | The sound's name and glyph. |
| `progress`  | The playing progress bar. |
| `label`     | The pill behind the sound's name. |
| `chip`      | The small pills on the picture (ID, loop, hotkey). |

```xml
<tilecolor name="red" primary="#FC3232" secondary="#F25959" text="#ffffff"/>
<tilecolor name="default" primary="#33ffffff" secondary="#22ffffff"/>
```

### `<order>` – reorganize
`<order area="..." items="a, b, c"/>` puts the items of an area in your order. Items you leave out
keep their usual order after yours (hide them with `<hide>` instead).

| Area           | Items (default order) |
|----------------|-----------------------|
| `sidebar`      | `@top, toggle, board, studio, library, routing, themes, \|, @bottom, settings` |
| `boardHeader`  | `title, search, colors, sort` |
| `boardButtons` | `loop, stop, \|` |

`|` is a stretchy gap: in the sidebar everything after it sits at the bottom; under the board,
`|, stop, loop` moves the buttons to the right. `@top` and `@bottom` are where your `sidebarTop` and
`sidebarBottom` elements go.

### `<replace>` – draw your own version of a part
`<replace part="..." file="Something.qml"/>` draws your QML file instead of one of EasyBoard's parts.
EasyBoard gives your file the values in the last column (declare them as properties to use them).

| Part               | What it replaces | Your file gets |
|--------------------|------------------|----------------|
| `spinner`          | The loading circle (Sound library: playing, reverting) | – (it is only shown while loading) |
| `downloadProgress` | The download bar in the Sound library | `property real progress` (0 to 1) |
| `soundId`          | The ID pill on the Soundboard's tiles (set its own `implicitWidth` / `implicitHeight`) | `property string text` |
| `tileGlyph`        | The glyph on sounds without a picture | `property color color`, `property bool playing` |
| `tileProgress`     | The playing progress bar under a tile | `property real progress`, `property color color` |
| `tooltip`          | Every tooltip in the app (set its own `implicitWidth` / `implicitHeight`; it draws the whole tooltip, text included) | `property string text` |

```qml
// a progress bar made of dots
import QtQuick
Row {
    property real progress: 0
    property color color: "white"
    spacing: 3
    Repeater {
        model: 12
        Rectangle { width: 5; height: 5; radius: 2.5; color: (index + 1) / 12 <= progress ? parent.color : "#33ffffff" }
    }
}
```

### `<icon>` – replace an icon
`<icon name="..." file="..."/>`, one per icon. SVGs that draw with `currentColor` are recolored to
match the text (and to stay readable on a highlighted button); other pictures are shown as they are.

Icon names: `home`, `studio`, `library`, `routing`, `themes`, `settings`, `chevron` (the sidebar arrow),
`speaker`, `muted`, `undo`, `redo`, `backspace`, `braceopen`, `braceclose`, `revert`, `tray`.

### `<hide>` – hide parts of the app
`<hide element="..."/>`, one per element:

| Element            | What it hides |
|--------------------|---------------|
| `sidebar.toggle`   | The arrow that expands the sidebar. |
| `sidebar.board`, `sidebar.studio`, `sidebar.library`, `sidebar.routing`, `sidebar.themes`, `sidebar.settings` | A page's sidebar button. (Hiding `sidebar.themes` leaves no way back to the Themes page except editing the config.) |
| `board.title`      | The "Soundboard" title. |
| `board.search`     | The search field. |
| `board.colors`     | The color filter. |
| `board.sort`       | The sort menu. |
| `board.loop`       | The "Loop Sounds" button. |
| `board.stop`       | The "Stop All Sounds" button. |
| `editor.color`     | The Color choice in the add / edit sound panel (useful with `<tiles uniform="true">`). |

### `<element>` – add your own elements (QML and JavaScript)
`<element slot="..." file="Something.qml"/>` loads a QML file into one of these places:

| Slot              | Where |
|-------------------|-------|
| `background`      | Fills the window, behind everything (animated skies, patterns, …). |
| `overlay`         | Fills the window, above everything. It can't be clicked, so it never gets in the way. |
| `sidebarTop`      | At the top of the sidebar, as wide as the sidebar. |
| `sidebarBottom`   | At the bottom of the sidebar, above Settings. |
| `boardBackground` | Inside the Soundboard's box, behind the sounds. |

A slot can have several elements. Performance: a `Canvas` is drawn by the CPU, so don't repaint a large one every frame (draw it once, or only
when its size changes); move, scale and fade ordinary items instead, which the GPU does for free. Elements
pause while the window is hidden or minimized, and `boardBackground` elements while another page is open.

Each file is an ordinary QML component: animations (`NumberAnimation`,
`SequentialAnimation`, …), `Canvas`, `Image`, `Timer`, effects (`import QtQuick.Effects`) and JavaScript
all work. Give elements in the sidebar slots an `implicitHeight`.

Inside your QML:
* `Qt.resolvedUrl("star.png")` and plain relative paths find files next to the QML file.
* `Window.window.theme` is your theme as EasyBoard read it (`.colors`, `.background`, `.dir`, …).
* `Window.window.isDark`, `Window.window.animSpeed`, `Window.window.page` (`"board"`, `"studio"`,
  `"library"`, `"routing"`, `"themes"`, `"settings"`) and `palette` (the theme's colors) are available.
* JavaScript can sit in the QML file, or in a `.js` file you import: `import "helpers.js" as Helpers`.

Example – a slowly pulsing glow in the corner:

```qml
import QtQuick

Item {
    Rectangle {
        width: 300; height: 300; radius: 150
        x: parent.width - 200; y: -120
        color: Window.window.theme.colors.accent
        SequentialAnimation on opacity {
            loops: Animation.Infinite
            NumberAnimation { from: 0.10; to: 0.30; duration: 3000 }
            NumberAnimation { from: 0.30; to: 0.10; duration: 3000 }
        }
    }
}
```

## Sharing a theme
Zip the theme's folder (so the zip contains `My Theme/theme.xml`, `My Theme/...`) and share the zip.
Others add it with **+** on the Themes page.

## Look at the built-in themes
The built-in themes in the themes folder are complete examples:
* *Starry Night*: an animated background, a replaced icon and its own tile colors.
* *Kitty*: replaced icons, pastel tile colors and a cat glyph, a heart `spinner` and `soundId`, a
  background and a `boardBackground` pattern.
* *Liquid Glass*: nearly everything at once: clear `<glass>` with `refraction`, a dock
  (`<sidebar position="bottom">` with `slide`), glass controls and tiles, `<depth>`, `<layout>` and
  `<tiles>` options, reordering, hidden elements, a `soundId` part and a melting animated background.
* *OLED*: the smallest possible theme: `<colors>`, one `<tilecolor>` and a few `<hide>`s.
