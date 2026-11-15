-- 56 (data, 2026-11-15): owner's answers on the 12→14 accounts. Backups: taxi_backup.fix_20261115_cash / _ledger.
--  * Ali: advance #19 (25,000, 12/11) was paid by the office and Ali returned it on 13/11 (Hamza's 25,000 "سلفه" receipt #45).
--    -> #19 not from cash + marked received 13/11 by حمزة; receipt #45 deleted (it was the advance coming back, not fares).
--  * Haidar: advances #20 (5,000) and #22 (20,000) were paid by the office (he handed in his fares) -> from_cash = false.
--  * Farouq: the 221,000 of 14/11 was received in full; the remark is information only.
update taxi_ledger set from_cash=false, deducted_at='2026-11-13 20:31:09+03', deducted_by='حمزة',
  note='سلفه شخصيه · رجّعها 13/11 (استلمها حمزة)' where id=19;
delete from taxi_cash where id=45;
update taxi_ledger set from_cash=false where id in (20,22);

-- later the same day (owner):
--  * Wisam's advances #18 (20,000), #21 (8,000 from cash), #23 (17,000) deleted. Backup: taxi_backup.wisam_adv_del_20261115.
--  * Wisam's receipt #44 (13/11, Hamza) 221,000 -> 229,000 (what he settled up to 13/11). Backup: taxi_backup.wisam_cash44_20261115.
--    His balance is then 14/11 + 15/11 fares only.
--  * حسام added to taxi_ledger_people (staff expenses/advances, like حمزة).
