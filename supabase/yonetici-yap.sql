-- Bir üyeyi yönetici yapar. Önce o e-postayla siteden üye olunmuş olmalı.
-- E-postayı değiştirip SQL Editor'da çalıştır.
insert into public.yoneticiler (user_id)
select id from auth.users where email = 'mhmterdm55@gmail.com'
on conflict (user_id) do nothing;

-- Kontrol:
select u.email, y.created_at as yonetici_oldu
from public.yoneticiler y join auth.users u on u.id = y.user_id;
