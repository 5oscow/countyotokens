# dmgbuild settings for the release disk image. Scripts/build_app.sh --dmg passes:
#   -D app=<count yo tokens.app> -D icon=<AppIcon.icns> -D background=<background.png, @2x beside it>
# dmgbuild writes the window's layout itself, so building needs no Finder scripting.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
name = os.path.basename(app)

format = "ULFO"  # LZFSE: small, opens on macOS 10.11 and later
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# The tally logo in place of the plain disk icon, on the desktop and in the sidebar.
icon = defines["icon"]  # noqa: F821

# Scripts/make_dmg_background.swift draws the background for this exact window.
background = defines["background"]  # noqa: F821
# Finder counts its 28-point title bar in the height, so the picture gets the full 600 × 340.
window_rect = ((200, 160), (600, 368))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {name: (150, 160), "Applications": (450, 160)}
