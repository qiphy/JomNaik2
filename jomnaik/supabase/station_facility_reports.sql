-- Anonymous station facility reports read and written only by the FastAPI service.
create table if not exists public.station_facility_reports (
  id uuid primary key default gen_random_uuid(),
  station_id text not null,
  station_name text not null,
  station_lat double precision not null check (station_lat between -90 and 90),
  station_lon double precision not null check (station_lon between -180 and 180),
  facility_type text not null check (facility_type in ('lift', 'escalator', 'toilet', 'ticket_machine', 'entrance', 'lighting', 'other')),
  issue_type text not null check (issue_type in ('out_of_service', 'blocked', 'damaged', 'unclean', 'other')),
  comment text check (comment is null or char_length(comment) <= 2000),
  reported_at timestamptz not null default now()
);

create index if not exists station_facility_reports_station_time_idx
  on public.station_facility_reports (station_id, reported_at desc);
create index if not exists station_facility_reports_time_idx
  on public.station_facility_reports (reported_at desc);

alter table public.station_facility_reports enable row level security;
grant insert, select on public.station_facility_reports to service_role;
-- Clients never access this table directly; FastAPI uses the service-role key.
