
create type public.app_role as enum ('admin','manager','staff','viewer');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  created_at timestamptz not null default now()
);
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  role app_role not null,
  unique (user_id, role)
);
grant select, update on public.profiles to authenticated;
grant all on public.profiles to service_role;
grant select, insert, update, delete on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;

create or replace function public.has_role(_user_id uuid, _role app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;
create or replace function public.has_any_role(_user_id uuid, _roles app_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = any(_roles))
$$;

create policy "read profiles" on public.profiles for select to authenticated using (true);
create policy "update own profile" on public.profiles for update to authenticated using (id = auth.uid() or public.has_role(auth.uid(),'admin'));
create policy "read roles" on public.user_roles for select to authenticated using (true);
create policy "admin manage roles" on public.user_roles for all to authenticated using (public.has_role(auth.uid(),'admin')) with check (public.has_role(auth.uid(),'admin'));

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.profiles(id, full_name, email) values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)), new.email);
  select count(*) into n from public.user_roles;
  insert into public.user_roles(user_id, role) values (new.id, case when n = 0 then 'admin'::app_role else 'viewer'::app_role end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create table public.app_settings (
  id int primary key default 1 check (id = 1),
  company_name text not null default 'CGM',
  company_address text,
  currency text not null default 'PKR',
  split_mode text not null default 'none' check (split_mode in ('none','equal')),
  payment_methods text[] not null default array['Cash','Bank Transfer','JazzCash','EasyPaisa','Card','Other'],
  updated_at timestamptz not null default now()
);
insert into public.app_settings(id) values (1);

create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique,
  description text,
  start_date date,
  end_date date,
  status text not null default 'active' check (status in ('active','paused','completed','archived')),
  budget numeric(14,2) not null default 0 check (budget >= 0),
  currency text not null default 'PKR',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text, phone text, role text,
  status text not null default 'active' check (status in ('active','inactive')),
  notes text,
  created_at timestamptz not null default now()
);
create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  status text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now()
);
create sequence public.expense_txn_seq;
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  transaction_number text not null unique,
  campaign_id uuid not null references public.campaigns(id),
  expense_date date not null,
  paid_by uuid not null references public.people(id),
  category_id uuid not null references public.expense_categories(id),
  description text,
  amount numeric(14,2) not null check (amount > 0),
  currency text not null default 'PKR',
  payment_method text,
  vendor text,
  reference_number text,
  notes text,
  status text not null default 'approved' check (status in ('pending','approved','reimbursed')),
  import_hash text unique,
  created_by uuid, updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz, deleted_by uuid, deletion_reason text
);
create index on public.expenses(campaign_id);
create index on public.expenses(expense_date);
create index on public.expenses(paid_by);
create index on public.expenses(category_id);
create index on public.expenses(transaction_number);

create table public.expense_receipts (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id) on delete cascade,
  file_path text not null,
  file_name text not null,
  uploaded_by uuid,
  created_at timestamptz not null default now()
);
create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  settlement_date date not null default current_date,
  from_person uuid not null references public.people(id),
  to_person uuid not null references public.people(id),
  amount numeric(14,2) not null check (amount > 0),
  campaign_id uuid references public.campaigns(id),
  method text, notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (from_person <> to_person)
);
create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  experience text,
  mock_call_status text not null default 'pending' check (mock_call_status in ('pending','done','passed','failed')),
  salary text,
  notes text,
  status text not null default 'new' check (status in ('new','interviewing','hired','rejected','on_hold')),
  created_at timestamptz not null default now()
);
create table public.audit_logs (
  id bigint generated always as identity primary key,
  user_id uuid,
  user_name text,
  action text not null,
  entity text not null,
  entity_id text,
  old_values jsonb,
  new_values jsonb,
  metadata jsonb,
  created_at timestamptz not null default now()
);
create index on public.audit_logs(entity, entity_id);

grant select, insert, update, delete on public.app_settings, public.campaigns, public.people, public.expense_categories, public.expenses, public.expense_receipts, public.settlements, public.candidates to authenticated;
grant select, insert on public.audit_logs to authenticated;
grant all on public.app_settings, public.campaigns, public.people, public.expense_categories, public.expenses, public.expense_receipts, public.settlements, public.candidates, public.audit_logs to service_role;
grant usage on sequence public.expense_txn_seq to authenticated;

alter table public.app_settings enable row level security;
alter table public.campaigns enable row level security;
alter table public.people enable row level security;
alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_receipts enable row level security;
alter table public.settlements enable row level security;
alter table public.candidates enable row level security;
alter table public.audit_logs enable row level security;

create policy "read" on public.app_settings for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "admin write" on public.app_settings for update to authenticated using (public.has_role(auth.uid(),'admin'));

create policy "read" on public.campaigns for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "admin insert" on public.campaigns for insert to authenticated with check (public.has_role(auth.uid(),'admin'));
create policy "admin update" on public.campaigns for update to authenticated using (public.has_role(auth.uid(),'admin'));
create policy "admin delete" on public.campaigns for delete to authenticated using (public.has_role(auth.uid(),'admin'));

