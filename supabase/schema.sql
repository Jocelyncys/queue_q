-- =====================================================================
--  Clinic Queue  —  Supabase database setup
--  Paste this whole file into Supabase → SQL Editor → Run.
--  Then set your admin password with the line at the very bottom.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

-- One-row settings table (admin password + clinic timezone)
create table if not exists settings (
  id         int primary key default 1 check (id = 1),
  admin_hash text,
  timezone   text not null default 'Asia/Kuala_Lumpur'
);
insert into settings (id) values (1) on conflict do nothing;

-- Rooms: public information only (readable by everyone, used for realtime)
create table if not exists rooms (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  prefix              text not null default 'A',
  doctor_name         text,
  status              text not null default 'open'
                      check (status in ('open', 'paused', 'closed')),
  status_message      text,
  default_est_minutes int  not null default 10
                      check (default_est_minutes between 1 and 240),
  sort_order          int  not null default 0,
  archived            boolean not null default false,
  version             bigint not null default 0,   -- bumped on every change → realtime signal
  updated_at          timestamptz not null default now()
);

-- Room secrets: host PIN, QR token, ticket counter (never readable by browsers)
create table if not exists room_secrets (
  room_id         uuid primary key references rooms(id) on delete cascade,
  pin_hash        text not null,
  qr_token        text not null,
  failed_attempts int  not null default 0,
  locked_until    timestamptz,
  next_number     int  not null default 0,
  number_date     date
);

-- Patients: anonymous, identified by id + secret key stored on their phone
create table if not exists patients (
  id         uuid primary key default gen_random_uuid(),
  key        uuid not null default gen_random_uuid(),
  name       text not null,
  phone      text,
  created_at timestamptz not null default now()
);

-- Queue entries: one row per patient per room per day
create table if not exists queue_entries (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references rooms(id) on delete cascade,
  patient_id   uuid not null references patients(id) on delete cascade,
  queue_date   date not null,
  queue_no     int  not null,
  ticket       text not null,
  position     numeric not null,
  status       text not null default 'waiting'
               check (status in ('waiting', 'serving', 'on_hold', 'done', 'skipped', 'left')),
  est_minutes  int check (est_minutes between 1 and 240),   -- null = room default
  call_count   int not null default 0,
  joined_at    timestamptz not null default now(),
  called_at    timestamptz,
  completed_at timestamptz
);

create index if not exists queue_entries_room_idx
  on queue_entries (room_id, queue_date, status, position);
create index if not exists queue_entries_patient_idx
  on queue_entries (patient_id, queue_date);

-- Safety rules enforced by the database itself:
-- a patient has at most one active entry per room per day
create unique index if not exists one_active_entry_per_room
  on queue_entries (room_id, patient_id, queue_date)
  where status in ('waiting', 'serving', 'on_hold');
-- a room serves at most one patient at a time
create unique index if not exists one_serving_per_room
  on queue_entries (room_id, queue_date) where status = 'serving';
-- a patient is in treatment in at most one room at a time
create unique index if not exists one_serving_per_patient
  on queue_entries (patient_id, queue_date) where status = 'serving';

-- ---------------------------------------------------------------------
-- Internal helpers (not callable from the browser)
-- ---------------------------------------------------------------------

create or replace function clinic_today() returns date
language sql stable security definer set search_path = public, extensions as $$
  select (now() at time zone timezone)::date from settings where id = 1;
$$;

-- Bump room versions so every open screen refreshes
create or replace function _bump_rooms(p_room_ids uuid[]) returns void
language sql security definer set search_path = public, extensions as $$
  update rooms set version = version + 1, updated_at = now()
  where id = any(p_room_ids);
$$;

create or replace function _patient_room_ids(p_patient uuid, p_date date) returns uuid[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(distinct room_id), '{}')
  from queue_entries where patient_id = p_patient and queue_date = p_date;
$$;

