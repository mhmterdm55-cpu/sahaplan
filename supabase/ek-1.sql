-- ============================================================
-- Ek 1: kargo ayarları, iptalde stok iadesi, kargo takibi,
--       indirimli fiyat, adres hatırlama
-- schema.sql'den SONRA, SQL Editor'da bir kez çalıştır.
-- ============================================================

-- ---------- AYARLAR (anahtar/değer) ----------
create table if not exists public.ayarlar (
  anahtar     text primary key,
  deger       jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);
alter table public.ayarlar enable row level security;
drop policy if exists "ayar herkes okur"      on public.ayarlar;
drop policy if exists "ayar yonetici yazar"   on public.ayarlar;
drop policy if exists "ayar yonetici ekler"   on public.ayarlar;
create policy "ayar herkes okur"    on public.ayarlar for select using (true);
create policy "ayar yonetici yazar" on public.ayarlar for update using (public.yonetici_mi());
create policy "ayar yonetici ekler" on public.ayarlar for insert with check (public.yonetici_mi());

insert into public.ayarlar (anahtar, deger)
values ('kargo', '{"ucret": 79.90, "bedava_esik": 1500}'::jsonb)
on conflict (anahtar) do nothing;

-- ---------- YENİ SÜTUNLAR ----------
alter table public.urunler    add column if not exists eski_fiyat   numeric(10,2);
alter table public.siparisler add column if not exists ara_toplam   numeric(10,2) not null default 0;
alter table public.siparisler add column if not exists kargo_ucreti numeric(10,2) not null default 0;
alter table public.siparisler add column if not exists kargo_firma  text not null default '';
alter table public.siparisler add column if not exists takip_no     text not null default '';
alter table public.profiller  add column if not exists adres        text not null default '';

-- Profil güncelleme: kişi kendi satırına yazabilsin (update var; insert de olsun)
drop policy if exists "profil ekler" on public.profiller;
create policy "profil ekler" on public.profiller for insert with check (user_id = auth.uid());

-- ---------- SİPARİŞ VERME (kargo dahil) ----------
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
  ara      numeric := 0;
  kargo    numeric := 0;
  ayar     jsonb;
  v_adres  text := trim(adres);
  v_tel    text := coalesce(trim(telefon), '');
begin
  if auth.uid() is null then raise exception 'Sipariş vermek için giriş yapmalısın.'; end if;
  if satirlar is null or jsonb_typeof(satirlar) <> 'array' or jsonb_array_length(satirlar) = 0 then
    raise exception 'Sepet boş.';
  end if;
  if coalesce(trim(ad_soyad), '') = '' or coalesce(trim(adres), '') = '' then
    raise exception 'Ad soyad ve adres zorunlu.';
  end if;

  for s in select * from jsonb_array_elements(satirlar) loop
    adet := greatest(1, coalesce((s->>'adet')::int, 1));
    select * into u from public.urunler where id = s->>'id' and aktif for update;
    if not found then raise exception 'Ürün bulunamadı: %', s->>'id'; end if;
    kalan := coalesce((u.stok->>(s->>'beden'))::int, 0);
    if kalan < adet then
      raise exception '"%" ürününün % bedeninde yeterli stok yok (kalan: %).',
        coalesce(nullif(u.ad,''), u.id), s->>'beden', kalan;
    end if;
    ara := ara + coalesce(u.fiyat, 0) * adet;
  end loop;

  -- Kargo ücreti (ayarlardan)
  select deger into ayar from public.ayarlar where anahtar = 'kargo';
  if ayar is not null then
    if ara < coalesce((ayar->>'bedava_esik')::numeric, 0) then
      kargo := coalesce((ayar->>'ucret')::numeric, 0);
    end if;
  end if;

  insert into public.siparisler (user_id, ara_toplam, kargo_ucreti, toplam, ad_soyad, telefon, adres, musteri_notu)
  values (auth.uid(), ara, kargo, ara + kargo, trim(ad_soyad), coalesce(trim(telefon),''), trim(adres), coalesce(musteri_notu,''))
  returning id into yeni_id;

  for s in select * from jsonb_array_elements(satirlar) loop
    adet := greatest(1, coalesce((s->>'adet')::int, 1));
    select * into u from public.urunler where id = s->>'id';
    insert into public.siparis_satirlari (siparis_id, urun_id, urun_ad, beden, adet, fiyat)
    values (yeni_id, u.id, u.ad, s->>'beden', adet, u.fiyat);
    update public.urunler
       set stok = jsonb_set(stok, array[s->>'beden'],
                    to_jsonb(greatest(0, coalesce((stok->>(s->>'beden'))::int, 0) - adet))),
           updated_at = now()
     where id = u.id;
  end loop;

  -- Son adresi profile yaz (bir sonraki siparişte hazır gelsin)
  update public.profiller p
     set adres = v_adres,
         telefon = coalesce(nullif(v_tel, ''), p.telefon)
   where p.user_id = auth.uid();

  return yeni_id;
end;
$$;

-- ---------- İPTALDE STOK İADESİ ----------
-- Durum "iptal"e geçince satırlardaki adetler stoğa geri eklenir;
-- iptalden başka bir duruma dönerse yeniden düşülür.
create or replace function public.siparis_durum_stok()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  r record;
  yon integer := 0;
begin
  if new.durum = 'iptal' and old.durum <> 'iptal' then yon := 1;      -- iade
  elsif old.durum = 'iptal' and new.durum <> 'iptal' then yon := -1;  -- yeniden düş
  else return new; end if;

  for r in select urun_id, beden, adet from public.siparis_satirlari where siparis_id = new.id loop
    update public.urunler
       set stok = jsonb_set(stok, array[r.beden],
                    to_jsonb(greatest(0, coalesce((stok->>r.beden)::int, 0) + yon * r.adet))),
           updated_at = now()
     where id = r.urun_id;
  end loop;
  return new;
end;
$$;

drop trigger if exists siparis_durum_stok_trg on public.siparisler;
create trigger siparis_durum_stok_trg
  after update of durum on public.siparisler
  for each row execute function public.siparis_durum_stok();
