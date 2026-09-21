-- Ek 2: ürün galerisi (birden fazla fotoğraf)
-- fotolar: fotoğraf URL'leri dizisi; ilk öğe kapak. Eski "foto" alanı
-- kapakla eşit tutulur (geriye uyumluluk).
alter table public.urunler add column if not exists fotolar jsonb not null default '[]'::jsonb;

-- Mevcut tek fotoğrafları galeriye taşı
update public.urunler
   set fotolar = jsonb_build_array(foto)
 where foto <> '' and (fotolar is null or fotolar = '[]'::jsonb);
