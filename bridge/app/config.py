from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT_ENV = Path(__file__).resolve().parent.parent.parent / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=REPO_ROOT_ENV, extra="ignore")

    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str

    bridge_host: str = "127.0.0.1"
    bridge_port: int = 8000
    log_level: str = "INFO"
    environment: str = "development"

    @property
    def dsn(self) -> str:
        return (
            f"host={self.db_host} port={self.db_port} "
            f"dbname={self.db_name} user={self.db_user} password={self.db_password}"
        )


settings = Settings()
