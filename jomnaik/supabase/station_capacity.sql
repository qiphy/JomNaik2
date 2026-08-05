-- Server-side routing capacity data. Do not grant client read access.
create table if not exists public.station_capacity (
  station_id text primary key,
  capacity integer not null check (capacity > 0),
  updated_at timestamptz not null default now()
);

alter table public.station_capacity enable row level security;

-- The FastAPI service reads this table using SUPABASE_SERVICE_ROLE_KEY.
-- Insert calibrated station capacities from operational data before enabling
-- capacity-aware ranking in production.
