import os
from pathlib import Path
import psycopg2
from psycopg2.extras import RealDictCursor
from dotenv import load_dotenv

# Locate .env relative to this checkout, independent of OS and working directory.
load_dotenv(Path(__file__).resolve().parents[1] / ".env")

def get_connection():
    return psycopg2.connect(
        host="localhost",
        dbname="home_shopper",
        user="home_shopper",
        password=os.environ["DB_PASSWORD"],
        cursor_factory=RealDictCursor,
    )
