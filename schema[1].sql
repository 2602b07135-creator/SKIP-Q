-- Skip Q schema (run in Supabase SQL editor)
create extension if not exists pgcrypto;

create table profiles(id uuid primary key references auth.users on delete cascade, name text, email text, phone text,
  role text not null default 'customer' check(role in('customer','owner')));
create table businesses(id uuid primary key default gen_random_uuid(), owner_id uuid references profiles(id) on delete cascade,
  name text not null, category text, address text, description text, lat float8, lng float8,
  open_time time default '10:00', close_time time default '13:00', slot_minutes int default 30);
create table services(id uuid primary key default gen_random_uuid(), business_id uuid not null references businesses on delete cascade,
  name text not null, price int not null check(price>=0), duration_min int not null check(duration_min>0), active bool default true);
create table slots(id uuid primary key default gen_random_uuid(), business_id uuid not null references businesses on delete cascade,
  date date not null, time time not null, capacity int not null default 2 check(capacity>=0), booked int not null default 0,
  unique(business_id,date,time));
create sequence ticket_seq start 1001;
create table bookings(id uuid primary key default gen_random_uuid(), code text unique not null default 'SQ-'||nextval('ticket_seq'),
  business_id uuid not null references businesses on delete cascade, service_id uuid references services on delete set null,
  customer_id uuid not null references profiles on delete cascade, slot_id uuid references slots,
  d date not null, t time not null, status text not null default 'Pending', created_at timestamptz default now());
create index on bookings(business_id,d,t); create index on bookings(customer_id); create index on services(business_id);

-- profile auto-created on sign up (name/role come from signUp metadata)
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,email,name,role) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'name',''),
  case when new.raw_user_meta_data->>'role'='owner' then 'owner' else 'customer' end); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- RLS
alter table profiles enable row level security; alter table businesses enable row level security;
alter table services enable row level security; alter table slots enable row level security; alter table bookings enable row level security;
create policy p_sel on profiles for select using(id=auth.uid());
create policy p_sel_owner on profiles for select using(exists(select 1 from bookings b join businesses s on s.id=b.business_id where b.customer_id=profiles.id and s.owner_id=auth.uid()));
create policy p_upd on profiles for update using(id=auth.uid()) with check(id=auth.uid() and role=(select role from profiles where id=auth.uid()));
create policy b_sel on businesses for select using(auth.uid() is not null);
create policy b_ins on businesses for insert with check(owner_id=auth.uid());
create policy b_upd on businesses for update using(owner_id=auth.uid());
create policy b_del on businesses for delete using(owner_id=auth.uid());
create policy s_sel on services for select using(auth.uid() is not null);
create policy s_all on services for all using(exists(select 1 from businesses b where b.id=business_id and b.owner_id=auth.uid()))
  with check(exists(select 1 from businesses b where b.id=business_id and b.owner_id=auth.uid()));
create policy sl_sel on slots for select using(auth.uid() is not null);
create policy sl_all on slots for all using(exists(select 1 from businesses b where b.id=business_id and b.owner_id=auth.uid()))
  with check(exists(select 1 from businesses b where b.id=business_id and b.owner_id=auth.uid()));
create policy bk_sel on bookings for select using(customer_id=auth.uid() or exists(select 1 from businesses b where b.id=business_id and b.owner_id=auth.uid()));

-- Atomic booking: locks the slot row so nobody can overbook
create function book_slot(p_biz uuid,p_svc uuid,p_date date,p_time time) returns bookings language plpgsql security definer set search_path=public as $$
declare s slots; r bookings; ist timestamp := now() at time zone 'Asia/Kolkata';
begin
  if auth.uid() is null then raise exception 'AUTH'; end if;
  if p_date<ist::date or (p_date=ist::date and p_time<ist::time) then raise exception 'PAST'; end if;
  insert into slots(business_id,date,time) values(p_biz,p_date,p_time) on conflict do nothing;
  select * into s from slots where business_id=p_biz and date=p_date and time=p_time for update;
  if s.booked>=s.capacity then raise exception 'SLOT_FULL'; end if;
  update slots set booked=booked+1 where id=s.id;
  insert into bookings(business_id,service_id,customer_id,slot_id,d,t) values(p_biz,p_svc,auth.uid(),s.id,p_date,p_time) returning * into r;
  return r;
end $$;

