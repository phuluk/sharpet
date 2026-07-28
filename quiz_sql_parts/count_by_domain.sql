select domain, count(*) as question_count
from public.quiz_questions
group by domain
order by question_count desc;
