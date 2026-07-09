import logging
import logging.handlers
from pathlib import Path

from app.config import settings

LOG_DIR = Path(__file__).resolve().parent.parent.parent / "logs"


def configure_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    formatter = logging.Formatter(
        "%(asctime)s %(levelname)-8s %(name)s: %(message)s"
    )

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)

    file_handler = logging.handlers.RotatingFileHandler(
        LOG_DIR / "bridge.log", maxBytes=5_000_000, backupCount=5
    )
    file_handler.setFormatter(formatter)

    root = logging.getLogger()
    root.setLevel(settings.log_level)
    root.addHandler(console_handler)
    root.addHandler(file_handler)
