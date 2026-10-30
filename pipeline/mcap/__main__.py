"""`python -m mcap <command>` entry point (run from PROJECT_DIR/pipeline)."""
import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
