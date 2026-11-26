# dmgbuild settings for the EasyBoard .dmg: the window that opens shows EasyBoard.app, an arrow
# and a shortcut to Applications, on background.png (background@2x.png is used on Retina screens).
# Used by packaging/macos/build-app.sh:  dmgbuild -s settings.py -D app=<EasyBoard.app> ...
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
here = defines["dir"]  # noqa: F821

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

background = os.path.join(here, "background.png")
# position on screen, then size; the background is a bit taller, so nothing else shows below it
window_rect = ((200, 140), (540, 360))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
show_icon_preview = False

icon_size = 100
text_size = 13
# icon centers, matching the arrow in background.png
icon_locations = {
    os.path.basename(app): (145, 165),
    "Applications": (395, 165),
}
