-- Crop Lifecycle Tracker: schema (PostgreSQL 14+)
-- Conventions
--   * money   = numeric(12,2), quantities = numeric(12,3). Never float.
--   * every table: created_by, created_at, updated_at, deleted_at (soft delete)
--     (notifications / push_subscriptions are delivery tables; see notes)
--   * every read query must filter "deleted_at IS NULL" (views below already do)
--   * created_by is a plain uuid; point it at your auth users table
--     (e.g. REFERENCES auth.users(id)) once you pick an auth provider.
--
-- Locked app rules (not all enforceable in SQL alone):
--   * On "Mark as paid", auto-create/link a workers row if missing.
--   * Cap allocations: sum per payment <= amount; sum per work_log <= amount_due.
--   * Lease: insert exactly one other_costs row with is_lease = true per cycle.

create extension if not exists pgcrypto;  -- gen_random_uuid()

-- ---------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end $$ language plpgsql;

-- Fixed unit list so reports never fragment ("kg" / "Kg" / "kgs").
create table units (
  code  text primary key,            -- 'kg', 'quintal', 'bag', 'litre', 'acre' ...
  label text not null,
  kind  text not null check (kind in ('weight','volume','count','area'))
);
insert into units (code, label, kind) values
  ('kg','Kg','weight'), ('quintal','Quintal','weight'), ('ton','Ton','weight'),
  ('bag','Bag','count'), ('piece','Piece','count'), ('bundle','Bundle','count'),
  ('litre','Litre','volume'),
  ('acre','Acre','area'), ('hectare','Hectare','area'), ('cent','Cent','area');

create type ownership_type as enum ('owned', 'leased');
create type cycle_status   as enum ('planned', 'active', 'completed');
create type purchase_category as enum ('seed', 'fertilizer', 'material');
create type pay_type       as enum ('daily_wage', 'monthly_salary');
create type vehicle_cost_type as enum ('fuel', 'repair', 'hire', 'other');
create type task_type      as enum ('fertilizer','spray','tractor','irrigation','workers','harvest','other');
create type task_status    as enum ('upcoming', 'notified', 'done', 'skipped');
create type notif_channel  as enum ('in_app', 'browser', 'push');
create type notif_status   as enum ('pending', 'sent', 'failed', 'dismissed');

-- ---------------------------------------------------------------
-- 1. lands
-- ---------------------------------------------------------------
create table lands (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  area_value     numeric(12,3) not null check (area_value > 0),
  area_unit      text not null references units(code),
  ownership      ownership_type not null,
  lease_amount   numeric(12,2),                 -- amount per lease_period
  lease_period   text check (lease_period in ('yearly','season','monthly')),
  location_notes text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  check (ownership = 'leased' or lease_amount is null)
);

-- ---------------------------------------------------------------
-- 2. crop_cycles
-- ---------------------------------------------------------------
create table crop_cycles (
  id                  uuid primary key default gen_random_uuid(),
  land_id             uuid not null references lands(id),
  crop_name           text not null,
  variety             text,
  season_label        text,                      -- 'Kharif 2026'
  start_date          date,
  end_date            date,
  status              cycle_status not null default 'planned',
  -- Needed for cost/acre and yield/acre, the numbers farmers compare year to year.
  area_planted        numeric(12,3) check (area_planted > 0),
  area_unit           text references units(code),
  -- Total harvested (sold + kept + lost). Lets the app show unsold stock.
  harvested_quantity  numeric(12,3) check (harvested_quantity >= 0),
  harvested_unit      text references units(code),
  notes               text,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  check (end_date is null or start_date is null or end_date >= start_date)
);
create index on crop_cycles (land_id) where deleted_at is null;

