def can_build(env, platform):
    # inotify es Linux; el shell corre en frt (Wayland) y x11.
    return platform in ("frt", "x11")


def configure(env):
    pass
