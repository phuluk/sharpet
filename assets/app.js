/* Sharpet — application logic.
 *
 * Extracted from the inline <script> in app.html so the page can run under a
 * Content-Security-Policy with no 'unsafe-inline'. For the same reason there
 * are no onclick="" attributes anywhere: every interactive element carries a
 * data-action and is dispatched from the single delegated listener at the
 * bottom of this file.
 *
 * All rendering goes through DOM APIs (createElement / textContent) rather
 * than innerHTML string building, so user- and database-supplied text can
 * never be parsed as markup.
 */
'use strict';

(function () {
  // ---------------------------------------------------------------- config
  var cfg = window.SHARPET_CONFIG || {};
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    throw new Error('assets/config.js is missing the Supabase project settings.');
  }
  var supabaseClient = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  // ----------------------------------------------------------------- state
  var DOMAINS = [];
  var MAX_DOMAINS = 5;
  var MIN_PASSWORD = 10;   // only enforced when *setting* a password
  var MAX_CAPTCHA_TRIES = 5;

  var state = {
    domains: [], numAnswers: 3, questions: [], current: 0,
    selected: null, validated: false, correctCount: 0, answered: [],
    captchaAnswer: 0, captchaTries: 0, sessionId: null, busy: false
  };
  var session = {
    isLoggedIn: false, email: null, userId: null,
    displayName: null, isSignupMode: false
  };
  var recoveryFlowActive = false;

  var EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
  var NICKNAME_REGEX = /^[A-Za-z0-9_]{5,32}$/;

  // ------------------------------------------------------------- utilities
  function $(id) { return document.getElementById(id); }

  function setText(id, value) {
    var el = $(id);
    if (el) el.textContent = value == null ? '' : String(value);
  }

  function show(el, visible) {
    if (el) el.classList.toggle('is-hidden', !visible);
  }

  function clearChildren(el) {
    while (el.firstChild) el.removeChild(el.firstChild);
  }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = String(text);
    return node;
  }

  function showToast(message, duration) {
    var container = $('toast-container');
    var node = el('div', 'toast', message);
    container.appendChild(node);
    requestAnimationFrame(function () { node.classList.add('show'); });
    window.setTimeout(function () {
      node.classList.remove('show');
      window.setTimeout(function () { node.remove(); }, 300);
    }, duration || 5000);
  }

  /* Supabase auth errors are deliberately not shown verbatim. Messages like
     "User already registered" turn the signup form into an account-existence
     oracle, which is exactly the enumeration we want to avoid. */
  function friendlyAuthError(error, fallbackKey) {
    if (!error) return '';
    var code = (error.code || '').toLowerCase();
    var message = (error.message || '').toLowerCase();
    if (code === 'over_email_send_rate_limit' || message.indexOf('rate limit') !== -1) {
      return t('err_rate_limited');
    }
    if (message.indexOf('weak') !== -1 || message.indexOf('password should be') !== -1) {
      return t('login_err_password_rules');
    }
    return t(fallbackKey);
  }

  /* These mirror the Supabase Auth password policy. Checking only the length
     here — as an earlier version did — meant a password like "dlouheheslo"
     passed the form and was then rejected by the server, leaving the user with
     a generic "sign-up failed" and no idea why. Keep the two in step. */
  var SYMBOLS = /[!@#$%^&*()_+\-=[\]{};'\\:"|<>?,./`~]/;

  function passwordRules(value) {
    value = value || '';
    return {
      length: value.length >= MIN_PASSWORD,
      case: /[a-z]/.test(value) && /[A-Z]/.test(value),
      digit: /\d/.test(value),
      symbol: SYMBOLS.test(value)
    };
  }

  function passwordIsValid(value) {
    var rules = passwordRules(value);
    return Object.keys(rules).every(function (k) { return rules[k]; });
  }

  function paintPasswordRules(listId, value) {
    var list = $(listId);
    if (!list) return;
    var rules = passwordRules(value);
    list.querySelectorAll('[data-rule]').forEach(function (item) {
      item.classList.toggle('ok', rules[item.getAttribute('data-rule')] === true);
    });
  }

  function bindPasswordRules(inputId, listId) {
    var input = $(inputId);
    if (!input || !$(listId)) return;
    input.addEventListener('input', function () {
      paintPasswordRules(listId, input.value);
    });
  }

  // ------------------------------------------------------------ navigation
  var LOGIN_SCREENS = { login: 1, 'reset-request': 1, 'reset-password': 1 };

  function showOnly(id) {
    var target = $('screen-' + id);
    if (!target) return;
    document.querySelectorAll('.screen').forEach(function (s) { s.classList.remove('active'); });
    target.classList.add('active');
    var main = $('main-area');
    if (main) {
      main.classList.toggle('dashboard-mode', id === 'home');
      main.classList.toggle('login-mode', Object.prototype.hasOwnProperty.call(LOGIN_SCREENS, id));
    }
  }

  function goExitHome() {
    if (session.isLoggedIn) showOnly('home');
    else window.location.href = 'index.html';
  }

  // ------------------------------------------------------------------ auth
  function clearLoginFieldErrors() {
    setText('login-error', '');
    setText('login-email-error', '');
    setText('login-nickname-error', '');
    setText('login-password-error', '');
  }

  function applyLoginModeText() {
    var signup = session.isSignupMode;
    setText('login-title', signup ? t('login_title_signup') : t('login_title'));
    setText('login-sub', signup ? t('login_sub_signup') : t('login_sub'));
    setText('login-submit', signup ? t('login_submit_signup') : t('login_submit'));
    setText('login-toggle', signup ? t('login_toggle_to_login') : t('login_toggle_to_signup'));
    show($('login-nickname-field'), signup);
    show($('login-forgot'), !signup);
    // The rules only apply when a password is being set, not when logging in.
    show($('login-pw-rules'), signup);
    if (signup) paintPasswordRules('login-pw-rules', $('login-password').value);
    var password = $('login-password');
    if (password) password.setAttribute('autocomplete', signup ? 'new-password' : 'current-password');
  }

  function toggleLoginMode() {
    session.isSignupMode = !session.isSignupMode;
    applyLoginModeText();
    clearLoginFieldErrors();
  }

  async function submitLogin(event) {
    if (event) event.preventDefault();
    if (state.busy) return;

    var email = $('login-email').value.trim();
    var nickname = $('login-nickname').value.trim();
    var password = $('login-password').value;
    var submitBtn = $('login-submit');
    var signup = session.isSignupMode;

    clearLoginFieldErrors();
    var hasError = false;

    if (!EMAIL_REGEX.test(email) || email.length > 254) {
      setText('login-email-error', t('login_err_email'));
      hasError = true;
    }
    if (signup && !NICKNAME_REGEX.test(nickname)) {
      setText('login-nickname-error', t('login_err_nickname'));
      hasError = true;
    }
    // The rules are only enforced when a password is being *set*. Applying them
    // on log in would lock out accounts created under the older, looser rule.
    if (signup ? !passwordIsValid(password) : password.length < 1) {
      setText('login-password-error', signup ? t('login_err_password_rules') : t('login_err_password_required'));
      hasError = true;
    }
    if (hasError) return;

    state.busy = true;
    submitBtn.disabled = true;
    try {
      var result = signup
        ? await supabaseClient.auth.signUp({
            email: email,
            password: password,
            options: { data: { display_name: nickname } }
          })
        : await supabaseClient.auth.signInWithPassword({ email: email, password: password });

      if (result.error) {
        setText('login-error', friendlyAuthError(result.error, signup ? 'err_signup_failed' : 'err_login_failed'));
        return;
      }
      if (signup && !result.data.session) {
        showToast(t('toast_signup_sent'));
        toggleLoginMode();
        return;
      }
      session.isLoggedIn = true;
      session.email = email;
      session.userId = result.data.user ? result.data.user.id : null;
      $('login-password').value = '';
      await loadProfileAndGoHome();
    } finally {
      state.busy = false;
      submitBtn.disabled = false;
      applyLoginModeText();
    }
  }

  function goResetRequest() {
    $('reset-request-email').value = '';
    setText('reset-request-error', '');
    setText('reset-request-email-error', '');
    showOnly('reset-request');
  }

  async function submitResetRequest(event) {
    if (event) event.preventDefault();
    if (state.busy) return;

    var email = $('reset-request-email').value.trim();
    var submitBtn = $('reset-request-submit');
    setText('reset-request-error', '');
    setText('reset-request-email-error', '');

    if (!EMAIL_REGEX.test(email) || email.length > 254) {
      setText('reset-request-email-error', t('login_err_email'));
      return;
    }

    state.busy = true;
    submitBtn.disabled = true;
    try {
      // The same toast is shown whether or not the address has an account, so
      // this form does not leak which e-mails are registered.
      await supabaseClient.auth.resetPasswordForEmail(email, {
        redirectTo: window.location.origin + window.location.pathname + '?mode=reset'
      });
    } finally {
      state.busy = false;
      submitBtn.disabled = false;
    }
    showToast(t('toast_reset_sent'));
    showOnly('login');
  }

  function clearResetPasswordErrors() {
    setText('reset-password-error', '');
    setText('reset-password-new-error', '');
    setText('reset-password-confirm-error', '');
  }

  async function submitResetPassword(event) {
    if (event) event.preventDefault();
    if (state.busy) return;

    var newPassword = $('reset-password-new').value;
    var confirmPassword = $('reset-password-confirm').value;
    var submitBtn = $('reset-password-submit');

    clearResetPasswordErrors();
    var hasError = false;

    if (!passwordIsValid(newPassword)) {
      setText('reset-password-new-error', t('login_err_password_rules'));
      hasError = true;
    }
    if (confirmPassword !== newPassword) {
      setText('reset-password-confirm-error', t('reset_err_mismatch'));
      hasError = true;
    }
    if (hasError) return;

    state.busy = true;
    submitBtn.disabled = true;
    var result;
    try {
      result = await supabaseClient.auth.updateUser({ password: newPassword });
    } finally {
      state.busy = false;
      submitBtn.disabled = false;
    }

    if (result.error) {
      setText('reset-password-error', friendlyAuthError(result.error, 'err_reset_failed'));
      return;
    }

    $('reset-password-new').value = '';
    $('reset-password-confirm').value = '';
    // Signing out everywhere invalidates any session an attacker may have
    // established with the old password.
    await supabaseClient.auth.signOut({ scope: 'global' });
    resetSessionState();
    recoveryFlowActive = false;
    showToast(t('toast_reset_success'));
    showOnly('login');
  }

  function resetSessionState() {
    session.isLoggedIn = false;
    session.email = null;
    session.userId = null;
    session.displayName = null;
    state.sessionId = null;
    show($('profile-menu'), false);
  }

  async function logOut() {
    closeProfileMenu();
    await supabaseClient.auth.signOut();
    resetSessionState();
    showOnly('landing');
  }

  async function loadProfileAndGoHome() {
    var displayName = session.email ? session.email.split('@')[0] : 'Player';
    if (session.userId) {
      var res = await supabaseClient
        .from('profiles').select('display_name').eq('id', session.userId).maybeSingle();
      if (res.data && res.data.display_name) displayName = res.data.display_name;
    }
    session.displayName = displayName;
    setText('nav-nickname', displayName);
    setText('nav-avatar', displayName.slice(0, 2).toUpperCase());
    show($('profile-menu'), true);
    showOnly('home');
    loadDashboardData();
  }

  // ------------------------------------------------------------- dashboard
  async function loadDashboardData() {
    if (!session.userId) return;

    var since30 = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    var answersRes = await supabaseClient
      .from('quiz_answers')
      .select('answered_at, is_correct, domain_id')
      .gte('answered_at', since30);
    if (answersRes.error) console.error('dashboard answers query failed:', answersRes.error);
    var answers = answersRes.data || [];

    renderAccuracyStats(answers);
    renderProgressChart(answers);
    renderWeakestDomains(answers);

    var totalRes = await supabaseClient
      .from('quiz_answers').select('id', { count: 'exact', head: true });
    if (totalRes.error) console.error('dashboard total-answered query failed:', totalRes.error);
    setText('stat-total', totalRes.count != null ? totalRes.count : '–');

    var streakRes = await supabaseClient
      .from('quiz_sessions').select('started_at').order('started_at', { ascending: true });
    if (streakRes.error) console.error('dashboard streak query failed:', streakRes.error);
    renderStreak(streakRes.data || []);

    var sessionsRes = await supabaseClient
      .from('quiz_sessions')
      .select('id, started_at, ended_at, domain_ids, correct_count, total_answered')
      .order('started_at', { ascending: false })
      .limit(5);
    if (sessionsRes.error) console.error('dashboard session-history query failed:', sessionsRes.error);
    renderSessionHistory(sessionsRes.data || []);

    loadAndRenderReportedQuestions();
  }

  function computeAccuracy(rows) {
    if (!rows.length) return null;
    var correct = rows.filter(function (r) { return r.is_correct; }).length;
    return Math.round((correct / rows.length) * 100);
  }

  function renderAccuracyStats(answers) {
    var sevenAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    var last7 = answers.filter(function (a) { return new Date(a.answered_at).getTime() >= sevenAgo; });
    var acc7 = computeAccuracy(last7);
    var acc30 = computeAccuracy(answers);
    setText('stat-7d', acc7 === null ? '–' : acc7 + '%');
    setText('stat-30d', acc30 === null ? '–' : acc30 + '%');
  }

  function renderEmpty(container, messageKey, extraClass) {
    clearChildren(container);
    container.appendChild(el('div', 'dash-empty' + (extraClass ? ' ' + extraClass : ''), t(messageKey)));
  }

  function renderProgressChart(answers) {
    var container = $('progress-chart');
    if (!answers.length) {
      renderEmpty(container, 'home_progress_empty', 'dash-empty-chart');
      return;
    }
    var days = [];
    for (var i = 6; i >= 0; i--) {
      var d = new Date();
      d.setHours(0, 0, 0, 0);
      d.setDate(d.getDate() - i);
      days.push({ date: d, correct: 0, wrong: 0 });
    }
    answers.forEach(function (a) {
      var d = new Date(a.answered_at);
      d.setHours(0, 0, 0, 0);
      var bucket = days.filter(function (x) { return x.date.getTime() === d.getTime(); })[0];
      if (!bucket) return;
      if (a.is_correct) bucket.correct++; else bucket.wrong++;
    });

    var max = Math.max.apply(null, days.map(function (x) { return x.correct + x.wrong; }).concat([1]));
    clearChildren(container);

    var bars = el('div', 'chart-bars');
    var labels = el('div', 'chart-labels');
    days.forEach(function (x) {
      var col = el('div', 'chart-bar-col');
      col.title = t('chart_day_summary', {
        total: x.correct + x.wrong, correct: x.correct, wrong: x.wrong
      });
      if (x.wrong) {
        var wrong = el('div', 'seg-wrong');
        wrong.style.height = (x.wrong / max * 100) + '%';
        col.appendChild(wrong);
      }
      if (x.correct) {
        var correct = el('div', 'seg-correct');
        correct.style.height = (x.correct / max * 100) + '%';
        col.appendChild(correct);
      }
      bars.appendChild(col);
      labels.appendChild(el('span', null, x.date.toLocaleDateString(getLang(), { weekday: 'short' })));
    });
    container.appendChild(bars);
    container.appendChild(labels);
  }

  function domainById(id) {
    return DOMAINS.filter(function (d) { return d.id === id; })[0] || null;
  }

  function renderWeakestDomains(answers) {
    var container = $('domains-list');
    var byDomain = {};
    answers.forEach(function (a) {
      if (a.domain_id == null) return;
      if (!byDomain[a.domain_id]) byDomain[a.domain_id] = { correct: 0, total: 0 };
      byDomain[a.domain_id].total++;
      if (a.is_correct) byDomain[a.domain_id].correct++;
    });

    var rows = Object.keys(byDomain).map(function (id) {
      var d = byDomain[id];
      var meta = domainById(parseInt(id, 10));
      return {
        name: meta ? meta.name : '#' + id,
        color: meta ? meta.color : '#4FD1FF',
        accuracy: Math.round((d.correct / d.total) * 100)
      };
    });

    if (!rows.length) {
      renderEmpty(container, 'home_domains_empty');
      return;
    }
    rows.sort(function (a, b) { return a.accuracy - b.accuracy; });

    clearChildren(container);
    rows.slice(0, 3).forEach(function (r) {
      var row = el('div', 'domain-row');
      var top = el('div', 'domain-row-top');
      top.appendChild(el('span', 'domain-name', r.name));
      top.appendChild(el('span', 'domain-pct mono', r.accuracy + '%'));
      var bar = el('div', 'domain-bar');
      var fill = el('div', 'domain-bar-fill');
      fill.style.width = r.accuracy + '%';
      // Colours come from the database, so keep them to a safe literal shape.
      fill.style.backgroundColor = /^#[0-9A-Fa-f]{6}$/.test(r.color) ? r.color : '#4FD1FF';
      bar.appendChild(fill);
      row.appendChild(top);
      row.appendChild(bar);
      container.appendChild(row);
    });
  }

  function renderStreak(sessionDates) {
    var streakEl = $('stat-streak');
    var lineEl = $('home-streak');
    if (!sessionDates.length) {
      streakEl.textContent = '–';
      lineEl.textContent = t('home_streak_empty');
      return;
    }

    var seen = Object.create(null);
    var days = [];
    sessionDates.forEach(function (s) {
      var d = new Date(s.started_at);
      d.setHours(0, 0, 0, 0);
      var key = d.getTime();
      if (!seen[key]) { seen[key] = true; days.push(key); }
    });
    days.sort(function (a, b) { return a - b; });

    // Day boundaries are not always exactly 24h apart (DST), so compare the
    // calendar days rather than the millisecond delta.
    function isNextDay(earlier, later) {
      var d = new Date(earlier);
      d.setDate(d.getDate() + 1);
      d.setHours(0, 0, 0, 0);
      return d.getTime() === later;
    }

    var longest = 1;
    var current = 1;
    for (var i = 1; i < days.length; i++) {
      if (isNextDay(days[i - 1], days[i])) { current++; longest = Math.max(longest, current); }
      else { current = 1; }
    }
    streakEl.textContent = String(longest);

    var todayStart = new Date();
    todayStart.setHours(0, 0, 0, 0);
    var lastDay = days[days.length - 1];
    var curStreak = 0;
    if (lastDay === todayStart.getTime() || isNextDay(lastDay, todayStart.getTime())) {
      curStreak = 1;
      for (var j = days.length - 1; j > 0; j--) {
        if (isNextDay(days[j - 1], days[j])) curStreak++; else break;
      }
    }
    lineEl.textContent = curStreak > 0 ? t('home_streak_active', { count: curStreak }) : t('home_streak_empty');
  }

  function renderSessionHistory(sessions) {
    var container = $('history-list');
    var viewAllBtn = $('history-view-all');
    if (!sessions.length) {
      renderEmpty(container, 'home_history_empty');
      viewAllBtn.disabled = true;
      return;
    }
    viewAllBtn.disabled = false;

    clearChildren(container);
    sessions.forEach(function (s) {
      var dateStr = new Date(s.started_at).toLocaleDateString(getLang(), { month: 'short', day: 'numeric' });
      var domainIds = s.domain_ids || [];
      var names = domainIds.slice(0, 2).map(function (id) {
        var d = domainById(id);
        return d ? d.name : '#' + id;
      }).join(', ');
      var more = domainIds.length > 2 ? ' +' + (domainIds.length - 2) : '';
      var score = s.ended_at
        ? s.correct_count + '/' + s.total_answered
        : t('home_history_in_progress');

      var row = el('div', 'dash-row');
      row.appendChild(el('span', 'grow', dateStr + ' · ' + names + more));
      row.appendChild(el('span', 'muted mono', score));
      container.appendChild(row);
    });
  }

  async function loadAndRenderReportedQuestions() {
    var container = $('reported-list');
    var viewAllBtn = $('reported-view-all');

    var res = await supabaseClient
      .from('reported_questions')
      .select('id, created_at, question_id')
      .order('created_at', { ascending: false })
      .limit(5);
    if (res.error) console.error('dashboard reported-questions query failed:', res.error);
    var reports = res.data || [];

    if (!reports.length) {
      renderEmpty(container, 'home_reported_empty');
      viewAllBtn.disabled = true;
      return;
    }
    viewAllBtn.disabled = false;

    var ids = reports.map(function (r) { return r.question_id; });
    var textsRes = await supabaseClient
      .from('question_translations')
      .select('question_id, text')
      .eq('language_code', getLang())
      .in('question_id', ids);
    if (textsRes.error) console.error('dashboard reported-questions text lookup failed:', textsRes.error);

    var textById = Object.create(null);
    (textsRes.data || []).forEach(function (row) { textById[row.question_id] = row.text; });

    clearChildren(container);
    reports.forEach(function (r) {
      var row = el('div', 'dash-row');
      row.appendChild(el('span', 'grow', textById[r.question_id] || '#' + r.question_id));
      var flag = el('span', 'muted', '⚑');
      flag.style.color = 'var(--coral)';
      row.appendChild(flag);
      container.appendChild(row);
    });
  }

  // ----------------------------------------------------------- profile menu
  function toggleProfileMenu(event) {
    if (event) event.stopPropagation();
    var opts = $('profile-options');
    var trigger = document.querySelector('#profile-menu .profile-trigger');
    if (!opts) return;
    var open = opts.classList.toggle('open');
    if (trigger) trigger.setAttribute('aria-expanded', open ? 'true' : 'false');
  }

  function closeProfileMenu() {
    var opts = $('profile-options');
    if (opts) opts.classList.remove('open');
    var trigger = document.querySelector('#profile-menu .profile-trigger');
    if (trigger) trigger.setAttribute('aria-expanded', 'false');
  }

  // ---------------------------------------------------------------- domains
  async function loadDomains() {
    var wrap = $('domain-pills');
    clearChildren(wrap);
    wrap.appendChild(el('span', 'hint', '…'));

    var res = await supabaseClient
      .from('domain_translations')
      .select('domain_id, name, domains!inner(id,color)')
      .eq('language_code', getLang())
      .order('domain_id');

    if (res.error || !res.data || !res.data.length) {
      if (res.error) console.error('domain load failed:', res.error);
      clearChildren(wrap);
      setText('setup-hint', t('setup_hint_error'));
      return;
    }
    DOMAINS = res.data.map(function (row) {
      return { id: row.domain_id, name: row.name, color: row.domains.color };
    });
    // Drop selections that no longer exist (e.g. after a language reload)
    state.domains = state.domains.filter(function (id) { return domainById(id) !== null; });
    renderDomainPills();
    updateSetupState();
  }

  function renderDomainPills() {
    var wrap = $('domain-pills');
    clearChildren(wrap);

    var allSelected = DOMAINS.length > 0 && state.domains.length === DOMAINS.length;

    DOMAINS.forEach(function (d) {
      var selected = state.domains.indexOf(d.id) !== -1;
      var pill = el('button', 'pill' + (selected ? ' active' : ''), d.name);
      pill.type = 'button';
      pill.setAttribute('aria-pressed', selected ? 'true' : 'false');
      // The cap only blocks *adding*; an already-selected pill stays clickable
      // so the player can always deselect.
      pill.disabled = !selected && !allSelected && state.domains.length >= MAX_DOMAINS;
      pill.addEventListener('click', function () { toggleDomain(d.id); });
      wrap.appendChild(pill);
    });

    var allPill = el('button', 'pill' + (allSelected ? ' active' : ''), t('all_domains'));
    allPill.type = 'button';
    allPill.setAttribute('aria-pressed', allSelected ? 'true' : 'false');
    allPill.addEventListener('click', function () {
      state.domains = allSelected ? [] : DOMAINS.map(function (d) { return d.id; });
      renderDomainPills();
      updateSetupState();
    });
    wrap.appendChild(allPill);
  }

  function toggleDomain(id) {
    var idx = state.domains.indexOf(id);
    if (idx === -1) {
      // "All domains" is a deliberate exception to the five-domain cap.
      if (state.domains.length >= MAX_DOMAINS && state.domains.length !== DOMAINS.length) return;
      state.domains.push(id);
    } else {
      state.domains.splice(idx, 1);
    }
    renderDomainPills();
    updateSetupState();
  }

  function updateSetupState() {
    var btn = $('start-btn');
    var hint = $('setup-hint');
    if (!btn || !hint) return;
    if (state.domains.length > 0) {
      btn.disabled = false;
      hint.textContent = t('setup_hint_selected', { n: state.domains.length });
    } else {
      btn.disabled = true;
      hint.textContent = t('setup_hint_pick');
    }
  }

  // ---------------------------------------------------------------- captcha
  /* A client-side arithmetic check is a speed bump, not bot protection — the
     answer lives in this file. It exists to slow down casual automation; the
     real limits are the per-user rate limits in db/05_rpc.sql. Swap in
     Turnstile or hCaptcha before opening this up to public traffic. */
  function goCaptcha() {
    var a = Math.floor(Math.random() * 8) + 2;
    var b = Math.floor(Math.random() * 8) + 1;
    state.captchaAnswer = a + b;
    setText('captcha-question', a + ' + ' + b + ' = ?');
    $('captcha-input').value = '';
    showOnly('captcha');
    $('captcha-input').focus();
  }

  function newCaptchaAfterFailure() {
    var a = Math.floor(Math.random() * 8) + 2;
    var b = Math.floor(Math.random() * 8) + 1;
    state.captchaAnswer = a + b;
    setText('captcha-question', a + ' + ' + b + ' = ?');
    $('captcha-input').value = '';
    $('captcha-input').focus();
  }

  function checkCaptcha(event) {
    if (event) event.preventDefault();
    var value = parseInt($('captcha-input').value, 10);
    if (value === state.captchaAnswer) {
      state.captchaTries = 0;
      setText('captcha-error', '');
      startQuiz();
      return;
    }
    state.captchaTries++;
    if (state.captchaTries >= MAX_CAPTCHA_TRIES) {
      state.captchaTries = 0;
      setText('captcha-error', '');
      showToast(t('captcha_too_many'));
      showOnly('setup');
      return;
    }
    // The old code regenerated the challenge through goCaptcha(), which wiped
    // this message before it was ever painted.
    setText('captcha-error', t('captcha_error'));
    newCaptchaAfterFailure();
  }

  // ------------------------------------------------------------------- quiz
  async function startQuiz() {
    if (state.busy) return;
    state.busy = true;
    try {
      state.numAnswers = parseInt($('sel-answers').value, 10) || 3;
      var requested = parseInt($('sel-count').value, 10) || 10;
      var lang = getLang();

      var questionsRes = await supabaseClient.rpc('get_quiz_questions', {
        p_domain_ids: state.domains,
        p_language: lang,
        p_num_options: state.numAnswers,
        p_limit: requested
      });

      if (questionsRes.error || !questionsRes.data || !questionsRes.data.length) {
        if (questionsRes.error) console.error('get_quiz_questions failed:', questionsRes.error);
        showToast(questionsRes.error ? t('load_error') : t('load_empty'), 7000);
        showOnly('setup');
        return;
      }

      state.questions = questionsRes.data.map(function (row) {
        return {
          id: row.question_id,
          domainId: row.domain_id,
          texts: row.texts || {},
          optionsByLang: row.options || {}
        };
      });
      state.current = 0;
      state.correctCount = 0;
      state.answered = new Array(state.questions.length).fill(null);
      state.sessionId = null;

      if (session.isLoggedIn) {
        var sessionRes = await supabaseClient.rpc('start_quiz_session', {
          p_domain_ids: state.domains,
          p_language: lang,
          p_num_options: state.numAnswers,
          p_num_questions: state.questions.length
        });
        if (sessionRes.error) console.error('start_quiz_session failed:', sessionRes.error);
        else state.sessionId = sessionRes.data;
      }

      showOnly('quiz');
      renderQuestion();
    } finally {
      state.busy = false;
    }
  }

  function questionText(q) {
    return q.texts[getLang()] || q.texts.en || '';
  }

  function questionOptions(q) {
    return q.optionsByLang[getLang()] || q.optionsByLang.en || [];
  }

  function setSnackbar(kind, message) {
    var sb = $('snackbar');
    sb.className = 'snackbar mono show ' + kind;
    sb.textContent = message;
  }

  function hideSnackbar() {
    var sb = $('snackbar');
    sb.className = 'snackbar mono';
    sb.textContent = '';
  }

  function renderQuestion() {
    var q = state.questions[state.current];
    setText('q-progress', t('q_progress', { current: state.current + 1, total: state.questions.length }));
    setText('q-score', t('q_score', { correct: state.correctCount, total: state.questions.length }));
    setText('q-text', questionText(q));

    var optsWrap = $('q-opts');
    clearChildren(optsWrap);
    optsWrap.classList.remove('locked');

    var prev = state.answered[state.current];
    state.selected = prev ? prev.selected : null;
    state.validated = !!prev;

    questionOptions(q).forEach(function (optText, i) {
      var button = el('button', 'opt', optText);
      button.type = 'button';
      button.addEventListener('click', function () { selectOption(i); });
      optsWrap.appendChild(button);
    });

    $('back-btn').classList.toggle('is-invisible', state.current === 0);
    // report_question requires a login, so don't dangle a dead control in
    // front of guests.
    show($('report-btn'), session.isLoggedIn);
    hideSnackbar();

    if (state.validated) paintValidated(); else paintSelection();
    updateNextButton();
  }

  function updateNextButton() {
    var nextBtn = $('next-btn');
    var validateBtn = $('validate-btn');
    nextBtn.disabled = !state.validated;
    nextBtn.classList.toggle('btn-primary-sky', state.validated);
    show(validateBtn, !state.validated);
  }

  function selectOption(i) {
    if (state.validated) return;
    state.selected = i;
    paintSelection();
  }

  function paintSelection() {
    var opts = $('q-opts').children;
    for (var i = 0; i < opts.length; i++) {
      opts[i].classList.toggle('selected', i === state.selected);
    }
  }

  function paintValidated() {
    var rec = state.answered[state.current];
    if (!rec) return;
    var optsWrap = $('q-opts');
    var opts = optsWrap.children;
    var correctText = rec.correctOption;
    optsWrap.classList.add('locked');

    for (var i = 0; i < opts.length; i++) {
      opts[i].classList.remove('selected');
      // The server returns the correct option as text, in the language the
      // answer was submitted in — match on the rendered label.
      var isCorrectOption = correctText != null && opts[i].textContent === correctText;
      if (isCorrectOption) opts[i].classList.add('correct');
      else if (i === rec.selected) opts[i].classList.add('wrong');
    }
    setSnackbar(rec.correct ? 'ok' : 'bad', rec.correct ? t('correct_msg') : t('wrong_msg'));
  }

  async function validateAnswer() {
    if (state.selected === null || state.validated || state.busy) return;
    var q = state.questions[state.current];
    var lang = getLang();
    var selectedText = questionOptions(q)[state.selected];

    state.busy = true;
    $('validate-btn').disabled = true;
    var res;
    try {
      // Grading happens on the server: the browser is never told which option
      // is correct until it has committed to one.
      res = await supabaseClient.rpc('submit_quiz_answer', {
        p_question_id: q.id,
        p_language: lang,
        p_selected_option: selectedText,
        p_selected_index: state.selected,
        p_session_id: state.sessionId
      });
    } finally {
      state.busy = false;
      $('validate-btn').disabled = false;
    }

    if (res.error || !res.data) {
      console.error('submit_quiz_answer failed:', res.error);
      setSnackbar('info', t('answer_error'));
      return;
    }

    var isCorrect = res.data.is_correct === true;
    state.answered[state.current] = {
      selected: state.selected,
      correct: isCorrect,
      correctOption: res.data.correct_option,
      // Remember the language so a mid-quiz switch can relabel correctly.
      correctByLang: buildCorrectByLang(q, res.data.correct_option, lang)
    };
    state.validated = true;
    if (isCorrect) state.correctCount++;
    setText('q-score', t('q_score', { correct: state.correctCount, total: state.questions.length }));
    paintValidated();
    updateNextButton();
  }

  /* The server answers in one language; the option lists share an order across
     languages, so the position of the correct option is enough to relabel it
     when the player switches language mid-quiz. */
  function buildCorrectByLang(q, correctOption, lang) {
    var list = q.optionsByLang[lang] || [];
    var idx = list.indexOf(correctOption);
    var byLang = {};
    if (idx === -1) return byLang;
    Object.keys(q.optionsByLang).forEach(function (l) {
      var opts = q.optionsByLang[l];
      if (opts && opts[idx] != null) byLang[l] = opts[idx];
    });
    return byLang;
  }

  function relabelAnswered() {
    var lang = getLang();
    state.answered.forEach(function (rec) {
      if (rec && rec.correctByLang && rec.correctByLang[lang]) {
        rec.correctOption = rec.correctByLang[lang];
      }
    });
  }

  function nextQuestion() {
    if (!state.validated) return;
    if (state.current < state.questions.length - 1) {
      state.current++;
      renderQuestion();
    } else {
      endGame();
    }
  }

  function prevQuestion() {
    if (state.current > 0) {
      state.current--;
      renderQuestion();
    }
  }

  async function reportQuestion() {
    if (!session.isLoggedIn) return;
    var q = state.questions[state.current];
    var res = await supabaseClient.rpc('report_question', {
      p_question_id: q.id,
      p_language: getLang(),
      p_reason: 'None of the answers seemed correct',
      p_session_id: state.sessionId
    });
    if (res.error) {
      console.error('report_question failed:', res.error);
      setSnackbar('info', t('report_error'));
      return;
    }
    setSnackbar('info', t('reported_msg'));
  }

  async function endGame() {
    var answeredCount = state.answered.filter(function (a) { return a !== null; }).length;
    var correctCount = state.correctCount;

    if (session.isLoggedIn && state.sessionId) {
      // The totals shown are the ones the server recomputed from the stored
      // answers, not the tally this page has been keeping.
      var res = await supabaseClient.rpc('finish_quiz_session', { p_session_id: state.sessionId });
      if (res.error) console.error('finish_quiz_session failed:', res.error);
      else if (res.data) {
        correctCount = res.data.correct_count;
        answeredCount = res.data.total_answered;
      }
    }

    var accuracy = answeredCount > 0 ? Math.round((correctCount / answeredCount) * 100) : 0;
    setText('sum-correct', correctCount + '/' + answeredCount);
    setText('sum-accuracy', accuracy + '%');
    setText('summary-note', session.isLoggedIn ? t('summary_note_saved') : t('summary_note_guest'));
    show($('view-stats-btn'), session.isLoggedIn);
    state.sessionId = null;
    showOnly('summary');
  }

  function resetApp() {
    state.domains = [];
    state.questions = [];
    state.answered = [];
    renderDomainPills();
    updateSetupState();
    if (session.isLoggedIn) {
      showOnly('home');
      loadDashboardData();
    } else {
      showOnly('landing');
    }
  }

  // -------------------------------------------------------- language change
  window.onLangChange = function () {
    if ($('screen-login').classList.contains('active')) applyLoginModeText();
    if (DOMAINS.length) loadDomains();
    if ($('screen-home').classList.contains('active')) loadDashboardData();
    if ($('screen-quiz').classList.contains('active') && state.questions.length) {
      relabelAnswered();
      renderQuestion();
    }
  };

  // ------------------------------------------------------------------- init
  function checkRecoveryLinkError() {
    // Supabase sends expired or already-used recovery links back here with the
    // error in the URL hash rather than as a normal auth error.
    var hash = window.location.hash && window.location.hash.length > 1
      ? window.location.hash.substring(1) : '';
    var params = new URLSearchParams(hash);
    if (!params.get('error')) return false;
    history.replaceState(null, '', window.location.pathname + window.location.search);
    showToast(t('toast_reset_link_invalid'), 7000);
    return true;
  }

  var ACTIONS = {
    'toggle-lang-menu': function (_el, event) { window.toggleLangMenu(event); },
    'set-lang': function (element) { window.setLang(element.getAttribute('data-lang')); },
    'toggle-profile-menu': function (_el, event) { toggleProfileMenu(event); },
    'log-out': logOut,
    'exit-home': goExitHome,
    'go-setup': function () { closeProfileMenu(); showOnly('setup'); },
    'go-login': function () { showOnly('login'); },
    'go-reset-request': goResetRequest,
    'toggle-login-mode': toggleLoginMode,
    'go-captcha': goCaptcha,
    'validate': validateAnswer,
    'prev-question': prevQuestion,
    'next-question': nextQuestion,
    'report-question': reportQuestion,
    'end-game': endGame,
    'play-again': resetApp,
    'view-stats': function () { showOnly('home'); loadDashboardData(); },
    'history-view-all': function () { showToast(t('coming_soon')); },
    'reported-view-all': function () { showToast(t('coming_soon')); }
  };

  function bindEvents() {
    // One delegated listener replaces the 28 inline onclick attributes the
    // page used to carry — which is what makes a script-src without
    // 'unsafe-inline' possible.
    document.addEventListener('click', function (event) {
      var target = event.target.closest('[data-action]');
      if (target) {
        var handler = ACTIONS[target.getAttribute('data-action')];
        if (handler) {
          event.preventDefault();
          handler(target, event);
          return;
        }
      }
      var opts = $('profile-options');
      if (opts && opts.classList.contains('open')) {
        var wrap = $('profile-menu');
        if (wrap && !wrap.contains(event.target)) closeProfileMenu();
      }
    });

    $('login-form').addEventListener('submit', submitLogin);
    $('reset-request-form').addEventListener('submit', submitResetRequest);
    $('reset-password-form').addEventListener('submit', submitResetPassword);
    $('captcha-form').addEventListener('submit', checkCaptcha);

    bindPasswordRules('login-password', 'login-pw-rules');
    bindPasswordRules('reset-password-new', 'reset-pw-rules');
  }

  async function init() {
    window.applyI18n();
    bindEvents();
    applyLoginModeText();
    updateSetupState();

    supabaseClient.auth.onAuthStateChange(function (event) {
      if (event === 'PASSWORD_RECOVERY') {
        recoveryFlowActive = true;
        clearResetPasswordErrors();
        $('reset-password-new').value = '';
        $('reset-password-confirm').value = '';
        paintPasswordRules('reset-pw-rules', '');
        showOnly('reset-password');
      }
    });

    var linkExpired = checkRecoveryLinkError();

    var existing = await supabaseClient.auth.getSession();
    var current = existing.data ? existing.data.session : null;
    if (current && !recoveryFlowActive) {
      session.isLoggedIn = true;
      session.email = current.user.email;
      session.userId = current.user.id;
    }

    await loadDomains();

    if (recoveryFlowActive) { showOnly('reset-password'); return; }

    var params = new URLSearchParams(window.location.search);
    var mode = params.get('mode');
    if (mode === 'guest') showOnly('setup');
    else if (session.isLoggedIn) await loadProfileAndGoHome();
    else if (mode === 'login' || linkExpired) showOnly('login');
    else showOnly('landing');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
