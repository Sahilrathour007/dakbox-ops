-- OPTIONAL: example trucks for testing the operations site. Driver names are made up.
-- Run after schema.sql. Delete them later with:
--   delete from public.trucks where driver_name like '%(example)';
insert into public.trucks (truck_no, driver_name, capacity_kg, load_kg, status) values
 ('DL01LA4521','Ramesh (example)',1500,300,'available'),
 ('DL1LB2209', 'Suresh (example)',1000,990,'available'),
 ('HR55AK7781','Imran (example)', 2500,0,  'available'),
 ('UP16BT3390','Vikram (example)',1000,0,  'off_duty'),
 ('DL1LC0912', 'Manoj (example)', 1500,0,  'available'),
 ('MH02CR5512','Santosh (example)',1500,200,'available'),
 ('MH04GH8823','Prakash (example)',2500,0, 'available'),
 ('MH01DE4410','Anil (example)',  1000,0,  'available')
on conflict (truck_no) do nothing;

-- One starting GPS position each. DL1LC0912's is 40 minutes old, to show the "old GPS" rule.
insert into public.gps_pings (truck_no, lat, lon, speed_kmph, recorded_at, source) values
 ('DL01LA4521',28.5480,77.2690,0,now(),'manual'),
 ('DL1LB2209', 28.7350,77.1080,0,now(),'manual'),
 ('HR55AK7781',28.4650,77.0300,0,now(),'manual'),
 ('UP16BT3390',28.5720,77.3180,0,now(),'manual'),
 ('DL1LC0912', 28.7010,77.1350,0,now() - interval '40 minutes','manual'),
 ('MH02CR5512',19.1150,72.8650,0,now(),'manual'),
 ('MH04GH8823',19.1950,72.9700,0,now(),'manual'),
 ('MH01DE4410',18.9350,72.8380,0,now(),'manual');
