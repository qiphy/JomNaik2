-- Anonymous, short-lived operational reports used by route ranking.
create table if not exists public.anonymous_incident_reports (
  id uuid primary key default gen_random_uuid(),
  station_id text not null,
  station_name text not null,
  station_lat double precision not null check (station_lat between -90 and 90),
  station_lon double precision not null check (station_lon between -180 and 180),
  report_type text not null,
  target_type text not null check (target_type in ('bus', 'station')),
  service_route text,
  reported_at timestamptz not null default now()
);

alter table public.anonymous_incident_reports enable row level security;
grant insert on public.anonymous_incident_reports to authenticated;

drop policy if exists "Authenticated users can add anonymous incident reports"
on public.anonymous_incident_reports;

create policy "Authenticated users can add anonymous incident reports"
on public.anonymous_incident_reports
for insert
to authenticated
with check (true);

-- No client read policy: FastAPI reads recent rows through its service-role key.
