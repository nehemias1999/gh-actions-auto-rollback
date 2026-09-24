#!/usr/bin/env python3
# ==============================================================================
# Description: FastAPI application entry point with health check endpoint.
# Author: implementer
# Usage: python -m app.main
# Env Variables: PORT (default: 8080)
# Dependencies: fastapi, uvicorn, python-dotenv
# ==============================================================================
"""FastAPI application with health check endpoint for container orchestration."""

import logging
import os
import signal
import types
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from app import __version__

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan handler for startup and shutdown events.

    Args:
        app: The FastAPI application instance.

    Yields:
        None
    """
    # Startup
    port = int(os.environ.get("PORT", "8080"))
    logger.info("Starting health check service version=%s on port=%d", __version__, port)

    yield

    # Shutdown
    logger.info("Shutting down health check service version=%s", __version__)


def create_app() -> FastAPI:
    """Create and configure the FastAPI application.

    Returns:
        Configured FastAPI application instance.
    """
    app = FastAPI(
        title="Health Check Service",
        description="Health check endpoint for container orchestration",
        version=__version__,
        lifespan=lifespan,
    )

    # Register shutdown event handler for graceful shutdown
    app.router.on_shutdown.append(shutdown_event)

    @app.get("/health", response_class=JSONResponse)
    async def health_check() -> dict[str, str]:
        """Health check endpoint for container orchestration.

        Returns:
            JSON response with status "healthy".

        Example:
            >>> response = await health_check()
            >>> response
            {"status": "healthy"}
        """
        return {"status": "healthy"}

    return app


async def shutdown_event() -> None:
    """Handle graceful shutdown on SIGTERM."""
    logger.info("Received shutdown signal, stopping gracefully...")


def main() -> None:
    """Run the application with uvicorn server."""
    port = int(os.environ.get("PORT", "8080"))

    # Set up signal handlers for graceful shutdown
    def handle_sigterm(signum: int, frame: types.FrameType | None) -> None:
        logger.info("Received SIGTERM, initiating graceful shutdown...")
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, handle_sigterm)

    uvicorn.run(
        "app.main:create_app",
        host="0.0.0.0",
        port=port,
        factory=True,
        log_level="info",
    )


if __name__ == "__main__":
    main()
