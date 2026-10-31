import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import create_engine, text


DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg://app:app@db:5432/appdb",
)

engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
)


def create_tables():
    with engine.begin() as connection:
        connection.execute(
            text(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id BIGSERIAL PRIMARY KEY,
                    name VARCHAR(100) NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
        )


@asynccontextmanager
async def lifespan(app: FastAPI):
    create_tables()
    yield


app = FastAPI(
    title="DevOps Demo App",
    lifespan=lifespan,
)


Instrumentator(
    excluded_handlers=["/metrics"],
).instrument(app).expose(
    app,
    endpoint="/metrics",
    include_in_schema=False,
)


templates = Jinja2Templates(
    directory=str(Path(__file__).parent / "templates")
)


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "error": request.query_params.get("error"),
        },
    )


@app.post("/users")
def save_user(name: str = Form(...)):
    name = name.strip()

    if not name or len(name) > 100:
        return RedirectResponse(
            url="/?error=1",
            status_code=303,
        )

    with engine.begin() as connection:
        connection.execute(
            text("INSERT INTO users (name) VALUES (:name)"),
            {"name": name},
        )

    return RedirectResponse(
        url="/",
        status_code=303,
    )


@app.get("/users", response_class=HTMLResponse)
def show_users(request: Request):
    with engine.connect() as connection:
        users = (
            connection.execute(
                text(
                    """
                    SELECT id, name, created_at
                    FROM users
                    ORDER BY id
                    """
                )
            )
            .mappings()
            .all()
        )

    return templates.TemplateResponse(
        request=request,
        name="users.html",
        context={"users": users},
    )


@app.get("/health")
def health():
    with engine.connect() as connection:
        connection.execute(text("SELECT 1"))

    return {"status": "ok"}