-- Check a host PIN. Returns 'ok', 'bad_pin', 'locked' or 'no_room'.
-- After 10 wrong PINs the room's host page is locked for 5 minutes.
create or replace function _host_check(p_room uuid, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v room_secrets%rowtype;
begin
  select * into v from room_secrets where room_id = p_room for update;
  if not found then return 'no_room'; end if;
  if v.locked_until is not null and v.locked_until > now() then return 'locked'; end if;
  if p_pin is not null and v.pin_hash = crypt(p_pin, v.pin_hash) then
    update room_secrets set failed_attempts = 0, locked_until = null where room_id = p_room;
    return 'ok';
  end if;
  if v.failed_attempts + 1 >= 10 then
    update room_secrets set failed_attempts = 0, locked_until = now() + interval '5 minutes'
    where room_id = p_room;
  else
    update room_secrets set failed_attempts = failed_attempts + 1 where room_id = p_room;
  end if;
  return 'bad_pin';
end $$;

create or replace function _admin_ok(p_password text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select admin_hash is not null and p_password is not null
         and admin_hash = crypt(p_password, admin_hash)
  from settings where id = 1;
$$;

create or replace function _err(p_code text) returns jsonb
language sql immutable as $$ select jsonb_build_object('ok', false, 'error', p_code); $$;

-- Estimated minutes until an entry at p_position is called
-- (null p_position = someone joining at the back of the queue now)
create or replace function _est_wait(p_room uuid, p_date date, p_position numeric) returns int
language sql stable security definer set search_path = public, extensions as $$
  with r as (select default_est_minutes d from rooms where id = p_room),
  cur as (
    select greatest(0, coalesce(e.est_minutes, r.d) * 60
                       - extract(epoch from now() - e.called_at)) / 60.0 as m
    from queue_entries e, r
    where e.room_id = p_room and e.queue_date = p_date and e.status = 'serving'
  ),
  ahead as (
    select coalesce(sum(coalesce(e.est_minutes, r.d)), 0) as m
    from queue_entries e, r
    where e.room_id = p_room and e.queue_date = p_date
      and e.status in ('waiting', 'on_hold')
      and (p_position is null or e.position < p_position)
  )
  select ceil(coalesce((select m from cur), 0) + (select m from ahead))::int;
$$;

-- Put the patient's other queues back to 'waiting' after they leave a room.
-- They keep their original position, so if their turn already came up they
-- are now first in line — right after whoever is currently being served.
create or replace function _release_holds(p_patient uuid, p_date date) returns void
language sql security definer set search_path = public, extensions as $$
  update queue_entries set status = 'waiting'
  where patient_id = p_patient and queue_date = p_date and status = 'on_hold';
$$;

-- Start serving an entry (entry and patient must already be locked).
-- Returns false if the patient is in treatment in another room.
create or replace function _start_serving(p_entry uuid) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  v queue_entries%rowtype;
begin
  select * into v from queue_entries where id = p_entry;
  if exists (select 1 from queue_entries
             where patient_id = v.patient_id and queue_date = v.queue_date
               and status = 'serving' and id <> p_entry) then
    update queue_entries set status = 'on_hold' where id = p_entry;
    return false;
  end if;
  update queue_entries
     set status = 'serving', called_at = now(), call_count = call_count + 1
   where id = p_entry;
  -- hold the patient's place in every other room
  update queue_entries set status = 'on_hold'
   where patient_id = v.patient_id and queue_date = v.queue_date
     and status = 'waiting' and id <> p_entry;
  return true;
end $$;

-- Finish whoever is being served in a room ('done' or 'skipped').
-- Returns that patient's id, or null if nobody was being served.
create or replace function _finish_current(p_room uuid, p_date date, p_status text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_entry uuid; v_patient uuid;
begin
  select id, patient_id into v_entry, v_patient from queue_entries
   where room_id = p_room and queue_date = p_date and status = 'serving' for update;
  if v_entry is null then return null; end if;
  perform 1 from patients where id = v_patient for update;
  update queue_entries set status = p_status, completed_at = now() where id = v_entry;
  perform _release_holds(v_patient, p_date);
  return v_patient;
end $$;

-- Full room view for hosts (includes patient names)
create or replace function _host_view(p_room uuid) returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  with d as (select clinic_today() t),
  r as (select * from rooms where id = p_room),
  e as (
    select q.*, coalesce(q.est_minutes, r.default_est_minutes) eff_est,
           p.name pname, p.phone pphone,
           (select r2.name from queue_entries q2 join rooms r2 on r2.id = q2.room_id
             where q2.patient_id = q.patient_id and q2.queue_date = q.queue_date
               and q2.status = 'serving' and q2.room_id <> q.room_id limit 1) busy_in
    from queue_entries q join patients p on p.id = q.patient_id, r, d
    where q.room_id = p_room and q.queue_date = d.t
  )
  select jsonb_build_object(
    'ok', true,
    'room', (select to_jsonb(r) from r),
    'today', (select t from d),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'ticket', e.ticket, 'name', e.pname, 'phone', e.pphone,
        'status', e.status, 'est_minutes', e.eff_est,
        'custom_est', e.est_minutes is not null,
        'joined_at', e.joined_at, 'called_at', e.called_at,
        'completed_at', e.completed_at, 'call_count', e.call_count,
        'busy_in', e.busy_in,
        'est_wait', case when e.status in ('waiting', 'on_hold')
                         then _est_wait(p_room, e.queue_date, e.position) end
      ) order by e.position)
      from e where e.status in ('waiting', 'serving', 'on_hold', 'skipped')), '[]'::jsonb),
    'done_today', (select count(*) from e where status = 'done'),
    'avg_minutes', (select round(avg(extract(epoch from completed_at - called_at) / 60.0))
                      from e where status = 'done' and called_at is not null)
  );
