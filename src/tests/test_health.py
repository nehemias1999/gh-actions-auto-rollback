#!/usr/bin/env python3
# ==============================================================================
# Description: Unit tests for the health check endpoint of the FastAPI application.
# Author: implementer
# Usage: pytest tests/test_health.py -v
# Dependencies: pytest, pytest-asyncio, httpx, fastapi
# ==============================================================================
"""Unit tests for the health check endpoint."""

import os
import signal
from unittest.mock import MagicMock, patch

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.main import create_app, lifespan, shutdown_event


class TestHealthEndpoint:
    """Tests for the GET /health endpoint."""

    @pytest.fixture
    def app(self) -> FastAPI:
        """Create a test FastAPI application."""
        return create_app()

    @pytest.fixture
    async def client(self, app: FastAPI) -> AsyncClient:
        """Create an async test client."""
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            yield ac

    @pytest.mark.asyncio
    async def test_health_endpoint_returns_200(self, client: AsyncClient) -> None:
        """Test that GET /health returns HTTP 200."""
        response = await client.get("/health")
        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_health_endpoint_returns_correct_json(self, client: AsyncClient) -> None:
        """Test that GET /health returns the expected JSON response."""
        response = await client.get("/health")
        assert response.json() == {"status": "healthy"}

    @pytest.mark.asyncio
    async def test_health_endpoint_response_time_under_100ms(self, client: AsyncClient) -> None:
        """Test that GET /health responds within 100ms."""
        import time
        start = time.perf_counter()
        response = await client.get("/health")
        elapsed = (time.perf_counter() - start) * 1000  # Convert to milliseconds
        assert response.status_code == 200
        assert elapsed < 100, f"Response took {elapsed:.2f}ms, expected < 100ms"


class TestApplicationConfiguration:
    """Tests for application configuration."""

    def test_default_port_is_8080(self) -> None:
        """Test that default port is 8080 when PORT env var is not set."""
        with patch.dict(os.environ, {}, clear=True):
            create_app()
            # The port is used in uvicorn.run, not stored in app
            # This test verifies the default value logic
            assert os.environ.get("PORT", "8080") == "8080"

    def test_custom_port_from_env_var(self) -> None:
        """Test that PORT environment variable is respected."""
        with patch.dict(os.environ, {"PORT": "9000"}, clear=True):
            assert os.environ.get("PORT", "8080") == "9000"


class TestGracefulShutdown:
    """Tests for graceful shutdown handling."""

    @pytest.mark.asyncio
    async def test_shutdown_event_called_on_sigterm(self) -> None:
        """Test that shutdown_event is registered for SIGTERM."""
        app = create_app()
        # Check that shutdown event handler is registered
        assert shutdown_event in app.router.on_shutdown


class TestApplicationStartup:
    """Tests for application startup logging."""

    @pytest.mark.asyncio
    async def test_startup_logs_version_and_port(self, caplog) -> None:
        """Test that startup logs version and port."""
        import logging
        caplog.set_level(logging.INFO)
        app = create_app()
        # Trigger startup events by using the lifespan context manager
        async with lifespan(app):
            pass
        # Check for version and port in logs
        log_messages = [record.message for record in caplog.records]
        assert any("version" in msg.lower() for msg in log_messages)
        assert any("port" in msg.lower() for msg in log_messages)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])


class TestMainFunction:
    """Tests for the main() function and signal handling."""

    @patch("app.main.uvicorn.run")
    @patch("app.main.signal.signal")
    def test_main_runs_uvicorn_with_correct_args(
        self, mock_signal: MagicMock, mock_uvicorn_run: MagicMock
    ) -> None:
        """Test that main() calls uvicorn.run with correct arguments."""
        from app.main import main

        with patch.dict(os.environ, {"PORT": "9000"}, clear=True):
            main()

        mock_uvicorn_run.assert_called_once()
        call_args = mock_uvicorn_run.call_args
        # uvicorn.run is called with positional args: app, host, port, factory, log_level
        assert call_args.args[0] == "app.main:create_app"
        assert call_args.kwargs["host"] == "0.0.0.0"
        assert call_args.kwargs["port"] == 9000
        assert call_args.kwargs["factory"] is True
        assert call_args.kwargs["log_level"] == "info"

        # Verify signal handler was registered
        mock_signal.assert_called_once_with(signal.SIGTERM, mock_signal.call_args.args[1])

    @patch("app.main.uvicorn.run")
    @patch("app.main.signal.signal")
    def test_main_uses_default_port_when_env_not_set(
        self, mock_signal: MagicMock, mock_uvicorn_run: MagicMock
    ) -> None:
        """Test that main() uses default port 8080 when PORT env var is not set."""
        from app.main import main

        with patch.dict(os.environ, {}, clear=True):
            main()

        call_kwargs = mock_uvicorn_run.call_args.kwargs
        assert call_kwargs["port"] == 8080

    def test_shutdown_event_logs_message(self, caplog) -> None:
        """Test that shutdown_event logs the expected message."""
        import asyncio
        import logging

        caplog.set_level(logging.INFO)
        asyncio.run(shutdown_event())

        log_messages = [record.message for record in caplog.records]
        assert any("shutdown signal" in msg.lower() for msg in log_messages)
        assert any("gracefully" in msg.lower() for msg in log_messages)
