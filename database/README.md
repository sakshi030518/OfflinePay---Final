# OfflinePay PostgreSQL database

The backend uses SQLAlchemy models in `backend/app/models.py`. On startup,
`backend/app/main.py` calls `Base.metadata.create_all(bind=engine)`, which
creates the required PostgreSQL tables automatically when the database user
has CREATE privileges.

## Local PostgreSQL

1. Install PostgreSQL and create a database:

   ```sql
   CREATE DATABASE offlinepay;
   ```

2. Set `DATABASE_URL` in `backend/.env`:

   ```text
   DATABASE_URL=postgresql://postgres:YOUR_PASSWORD@localhost:5432/offlinepay
   ```

3. Start the API. SQLAlchemy creates the tables at startup.

## Neon PostgreSQL

Create a Neon project/database and set `DATABASE_URL` to the Neon pooled or
non-pooled connection string. Keep the password private. The backend enables
SSL automatically when the URL contains `neon.tech`.

## Important

`create_all()` creates missing tables; it does not migrate existing tables.
For future schema changes, use Alembic migrations. This project database is a
simulated Dummy Bank ledger, not a real bank or UPI integration.
