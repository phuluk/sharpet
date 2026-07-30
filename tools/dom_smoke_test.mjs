/* Sharpet — headless smoke test for app.html + assets/app.js.
 *
 * Loads the real page in jsdom with a stubbed Supabase client and drives it the
 * way a player would: pick a domain, pass the captcha, answer, switch language
 * mid-quiz, finish. Two passes — once as a guest, once signed in — because the
 * two differ in exactly the places that matter (session creation, reporting,
 * where the final score comes from).
 *
 * This checks what the browser would actually render, which the static analysis
 * in check_frontend.py cannot.
 *
 *   npm install --no-save jsdom
 *   node tools/dom_smoke_test.mjs
 */
import { JSDOM } from 'jsdom';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(ROOT, p), 'utf8');

let failures = 0;
function check(label, ok) {
  console.log(`${ok ? 'PASS ' : 'FAIL '} ${label}`);
  if (!ok) failures++;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------ stub backend
const QUESTIONS = [
  {
    question_id: 101, domain_id: 1,
    texts: { en: 'Capital of Austria?', de: 'Hauptstadt von Österreich?', cs: 'Hlavní město Rakouska?' },
    options: { en: ['Graz', 'Vienna', 'Linz'], de: ['Graz', 'Wien', 'Linz'], cs: ['Štýrský Hradec', 'Vídeň', 'Linec'] }
  },
  {
    question_id: 102, domain_id: 1,
    texts: { en: 'Largest planet?', de: 'Größter Planet?', cs: 'Největší planeta?' },
    options: { en: ['Mars', 'Jupiter', 'Venus'], de: ['Mars', 'Jupiter', 'Venus'], cs: ['Mars', 'Jupiter', 'Venuše'] }
  }
];
const CORRECT = {
  101: { en: 'Vienna', de: 'Wien', cs: 'Vídeň' },
  102: { en: 'Jupiter', de: 'Jupiter', cs: 'Jupiter' }
};
const USER = { id: 'user-1', email: 'peter@example.test' };

function boot({ loggedIn, url = 'https://sharpet.test/app.html?mode=guest' }) {
  const calls = [];

  const query = (name) => {
    const chain = {
      select() { return chain; },
      eq() { return chain; },
      gte() { return chain; },
      in() { return chain; },
      order() { return chain; },
      limit() { return chain; },
      maybeSingle: () => Promise.resolve({
        data: name === 'profiles' ? { display_name: 'Peter' } : null, error: null
      }),
      then(resolve) {
        if (name === 'domain_translations') {
          return resolve({
            data: [
              { domain_id: 1, name: 'Pharmacy', domains: { id: 1, color: '#4FD1FF' } },
              { domain_id: 2, name: 'Geography', domains: { id: 2, color: '#FF5D73' } }
            ],
            error: null
          });
        }
        return resolve({ data: [], error: null, count: 0 });
      }
    };
    return chain;
  };

  const client = {
    auth: {
      getSession: () => Promise.resolve({
        data: { session: loggedIn ? { user: USER } : null }, error: null
      }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: () => Promise.resolve({ error: null }),
      signInWithPassword: (args) => {
        calls.push({ name: 'signInWithPassword', args });
        return Promise.resolve({ data: { session: { user: USER }, user: USER }, error: null });
      },
      signUp: (args) => {
        calls.push({ name: 'signUp', args });
        return Promise.resolve({ data: { session: null, user: USER }, error: null });
      }
    },
    from: (name) => { calls.push({ name: 'from:' + name }); return query(name); },
    rpc(name, args) {
      calls.push({ name, args });
      if (name === 'get_quiz_questions') return Promise.resolve({ data: QUESTIONS, error: null });
      if (name === 'start_quiz_session') return Promise.resolve({ data: 'session-1', error: null });
      if (name === 'submit_quiz_answer') {
        const answer = CORRECT[args.p_question_id][args.p_language];
        return Promise.resolve({
          data: { is_correct: args.p_selected_option === answer, correct_option: answer },
          error: null
        });
      }
      if (name === 'finish_quiz_session') {
        // Deliberately disagrees with the client's own tally — the UI must
        // trust this, not the number it has been counting.
        return Promise.resolve({ data: { correct_count: 1, total_answered: 2 }, error: null });
      }
      if (name === 'report_question') return Promise.resolve({ data: null, error: null });
      return Promise.resolve({ data: null, error: null });
    }
  };

  const html = read('app.html').replace(/<script src="[^"]*"(?: defer)?><\/script>/g, '');
  const dom = new JSDOM(html, {
    runScripts: 'dangerously',
    url,
    pretendToBeVisual: true
  });
  const { window } = dom;
  window.eval(read('assets/i18n.js'));
  window.eval(read('assets/config.js'));
  window.supabase = { createClient: () => client };
  window.eval(read('assets/app.js'));

  const doc = window.document;
  return {
    window, calls,
    $: (id) => doc.getElementById(id),
    visible: (id) => doc.getElementById('screen-' + id).classList.contains('active'),
    click: (el) => el.dispatchEvent(new window.MouseEvent('click', { bubbles: true })),
    submit: (id) => doc.getElementById(id)
      .dispatchEvent(new window.Event('submit', { bubbles: true, cancelable: true }))
  };
}

async function solveCaptcha(ctx) {
  const [, a, b] = ctx.$('captcha-question').textContent.match(/(\d+) \+ (\d+)/);
  ctx.$('captcha-input').value = String(Number(a) + Number(b));
  ctx.submit('captcha-form');
  await sleep(60);
}

// ======================================================================
console.log('--- guest ---');
// ======================================================================
{
  const ctx = boot({ loggedIn: false });
  const { $, click, visible, calls } = ctx;
  await sleep(60);

  check('?mode=guest lands on the setup screen', visible('setup'));
  check('domain pills are rendered from the database', $('domain-pills').querySelectorAll('.pill').length === 3);
  check('start is disabled until a domain is picked', $('start-btn').disabled === true);
  check('static markup is translated on load', $('setup-hint').textContent.length > 0);

  click($('domain-pills').querySelector('.pill'));
  check('picking a domain enables start', $('start-btn').disabled === false);
  check('the picked pill is marked pressed', $('domain-pills').querySelector('.pill').getAttribute('aria-pressed') === 'true');

  click($('start-btn'));
  check('start goes to the captcha', visible('captcha'));
  check('the captcha shows a challenge', /\d \+ \d = \?/.test($('captcha-question').textContent));

  $('captcha-input').value = '999';
  ctx.submit('captcha-form');
  await sleep(20);
  check('a wrong captcha leaves its error on screen', $('captcha-error').textContent.length > 0);
  check('a wrong captcha stays on the captcha screen', visible('captcha'));
  check('a wrong captcha issues a new challenge', $('captcha-input').value === '');

  await solveCaptcha(ctx);
  check('a correct captcha starts the quiz', visible('quiz'));
  check('questions come from the RPC, not a table read', calls.some((c) => c.name === 'get_quiz_questions'));
  check('a guest starts no server-side session', !calls.some((c) => c.name === 'start_quiz_session'));
  check('the question is rendered', $('q-text').textContent === 'Capital of Austria?');
  check('all three options are rendered', $('q-opts').children.length === 3);
  check('a guest is not shown a report button', $('report-btn').classList.contains('is-hidden'));
  check('next is blocked before validating', $('next-btn').disabled === true);
  check('back is hidden on question 1', $('back-btn').classList.contains('is-invisible'));

  click($('q-opts').children[0]);
  check('selecting marks the option', $('q-opts').children[0].classList.contains('selected'));
  click($('validate-btn'));
  await sleep(40);

  const submitted = calls.filter((c) => c.name === 'submit_quiz_answer').pop();
  check('grading happens on the server', submitted && submitted.args.p_selected_option === 'Graz');
  check('a guest submits no session id', submitted && submitted.args.p_session_id === null);
  check('the wrong pick is marked wrong', $('q-opts').children[0].classList.contains('wrong'));
  check('the right answer is revealed', $('q-opts').children[1].classList.contains('correct'));
  check('the snackbar reports failure', $('snackbar').classList.contains('bad'));
  check('the score stays at zero', $('q-score').textContent.includes('0/2'));
  check('next unlocks after validating', $('next-btn').disabled === false);
  check('answered options stop responding', $('q-opts').classList.contains('locked'));

  ctx.window.setLang('de');
  await sleep(40);
  check('switching language translates the question', $('q-text').textContent === 'Hauptstadt von Österreich?');
  check('option order survives the language switch', $('q-opts').children[1].textContent === 'Wien');
  check('the revealed answer follows the language', $('q-opts').children[1].classList.contains('correct'));
  check('the wrong pick is still marked after the switch', $('q-opts').children[0].classList.contains('wrong'));
  check('no refetch was needed to change language',
    calls.filter((c) => c.name === 'get_quiz_questions').length === 1);
  ctx.window.setLang('en');
  await sleep(40);

  click($('next-btn'));
  await sleep(20);
  check('next advances', $('q-text').textContent === 'Largest planet?');
  check('back is available from question 2', !$('back-btn').classList.contains('is-invisible'));

  click($('q-opts').children[1]);
  click($('validate-btn'));
  await sleep(40);
  check('a correct answer scores', $('q-score').textContent.includes('1/2'));

  click($('next-btn'));
  await sleep(40);
  check('finishing shows the summary', visible('summary'));
  check('a guest score is computed locally', $('sum-correct').textContent === '1/2');
  check('the summary shows accuracy', $('sum-accuracy').textContent === '50%');
  check('a guest never calls finish_quiz_session', !calls.some((c) => c.name === 'finish_quiz_session'));
  check('a guest is told nothing was saved', $('summary-note').textContent.length > 0);
  check('a guest gets no stats button', $('view-stats-btn').classList.contains('is-hidden'));
  check('rendered text is never parsed as markup', $('q-opts').innerHTML.indexOf('<script') === -1);
}

// ======================================================================
console.log('\n--- sign-up form ---');
// ======================================================================
{
  const ctx = boot({ loggedIn: false, url: 'https://sharpet.test/app.html?mode=login' });
  const { $, click, visible } = ctx;
  await sleep(60);

  check('?mode=login lands on the login screen', visible('login'));
  check('log in hides the password rules', $('login-pw-rules').classList.contains('is-hidden'));

  click($('login-toggle'));
  check('sign up shows the password rules', !$('login-pw-rules').classList.contains('is-hidden'));
  check('all four rules are listed', $('login-pw-rules').querySelectorAll('[data-rule]').length === 4);
  check('the rules are translated', $('login-pw-rules').firstElementChild.textContent.length > 3);

  const type = (value) => {
    $('login-password').value = value;
    $('login-password').dispatchEvent(new ctx.window.Event('input', { bubbles: true }));
  };
  const met = () => Array.from($('login-pw-rules').querySelectorAll('.ok'))
    .map((li) => li.getAttribute('data-rule')).sort().join(',');

  type('abc');
  check('a short password satisfies nothing', met() === '');
  type('dlouheheslo');
  check('length alone ticks only the length rule', met() === 'length');
  type('DlouheHeslo1');
  check('mixed case and a digit tick three rules', met() === 'case,digit,length');
  type('DlouheHeslo1!');
  check('adding a symbol ticks all four', met() === 'case,digit,length,symbol');

  // The whole point: the form must reject what Supabase would reject.
  $('login-email').value = 'peter@example.test';
  $('login-nickname').value = 'peter_h';
  type('dlouheheslo');
  ctx.submit('login-form');
  await sleep(40);
  check('a rules-violating password is blocked before it reaches the server',
    $('login-password-error').textContent.length > 0);
  check('the error names the requirements rather than just the length',
    !/10/.test($('login-password-error').textContent));

  // Logging in must NOT apply the rules — legacy accounts have weaker passwords.
  click($('login-toggle'));
  await sleep(20);
  check('switching back to log in hides the rules again',
    $('login-pw-rules').classList.contains('is-hidden'));
  type('old6ch');
  ctx.submit('login-form');
  await sleep(60);
  check('a legacy short password is still accepted by the log-in form',
    $('login-password-error').textContent === '');
  check('the log-in attempt actually reached the auth call',
    ctx.calls.some((c) => c.name === 'signInWithPassword'));
}

// ======================================================================
console.log('\n--- signed in ---');
// ======================================================================
{
  const ctx = boot({ loggedIn: true, url: 'https://sharpet.test/app.html' });
  const { $, click, visible, calls } = ctx;
  await sleep(80);

  check('an existing session lands on the dashboard', visible('home'));
  check('the profile menu appears', !$('profile-menu').classList.contains('is-hidden'));
  check('the display name comes from the profile', $('nav-nickname').textContent === 'Peter');
  check('the avatar shows initials', $('nav-avatar').textContent === 'PE');
  check('empty stats render as a dash, not NaN', $('stat-7d').textContent === '–');
  check('an empty history disables "view all"', $('history-view-all').disabled === true);

  click(doc$(ctx, '[data-action="go-setup"]'));
  check('play goes to setup', visible('setup'));

  click($('domain-pills').querySelector('.pill'));
  click($('start-btn'));
  await solveCaptcha(ctx);

  check('a signed-in player gets a server-side session', calls.some((c) => c.name === 'start_quiz_session'));
  check('a signed-in player can report a question', !$('report-btn').classList.contains('is-hidden'));

  click($('report-btn'));
  await sleep(30);
  const report = calls.filter((c) => c.name === 'report_question').pop();
  check('reporting goes through the RPC', !!report);
  check('the report carries no client-supplied user id', report && !('p_user_id' in report.args));
  check('the report is acknowledged in the UI', $('snackbar').classList.contains('info'));

  click($('q-opts').children[1]);
  click($('validate-btn'));
  await sleep(40);
  const submitted = calls.filter((c) => c.name === 'submit_quiz_answer').pop();
  check('the answer is tied to the server session', submitted && submitted.args.p_session_id === 'session-1');
  check('the answer carries no is_correct claim', submitted && !('p_is_correct' in submitted.args));

  click($('next-btn'));
  await sleep(20);
  click($('q-opts').children[1]);
  click($('validate-btn'));
  await sleep(40);
  click($('next-btn'));
  await sleep(60);

  check('finishing shows the summary', visible('summary'));
  check('the summary uses the server totals, not the local tally',
    $('sum-correct').textContent === '1/2');
  check('a signed-in player is told it was saved', $('summary-note').textContent.length > 0);
  check('a signed-in player gets the stats button', !$('view-stats-btn').classList.contains('is-hidden'));
}

function doc$(ctx, selector) {
  return ctx.$('screen-home').querySelector(selector);
}

console.log(failures ? `\n${failures} failure(s)` : '\nall DOM smoke tests passed');
process.exit(failures ? 1 : 0);
