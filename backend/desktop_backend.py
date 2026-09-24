"""PyInstaller entry point; stdout is exclusively the application protocol."""
import multiprocessing
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

if __name__ == "__main__":
    multiprocessing.freeze_support()
    if len(sys.argv) > 1 and sys.argv[1] == "--native-worker":
        from backend.aircard_desktop.worker import main
        raise SystemExit(main(sys.argv[2:]))
    from backend.aircard_desktop.service import main
    main()
