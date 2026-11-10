import os
import sys

# The plugin's launcher (skills/km/bin/km) tells a km that started from a uv that could not set up
# its Python by this empty file being gone. Popped first, so no command km runs inherits it; a km
# that cannot remove it runs nothing, so the launcher's fallback never runs a command twice.
if pending := os.environ.pop("KM_PENDING_FILE", None):
    try:
        if os.path.getsize(pending):
            raise OSError("the file is not empty")    # never delete what the launcher did not create
        os.remove(pending)
    except OSError as e:
        sys.exit(f"km: cannot remove KM_PENDING_FILE {pending} ({e}); unset that variable")

from km.cli import main  # noqa: E402

sys.exit(main())
