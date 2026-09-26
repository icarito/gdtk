import subprocess


def can_build(env, platform):
    if platform not in ("frt", "x11"):
        return False
    try:
        return subprocess.call(["pkg-config", "--exists", "wlroots-0.20"]) == 0
    except OSError:
        return False


def configure(env):
    pass