-- ---------------------------------------------------------------
-- 3. purchases  (seeds + farm_materials + fertilizers)
--    UI tabs filter on category. total_cost is source of truth;
--    unit_price is derived.
-- ---------------------------------------------------------------
create table purchases (
  id             uuid primary key default gen_random_uuid(),
  crop_cycle_id  uuid not null references crop_cycles(id),
  category       purchase_category not null,
  item_name      text not null,                  -- 'Urea', 'BT cotton seed', 'Drip pipe'
  variety        text,                           -- seeds only
  quantity       numeric(12,3) check (quantity > 0),
  unit           text references units(code),
  total_cost     numeric(12,2) not null check (total_cost >= 0),
  unit_price     numeric(12,2) generated always as
                   (case when quantity > 0 then round(total_cost / quantity, 2) end) stored,
  purchased_from text,
  purchase_date  date,
  applied_date   date,                           -- fertilizers: when sprayed / applied
  -- Credit tracking: dealers often supply on credit until harvest.
  amount_paid    numeric(12,2) not null default 0 check (amount_paid >= 0),
  payment_status text generated always as (
                   case when amount_paid <= 0 then 'due'
                        when amount_paid >= total_cost then 'paid'
                        else 'partial' end) stored,
  notes          text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index on purchases (crop_cycle_id, category) where deleted_at is null;

-- ---------------------------------------------------------------
-- 4. workers, work_logs, worker_payments, allocations
-- ---------------------------------------------------------------
create table workers (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  pay_type       pay_type not null,
  default_amount numeric(12,2),                  -- default daily wage or monthly salary
  phone          text,
  active         boolean not null default true,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);

create table work_logs (
  id              uuid primary key default gen_random_uuid(),
  crop_cycle_id   uuid not null references crop_cycles(id),
  worker_id       uuid references workers(id),
  worker_name     text,                          -- one-off worker not saved in master
  pay_type        pay_type not null,
  work_date       date not null,                 -- day worked, or first day of salary month
  days_count      numeric(5,2) check (days_count > 0),   -- daily wage only
  amount_due      numeric(12,2) not null check (amount_due >= 0),
  work_description text,                         -- sowing, weeding, harvest...
  -- Monthly salary across several crops: one work_log per cycle share.
  salary_month    date,                          -- first day of month, salary rows only
  notes           text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  check (worker_id is not null or worker_name is not null)
);
create index on work_logs (crop_cycle_id) where deleted_at is null;
create index on work_logs (worker_id)     where deleted_at is null;

create table worker_payments (
  id          uuid primary key default gen_random_uuid(),
  worker_id   uuid not null references workers(id),
  paid_on     date not null,
  amount      numeric(12,2) not null check (amount > 0),
  kind        text not null default 'wage' check (kind in ('wage','advance')),
  notes       text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

-- One payment may settle many work logs; one work log may be settled by many payments.
create table worker_payment_allocations (
  payment_id  uuid not null references worker_payments(id),
  work_log_id uuid not null references work_logs(id),
  amount      numeric(12,2) not null check (amount > 0),
  primary key (payment_id, work_log_id)
);

-- ---------------------------------------------------------------
-- 5. vehicles + vehicle_costs
--    vehicles master = owned fleet; hire uses vehicle_label / cost_type = hire.
-- ---------------------------------------------------------------
create table vehicles (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,                     -- 'Tractor 1'
  type        text,                              -- tractor / trailer / bike
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create table vehicle_costs (
  id             uuid primary key default gen_random_uuid(),
  crop_cycle_id  uuid not null references crop_cycles(id),
  vehicle_id     uuid references vehicles(id),
  vehicle_label  text,                           -- hired one-off, e.g. 'Ramu tractor'
  cost_type      vehicle_cost_type not null,
  quantity       numeric(12,3),                  -- litres for fuel
  amount         numeric(12,2) not null check (amount >= 0),
  amount_paid    numeric(12,2) not null default 0 check (amount_paid >= 0),
  payment_status text generated always as (
                   case when amount_paid <= 0 then 'due'
                        when amount_paid >= amount then 'paid'
                        else 'partial' end) stored,
  cost_date      date not null,
  notes          text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  check (vehicle_id is not null or vehicle_label is not null)
);
create index on vehicle_costs (crop_cycle_id) where deleted_at is null;

-- ---------------------------------------------------------------
-- 6. other_costs  (also carries the lease cost)
--    LEASE RULE: when a crop cycle is created on leased land, insert exactly
--    one other_costs row with is_lease = true, category = 'lease'.
-- ---------------------------------------------------------------
create table other_costs (
  id             uuid primary key default gen_random_uuid(),
  crop_cycle_id  uuid not null references crop_cycles(id),
  category       text not null,                  -- transport, water, electricity, lease, misc
  is_lease       boolean not null default false,
  description    text,
  amount         numeric(12,2) not null check (amount >= 0),
  amount_paid    numeric(12,2) not null default 0 check (amount_paid >= 0),
  payment_status text generated always as (
                   case when amount_paid <= 0 then 'due'
                        when amount_paid >= amount then 'paid'
                        else 'partial' end) stored,
  cost_date      date not null,
  notes          text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index on other_costs (crop_cycle_id) where deleted_at is null;
create unique index one_lease_row_per_cycle
  on other_costs (crop_cycle_id) where is_lease and deleted_at is null;

-- ---------------------------------------------------------------
-- 7. harvest_sales
-- ---------------------------------------------------------------
create table harvest_sales (
  id              uuid primary key default gen_random_uuid(),
  crop_cycle_id   uuid not null references crop_cycles(id),
  produce_name    text not null,
  quantity        numeric(12,3) not null check (quantity > 0),
  unit            text not null references units(code),
  total_amount    numeric(12,2) not null check (total_amount >= 0),
  unit_price      numeric(12,2) generated always as
                    (round(total_amount / quantity, 2)) stored,
  buyer_name      text,
  sale_date       date not null,
  amount_received numeric(12,2) not null default 0 check (amount_received >= 0),
  payment_status  text generated always as (
                    case when amount_received <= 0 then 'due'
                         when amount_received >= total_amount then 'paid'
                         else 'partial' end) stored,
  notes           text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index on harvest_sales (crop_cycle_id) where deleted_at is null;

-- ---------------------------------------------------------------
-- 8. field_tasks, notifications, push_subscriptions
-- ---------------------------------------------------------------
create table field_tasks (
  id               uuid primary key default gen_random_uuid(),
  crop_cycle_id    uuid not null references crop_cycles(id),
  task_type        task_type not null,
  title            text not null,
  due_at           timestamptz not null,
  remind_at        timestamptz,
  reminder_enabled boolean not null default true,
  status           task_status not null default 'upcoming',
  completed_at     timestamptz,
  related_table    text check (related_table in ('purchases','vehicle_costs','work_logs','other_costs')),
  related_id       uuid,
  notes            text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create index on field_tasks (remind_at)
  where reminder_enabled and status = 'upcoming' and deleted_at is null;

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  field_task_id  uuid not null references field_tasks(id),
  crop_cycle_id  uuid not null references crop_cycles(id),
  user_id        uuid not null,                  -- locked: NOT NULL so unique key works
  title          text not null,
  body           text,
  channel        notif_channel not null,
  scheduled_for  timestamptz not null,
  sent_at        timestamptz,
  read_at        timestamptz,
  status         notif_status not null default 'pending',
  created_at     timestamptz not null default now(),
  unique (field_task_id, user_id, channel)
);

create table push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'lands','crop_cycles','purchases','workers','work_logs','worker_payments',
    'vehicles','vehicle_costs','other_costs','harvest_sales','field_tasks']
  loop
    execute format(
      'create trigger trg_%1$s_updated before update on %1$s
         for each row execute function set_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------
-- Reporting views (soft-deleted rows excluded)
-- ---------------------------------------------------------------

create view cycle_summary as
select
  c.id as crop_cycle_id,
  c.crop_name, c.season_label, c.status, c.land_id,
  c.area_planted, c.area_unit,

  coalesce(p.total, 0)  as purchases_total,
  coalesce(w.total, 0)  as workers_total,
  coalesce(v.total, 0)  as vehicles_total,
  coalesce(o.total, 0)  as other_total,
  coalesce(p.total,0) + coalesce(w.total,0) + coalesce(v.total,0) + coalesce(o.total,0)
                        as total_investment,

  coalesce(s.total, 0)  as total_sales,
  coalesce(s.total,0) - (coalesce(p.total,0) + coalesce(w.total,0)
                         + coalesce(v.total,0) + coalesce(o.total,0))
                        as net_gain,

  coalesce(p.owed,0) + coalesce(w.owed,0) + coalesce(v.owed,0) + coalesce(o.owed,0)
                        as money_i_owe,
  coalesce(w.owed, 0)   as workers_due,
  coalesce(s.pending, 0) as money_owed_to_me,

  case when c.area_planted > 0 then
    round((coalesce(p.total,0) + coalesce(w.total,0) + coalesce(v.total,0) + coalesce(o.total,0))
          / c.area_planted, 2) end as cost_per_area,
  case when c.area_planted > 0 then
    round(c.harvested_quantity / c.area_planted, 3) end as yield_per_area,
  c.harvested_quantity, c.harvested_unit
from crop_cycles c
left join lateral (
  select sum(total_cost) total, sum(total_cost - least(amount_paid, total_cost)) owed
  from purchases where crop_cycle_id = c.id and deleted_at is null) p on true
left join lateral (
  select sum(wl.amount_due) total,
         sum(wl.amount_due - coalesce(a.paid, 0)) owed
  from work_logs wl
  left join lateral (
    select sum(amount) paid from worker_payment_allocations x
    join worker_payments wp on wp.id = x.payment_id and wp.deleted_at is null
    where x.work_log_id = wl.id) a on true
  where wl.crop_cycle_id = c.id and wl.deleted_at is null) w on true
left join lateral (
  select sum(amount) total, sum(amount - least(amount_paid, amount)) owed
  from vehicle_costs where crop_cycle_id = c.id and deleted_at is null) v on true
left join lateral (
  select sum(amount) total, sum(amount - least(amount_paid, amount)) owed
  from other_costs where crop_cycle_id = c.id and deleted_at is null) o on true
left join lateral (
  select sum(total_amount) total,
         sum(total_amount - least(amount_received, total_amount)) pending
  from harvest_sales where crop_cycle_id = c.id and deleted_at is null) s on true
where c.deleted_at is null;

create view cycle_stock as
select c.id as crop_cycle_id,
       c.harvested_quantity,
       coalesce(sum(hs.quantity), 0) as sold_quantity,
       c.harvested_quantity - coalesce(sum(hs.quantity), 0) as unsold_quantity
from crop_cycles c
left join harvest_sales hs on hs.crop_cycle_id = c.id and hs.deleted_at is null
where c.deleted_at is null
group by c.id;

create view worker_balance as
select w.id as worker_id, w.name,
       coalesce(l.earned, 0) as total_earned,
       coalesce(p.paid, 0)   as total_paid,
       coalesce(l.earned, 0) - coalesce(p.paid, 0) as balance_due
from workers w
left join (select worker_id, sum(amount_due) earned
           from work_logs where deleted_at is null group by worker_id) l on l.worker_id = w.id
left join (select worker_id, sum(amount) paid
           from worker_payments where deleted_at is null group by worker_id) p on p.worker_id = w.id
where w.deleted_at is null;

create view cycle_cost_breakdown as
select crop_cycle_id, category::text as category, sum(total_cost) as amount
  from purchases where deleted_at is null group by crop_cycle_id, category
union all
select crop_cycle_id, 'workers', sum(amount_due)
  from work_logs where deleted_at is null group by crop_cycle_id
union all
select crop_cycle_id, 'vehicles', sum(amount)
  from vehicle_costs where deleted_at is null group by crop_cycle_id
union all
select crop_cycle_id, case when is_lease then 'lease' else 'other' end, sum(amount)
  from other_costs where deleted_at is null group by crop_cycle_id, is_lease;
