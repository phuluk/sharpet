/* Sharpet — admin console.
 *
 * Same rules as assets/app.js: no innerHTML string building, no inline
 * handlers, CSP-friendly. This file is intentionally self-contained rather
 * than sharing code with app.js, since the two pages have very little
 * overlapping logic and app.js isn't structured to export anything.
 *
 * Every action here calls a SECURITY DEFINER admin_* RPC (db/07_admin.sql)
 * that re-checks is_admin() itself — this file deciding whether to *show*
 * a button is a convenience, never the actual control. Same philosophy as
 * the rest of the app.
 */
'use strict';

(function () {
  var cfg = window.SHARPET_CONFIG || {};
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    throw new Error('assets/config.js is missing the Supabase project settings.');
  }
  var supabaseClient = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  var state = { domains: [], loadedTabs: {}, editingQuestionId: null, editingOptionCount: 2 };

  // Same Turnstile pattern as assets/app.js — a fresh challenge on every
  // visit to the login screen, tokens are single-use.
  var ts = { widgets: {}, tokens: {} };
  function showTurnstile(slotId) {
    if (!cfg.turnstileSiteKey || cfg.turnstileSiteKey.indexOf('REPLACE_WITH') === 0) return;
    if (!window.turnstile) {
      window.setTimeout(function () { showTurnstile(slotId); }, 200);
      return;
    }
    if (ts.widgets[slotId] == null) {
      ts.widgets[slotId] = window.turnstile.render('#' + slotId, {
        sitekey: cfg.turnstileSiteKey,
        callback: function (token) { ts.tokens[slotId] = token; },
        'expired-callback': function () { ts.tokens[slotId] = null; },
        'error-callback': function () { ts.tokens[slotId] = null; }
      });
    } else {
      ts.tokens[slotId] = null;
      window.turnstile.reset(ts.widgets[slotId]);
    }
  }
  function turnstileToken(slotId) {
    return ts.tokens[slotId] || null;
  }

  // ------------------------------------------------------------- utilities
  function $(id) { return document.getElementById(id); }
  function clearChildren(el) { while (el.firstChild) el.removeChild(el.firstChild); }
  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = String(text);
    return node;
  }
  function fmtDate(value) {
    if (!value) return '—';
    var d = new Date(value);
    return isNaN(d.getTime()) ? '—' : d.toLocaleString();
  }
  function showToast(message, duration) {
    var container = $('toast-container');
    var node = el('div', 'toast', message);
    container.appendChild(node);
    requestAnimationFrame(function () { node.classList.add('show'); });
    window.setTimeout(function () {
      node.classList.remove('show');
      window.setTimeout(function () { node.remove(); }, 300);
    }, duration || 4500);
  }
  function friendlyError(res, fallback) {
    return (res && res.error && res.error.message) ? res.error.message : (fallback || 'Something went wrong.');
  }
  function debounce(fn, wait) {
    var timer = null;
    return function () {
      var args = arguments;
      window.clearTimeout(timer);
      timer = window.setTimeout(function () { fn.apply(null, args); }, wait);
    };
  }

  // ------------------------------------------------------------------ gate
  var currentUserId = null;

  async function boot() {
    var existing = await supabaseClient.auth.getSession();
    var session = existing.data ? existing.data.session : null;
    if (!session) {
      $('gate-message').textContent = 'Log in with an admin account.';
      show($('gate-login'), true);
      showTurnstile('turnstile-admin-login');
      return;
    }
    currentUserId = session.user.id;
    await checkAdminAndEnter();
  }

  function show(node, visible) {
    if (node) node.classList.toggle('is-hidden', !visible);
  }

  async function checkAdminAndEnter() {
    $('gate-message').textContent = 'Checking access…';
    show($('gate-login'), false);
    var res = await supabaseClient.rpc('is_admin', {});
    if (res.error || res.data !== true) {
      $('gate-message').textContent = 'This account is not an admin.';
      show($('gate-login'), false);
      return;
    }
    $('admin-screen-gate').classList.remove('active');
    $('admin-screen-app').classList.add('active');
    loadTab('users');
  }

  async function submitGateLogin(event) {
    event.preventDefault();
    var email = $('gate-email').value.trim();
    var password = $('gate-password').value;
    setText('gate-error', '');
    var captchaToken = turnstileToken('turnstile-admin-login') || undefined;
    var res = await supabaseClient.auth.signInWithPassword({
      email: email, password: password, options: { captchaToken: captchaToken }
    });
    if (res.error) {
      setText('gate-error', res.error.message || 'Log in failed.');
      showTurnstile('turnstile-admin-login');
      return;
    }
    currentUserId = res.data.user.id;
    await checkAdminAndEnter();
  }

  function setText(id, value) {
    var node = $(id);
    if (node) node.textContent = value == null ? '' : String(value);
  }

  async function logOut() {
    await supabaseClient.auth.signOut();
    window.location.href = 'app.html?mode=login';
  }

  // ------------------------------------------------------------------ tabs
  function loadTab(name) {
    document.querySelectorAll('.admin-tab').forEach(function (t) {
      t.classList.toggle('active', t.getAttribute('data-tab') === name);
    });
    document.querySelectorAll('.admin-panel').forEach(function (p) {
      p.classList.toggle('active', p.id === 'panel-' + name);
    });
    if (name === 'users') loadUsers();
    else if (name === 'reported') loadReported();
    else if (name === 'questions') loadQuestions();
    else if (name === 'submissions') loadSubmissions();
    else if (name === 'settings') loadSettings();
    else if (name === 'region') loadRegion();
    else if (name === 'audit') loadAudit();
    else if (name === 'usage') loadUsage();
  }

  // ----------------------------------------------------------------- users
  async function loadUsers() {
    var tbody = $('users-tbody');
    clearChildren(tbody);
    var search = $('users-search').value.trim();
    var res = await supabaseClient.rpc('admin_list_users', { p_search: search || null, p_limit: 200, p_offset: 0 });
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (u) {
      var row = el('tr');
      row.appendChild(el('td', null, u.email || '—'));
      row.appendChild(el('td', null, u.display_name || '—'));
      row.appendChild(el('td', null, fmtDate(u.created_at)));
      row.appendChild(el('td', null, fmtDate(u.last_sign_in_at)));
      row.appendChild(el('td', 'num', String(u.quizzes_played)));
      row.appendChild(el('td', 'num', String(u.questions_answered)));
      row.appendChild(el('td', null, u.is_banned ? 'Deactivated' : 'Active'));
      row.appendChild(el('td', null, u.is_admin ? 'Admin' : 'Player'));

      var actions = el('td', 'admin-actions');
      var isSelf = u.id === currentUserId;

      var activeBtn = el('button', 'btn btn-sm', u.is_banned ? 'Activate' : 'Deactivate');
      activeBtn.type = 'button';
      activeBtn.disabled = isSelf && !u.is_banned;
      activeBtn.addEventListener('click', function () { setUserActive(u.id, u.is_banned); });
      actions.appendChild(activeBtn);

      var adminBtn = el('button', 'btn btn-sm', u.is_admin ? 'Remove admin' : 'Make admin');
      adminBtn.type = 'button';
      adminBtn.disabled = isSelf && u.is_admin;
      adminBtn.addEventListener('click', function () { setUserAdmin(u.id, !u.is_admin); });
      actions.appendChild(adminBtn);

      row.appendChild(actions);
      tbody.appendChild(row);
    });
  }

  async function setUserActive(userId, makeActive) {
    var res = await supabaseClient.rpc('admin_set_user_active', { p_user_id: userId, p_active: makeActive });
    if (res.error) { showToast(friendlyError(res)); return; }
    showToast(makeActive ? 'User activated.' : 'User deactivated.');
    loadUsers();
  }

  async function setUserAdmin(userId, makeAdmin) {
    var res = await supabaseClient.rpc('admin_set_user_admin', { p_user_id: userId, p_is_admin: makeAdmin });
    if (res.error) { showToast(friendlyError(res)); return; }
    showToast(makeAdmin ? 'Granted admin access.' : 'Removed admin access.');
    loadUsers();
  }

  // -------------------------------------------------------------- reported
  async function loadReported() {
    var tbody = $('reported-tbody');
    clearChildren(tbody);
    var includeResolved = $('reported-include-resolved').checked;
    var res = await supabaseClient.rpc('admin_list_reported_questions', {
      p_include_resolved: includeResolved, p_limit: 200, p_offset: 0
    });
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (r) {
      var row = el('tr');
      row.appendChild(el('td', null, r.question_text || ('#' + r.question_id)));
      row.appendChild(el('td', null, r.reason || '—'));
      row.appendChild(el('td', null, r.reporter_email || '—'));
      row.appendChild(el('td', null, fmtDate(r.created_at)));
      row.appendChild(el('td', null, r.resolved ? 'Resolved' : 'Open'));

      var actions = el('td', 'admin-actions');
      var toggleBtn = el('button', 'btn btn-sm', r.resolved ? 'Reopen' : 'Resolve');
      toggleBtn.type = 'button';
      toggleBtn.addEventListener('click', function () { resolveReport(r.id, !r.resolved); });
      actions.appendChild(toggleBtn);

      var deactivateBtn = el('button', 'btn btn-sm', 'Deactivate question');
      deactivateBtn.type = 'button';
      deactivateBtn.addEventListener('click', function () { setQuestionActive(r.question_id, false, loadReported); });
      actions.appendChild(deactivateBtn);

      row.appendChild(actions);
      tbody.appendChild(row);
    });
  }

  async function resolveReport(reportId, resolved) {
    var res = await supabaseClient.rpc('admin_resolve_report', { p_report_id: reportId, p_resolved: resolved });
    if (res.error) { showToast(friendlyError(res)); return; }
    loadReported();
  }

  // ------------------------------------------------------------- questions
  async function loadQuestions() {
    if (!state.domains.length) await loadDomains();
    var tbody = $('questions-tbody');
    clearChildren(tbody);
    var search = $('questions-search').value.trim();
    var res = await supabaseClient.rpc('admin_list_questions', {
      p_search: search || null, p_domain_id: null, p_only_active: null, p_limit: 100, p_offset: 0
    });
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (q) {
      var row = el('tr');
      row.appendChild(el('td', null, String(q.id)));
      row.appendChild(el('td', null, domainName(q.domain_id)));
      row.appendChild(el('td', null, q.difficulty || '—'));
      row.appendChild(el('td', 'admin-truncate', q.text_en || '—'));
      row.appendChild(el('td', null, q.is_active ? 'Active' : 'Inactive'));
      row.appendChild(el('td', null, q.is_guest_demo ? 'Yes' : '—'));

      var actions = el('td', 'admin-actions');
      var editBtn = el('button', 'btn btn-sm', 'Edit');
      editBtn.type = 'button';
      editBtn.addEventListener('click', function () { openQuestionEditor(q); });
      actions.appendChild(editBtn);

      var toggleBtn = el('button', 'btn btn-sm', q.is_active ? 'Deactivate' : 'Activate');
      toggleBtn.type = 'button';
      toggleBtn.addEventListener('click', function () { setQuestionActive(q.id, !q.is_active, loadQuestions); });
      actions.appendChild(toggleBtn);

      row.appendChild(actions);
      tbody.appendChild(row);
    });
  }

  async function setQuestionActive(questionId, active, onDone) {
    var res = await supabaseClient.rpc('admin_set_question_active', { p_question_id: questionId, p_active: active });
    if (res.error) { showToast(friendlyError(res)); return; }
    showToast(active ? 'Question activated.' : 'Question deactivated.');
    if (onDone) onDone();
  }

  async function loadDomains() {
    var res = await supabaseClient
      .from('domain_translations')
      .select('domain_id, name')
      .eq('language_code', 'en')
      .order('domain_id');
    if (res.error) { showToast(friendlyError(res)); return; }
    state.domains = res.data || [];
    var select = $('edit-domain');
    clearChildren(select);
    state.domains.forEach(function (d) {
      var opt = document.createElement('option');
      opt.value = String(d.domain_id);
      opt.textContent = d.name;
      select.appendChild(opt);
    });
  }

  function domainName(id) {
    var d = state.domains.filter(function (x) { return x.domain_id === id; })[0];
    return d ? d.name : '#' + id;
  }

  // --------------------------------------------------------- question edit
  function openQuestionEditor(q) {
    state.editingQuestionId = q.id;
    setText('edit-question-id', '#' + q.id);
    $('edit-domain').value = String(q.domain_id);
    $('edit-difficulty').value = q.difficulty || 'medium';
    $('edit-active').value = q.is_active ? 'true' : 'false';
    $('edit-text-en').value = q.text_en || '';
    $('edit-text-de').value = q.text_de || '';
    $('edit-text-cs').value = q.text_cs || '';
    $('edit-guest-demo').checked = !!q.is_guest_demo;
    setText('edit-error', '');

    var optsEn = q.options_en || [];
    renderOptionEditor(optsEn.length || 2, optsEn, q.options_de || [], q.options_cs || []);
    var correctSelect = $('edit-correct');
    fillCorrectOptions(optsEn.length || 2);
    correctSelect.value = String(q.correct_index || 0);

    document.querySelectorAll('.admin-panel').forEach(function (p) { p.classList.remove('active'); });
    $('panel-question-edit').classList.add('active');
  }

  function closeQuestionEditor() {
    state.editingQuestionId = null;
    loadTab('questions');
  }

  function renderOptionEditor(count, en, de, cs) {
    state.editingOptionCount = count;
    var wrap = $('edit-options');
    clearChildren(wrap);
    for (var i = 0; i < count; i++) {
      var row = el('div', 'field-row admin-option-row');
      var f1 = el('div', 'field');
      f1.appendChild(el('label', 'field-label', 'Option ' + (i + 1) + ' (EN)'));
      var i1 = document.createElement('input');
      i1.id = 'edit-opt-en-' + i; i1.value = en[i] || '';
      f1.appendChild(i1);
      var f2 = el('div', 'field');
      f2.appendChild(el('label', 'field-label', 'Option ' + (i + 1) + ' (DE)'));
      var i2 = document.createElement('input');
      i2.id = 'edit-opt-de-' + i; i2.value = de[i] || '';
      f2.appendChild(i2);
      var f3 = el('div', 'field');
      f3.appendChild(el('label', 'field-label', 'Option ' + (i + 1) + ' (CS)'));
      var i3 = document.createElement('input');
      i3.id = 'edit-opt-cs-' + i; i3.value = cs[i] || '';
      f3.appendChild(i3);
      row.appendChild(f1); row.appendChild(f2); row.appendChild(f3);
      wrap.appendChild(row);
    }
    var controls = el('div', 'admin-option-controls');
    if (count < 4) {
      var addBtn = el('button', 'btn btn-sm', 'Add option');
      addBtn.type = 'button';
      addBtn.addEventListener('click', function () {
        renderOptionEditor(count + 1, collectOptions('en', count), collectOptions('de', count), collectOptions('cs', count));
        fillCorrectOptions(count + 1);
      });
      controls.appendChild(addBtn);
    }
    if (count > 2) {
      var removeBtn = el('button', 'btn btn-sm', 'Remove last option');
      removeBtn.type = 'button';
      removeBtn.addEventListener('click', function () {
        renderOptionEditor(count - 1, collectOptions('en', count), collectOptions('de', count), collectOptions('cs', count));
        fillCorrectOptions(count - 1);
      });
      controls.appendChild(removeBtn);
    }
    wrap.appendChild(controls);
  }

  function collectOptions(lang, count) {
    var out = [];
    for (var i = 0; i < count; i++) {
      var node = $('edit-opt-' + lang + '-' + i);
      out.push(node ? node.value : '');
    }
    return out;
  }

  function fillCorrectOptions(count) {
    var select = $('edit-correct');
    var current = select.value;
    clearChildren(select);
    for (var i = 0; i < count; i++) {
      var opt = document.createElement('option');
      opt.value = String(i);
      opt.textContent = 'Option ' + (i + 1);
      select.appendChild(opt);
    }
    if (parseInt(current, 10) < count) select.value = current;
  }

  async function submitQuestionEdit(event) {
    event.preventDefault();
    if (state.editingQuestionId == null) return;
    var count = state.editingOptionCount;
    var optsEn = collectOptions('en', count).map(function (s) { return s.trim(); });
    var optsDe = collectOptions('de', count).map(function (s) { return s.trim(); });
    var optsCs = collectOptions('cs', count).map(function (s) { return s.trim(); });

    if (optsEn.some(function (s) { return !s; }) || optsDe.some(function (s) { return !s; }) || optsCs.some(function (s) { return !s; })) {
      setText('edit-error', 'Every option needs text in all three languages.');
      return;
    }

    var res = await supabaseClient.rpc('admin_update_question', {
      p_question_id: state.editingQuestionId,
      p_domain_id: parseInt($('edit-domain').value, 10),
      p_difficulty: $('edit-difficulty').value,
      p_is_active: $('edit-active').value === 'true',
      p_text_en: $('edit-text-en').value.trim(),
      p_text_de: $('edit-text-de').value.trim(),
      p_text_cs: $('edit-text-cs').value.trim(),
      p_options_en: optsEn,
      p_options_de: optsDe,
      p_options_cs: optsCs,
      p_correct_index: parseInt($('edit-correct').value, 10),
      p_is_guest_demo: $('edit-guest-demo').checked
    });
    if (res.error) { setText('edit-error', friendlyError(res)); return; }
    showToast('Question saved.');
    closeQuestionEditor();
  }

  // ------------------------------------------------------------- CSV import
  /* Minimal RFC4180 parser: handles quoted fields, embedded commas/newlines,
     and "" as an escaped quote. Good enough for a spreadsheet export; not a
     general-purpose CSV library. */
  function parseCSV(text) {
    var rows = [];
    var row = [];
    var field = '';
    var inQuotes = false;
    var i = 0;
    text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    while (i < text.length) {
      var c = text[i];
      if (inQuotes) {
        if (c === '"') {
          if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
          inQuotes = false; i++; continue;
        }
        field += c; i++; continue;
      }
      if (c === '"') { inQuotes = true; i++; continue; }
      if (c === ',') { row.push(field); field = ''; i++; continue; }
      if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; i++; continue; }
      field += c; i++;
    }
    if (field.length || row.length) { row.push(field); rows.push(row); }
    if (!rows.length) return [];

    var headers = rows[0].map(function (h) { return h.trim().toLowerCase(); });
    var out = [];
    for (var r = 1; r < rows.length; r++) {
      if (rows[r].length === 1 && rows[r][0].trim() === '') continue; // trailing blank line
      var obj = {};
      headers.forEach(function (h, idx) { obj[h] = rows[r][idx] != null ? rows[r][idx] : ''; });
      out.push(obj);
    }
    return out;
  }

  function handleCsvFileChange() {
    var input = $('csv-file-input');
    $('csv-upload-btn').disabled = !(input.files && input.files.length);
    show($('csv-summary'), false);
  }

  async function uploadCsv() {
    var input = $('csv-file-input');
    if (!input.files || !input.files.length) return;
    var file = input.files[0];
    if (file.size > 5 * 1024 * 1024) {
      showToast('That file is larger than 5 MB — split it into smaller batches.');
      return;
    }
    var text = await file.text();
    var rows = parseCSV(text);
    if (!rows.length) {
      showToast('No data rows found in that file.');
      return;
    }

    var btn = $('csv-upload-btn');
    btn.disabled = true;
    var res;
    try {
      res = await supabaseClient.rpc('admin_upsert_questions_csv', { p_rows: rows });
    } finally {
      btn.disabled = false;
    }
    if (res.error) { showToast(friendlyError(res, 'Upload failed.')); return; }

    var summary = res.data || {};
    var box = $('csv-summary');
    clearChildren(box);
    box.appendChild(el('p', null,
      summary.total + ' rows — ' + summary.created + ' created, ' + summary.updated + ' updated, ' +
      summary.duplicates + ' duplicates, ' + summary.invalid + ' invalid.'));
    (summary.errors || []).slice(0, 20).forEach(function (e) {
      box.appendChild(el('p', 'admin-error-line', 'Row ' + e.row + ': ' + e.reason));
    });
    if ((summary.errors || []).length > 20) {
      box.appendChild(el('p', 'admin-error-line', '…and ' + (summary.errors.length - 20) + ' more.'));
    }
    show(box, true);
    input.value = '';
    $('csv-upload-btn').disabled = true;
    loadQuestions();
  }

  // ----------------------------------------------------------- submissions
  async function loadSubmissions() {
    var tbody = $('submissions-tbody');
    clearChildren(tbody);
    var includeResolved = $('submissions-include-resolved').checked;
    var res = await supabaseClient.rpc('admin_list_submissions', {
      p_status: includeResolved ? null : 'needs_review', p_limit: 200, p_offset: 0
    });
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (s) {
      var row = el('tr');
      row.appendChild(el('td', null, s.submitted_by_email || '—'));
      row.appendChild(el('td', null, s.source || '—'));
      row.appendChild(el('td', null, s.domain_name || '—'));
      row.appendChild(el('td', null, (s.languages || []).join(', ').toUpperCase() || '—'));
      row.appendChild(el('td', 'admin-truncate', s.preview_text || '—'));
      row.appendChild(el('td', 'admin-truncate', s.matched_question_text || '—'));
      row.appendChild(el('td', 'num', s.similarity_score != null ? Number(s.similarity_score).toFixed(2) : '—'));
      row.appendChild(el('td', 'admin-truncate', s.ai_notes || '—'));
      row.appendChild(el('td', null, s.status));

      var actions = el('td', 'admin-actions');
      if (s.status === 'needs_review') {
        var approveBtn = el('button', 'btn btn-sm', 'Approve (add as new)');
        approveBtn.type = 'button';
        approveBtn.addEventListener('click', function () { reviewSubmission(s.id, true); });
        actions.appendChild(approveBtn);

        var rejectBtn = el('button', 'btn btn-sm', 'Reject');
        rejectBtn.type = 'button';
        rejectBtn.addEventListener('click', function () { reviewSubmission(s.id, false); });
        actions.appendChild(rejectBtn);
      }
      row.appendChild(actions);
      tbody.appendChild(row);
    });
  }

  async function reviewSubmission(id, approve) {
    var res = await supabaseClient.rpc('admin_review_submission', { p_submission_id: id, p_approve: approve });
    if (res.error) { showToast(friendlyError(res)); return; }
    showToast(approve ? 'Question added.' : 'Submission rejected.');
    loadSubmissions();
  }

  // -------------------------------------------------------------- settings
  async function loadSettings() {
    var tbody = $('settings-tbody');
    clearChildren(tbody);
    var res = await supabaseClient.rpc('admin_get_settings', {});
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (s) {
      var row = el('tr');
      row.appendChild(el('td', null, s.label + ' (' + s.key + ')'));
      var valueTd = el('td');
      var input = document.createElement('input');
      input.type = 'text';
      input.inputMode = 'numeric';
      input.value = s.value;
      valueTd.appendChild(input);
      row.appendChild(valueTd);

      var actionTd = el('td');
      var saveBtn = el('button', 'btn btn-sm', 'Save');
      saveBtn.type = 'button';
      saveBtn.addEventListener('click', function () { saveSetting(s.key, input.value); });
      actionTd.appendChild(saveBtn);
      row.appendChild(actionTd);

      tbody.appendChild(row);
    });
  }

  async function saveSetting(key, value) {
    var res = await supabaseClient.rpc('admin_set_setting', { p_key: key, p_value: String(value).trim() });
    if (res.error) { showToast(friendlyError(res)); return; }
    showToast('Setting saved.');
    loadSettings();
  }

  // ---------------------------------------------------------------- region
  async function loadRegion() {
    var settingsRes = await supabaseClient.rpc('admin_get_settings', {});
    if (settingsRes.error) { showToast(friendlyError(settingsRes)); return; }
    var continentsSetting = (settingsRes.data || []).filter(function (s) { return s.key === 'blocked_continents'; })[0];
    $('region-continents-input').value = continentsSetting ? continentsSetting.value : '';

    await loadIpBans();
  }

  async function saveContinents() {
    var value = $('region-continents-input').value.trim();
    if (!value) { showToast('Enter at least one continent, or clear the rule entirely by removing the block.'); return; }
    var res = await supabaseClient.rpc('admin_set_setting', { p_key: 'blocked_continents', p_value: value });
    if (res.error) { showToast(friendlyError(res)); return; }
    showToast('Blocked continents saved.');
  }

  async function loadIpBans() {
    var tbody = $('ip-bans-tbody');
    clearChildren(tbody);
    var res = await supabaseClient.rpc('admin_list_ip_bans', {});
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (b) {
      var row = el('tr');
      row.appendChild(el('td', 'mono', b.cidr));
      row.appendChild(el('td', null, b.reason || '—'));
      row.appendChild(el('td', null, b.created_by_email || '—'));
      row.appendChild(el('td', null, fmtDate(b.created_at)));
      var actionTd = el('td');
      var removeBtn = el('button', 'btn btn-sm', 'Remove');
      removeBtn.type = 'button';
      removeBtn.addEventListener('click', function () { removeIpBan(b.id); });
      actionTd.appendChild(removeBtn);
      row.appendChild(actionTd);
      tbody.appendChild(row);
    });
  }

  async function addIpBan() {
    var cidr = $('ip-ban-cidr-input').value.trim();
    var reason = $('ip-ban-reason-input').value.trim();
    if (!cidr) { showToast('Enter an IP address or CIDR range.'); return; }
    var res = await supabaseClient.rpc('admin_add_ip_ban', { p_cidr: cidr, p_reason: reason || null });
    if (res.error) { showToast(friendlyError(res, 'Could not add that ban.')); return; }
    showToast('Ban added.');
    $('ip-ban-cidr-input').value = '';
    $('ip-ban-reason-input').value = '';
    loadIpBans();
  }

  async function removeIpBan(id) {
    var res = await supabaseClient.rpc('admin_remove_ip_ban', { p_id: id });
    if (res.error) { showToast(friendlyError(res)); return; }
    loadIpBans();
  }

  // -------------------------------------------------------------- audit log
  async function loadAudit() {
    var tbody = $('audit-tbody');
    clearChildren(tbody);
    var res = await supabaseClient.rpc('admin_list_audit_log', { p_limit: 200, p_offset: 0 });
    if (res.error) { showToast(friendlyError(res)); return; }

    (res.data || []).forEach(function (a) {
      var row = el('tr');
      row.appendChild(el('td', null, fmtDate(a.created_at)));
      row.appendChild(el('td', null, a.actor_email || '—'));
      row.appendChild(el('td', null, a.action));
      row.appendChild(el('td', null, a.target || '—'));
      row.appendChild(el('td', 'admin-truncate', a.details ? JSON.stringify(a.details) : ''));
      tbody.appendChild(row);
    });
  }

  // ------------------------------------------------------------------ usage
  async function loadUsage() {
    var res = await supabaseClient.rpc('admin_usage_stats', { p_days: 30 });
    if (res.error) { showToast(friendlyError(res)); return; }
    var data = res.data || {};

    var statsWrap = $('usage-stats');
    clearChildren(statsWrap);
    [
      ['Total users', data.total_users],
      ['Admins', data.total_admins],
      ['Deactivated', data.total_banned],
      ['Active questions', data.total_questions],
      ['Open reports', data.open_reports]
    ].forEach(function (pair) {
      var box = el('div', 'stat-box');
      box.appendChild(el('div', 'num', String(pair[1] == null ? '–' : pair[1])));
      box.appendChild(el('div', 'lbl', pair[0]));
      statsWrap.appendChild(box);
    });

    var tbody = $('usage-daily-tbody');
    clearChildren(tbody);
    (data.daily || []).forEach(function (d) {
      var row = el('tr');
      row.appendChild(el('td', null, d.day));
      row.appendChild(el('td', 'num', String(d.guest_quizzes || 0)));
      row.appendChild(el('td', 'num', String(d.registered_quizzes || 0)));
      tbody.appendChild(row);
    });

    var countryTbody = $('usage-country-tbody');
    clearChildren(countryTbody);
    (data.by_country || []).forEach(function (c) {
      var row = el('tr');
      row.appendChild(el('td', null, c.country));
      row.appendChild(el('td', 'num', String(c.quizzes || 0)));
      countryTbody.appendChild(row);
    });
    if (!(data.by_country || []).length) {
      var empty = el('tr');
      var cell = el('td', 'muted', 'No quiz starts recorded yet.');
      cell.colSpan = 2;
      empty.appendChild(cell);
      countryTbody.appendChild(empty);
    }
  }

  // ------------------------------------------------------------------- init
  function bindEvents() {
    $('gate-login-form').addEventListener('submit', submitGateLogin);
    document.addEventListener('click', function (event) {
      var logoutBtn = event.target.closest('[data-action="log-out"]');
      if (logoutBtn) { logOut(); return; }
      var closeEdit = event.target.closest('[data-action="close-edit"]');
      if (closeEdit) { closeQuestionEditor(); return; }
      var tabBtn = event.target.closest('.admin-tab');
      if (tabBtn) { loadTab(tabBtn.getAttribute('data-tab')); return; }
    });

    $('users-search').addEventListener('input', debounce(loadUsers, 300));
    $('reported-include-resolved').addEventListener('change', loadReported);
    $('submissions-include-resolved').addEventListener('change', loadSubmissions);
    $('questions-search').addEventListener('input', debounce(loadQuestions, 300));
    $('csv-file-input').addEventListener('change', handleCsvFileChange);
    $('csv-upload-btn').addEventListener('click', uploadCsv);
    $('question-edit-form').addEventListener('submit', submitQuestionEdit);
    $('region-continents-save').addEventListener('click', saveContinents);
    $('ip-ban-add-btn').addEventListener('click', addIpBan);
  }

  function init() {
    bindEvents();
    supabaseClient.auth.onAuthStateChange(function (event) {
      if (event === 'SIGNED_OUT') {
        $('admin-screen-app').classList.remove('active');
        $('admin-screen-gate').classList.add('active');
        $('gate-message').textContent = 'Log in with an admin account.';
        show($('gate-login'), true);
      }
    });
    boot();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
