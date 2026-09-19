-- ============================================================
-- Lure İç Giyim — Supabase veritabanı şeması
-- Supabase Dashboard → SQL Editor içine yapıştırıp çalıştır.
-- Tekrar çalıştırılabilir (varsa yeniden oluşturur).
-- ============================================================

-- ---------- ÜRÜNLER ----------
create table if not exists public.urunler (
  id          text primary key,
  ad          text not null default '',
  cat         text not null default '',
  tag         text not null default '',
  fiyat       numeric(10,2),
  art         text not null default 'sutyen',
  foto        text not null default '',
  aciklama    text not null default '',
  stok        jsonb not null default '{"XS":0,"S":0,"M":0,"L":0,"XL":0}'::jsonb,
  sira        integer not null default 0,
  aktif       boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- YÖNETİCİLER ----------
-- Bu tabloda user_id'si olan hesap yönetim panelini kullanabilir.
create table if not exists public.yoneticiler (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create or replace function public.yonetici_mi()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.yoneticiler where user_id = auth.uid());
$$;

-- ---------- ÜYE PROFİLLERİ ----------
create table if not exists public.profiller (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  ad          text not null default '',
  soyad       text not null default '',
  telefon     text not null default '',
  eposta      text not null default '',
  created_at  timestamptz not null default now()
);

-- Üye olunca profil satırı kendiliğinden açılsın
create or replace function public.yeni_kullanici()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.profiller (user_id, ad, soyad, telefon, eposta)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'ad', ''),
    coalesce(new.raw_user_meta_data->>'soyad', ''),
    coalesce(new.raw_user_meta_data->>'telefon', ''),
    coalesce(new.email, '')
  )
  on conflict (user_id) do nothing;

  -- Mağaza sahibinin e-postası: üye olduğu anda yönetici olsun
  if lower(coalesce(new.email, '')) in ('mhmterdm55@gmail.com') then
    insert into public.yoneticiler (user_id) values (new.id) on conflict (user_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.yeni_kullanici();

-- ---------- SİPARİŞLER ----------
create table if not exists public.siparisler (
  id            bigint generated always as identity primary key,
  user_id       uuid references auth.users(id) on delete set null,
  durum         text not null default 'alindi',   -- alindi | hazirlaniyor | kargoda | teslim | iptal
  toplam        numeric(10,2) not null default 0,
  ad_soyad      text not null default '',
  telefon       text not null default '',
  adres         text not null default '',
  musteri_notu  text not null default '',
  created_at    timestamptz not null default now()
);

create table if not exists public.siparis_satirlari (
  id          bigint generated always as identity primary key,
  siparis_id  bigint not null references public.siparisler(id) on delete cascade,
  urun_id     text,
  urun_ad     text not null default '',
  beden       text not null default '',
  adet        integer not null default 1,
  fiyat       numeric(10,2)
);

create index if not exists siparisler_user_idx on public.siparisler(user_id, created_at desc);
create index if not exists satirlar_siparis_idx on public.siparis_satirlari(siparis_id);

-- ---------- GÜVENLİK (RLS) ----------
alter table public.urunler           enable row level security;
alter table public.yoneticiler       enable row level security;
alter table public.profiller         enable row level security;
alter table public.siparisler        enable row level security;
alter table public.siparis_satirlari enable row level security;

-- Ürünler: herkes okur, yalnızca yönetici yazar
drop policy if exists "urunler herkese acik"      on public.urunler;
drop policy if exists "urunler yonetici ekler"    on public.urunler;
drop policy if exists "urunler yonetici gunceller" on public.urunler;
drop policy if exists "urunler yonetici siler"    on public.urunler;
create policy "urunler herkese acik"       on public.urunler for select using (true);
create policy "urunler yonetici ekler"     on public.urunler for insert with check (public.yonetici_mi());
create policy "urunler yonetici gunceller" on public.urunler for update using (public.yonetici_mi());
create policy "urunler yonetici siler"     on public.urunler for delete using (public.yonetici_mi());

-- Yöneticiler: herkes yalnızca kendi kaydını görebilir
drop policy if exists "yonetici kendini gorur" on public.yoneticiler;
create policy "yonetici kendini gorur" on public.yoneticiler for select using (user_id = auth.uid());

-- Profiller: kişi kendininkini okur/günceller, yönetici hepsini okur
drop policy if exists "profil okur"      on public.profiller;
drop policy if exists "profil gunceller" on public.profiller;
create policy "profil okur"      on public.profiller for select using (user_id = auth.uid() or public.yonetici_mi());
create policy "profil gunceller" on public.profiller for update using (user_id = auth.uid());

-- Siparişler: kişi kendininkini görür, yönetici hepsini görür ve durumunu günceller.
-- Sipariş oluşturma yalnızca siparis_ver() fonksiyonuyla yapılır (stok kontrolü için).
drop policy if exists "siparis okur"      on public.siparisler;
drop policy if exists "siparis gunceller" on public.siparisler;
create policy "siparis okur"      on public.siparisler for select using (user_id = auth.uid() or public.yonetici_mi());
create policy "siparis gunceller" on public.siparisler for update using (public.yonetici_mi());

drop policy if exists "satir okur" on public.siparis_satirlari;
create policy "satir okur" on public.siparis_satirlari for select
  using (exists (
    select 1 from public.siparisler s
    where s.id = siparis_id and (s.user_id = auth.uid() or public.yonetici_mi())
  ));

-- ---------- SİPARİŞ VERME ----------
-- Sepetteki satırları alır, stoğu kontrol eder, siparişi kaydeder ve
-- stoğu düşer — hepsi tek işlemde. Yetersiz stokta hata verir, hiçbir
-- şey yazılmaz.
create or replace function public.siparis_ver(
  satirlar      jsonb,
  ad_soyad      text,
  telefon       text,
  adres         text,
  musteri_notu  text default ''
)
returns bigint
language plpgsql security definer
set search_path = public
as $$
declare
  s        jsonb;
  u        public.urunler%rowtype;
  kalan    integer;
  adet     integer;
  yeni_id  bigint;
  toplam   numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Sipariş vermek için giriş yapmalısın.';
  end if;
  if satirlar is null or jsonb_typeof(satirlar) <> 'array' or jsonb_array_length(satirlar) = 0 then
    raise exception 'Sepet boş.';
  end if;
  if coalesce(trim(ad_soyad), '') = '' or coalesce(trim(adres), '') = '' then
    raise exception 'Ad soyad ve adres zorunlu.';
  end if;

  -- 1) Stok kontrolü (satırları kilitleyerek)
  for s in select * from jsonb_array_elements(satirlar) loop
    adet := greatest(1, coalesce((s->>'adet')::int, 1));
    select * into u from public.urunler where id = s->>'id' and aktif for update;
    if not found then
      raise exception 'Ürün bulunamadı: %', s->>'id';
    end if;
    kalan := coalesce((u.stok->>(s->>'beden'))::int, 0);
    if kalan < adet then
      raise exception '"%" ürününün % bedeninde yeterli stok yok (kalan: %).',
        coalesce(nullif(u.ad,''), u.id), s->>'beden', kalan;
    end if;
    toplam := toplam + coalesce(u.fiyat, 0) * adet;
  end loop;

  -- 2) Sipariş başlığı
  insert into public.siparisler (user_id, toplam, ad_soyad, telefon, adres, musteri_notu)
  values (auth.uid(), toplam, trim(ad_soyad), coalesce(trim(telefon),''), trim(adres), coalesce(musteri_notu,''))
  returning id into yeni_id;

  -- 3) Satırlar + stok düşümü
  for s in select * from jsonb_array_elements(satirlar) loop
    adet := greatest(1, coalesce((s->>'adet')::int, 1));
    select * into u from public.urunler where id = s->>'id';
    insert into public.siparis_satirlari (siparis_id, urun_id, urun_ad, beden, adet, fiyat)
    values (yeni_id, u.id, u.ad, s->>'beden', adet, u.fiyat);
    update public.urunler
       set stok = jsonb_set(
                    stok,
                    array[s->>'beden'],
                    to_jsonb(greatest(0, coalesce((stok->>(s->>'beden'))::int, 0) - adet))
                  ),
           updated_at = now()
     where id = u.id;
  end loop;

  return yeni_id;
end;
$$;

-- ---------- FOTOĞRAF DEPOSU ----------
insert into storage.buckets (id, name, public)
values ('urun-fotolari', 'urun-fotolari', true)
on conflict (id) do nothing;

drop policy if exists "foto herkes gorur"       on storage.objects;
drop policy if exists "foto yonetici yukler"    on storage.objects;
drop policy if exists "foto yonetici gunceller" on storage.objects;
drop policy if exists "foto yonetici siler"     on storage.objects;
create policy "foto herkes gorur"       on storage.objects for select using (bucket_id = 'urun-fotolari');
create policy "foto yonetici yukler"    on storage.objects for insert with check (bucket_id = 'urun-fotolari' and public.yonetici_mi());
create policy "foto yonetici gunceller" on storage.objects for update using (bucket_id = 'urun-fotolari' and public.yonetici_mi());
create policy "foto yonetici siler"     on storage.objects for delete using (bucket_id = 'urun-fotolari' and public.yonetici_mi());
