import logging

from psycopg.types.json import Jsonb
from psycopg_pool import AsyncConnectionPool

from . import config

__all__ = ["pool", "open_pool", "close_pool", "Jsonb"]

logger = logging.getLogger("backuptrace.db")

pool: AsyncConnectionPool = AsyncConnectionPool(
    conninfo=config.DATABASE_URL,
    min_size=1,
    max_size=10,
    open=False,
    kwargs={"autocommit": True},
)


async def open_pool() -> None:
    await pool.open(wait=True, timeout=30)
    logger.info("Database connection pool opened")


async def close_pool() -> None:
    await pool.close()
    logger.info("Database connection pool closed")