$$;

-- ---------------------------------------------------------------------
-- Patient functions (called from the patient's phone)
-- ---------------------------------------------------------------------

-- Room info shown on the join page after scanning the QR code
create or replace function room_info(p_room uuid, p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_today date := clinic_today();
  r rooms%rowtype;
begin
  select * into r from rooms where id = p_room and not archived;
  if not found then return _err('room_not_found'); end if;
  if not exists (select 1 from room_secrets where room_id = p_room and qr_token = p_token) then
    return _err('invalid_qr');
  end if;
  return jsonb_build_object(
    'ok', true,
    'room', jsonb_build_object('id', r.id, 'name', r.name, 'doctor_name', r.doctor_name,
                               'status', r.status, 'status_message', r.status_message),
    'waiting', (select count(*) from queue_entries
                 where room_id = p_room and queue_date = v_today
                   and status in ('waiting', 'on_hold')),
    'now_serving', (select ticket from queue_entries
                     where room_id = p_room and queue_date = v_today and status = 'serving'),
    'est_wait', _est_wait(p_room, v_today, null)
  );
end $$;

create or replace function join_queue(
  p_room uuid, p_token text,
  p_patient_id uuid default null, p_patient_key uuid default null,
  p_name text default null, p_phone text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_today date := clinic_today();
  r rooms%rowtype;
  v_pid uuid; v_key uuid;
  v_existing queue_entries%rowtype;
  v_no int; v_ticket text; v_status text;
begin
  select * into r from rooms where id = p_room and not archived for update;
  if not found then return _err('room_not_found'); end if;
  if not exists (select 1 from room_secrets where room_id = p_room and qr_token = p_token) then
    return _err('invalid_qr');
  end if;
  if r.status = 'closed' then return _err('room_closed'); end if;

  -- find or create the patient
  if p_patient_id is not null then
    select id, key into v_pid, v_key from patients
     where id = p_patient_id and key = p_patient_key for update;
  end if;
  if v_pid is null then
    if coalesce(trim(p_name), '') = '' then return _err('name_required'); end if;
    insert into patients (name, phone) values (left(trim(p_name), 60), left(trim(p_phone), 20))
    returning id, key into v_pid, v_key;
  elsif coalesce(trim(p_name), '') <> '' then
    update patients set name = left(trim(p_name), 60),
                        phone = coalesce(left(trim(p_phone), 20), phone)
     where id = v_pid;
  end if;

  -- already in this room's queue today? return that ticket
  select * into v_existing from queue_entries
   where room_id = p_room and patient_id = v_pid and queue_date = v_today
     and status in ('waiting', 'serving', 'on_hold');
  if found then
    return jsonb_build_object('ok', true, 'patient_id', v_pid, 'patient_key', v_key,
                              'ticket', v_existing.ticket, 'already', true);
  end if;

  -- next ticket number (restarts at 1 every day)
  update room_secrets
     set next_number = case when number_date = v_today then next_number + 1 else 1 end,
         number_date = v_today
   where room_id = p_room
  returning next_number into v_no;
  v_ticket := r.prefix || lpad(v_no::text, 3, '0');

  -- if they are in treatment in another room right now, start on hold
  v_status := case when exists (select 1 from queue_entries
                                 where patient_id = v_pid and queue_date = v_today
                                   and status = 'serving')
              then 'on_hold' else 'waiting' end;

  insert into queue_entries (room_id, patient_id, queue_date, queue_no, ticket, position, status)
  values (p_room, v_pid, v_today, v_no, v_ticket, v_no, v_status);

  perform _bump_rooms(array[p_room]);
  return jsonb_build_object('ok', true, 'patient_id', v_pid, 'patient_key', v_key,
                            'ticket', v_ticket, 'already', false);
end $$;

-- Everything the patient's "My queues" page needs. No other patients' names.
create or replace function my_queues(p_patient_id uuid, p_patient_key uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_today date := clinic_today();
  v_name text;
begin
  select name into v_name from patients where id = p_patient_id and key = p_patient_key;
  if not found then return _err('unknown_patient'); end if;
  return jsonb_build_object(
    'ok', true,
    'name', v_name,
    'today', v_today,
    'queues', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'room_id', r.id, 'room_name', r.name, 'doctor_name', r.doctor_name,
        'room_status', r.status, 'room_message', r.status_message,
        'ticket', e.ticket, 'status', e.status, 'call_count', e.call_count,
        'called_at', e.called_at, 'completed_at', e.completed_at,
        'now_serving', (select q.ticket from queue_entries q
                         where q.room_id = r.id and q.queue_date = v_today
                           and q.status = 'serving'),
        'ahead', case when e.status in ('waiting', 'on_hold') then
                   (select count(*) from queue_entries q
                     where q.room_id = r.id and q.queue_date = v_today
                       and q.status in ('waiting', 'on_hold') and q.position < e.position) end,
        'est_wait', case when e.status in ('waiting', 'on_hold')
                         then _est_wait(r.id, v_today, e.position) end,
        'busy_in', case when e.status = 'on_hold' then
                   (select r2.name from queue_entries q2 join rooms r2 on r2.id = q2.room_id
                     where q2.patient_id = e.patient_id and q2.queue_date = v_today
                       and q2.status = 'serving' limit 1) end,
        'can_postpone', e.status in ('waiting', 'on_hold') and exists (
                   select 1 from queue_entries q
                    where q.room_id = r.id and q.queue_date = v_today
                      and q.status in ('waiting', 'on_hold') and q.position > e.position)
      ) order by (e.status in ('done', 'skipped', 'left')), e.joined_at)
      from queue_entries e join rooms r on r.id = e.room_id
      where e.patient_id = p_patient_id and e.queue_date = v_today), '[]'::jsonb)
  );
