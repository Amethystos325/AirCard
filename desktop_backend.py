"""PyInstaller entry point; stdout is exclusively the application protocol."""
import multiprocessing
import sys

if __name__ == "__main__":
    multiprocessing.freeze_support()
    if len(sys.argv) > 1 and sys.argv[1] == "--native-worker":
        from aircard_desktop.worker import main
        raise SystemExit(main(sys.argv[2:]))
    from aircard_desktop.service import main
    main()