-- Status changes (owner: any step; customer: cancel own). Cancel/reject/no-show frees the slot.
create function set_status(p_id uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
declare b bookings; own bool;
begin
  select * into b from bookings where id=p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  own := exists(select 1 from businesses where id=b.business_id and owner_id=auth.uid());
  if not own and not (b.customer_id=auth.uid() and p_status='Cancelled') then raise exception 'FORBIDDEN'; end if;
  if b.status in('Completed','Cancelled','Rejected','No-show') then raise exception 'CLOSED'; end if;
  if p_status in('Cancelled','Rejected','No-show') then update slots set booked=greatest(booked-1,0) where id=b.slot_id; end if;
  update bookings set status=p_status where id=p_id;
end $$;

-- Queue position + estimated wait (sum of durations of active bookings ahead)
create function queue_info(p_code text) returns table(pos int,ahead int,wait int) language sql security definer set search_path=public as $$
  with me as(select * from bookings where code=p_code and customer_id=auth.uid()),
  a as(select s.duration_min from bookings o join me on o.business_id=me.business_id and o.d=me.d and o.id<>me.id
       and o.status not in('Completed','Cancelled','Rejected','No-show') and (o.t<me.t or (o.t=me.t and o.created_at<me.created_at))
       join services s on s.id=o.service_id)
  select (count(*)+1)::int, count(*)::int, coalesce(sum(duration_min),0)::int from a $$;

-- Mark Waiting/Confirmed bookings as No-show after a grace period (schedule with pg_cron every 5 min)
create function auto_no_show(grace_min int default 20) returns void language sql security definer set search_path=public as $$
  update slots s set booked=greatest(booked-1,0) from bookings b where b.slot_id=s.id and b.status in('Pending','Confirmed')
    and (b.d+b.t) < ((now() at time zone 'Asia/Kolkata') - make_interval(mins=>grace_min));
  update bookings set status='No-show' where status in('Pending','Confirmed') and (d+t) < ((now() at time zone 'Asia/Kolkata') - make_interval(mins=>grace_min)); $$;

create function delete_me() returns void language sql security definer set search_path=public,auth as $$ delete from auth.users where id=auth.uid() $$;

alter publication supabase_realtime add table bookings;

-- Seed businesses (owner_id null until a real owner claims their own business in the app)
insert into businesses(name,category,address,description) values
('City Care Clinic','Clinic','Banjara Hills','General physician and family care.'),
('Smart Style Salon','Salon','Madhapur','Haircuts, styling and grooming.'),
('QuickFix Service Centre','Service Centre','Gachibowli','Phone and laptop repair.'),
('Health First Diagnostics','Diagnostic Centre','Kukatpally','Blood tests, scans and reports.'),
('Glow Beauty Studio','Beauty & Wellness','Jubilee Hills','Facials, makeup and wellness.');
insert into services(business_id,name,price,duration_min)
select b.id,v.n,v.p,v.d from businesses b join (values
('City Care Clinic','General consultation',300,15),('City Care Clinic','Follow-up visit',150,10),('City Care Clinic','Health check-up',900,40),
('Smart Style Salon','Haircut',250,30),('Smart Style Salon','Hair spa',800,60),('Smart Style Salon','Beard trim',120,15),
('QuickFix Service Centre','Screen replacement',2500,45),('QuickFix Service Centre','Diagnosis',200,15),('QuickFix Service Centre','Battery change',1200,30),
('Health First Diagnostics','Blood test',500,10),('Health First Diagnostics','X-ray',700,15),('Health First Diagnostics','Full body panel',2200,30),
('Glow Beauty Studio','Facial',1200,45),('Glow Beauty Studio','Manicure',600,30),('Glow Beauty Studio','Makeup',2500,60)
) v(bn,n,p,d) on v.bn=b.name;

-- Run auto no-show every 5 minutes (enable the pg_cron extension in Database > Extensions first)
select cron.schedule('skipq-no-show','*/5 * * * *','select auto_no_show(20)');

-- ===== Push subscriptions (for alerts when the app is closed) =====
create table push_subscriptions(id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references profiles on delete cascade,
  endpoint text unique not null, sub jsonb not null, created_at timestamptz default now());
alter table push_subscriptions enable row level security;
create policy ps_own on push_subscriptions for all using(user_id=auth.uid()) with check(user_id=auth.uid());

-- ===== Owners claim a seeded business (only unowned ones, one per owner) =====
create function claim_business(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if (select role from profiles where id=auth.uid()) is distinct from 'owner' then raise exception 'FORBIDDEN'; end if;
  if exists(select 1 from businesses where owner_id=auth.uid()) then raise exception 'You already manage a business.'; end if;
  update businesses set owner_id=auth.uid() where id=p_id and owner_id is null;
  if not found then raise exception 'That business is already claimed.'; end if;
end $$;
