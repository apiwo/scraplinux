# ScrapLinux-specific environment.

# Wayland-first defaults. Applications that can pick a backend pick Wayland.
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM="wayland;xcb"
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export GDK_BACKEND=wayland,x11
export CLUTTER_BACKEND=wayland
export ELECTRON_OZONE_PLATFORM_HINT=auto

# mandoc is the manual reader.
export MANPAGER=${MANPAGER:-less}