create policy "read" on public.people for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "mgr insert" on public.people for insert to authenticated with check (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));
create policy "mgr update" on public.people for update to authenticated using (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));
create policy "admin delete" on public.people for delete to authenticated using (public.has_role(auth.uid(),'admin'));

create policy "read" on public.expense_categories for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "admin insert" on public.expense_categories for insert to authenticated with check (public.has_role(auth.uid(),'admin'));
create policy "admin update" on public.expense_categories for update to authenticated using (public.has_role(auth.uid(),'admin'));

create policy "read" on public.expenses for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "staff insert" on public.expenses for insert to authenticated with check (public.has_any_role(auth.uid(), array['admin','manager','staff']::app_role[]) and deleted_at is null);
create policy "mgr update" on public.expenses for update to authenticated using (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));

create policy "read" on public.expense_receipts for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "staff insert" on public.expense_receipts for insert to authenticated with check (public.has_any_role(auth.uid(), array['admin','manager','staff']::app_role[]));
create policy "mgr delete" on public.expense_receipts for delete to authenticated using (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));

create policy "read" on public.settlements for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "mgr insert" on public.settlements for insert to authenticated with check (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));
create policy "admin delete" on public.settlements for delete to authenticated using (public.has_role(auth.uid(),'admin'));

create policy "read" on public.candidates for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "mgr insert" on public.candidates for insert to authenticated with check (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));
create policy "mgr update" on public.candidates for update to authenticated using (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));
create policy "admin delete" on public.candidates for delete to authenticated using (public.has_role(auth.uid(),'admin'));

create policy "read audit" on public.audit_logs for select to authenticated using (public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));
create policy "log import" on public.audit_logs for insert to authenticated with check (user_id = auth.uid() and action = 'import');

create or replace function public.expenses_before() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.transaction_number is null or new.transaction_number = '' then
      new.transaction_number := 'EXP-' || to_char(coalesce(new.expense_date, current_date),'YYYY') || '-' || lpad(nextval('public.expense_txn_seq')::text, 6, '0');
    end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.created_at := now();
  else
    new.transaction_number := old.transaction_number;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_by := auth.uid();
    new.updated_at := now();
    if old.deleted_at is not null and new.deleted_at is null and not public.has_role(auth.uid(),'admin') then
      raise exception 'Only admins can restore deleted expenses';
    end if;
    if old.deleted_at is null and new.deleted_at is not null then
      if coalesce(trim(new.deletion_reason),'') = '' then raise exception 'A deletion reason is required'; end if;
      new.deleted_by := auth.uid();
      new.deleted_at := now();
    end if;
    if new.deleted_at is null then new.deleted_by := null; new.deletion_reason := null; end if;
  end if;
  if new.expense_date > current_date + 365 or new.expense_date < date '2000-01-01' then
    raise exception 'Expense date is out of range';
  end if;
  return new;
end $$;
create trigger expenses_before before insert or update on public.expenses for each row execute function public.expenses_before();

create or replace function public.audit_trigger() returns trigger language plpgsql security definer set search_path = public as $$
declare act text; uname text; o jsonb; n jsonb; eid text; hdr jsonb;
begin
  select coalesce(full_name, email) into uname from public.profiles where id = auth.uid();
  begin hdr := current_setting('request.headers', true)::jsonb; exception when others then hdr := null; end;
  if tg_op = 'INSERT' then act := 'create'; n := to_jsonb(new); eid := (n->>'id');
  elsif tg_op = 'DELETE' then act := 'delete'; o := to_jsonb(old); eid := (o->>'id');
  else
    eid := (to_jsonb(new)->>'id');
    act := 'update';
    if tg_table_name = 'expenses' then
      if old.deleted_at is null and new.deleted_at is not null then act := 'delete';
      elsif old.deleted_at is not null and new.deleted_at is null then act := 'restore'; end if;
    end if;
    select jsonb_object_agg(k, to_jsonb(old)->k) into o from jsonb_object_keys(to_jsonb(new)) k where (to_jsonb(old)->k) is distinct from (to_jsonb(new)->k) and k not in ('updated_at','updated_by');
    select jsonb_object_agg(k, to_jsonb(new)->k) into n from jsonb_object_keys(to_jsonb(new)) k where (to_jsonb(old)->k) is distinct from (to_jsonb(new)->k) and k not in ('updated_at','updated_by');
    if n is null then return new; end if;
  end if;
  if tg_table_name = 'settlements' and act = 'create' then act := 'settlement'; end if;
  insert into public.audit_logs(user_id, user_name, action, entity, entity_id, old_values, new_values, metadata)
  values (auth.uid(), uname, act, tg_table_name, eid, o, n,
    jsonb_build_object('user_agent', hdr->>'user-agent', 'ip', hdr->>'x-forwarded-for'));
  return coalesce(new, old);