end $$;

create or replace function patient_leave(p_patient_id uuid, p_patient_key uuid, p_entry uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v queue_entries%rowtype;
begin
  if not exists (select 1 from patients where id = p_patient_id and key = p_patient_key) then
    return _err('unknown_patient');
  end if;
  select * into v from queue_entries where id = p_entry and patient_id = p_patient_id for update;
  if not found or v.status not in ('waiting', 'on_hold') then return _err('cannot_leave'); end if;
  update queue_entries set status = 'left', completed_at = now() where id = p_entry;
  perform _bump_rooms(array[v.room_id]);
  return jsonb_build_object('ok', true);
end $$;

-- Swap places with the person directly behind (patient asks for more time)
create or replace function patient_postpone(p_patient_id uuid, p_patient_key uuid, p_entry uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v queue_entries%rowtype; v_next queue_entries%rowtype;
begin
  if not exists (select 1 from patients where id = p_patient_id and key = p_patient_key) then
    return _err('unknown_patient');
  end if;
  select * into v from queue_entries where id = p_entry and patient_id = p_patient_id;
  if not found or v.status not in ('waiting', 'on_hold') then return _err('cannot_postpone'); end if;
  perform 1 from rooms where id = v.room_id for update;   -- one change per room at a time
  select * into v from queue_entries where id = p_entry for update;
  select * into v_next from queue_entries
   where room_id = v.room_id and queue_date = v.queue_date
     and status in ('waiting', 'on_hold') and position > v.position
   order by position limit 1 for update;
  if not found then return _err('already_last'); end if;
  update queue_entries set position = v_next.position where id = v.id;
  update queue_entries set position = v.position where id = v_next.id;
  perform _bump_rooms(array[v.room_id]);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Host functions (room PIN required)
-- ---------------------------------------------------------------------

create or replace function host_queue(p_room uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_check text := _host_check(p_room, p_pin);
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  return _host_view(p_room);
end $$;

-- Finish the current patient and call the next one in line.
-- Patients who are in treatment in another room are skipped over (their
-- place is kept) and the next available patient is called instead.
create or replace function host_call_next(p_room uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_check text := _host_check(p_room, p_pin);
  v_today date := clinic_today();
  v_prev uuid; v_entry uuid; v_patient uuid; v_ticket text;
  v_rooms uuid[] := array[p_room];
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  perform 1 from rooms where id = p_room for update;
  v_prev := _finish_current(p_room, v_today, 'done');
  if v_prev is not null then v_rooms := v_rooms || _patient_room_ids(v_prev, v_today); end if;

  loop
    select id, patient_id into v_entry, v_patient from queue_entries
     where room_id = p_room and queue_date = v_today and status = 'waiting'
     order by position limit 1;
    exit when v_entry is null;
    perform 1 from patients where id = v_patient for update;
    perform 1 from queue_entries where id = v_entry and status = 'waiting' for update;
    if found and _start_serving(v_entry) then
      select ticket into v_ticket from queue_entries where id = v_entry;
      v_rooms := v_rooms || _patient_room_ids(v_patient, v_today);
      exit;
    end if;
    v_entry := null;
  end loop;

  perform _bump_rooms(v_rooms);
  return _host_view(p_room) || jsonb_build_object('called', v_ticket);
end $$;

-- Call a specific patient (e.g. priority: elderly, OKU, pregnant)
create or replace function host_call_entry(p_room uuid, p_pin text, p_entry uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_check text := _host_check(p_room, p_pin);
  v_today date := clinic_today();
  v queue_entries%rowtype; v_prev uuid;
  v_rooms uuid[] := array[p_room];
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  perform 1 from rooms where id = p_room for update;
  select * into v from queue_entries
   where id = p_entry and room_id = p_room and queue_date = v_today;
  if not found or v.status not in ('waiting', 'on_hold') then return _err('not_waiting'); end if;
  perform 1 from patients where id = v.patient_id for update;
  if exists (select 1 from queue_entries where patient_id = v.patient_id
               and queue_date = v_today and status = 'serving') then
    return _err('patient_busy');
  end if;
  v_prev := _finish_current(p_room, v_today, 'done');
  if v_prev is not null then v_rooms := v_rooms || _patient_room_ids(v_prev, v_today); end if;
  update queue_entries set status = 'waiting' where id = p_entry and status = 'on_hold';
  perform _start_serving(p_entry);
  v_rooms := v_rooms || _patient_room_ids(v.patient_id, v_today);
  perform _bump_rooms(v_rooms);
  return _host_view(p_room) || jsonb_build_object('called', v.ticket);
end $$;

create or replace function host_complete(p_room uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_check text := _host_check(p_room, p_pin);
  v_today date := clinic_today(); v_prev uuid;
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  perform 1 from rooms where id = p_room for update;
  v_prev := _finish_current(p_room, v_today, 'done');
  perform _bump_rooms(array[p_room] || coalesce(_patient_room_ids(v_prev, v_today), '{}'));
  return _host_view(p_room);
end $$;

-- Mark as no-show. Works on the patient being served or anyone waiting.
create or replace function host_skip(p_room uuid, p_pin text, p_entry uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_check text := _host_check(p_room, p_pin);
  v_today date := clinic_today(); v queue_entries%rowtype;
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  perform 1 from rooms where id = p_room for update;
  select * into v from queue_entries where id = p_entry and room_id = p_room and queue_date = v_today;
  if not found or v.status not in ('waiting', 'serving', 'on_hold') then return _err('cannot_skip'); end if;
  if v.status = 'serving' then
    perform _finish_current(p_room, v_today, 'skipped');
  else
    update queue_entries set status = 'skipped', completed_at = now() where id = p_entry;
  end if;
  perform _bump_rooms(array[p_room] || _patient_room_ids(v.patient_id, v_today));
  return _host_view(p_room);
end $$;

-- Bring a skipped patient back. They return to their original place.
create or replace function host_restore(p_room uuid, p_pin text, p_entry uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_check text := _host_check(p_room, p_pin);
  v_today date := clinic_today(); v queue_entries%rowtype;
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  perform 1 from rooms where id = p_room for update;
  select * into v from queue_entries where id = p_entry and room_id = p_room and queue_date = v_today;
  if not found or v.status <> 'skipped' then return _err('not_skipped'); end if;
  if exists (select 1 from queue_entries where room_id = p_room and patient_id = v.patient_id
               and queue_date = v_today and status in ('waiting', 'serving', 'on_hold')) then
    return _err('already_in_queue');
  end if;
  update queue_entries
     set completed_at = null,
         status = case when exists (select 1 from queue_entries
                                     where patient_id = v.patient_id and queue_date = v_today
                                       and status = 'serving')
                       then 'on_hold' else 'waiting' end
   where id = p_entry;
  perform _bump_rooms(array[p_room]);
  return _host_view(p_room);
end $$;

-- Ring the patient's phone again
create or replace function host_recall(p_room uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_check text := _host_check(p_room, p_pin);
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  update queue_entries set call_count = call_count + 1
   where room_id = p_room and queue_date = clinic_today() and status = 'serving';
  perform _bump_rooms(array[p_room]);
  return _host_view(p_room);
end $$;

-- Set the estimated minutes for one patient (null = use room default)
create or replace function host_set_est(p_room uuid, p_pin text, p_entry uuid, p_minutes int)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_check text := _host_check(p_room, p_pin);
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  if p_minutes is not null and (p_minutes < 1 or p_minutes > 240) then
    return _err('invalid_minutes');
  end if;
  update queue_entries set est_minutes = p_minutes
   where id = p_entry and room_id = p_room and queue_date = clinic_today();
  perform _bump_rooms(array[p_room]);
  return _host_view(p_room);
end $$;

-- Open / pause / close the room, set the default time per patient
create or replace function host_update_room(
  p_room uuid, p_pin text, p_status text, p_message text, p_default_est int
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_check text := _host_check(p_room, p_pin);
begin
  if v_check <> 'ok' then return _err(v_check); end if;
  if p_status not in ('open', 'paused', 'closed') then return _err('invalid_status'); end if;
  if p_default_est < 1 or p_default_est > 240 then return _err('invalid_minutes'); end if;
  update rooms set status = p_status,
                   status_message = nullif(left(trim(p_message), 120), ''),
                   default_est_minutes = p_default_est
   where id = p_room;
  perform _bump_rooms(array[p_room]);
  return _host_view(p_room);
end $$;

-- ---------------------------------------------------------------------
-- Admin functions (admin password required)
-- ---------------------------------------------------------------------

create or replace function admin_rooms(p_password text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not _admin_ok(p_password) then return _err('bad_password'); end if;
  return jsonb_build_object('ok', true, 'rooms', coalesce((
    select jsonb_agg(to_jsonb(r) || jsonb_build_object('qr_token', s.qr_token)
                     order by r.archived, r.sort_order, r.name)
    from rooms r join room_secrets s on s.room_id = r.id), '[]'::jsonb));
end $$;

-- Create (p_id null) or update a room. PIN is required when creating.
create or replace function admin_save_room(
  p_password text, p_id uuid, p_name text, p_prefix text, p_doctor text,
  p_default_est int, p_sort int, p_pin text, p_archived boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if not _admin_ok(p_password) then return _err('bad_password'); end if;
  if coalesce(trim(p_name), '') = '' then return _err('name_required'); end if;
  if coalesce(trim(p_prefix), '') !~ '^[A-Za-z0-9]{1,3}$' then return _err('invalid_prefix'); end if;
  if p_default_est is null or p_default_est < 1 or p_default_est > 240 then
    return _err('invalid_minutes');
  end if;
  if p_pin is not null and p_pin !~ '^[0-9]{4,8}$' then return _err('invalid_pin'); end if;

  if p_id is null then
    if p_pin is null then return _err('pin_required'); end if;
    insert into rooms (name, prefix, doctor_name, default_est_minutes, sort_order)
    values (trim(p_name), upper(trim(p_prefix)), nullif(trim(p_doctor), ''),
            p_default_est, coalesce(p_sort, 0))
    returning id into v_id;
    insert into room_secrets (room_id, pin_hash, qr_token)
    values (v_id, crypt(p_pin, gen_salt('bf')), encode(gen_random_bytes(9), 'hex'));
  else
    update rooms set name = trim(p_name), prefix = upper(trim(p_prefix)),
                     doctor_name = nullif(trim(p_doctor), ''),
                     default_est_minutes = p_default_est,
                     sort_order = coalesce(p_sort, 0),
                     archived = coalesce(p_archived, false)
     where id = p_id returning id into v_id;
    if v_id is null then return _err('room_not_found'); end if;
    if p_pin is not null then
      update room_secrets set pin_hash = crypt(p_pin, gen_salt('bf')),
                              failed_attempts = 0, locked_until = null
       where room_id = v_id;
    end if;
    perform _bump_rooms(array[v_id]);
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Make a new QR code for a room (old printed QR codes stop working)
create or replace function admin_new_qr(p_password text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not _admin_ok(p_password) then return _err('bad_password'); end if;
  update room_secrets set qr_token = encode(gen_random_bytes(9), 'hex') where room_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Security: browsers can only read public room info and call the
-- functions below. Everything else is locked away.
-- ---------------------------------------------------------------------

alter table settings      enable row level security;
alter table rooms         enable row level security;
alter table room_secrets  enable row level security;
alter table patients      enable row level security;
alter table queue_entries enable row level security;

revoke all on settings, rooms, room_secrets, patients, queue_entries from anon, authenticated;
grant select on rooms to anon, authenticated;
drop policy if exists "rooms are public" on rooms;
create policy "rooms are public" on rooms for select to anon, authenticated using (true);

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  room_info(uuid, text),
  join_queue(uuid, text, uuid, uuid, text, text),
  my_queues(uuid, uuid),
  patient_leave(uuid, uuid, uuid),
  patient_postpone(uuid, uuid, uuid),
  host_queue(uuid, text),
  host_call_next(uuid, text),
  host_call_entry(uuid, text, uuid),
  host_complete(uuid, text),
  host_skip(uuid, text, uuid),
  host_restore(uuid, text, uuid),
  host_recall(uuid, text),
  host_set_est(uuid, text, uuid, int),
  host_update_room(uuid, text, text, text, int),
  admin_rooms(text),
  admin_save_room(text, uuid, text, text, text, int, int, text, boolean),
  admin_new_qr(text, uuid)
to anon, authenticated;

-- Realtime: screens listen for changes to the rooms table
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'rooms') then
    alter publication supabase_realtime add table rooms;
  end if;
end $$;

-- =====================================================================
--  SET YOUR ADMIN PASSWORD: change the text below, then run this line.
-- =====================================================================
update settings set admin_hash = extensions.crypt('change-this-password', extensions.gen_salt('bf'))
where id = 1;
