#!/usr/bin/env bash
# Fluid - the fluid plugin's one entry point. Its commands and its
# hook call this file and nothing else; it hands over to the installer that
# ships beside it, or to the script that installer put in ~/.fluid.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp="$HOME/.fluid/fluid.sh"

installed() {
    [[ -x "$cp" ]] && return 0
    echo "Fluid is not installed. Run /fluid:install"
    return 1
}

case "${1:-}" in
    install)
        # The plugin carries the StopFailure hook, so settings.json does not need it too
        FLUID_HOOK=plugin exec bash "$root/install-fluid.sh" install
        ;;
    uninstall)
        exec bash "$root/install-fluid.sh" uninstall
        ;;
    status)
        installed && exec "$cp" status
        ;;
    anchor)
        # Only what the anchor accepts gets through to it
        if [[ -n "${2:-}" && ! "$2" =~ ^(([01][0-9]|2[0-3]):[0-5][0-9]|off)$ ]]; then
            echo "Usage: /fluid:anchor [HH:MM|off]"
            exit 2
        fi
        installed && exec "$cp" anchor ${2:+"$2"}
        ;;
    rate-limit)
        # The hook: a no-op until Fluid is installed
        [[ -x "$cp" ]] && exec "$cp" rate-limit claude
        cat >/dev/null
        ;;
    *)
        echo "Usage: $0 {install|uninstall|status|anchor [HH:MM|off]|rate-limit}" >&2
        exit 2
        ;;
esac
exit 0
