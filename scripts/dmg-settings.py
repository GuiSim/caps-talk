from pathlib import Path

root = Path(defines["project_dir"])
format = "UDZO"
filesystem = "HFS+"
files = [str(root / "dist/CapsTalk.app"), str(root / "dist/Start Here.pdf")]
symlinks = {"Applications": "/Applications"}
icon = str(root / "Resources/CapsTalk.icns")
background = str(root / "dist/installer-background.png")
window_rect = ((200, 200), (660, 500))
default_view = "icon-view"
show_status_bar = False
show_toolbar = False
show_sidebar = False
show_pathbar = False
show_tab_view = False
show_icon_preview = False
icon_size = 112
text_size = 14
icon_locations = {
    "CapsTalk.app": (170, 205),
    "Applications": (490, 205),
    "Start Here.pdf": (330, 392),
}