end $$;
create trigger audit after insert or update or delete on public.expenses for each row execute function public.audit_trigger();
create trigger audit after insert or update or delete on public.campaigns for each row execute function public.audit_trigger();
create trigger audit after insert or update or delete on public.people for each row execute function public.audit_trigger();
create trigger audit after insert or update or delete on public.expense_categories for each row execute function public.audit_trigger();
create trigger audit after insert or update or delete on public.settlements for each row execute function public.audit_trigger();
create trigger audit after insert or update or delete on public.candidates for each row execute function public.audit_trigger();
create trigger audit after update on public.app_settings for each row execute function public.audit_trigger();

create policy "receipts read" on storage.objects for select to authenticated using (bucket_id = 'receipts' and public.has_any_role(auth.uid(), array['admin','manager','staff','viewer']::app_role[]));
create policy "receipts upload" on storage.objects for insert to authenticated with check (bucket_id = 'receipts' and public.has_any_role(auth.uid(), array['admin','manager','staff']::app_role[]));
create policy "receipts delete" on storage.objects for delete to authenticated using (bucket_id = 'receipts' and public.has_any_role(auth.uid(), array['admin','manager']::app_role[]));

insert into public.campaigns(id, name, code, description, start_date, end_date, status, budget, notes) values
 ('11111111-1111-1111-1111-111111111111','CGM Campaign — October 2026','CGM-2026-10','Demo seed campaign from spreadsheet','2026-10-01','2026-10-31','active',1000000,'DEMO / SEED DATA');
insert into public.people(id, name, role, notes) values
 ('22222222-0000-0000-0000-000000000001','Abdullah','Partner','DEMO / SEED DATA'),
 ('22222222-0000-0000-0000-000000000002','Hammad','Partner','DEMO / SEED DATA'),
 ('22222222-0000-0000-0000-000000000003','Awais','Partner','DEMO / SEED DATA');
insert into public.expense_categories(name) values ('Rent'),('Laptops'),('Server'),('Ringba'),('Standby'),('VOIP'),('Data'),('Dialer'),('BOTS'),('Numero'),('FB Ads'),('Other');

insert into public.expenses(campaign_id, expense_date, paid_by, category_id, description, amount, payment_method, notes)
select '11111111-1111-1111-1111-111111111111', d::date, p::uuid, (select id from public.expense_categories where name = c), descr, amt, 'Bank Transfer', 'DEMO / SEED DATA'
from (values
 ('2026-10-01','22222222-0000-0000-0000-000000000003','Ringba','Ringba account funding',300000),
 ('2026-10-02','22222222-0000-0000-0000-000000000003','Laptops','Laptops purchase',185000),
 ('2026-10-03','22222222-0000-0000-0000-000000000003','VOIP','VOIP credit',5000),
 ('2026-10-10','22222222-0000-0000-0000-000000000003','VOIP','VOIP credit top-up',10000),
 ('2026-10-02','22222222-0000-0000-0000-000000000002','Laptops','Laptop accessories',15000),
 ('2026-10-04','22222222-0000-0000-0000-000000000002','VOIP','VOIP credit',10000),
 ('2026-10-05','22222222-0000-0000-0000-000000000002','BOTS','Bots subscription',74790),
 ('2026-10-06','22222222-0000-0000-0000-000000000002','Data','Data leads',60000),
 ('2026-10-07','22222222-0000-0000-0000-000000000002','FB Ads','Facebook ads',2280),
 ('2026-10-08','22222222-0000-0000-0000-000000000002','Numero','Numero numbers',1182),
 ('2026-10-01','22222222-0000-0000-0000-000000000002','Rent','Office rent share',50000),
 ('2026-10-01','22222222-0000-0000-0000-000000000001','Rent','Office rent share',50000),
 ('2026-10-04','22222222-0000-0000-0000-000000000001','VOIP','VOIP credit',25000)
) v(d,p,c,descr,amt);

insert into public.candidates(name, experience, mock_call_status, salary, notes) values
 ('Lubna Perviz','Fresh','pending','35+5','DEMO / SEED DATA'),
 ('Romaisa Abbasi','8 months as fronter and 2 months as verifier','pending','40+5','DEMO / SEED DATA'),
 ('M. Assaq Kiani','Fresh','pending','25+5','DEMO / SEED DATA'),
 ('Ahtasham Imtiaz','6 months in ACA and HI','pending','45+5','DEMO / SEED DATA'),
 ('Syed Khobaib','1.5 years','pending','60+5','DEMO / SEED DATA'),
 ('Adan Irfan','Fresh','done','30+5','DEMO / SEED DATA'),
 ('Zubaira Abbasi','2 months in Auto','pending','30+5','DEMO / SEED DATA'),
 ('Sherish','ACA 1 year & SSDI 1 year','pending','45+5','DEMO / SEED DATA'),
 ('Hashir','2 years','pending','50+5','DEMO / SEED DATA');
