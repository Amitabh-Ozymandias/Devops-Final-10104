import os


class Settings:
    """Runtime configuration read from environment variables."""

    database_url: str = os.getenv(
        "DATABASE_URL",
        "postgresql+psycopg2://spendwise:spendwise@localhost:5432/spendwise",
    )
    app_name: str = os.getenv("APP_NAME", "SpendWise API")
    app_version: str = os.getenv("APP_VERSION", "dev")
    cors_origins: list[str] = [
        origin.strip()
        for origin in os.getenv("CORS_ORIGINS", "http://localhost:3000,http://localhost:5173").split(",")
        if origin.strip()
    ]


settings = Settings()
