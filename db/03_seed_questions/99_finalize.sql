-- ============================================================
-- Sharpet — question seed, finalize
-- GENERATED FILE — do not edit by hand.
--
-- Run this LAST, after every numbered part.
-- ============================================================

-- Questions the current seed leaves out are retired, not deleted, so any
-- historical quiz_answers keep their foreign key.
update public.questions set is_active = false
 where id > 6059 or id in (110, 146, 4563, 4564, 4565, 4566, 4567, 4568, 4569, 4570, 4571, 4572, 4573, 4574, 4575, 4576, 4577, 4578, 4579, 4580, 4581, 4582, 4583, 4584, 4585, 4586, 4587, 4588, 4589, 4590, 4591, 4592, 4593, 4594, 4595, 4596, 4597, 4598, 4599, 4600, 4601, 4602, 6001, 6026);

-- Their translations, on the other hand, are dead weight: nothing points
-- at them and the RLS policy on question_translations already hides rows
-- whose question is inactive. Scoped to exactly the ids this seed drops,
-- so a question an admin deactivated by hand keeps its text.
delete from public.question_translations
 where question_id in (select id from public.questions where id > 6059 or id in (110, 146, 4563, 4564, 4565, 4566, 4567, 4568, 4569, 4570, 4571, 4572, 4573, 4574, 4575, 4576, 4577, 4578, 4579, 4580, 4581, 4582, 4583, 4584, 4585, 4586, 4587, 4588, 4589, 4590, 4591, 4592, 4593, 4594, 4595, 4596, 4597, 4598, 4599, 4600, 4601, 4602, 6001, 6026));

-- Keep the sequence ahead of the seeded ids.
select setval('public.questions_id_seq',
              (select coalesce(max(id), 1) from public.questions));
