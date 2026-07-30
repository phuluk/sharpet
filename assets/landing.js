/* Sharpet — landing page interactivity.
 * Extracted from the inline <script> in index.html and converted to event
 * delegation so the page needs no 'unsafe-inline' in script-src. */
'use strict';

(function () {
  var selected = null;
  var validated = false;

  function pickDemo(button) {
    if (validated) return;
    document.querySelectorAll('.demo-opt').forEach(function (o) {
      o.classList.remove('selected');
      o.setAttribute('aria-pressed', 'false');
    });
    button.classList.add('selected');
    button.setAttribute('aria-pressed', 'true');
    selected = button;
  }

  function validateDemo() {
    if (!selected || validated) return;
    validated = true;

    var wasCorrect = selected.getAttribute('data-demo-correct') === 'true';
    var correctLabel = '';

    document.querySelectorAll('.demo-opt').forEach(function (o) {
      if (o.getAttribute('data-demo-correct') === 'true') {
        o.classList.add('correct');
        correctLabel = o.textContent.trim();
      }
    });
    if (!wasCorrect) {
      selected.classList.remove('selected');
      selected.classList.add('wrong');
    }

    var snackbar = document.getElementById('demo-snackbar');
    snackbar.className = 'demo-snackbar mono show ' + (wasCorrect ? 'ok' : 'bad');
    snackbar.textContent = wasCorrect
      ? t('demo_correct')
      : t('demo_wrong', { answer: correctLabel });
  }

  document.addEventListener('click', function (event) {
    var option = event.target.closest('.demo-opt');
    if (option) { pickDemo(option); return; }

    var action = event.target.closest('[data-action]');
    if (!action) return;
    var name = action.getAttribute('data-action');
    if (name === 'demo-validate') { validateDemo(); }
    else if (name === 'toggle-lang-menu') { window.toggleLangMenu(event); }
    else if (name === 'set-lang') { window.setLang(action.getAttribute('data-lang')); }
  });

  window.applyI18n();
})();
