// Sharpet — shared i18n helper.
// Include on every page: <script src="assets/i18n.js" defer></script>

window.STRINGS = {
  en: {
    nav_how: "How it works", nav_domains: "Domains", nav_teams: "For teams",
    nav_login: "Log in", nav_start: "Start quiz", exit_home: "Exit to home",

    hero_eyebrow: "No sign-up required",
    hero_title_1: "Prove you know", hero_title_hl: "your stack", hero_title_2: ", one question at a time.",
    hero_lead: "Pick your domains, set the pace, and see how you stack up. Play as a guest, or sign in to track your streaks over time.",
    hero_cta_play: "Start quiz →", hero_cta_how: "See how it works",
    hero_stat_domains: "domains covered", hero_stat_answers: "answers per question",

    how_eyebrow: "How it works", how_title: "Three steps. No account needed.",
    how_sub: "Guests get the full game — the only thing tied to an account is your history.",
    step1_title: "Set your scope", step1_body: "Choose up to five domains, or play across all of them. Pick 2, 3, or 4 answer choices per question.",
    step2_title: "Answer and validate", step2_body: "Select a choice, change your mind as much as you like, then lock it in. The right answer is always revealed.",
    step3_title: "See your score", step3_body: "Track your live tally as you go, end whenever you want, and get a summary the moment you're done.",

    domains_eyebrow: "Domains", domains_title: "Pick what you want to be tested on.",
    domains_sub: "Mix and match up to five, or select everything at once.",

    teams_eyebrow: "For registered users", teams_title: "Sign in to keep the receipts.",
    feat1_title: "Full history", feat1_body: "Every session saved, broken down by domain and by correct vs. incorrect.",
    feat2_title: "Progress over time", feat2_body: "See your accuracy trend across the last 7 and 30 days.",
    feat3_title: "Friends and invites", feat3_body: "Invite teammates, compare scores, and see where you rank.",
    feat4_title: "Flag a bad question", feat4_body: "Think none of the answers are right? Report it straight to an admin.",
    stat_accuracy_30d: "accuracy, last 30 days", stat_questions_answered: "questions answered",

    cta_title: "Ready to test what you know?", cta_sub: "Jump in as a guest right now — no account, no setup beyond picking your domains.",
    cta_play: "Start quiz →", cta_create: "Create an account",
    footer_privacy: "Privacy",

    landing_title: "Ready when you are.", landing_lead: "Play as a guest right now, or log in to save your streaks and stats.",
    landing_guest: "Start quiz →", landing_login: "Log in",

    home_welcome: "Welcome back",
    home_play: "Play quiz →", home_logout: "Log out",
    home_streak_empty: "No streak yet — play your first quiz today.",
    home_stat_7d: "Accuracy (7d)", home_stat_30d: "Accuracy (30d)",
    home_stat_streak: "Longest streak", home_stat_total: "Total answered",
    home_progress: "Progress over time", home_progress_empty: "Your accuracy trend will show up here after a few sessions.",
    home_domains: "Weakest domains", home_domains_empty: "Play across a few domains to see a breakdown.",
    home_history: "Session history", home_history_empty: "No sessions yet.",
    home_history_in_progress: "In progress",
    home_reported: "Reported questions", home_reported_empty: "You haven't reported any questions.",
    home_view_all: "View all",
    home_streak_active: "{count}-day streak",

    login_title: "Log in", login_title_signup: "Create your account",
    login_sub: "Track your streaks, history, and where you rank.",
    login_sub_signup: "One account, every device — your history follows you.",
    field_email: "Email", field_password: "Password", field_nickname: "Nickname",
    login_submit: "Log in", login_submit_signup: "Create account",
    login_toggle_to_signup: "Need an account? Sign up", login_toggle_to_login: "Already have an account? Log in", login_err_email: "Enter a valid email address (at least 5 characters).",
    login_err_password_rules: "Your password doesn't meet all the requirements below yet.",
    pw_rule_length: "At least 10 characters", pw_rule_case: "Upper and lower case",
    pw_rule_digit: "A number", pw_rule_symbol: "A symbol",
    login_err_nickname: "Nickname must be at least 5 characters (letters, numbers, underscore only).",
    toast_signup_sent: "Account created — we've sent a confirmation email. Please confirm your address before logging in.",
    login_forgot: "Forgot your password?",
    field_new_password: "New password", field_confirm_password: "Confirm new password",
    reset_request_title: "Reset your password",
    reset_request_sub: "Enter the email on your account and we'll send you a link to set a new password.",
    reset_request_submit: "Send reset link", reset_request_back: "← Back to log in",
    toast_reset_sent: "If that email has an account, we've sent a link to reset your password. It's valid for 1 day.",
    reset_password_title: "Choose a new password",
    reset_password_sub: "Your reset link checked out. Set a new password to finish.",
    reset_password_submit: "Update password",
    reset_err_mismatch: "Passwords don't match.",
    toast_reset_success: "Your password has been updated. Log in with your new password.",
    toast_reset_link_invalid: "That reset link has expired or was already used. Request a new one below.",

    setup_eyebrow: "Set up your game",
    field_domains: "Domains", field_domains_hint: "— up to 5",
    field_answers: "Answers per question", opt_2: "2 options", opt_3: "3 options", opt_4: "4 options",
    field_count: "Number of questions",
    setup_start: "Start →", setup_hint_pick: "Pick at least one domain to continue",
    setup_hint_selected: "{n} domain(s) selected", setup_hint_error: "Could not load domains — check your Supabase config.",
    all_domains: "All domains",

    captcha_title: "Quick check", captcha_sub: "Just making sure you're human.",
    captcha_placeholder: "Your answer", captcha_verify: "Verify", captcha_error: "Not quite — try a new one.",

    q_progress: "Question {current} of {total}", q_score: "Score: {correct}/{total}",
    validate: "Validate", back: "← Back", next: "Next →",
    report: "⚑ Report question as incorrect", end_game: "End game",
    correct_msg: "Correct!", wrong_msg: "Not quite — the correct answer is highlighted above.",
    reported_msg: "Reported to an admin for review — thanks for the flag.",
    load_error: "Could not load questions. Check your Supabase config.",

    summary_title: "Game over", summary_lead: "Here's how you did.",
    stat_correct: "Correct", stat_accuracy: "Accuracy",
    summary_note_guest: "Guest session — log in next time to save this and track progress over time.",
    summary_note_saved: "Saved to your history — see it anytime under your stats.",
    play_again: "Play again", view_stats: "View my stats",

    domain_geography: "Geography", domain_history: "History", domain_science: "Science & Physics", domain_space: "Space & Astronomy",
    domain_tech: "Technology & Computing", domain_pharmacy: "Pharmacy & Medicine",
    domain_nature: "Nature & Environment", domain_mythology: "Mythology & Religion",
    domain_more: "…and nine more",

    hero_stat_questions: "questions in three languages",
    sample_data: "Example dashboard",
    demo_head: "Question 4 of 10 · Security",
    demo_question: "Which protocol is used to securely transfer files over a network?",
    demo_correct: "Correct — nice.",
    demo_wrong: "Not quite — {answer} was the answer.",

    login_err_password_required: "Enter your password.",
    err_login_failed: "That email and password combination didn't work.",
    err_signup_failed: "We couldn't complete the sign-up. Please try again.",
    err_reset_failed: "We couldn't update your password. Request a new reset link and try again.",
    err_rate_limited: "Too many attempts. Please wait a few minutes and try again.",

    captcha_too_many: "Too many wrong answers — let's start over.",
    load_empty: "No questions available for those domains yet. Try picking another one.",
    answer_error: "Couldn't submit that answer. Check your connection and try again.",
    report_error: "Couldn't send the report right now. Please try again later.",
    coming_soon: "Not built yet — coming soon.",
    chart_day_summary: "{total} answered, {correct} correct, {wrong} incorrect"
  },

  de: {
    nav_how: "So funktioniert's", nav_domains: "Bereiche", nav_teams: "Für Teams",
    nav_login: "Anmelden", nav_start: "Quiz starten", exit_home: "Zur Startseite",

    hero_eyebrow: "Keine Anmeldung nötig",
    hero_title_1: "Beweise, dass du", hero_title_hl: "deinen Stack", hero_title_2: " kennst — Frage für Frage.",
    hero_lead: "Wähle deine Bereiche, bestimme das Tempo und sieh, wie gut du abschneidest. Spiele als Gast oder melde dich an, um deine Serien zu verfolgen.",
    hero_cta_play: "Quiz starten →", hero_cta_how: "So funktioniert's",
    hero_stat_domains: "Bereiche verfügbar", hero_stat_answers: "Antworten pro Frage",

    how_eyebrow: "So funktioniert's", how_title: "Drei Schritte. Kein Konto nötig.",
    how_sub: "Gäste bekommen das komplette Spiel — nur der Verlauf ist an ein Konto gebunden.",
    step1_title: "Bereich festlegen", step1_body: "Wähle bis zu fünf Bereiche oder spiele über alle hinweg. Wähle 2, 3 oder 4 Antwortmöglichkeiten pro Frage.",
    step2_title: "Antworten und bestätigen", step2_body: "Wähle eine Antwort, ändere sie so oft du willst, und bestätige sie dann. Die richtige Antwort wird immer angezeigt.",
    step3_title: "Punktestand sehen", step3_body: "Verfolge deinen Punktestand live, beende jederzeit und erhalte sofort eine Zusammenfassung.",

    domains_eyebrow: "Bereiche", domains_title: "Wähle, worauf du getestet werden möchtest.",
    domains_sub: "Kombiniere bis zu fünf Bereiche oder wähle alle auf einmal.",

    teams_eyebrow: "Für registrierte Nutzer", teams_title: "Melde dich an, um alles festzuhalten.",
    feat1_title: "Vollständiger Verlauf", feat1_body: "Jede Runde wird gespeichert, aufgeschlüsselt nach Bereich sowie richtig und falsch.",
    feat2_title: "Fortschritt über Zeit", feat2_body: "Sieh deinen Genauigkeitstrend der letzten 7 und 30 Tage.",
    feat3_title: "Freunde und Einladungen", feat3_body: "Lade Teamkolleg:innen ein, vergleiche Ergebnisse und sieh, wo du stehst.",
    feat4_title: "Fehlerhafte Frage melden", feat4_body: "Denkst du, keine Antwort stimmt? Melde es direkt an eine Administration.",
    stat_accuracy_30d: "Genauigkeit, letzte 30 Tage", stat_questions_answered: "beantwortete Fragen",

    cta_title: "Bereit, dein Wissen zu testen?", cta_sub: "Starte jetzt als Gast — kein Konto nötig, nur Bereiche auswählen.",
    cta_play: "Quiz starten →", cta_create: "Konto erstellen",
    footer_privacy: "Datenschutz",

    landing_title: "Bereit, wenn du es bist.", landing_lead: "Spiele jetzt als Gast oder melde dich an, um deine Serien und Statistiken zu speichern.",
    landing_guest: "Quiz starten →", landing_login: "Anmelden",

    home_welcome: "Willkommen zurück",
    home_play: "Quiz starten →", home_logout: "Abmelden",
    home_streak_empty: "Noch keine Serie — starte heute dein erstes Quiz.",
    home_stat_7d: "Genauigkeit (7T)", home_stat_30d: "Genauigkeit (30T)",
    home_stat_streak: "Längste Serie", home_stat_total: "Beantwortet gesamt",
    home_progress: "Verlauf über Zeit", home_progress_empty: "Dein Genauigkeitsverlauf erscheint hier nach ein paar Sitzungen.",
    home_domains: "Schwächste Bereiche", home_domains_empty: "Spiele in mehreren Bereichen, um eine Aufschlüsselung zu sehen.",
    home_history: "Sitzungsverlauf", home_history_empty: "Noch keine Sitzungen.",
    home_history_in_progress: "Läuft noch",
    home_reported: "Gemeldete Fragen", home_reported_empty: "Du hast noch keine Fragen gemeldet.",
    home_view_all: "Alle anzeigen",
    home_streak_active: "{count}-Tage-Serie",

    login_title: "Anmelden", login_title_signup: "Konto erstellen",
    login_sub: "Verfolge deine Serien, deinen Verlauf und deine Platzierung.",
    login_sub_signup: "Ein Konto, jedes Gerät — dein Verlauf bleibt erhalten.",
    field_email: "E-Mail", field_password: "Passwort", field_nickname: "Nickname",
    login_submit: "Anmelden", login_submit_signup: "Konto erstellen",
    login_toggle_to_signup: "Noch kein Konto? Registrieren", login_toggle_to_login: "Schon ein Konto? Anmelden", login_err_email: "Bitte eine gültige E-Mail-Adresse eingeben (mindestens 5 Zeichen).",
    login_err_password_rules: "Dein Passwort erfüllt noch nicht alle Anforderungen unten.",
    pw_rule_length: "Mindestens 10 Zeichen", pw_rule_case: "Groß- und Kleinbuchstaben",
    pw_rule_digit: "Eine Ziffer", pw_rule_symbol: "Ein Sonderzeichen",
    login_err_nickname: "Der Nickname muss mindestens 5 Zeichen haben (nur Buchstaben, Zahlen, Unterstrich).",
    toast_signup_sent: "Konto erstellt — wir haben dir eine Bestätigungs-E-Mail geschickt. Bitte bestätige deine Adresse, bevor du dich anmeldest.",
    login_forgot: "Passwort vergessen?",
    field_new_password: "Neues Passwort", field_confirm_password: "Neues Passwort bestätigen",
    reset_request_title: "Passwort zurücksetzen",
    reset_request_sub: "Gib die E-Mail-Adresse deines Kontos ein — wir schicken dir einen Link zum Zurücksetzen deines Passworts.",
    reset_request_submit: "Link senden", reset_request_back: "← Zurück zur Anmeldung",
    toast_reset_sent: "Falls diese E-Mail-Adresse ein Konto hat, haben wir einen Link zum Zurücksetzen des Passworts gesendet. Er ist 1 Tag gültig.",
    reset_password_title: "Neues Passwort wählen",
    reset_password_sub: "Dein Reset-Link war gültig. Lege jetzt ein neues Passwort fest.",
    reset_password_submit: "Passwort aktualisieren",
    reset_err_mismatch: "Die Passwörter stimmen nicht überein.",
    toast_reset_success: "Dein Passwort wurde aktualisiert. Melde dich mit dem neuen Passwort an.",
    toast_reset_link_invalid: "Dieser Reset-Link ist abgelaufen oder wurde bereits verwendet. Fordere unten einen neuen an.",

    setup_eyebrow: "Spiel einrichten",
    field_domains: "Bereiche", field_domains_hint: "— bis zu 5",
    field_answers: "Antworten pro Frage", opt_2: "2 Antworten", opt_3: "3 Antworten", opt_4: "4 Antworten",
    field_count: "Anzahl der Fragen",
    setup_start: "Starten →", setup_hint_pick: "Wähle mindestens einen Bereich aus",
    setup_hint_selected: "{n} Bereich(e) ausgewählt", setup_hint_error: "Bereiche konnten nicht geladen werden — Supabase-Konfiguration prüfen.",
    all_domains: "Alle Bereiche",

    captcha_title: "Kurze Prüfung", captcha_sub: "Wir stellen nur sicher, dass du ein Mensch bist.",
    captcha_placeholder: "Deine Antwort", captcha_verify: "Bestätigen", captcha_error: "Nicht ganz — versuch es erneut.",

    q_progress: "Frage {current} von {total}", q_score: "Punkte: {correct}/{total}",
    validate: "Bestätigen", back: "← Zurück", next: "Weiter →",
    report: "⚑ Frage als falsch melden", end_game: "Spiel beenden",
    correct_msg: "Richtig!", wrong_msg: "Nicht ganz — die richtige Antwort ist oben markiert.",
    reported_msg: "An eine Administration zur Prüfung gemeldet — danke für den Hinweis.",
    load_error: "Fragen konnten nicht geladen werden. Supabase-Konfiguration prüfen.",

    summary_title: "Spiel beendet", summary_lead: "So hast du abgeschnitten.",
    stat_correct: "Richtig", stat_accuracy: "Genauigkeit",
    summary_note_guest: "Gastsitzung — melde dich beim nächsten Mal an, um dies zu speichern und deinen Fortschritt zu verfolgen.",
    summary_note_saved: "In deinem Verlauf gespeichert — jederzeit unter deinen Statistiken einsehbar.",
    play_again: "Nochmal spielen", view_stats: "Meine Statistiken",

    domain_geography: "Geografie", domain_history: "Geschichte", domain_science: "Wissenschaft & Physik", domain_space: "Weltraum & Astronomie",
    domain_tech: "Technik & Informatik", domain_pharmacy: "Pharmazie & Medizin",
    domain_nature: "Natur & Umwelt", domain_mythology: "Mythologie & Religion",
    domain_more: "…und neun weitere",

    hero_stat_questions: "Fragen in drei Sprachen",
    sample_data: "Beispiel-Dashboard",
    demo_head: "Frage 4 von 10 · Sicherheit",
    demo_question: "Welches Protokoll überträgt Dateien sicher über ein Netzwerk?",
    demo_correct: "Richtig — stark.",
    demo_wrong: "Knapp daneben — {answer} war die Antwort.",

    login_err_password_required: "Bitte gib dein Passwort ein.",
    err_login_failed: "Diese Kombination aus E-Mail und Passwort hat nicht funktioniert.",
    err_signup_failed: "Die Registrierung hat nicht geklappt. Bitte versuche es erneut.",
    err_reset_failed: "Das Passwort konnte nicht geändert werden. Fordere einen neuen Link an.",
    err_rate_limited: "Zu viele Versuche. Bitte warte ein paar Minuten.",

    captcha_too_many: "Zu viele Fehlversuche — wir fangen neu an.",
    load_empty: "Für diese Bereiche gibt es noch keine Fragen. Wähle einen anderen.",
    answer_error: "Antwort konnte nicht gesendet werden. Prüfe deine Verbindung.",
    report_error: "Die Meldung konnte gerade nicht gesendet werden. Bitte später erneut versuchen.",
    coming_soon: "Noch nicht gebaut — kommt bald.",
    chart_day_summary: "{total} beantwortet, {correct} richtig, {wrong} falsch"
  },

  cs: {
    nav_how: "Jak to funguje", nav_domains: "Oblasti", nav_teams: "Pro týmy",
    nav_login: "Přihlásit se", nav_start: "Spustit kvíz", exit_home: "Zpět na úvod",

    hero_eyebrow: "Registrace není nutná",
    hero_title_1: "Dokaž, že znáš", hero_title_hl: "svůj obor", hero_title_2: " — otázku po otázce.",
    hero_lead: "Vyber si oblasti, nastav si tempo a zjisti, na čem jsi. Hraj jako host, nebo se přihlas a sleduj svou sérii v čase.",
    hero_cta_play: "Spustit kvíz →", hero_cta_how: "Jak to funguje",
    hero_stat_domains: "dostupných oblastí", hero_stat_answers: "odpovědí na otázku",

    how_eyebrow: "Jak to funguje", how_title: "Tři kroky. Bez nutnosti účtu.",
    how_sub: "Hosté mají k dispozici celou hru — jediné, co je vázané na účet, je historie.",
    step1_title: "Nastav si rozsah", step1_body: "Vyber až pět oblastí, nebo hraj napříč všemi. Zvol 2, 3 nebo 4 možnosti odpovědi na otázku.",
    step2_title: "Odpověz a potvrď", step2_body: "Vyber možnost, klidně si to rozmysli, a pak ji potvrď. Správná odpověď se vždy zobrazí.",
    step3_title: "Sleduj své skóre", step3_body: "Sleduj skóre průběžně, kdykoliv hru ukonči a hned dostaneš shrnutí.",

    domains_eyebrow: "Oblasti", domains_title: "Vyber si, z čeho chceš být testován.",
    domains_sub: "Zkombinuj až pět oblastí, nebo vyber všechny najednou.",

    teams_eyebrow: "Pro registrované uživatele", teams_title: "Přihlas se a měj vše zaznamenané.",
    feat1_title: "Kompletní historie", feat1_body: "Každá hra se uloží, rozdělená podle oblasti a podle správných/nesprávných odpovědí.",
    feat2_title: "Vývoj v čase", feat2_body: "Sleduj trend své úspěšnosti za posledních 7 a 30 dní.",
    feat3_title: "Přátelé a pozvánky", feat3_body: "Pozvi kolegy z týmu, porovnej skóre a zjisti, na jakém jsi místě.",
    feat4_title: "Nahlásit špatnou otázku", feat4_body: "Myslíš, že žádná odpověď není správná? Nahlas to přímo administrátorovi.",
    stat_accuracy_30d: "úspěšnost za posledních 30 dní", stat_questions_answered: "zodpovězených otázek",

    cta_title: "Připraven otestovat své znalosti?", cta_sub: "Zapoj se hned teď jako host — žádný účet, jen výběr oblastí.",
    cta_play: "Spustit kvíz →", cta_create: "Vytvořit účet",
    footer_privacy: "Ochrana soukromí",

    landing_title: "Připraveno, kdykoliv budeš chtít.", landing_lead: "Hraj hned jako host, nebo se přihlas a ulož si své série a statistiky.",
    landing_guest: "Spustit kvíz →", landing_login: "Přihlásit se",

    home_welcome: "Vítej zpět",
    home_play: "Spustit kvíz →", home_logout: "Odhlásit se",
    home_streak_empty: "Zatím žádná série — zahraj si dnes svůj první kvíz.",
    home_stat_7d: "Úspěšnost (7 dní)", home_stat_30d: "Úspěšnost (30 dní)",
    home_stat_streak: "Nejdelší série", home_stat_total: "Zodpovězeno celkem",
    home_progress: "Vývoj v čase", home_progress_empty: "Tvůj trend úspěšnosti se zde zobrazí po několika hrách.",
    home_domains: "Nejslabší oblasti", home_domains_empty: "Zahraj si napříč více oblastmi a uvidíš rozpis.",
    home_history: "Historie her", home_history_empty: "Zatím žádné hry.",
    home_history_in_progress: "Probíhá",
    home_reported: "Nahlášené otázky", home_reported_empty: "Zatím jsi nenahlásil žádnou otázku.",
    home_view_all: "Zobrazit vše",
    home_streak_active: "Série {count} dní",

    login_title: "Přihlásit se", login_title_signup: "Vytvořit účet",
    login_sub: "Sleduj své série, historii a umístění.",
    login_sub_signup: "Jeden účet, každé zařízení — tvoje historie tě bude následovat.",
    field_email: "E-mail", field_password: "Heslo", field_nickname: "Přezdívka",
    login_submit: "Přihlásit se", login_submit_signup: "Vytvořit účet",
    login_toggle_to_signup: "Nemáš účet? Zaregistruj se", login_toggle_to_login: "Už máš účet? Přihlas se", login_err_email: "Zadej platnou e-mailovou adresu (alespoň 5 znaků).",
    login_err_password_rules: "Heslo zatím nesplňuje všechny požadavky níže.",
    pw_rule_length: "Alespoň 10 znaků", pw_rule_case: "Velká i malá písmena",
    pw_rule_digit: "Číslici", pw_rule_symbol: "Speciální znak",
    login_err_nickname: "Přezdívka musí mít alespoň 5 znaků (pouze písmena, čísla, podtržítko).",
    toast_signup_sent: "Účet vytvořen — poslali jsme ti potvrzovací e-mail. Před přihlášením prosím potvrď svou adresu.",
    login_forgot: "Zapomněl jsi heslo?",
    field_new_password: "Nové heslo", field_confirm_password: "Potvrď nové heslo",
    reset_request_title: "Obnovení hesla",
    reset_request_sub: "Zadej e-mail svého účtu a pošleme ti odkaz pro nastavení nového hesla.",
    reset_request_submit: "Odeslat odkaz", reset_request_back: "← Zpět na přihlášení",
    toast_reset_sent: "Pokud k tomuto e-mailu existuje účet, poslali jsme odkaz pro obnovení hesla. Je platný 1 den.",
    reset_password_title: "Zvol nové heslo",
    reset_password_sub: "Tvůj odkaz pro obnovení hesla je platný. Nastav si nové heslo.",
    reset_password_submit: "Aktualizovat heslo",
    reset_err_mismatch: "Hesla se neshodují.",
    toast_reset_success: "Heslo bylo aktualizováno. Přihlas se novým heslem.",
    toast_reset_link_invalid: "Odkaz pro obnovení hesla vypršel nebo už byl použit. Níže si vyžádej nový.",

    setup_eyebrow: "Nastavení hry",
    field_domains: "Oblasti", field_domains_hint: "— až 5",
    field_answers: "Odpovědí na otázku", opt_2: "2 možnosti", opt_3: "3 možnosti", opt_4: "4 možnosti",
    field_count: "Počet otázek",
    setup_start: "Začít →", setup_hint_pick: "Vyber alespoň jednu oblast",
    setup_hint_selected: "Vybráno oblastí: {n}", setup_hint_error: "Oblasti se nepodařilo načíst — zkontroluj nastavení Supabase.",
    all_domains: "Všechny oblasti",

    captcha_title: "Rychlá kontrola", captcha_sub: "Jen si ověřujeme, že jsi člověk.",
    captcha_placeholder: "Tvoje odpověď", captcha_verify: "Ověřit", captcha_error: "Není to ono — zkus to znovu.",

    q_progress: "Otázka {current} z {total}", q_score: "Skóre: {correct}/{total}",
    validate: "Potvrdit", back: "← Zpět", next: "Další →",
    report: "⚑ Nahlásit otázku jako nesprávnou", end_game: "Ukončit hru",
    correct_msg: "Správně!", wrong_msg: "Není to ono — správná odpověď je zvýrazněná výše.",
    reported_msg: "Nahlášeno administrátorovi ke kontrole — díky za upozornění.",
    load_error: "Otázky se nepodařilo načíst. Zkontroluj nastavení Supabase.",

    summary_title: "Hra skončila", summary_lead: "Takhle sis vedl/a.",
    stat_correct: "Správně", stat_accuracy: "Úspěšnost",
    summary_note_guest: "Hra jako host — příště se přihlas, aby se výsledek uložil a šlo sledovat pokrok.",
    summary_note_saved: "Uloženo do tvé historie — kdykoliv dostupné ve statistikách.",
    play_again: "Hrát znovu", view_stats: "Moje statistiky",

    domain_geography: "Zeměpis", domain_history: "Historie", domain_science: "Věda a fyzika", domain_space: "Vesmír a astronomie",
    domain_tech: "Technika a výpočetní technika", domain_pharmacy: "Farmacie a medicína",
    domain_nature: "Příroda a životní prostředí", domain_mythology: "Mytologie a náboženství",
    domain_more: "…a dalších devět",

    hero_stat_questions: "otázek ve třech jazycích",
    sample_data: "Ukázkový přehled",
    demo_head: "Otázka 4 z 10 · Bezpečnost",
    demo_question: "Který protokol slouží k bezpečnému přenosu souborů po síti?",
    demo_correct: "Správně — paráda.",
    demo_wrong: "Těsně vedle — správně bylo {answer}.",

    login_err_password_required: "Zadej svoje heslo.",
    err_login_failed: "Tahle kombinace e-mailu a hesla nefunguje.",
    err_signup_failed: "Registraci se nepodařilo dokončit. Zkus to prosím znovu.",
    err_reset_failed: "Heslo se nepodařilo změnit. Vyžádej si nový odkaz a zkus to znovu.",
    err_rate_limited: "Příliš mnoho pokusů. Počkej pár minut a zkus to znovu.",

    captcha_too_many: "Příliš mnoho špatných odpovědí — začínáme znovu.",
    load_empty: "Pro tyhle oblasti zatím nejsou žádné otázky. Zkus vybrat jinou.",
    answer_error: "Odpověď se nepodařilo odeslat. Zkontroluj připojení a zkus to znovu.",
    report_error: "Nahlášení se teď nepodařilo odeslat. Zkus to prosím později.",
    coming_soon: "Zatím není hotové — připravujeme.",
    chart_day_summary: "{total} zodpovězeno, {correct} správně, {wrong} špatně"
  }
};

(function(){
  var SUPPORTED = ['en','de','cs'];

  window.getLang = function(){
    var stored = localStorage.getItem('sharpet_lang');
    if(stored && SUPPORTED.indexOf(stored) !== -1) return stored;
    var browserLang = (navigator.language || 'en').slice(0,2);
    return SUPPORTED.indexOf(browserLang) !== -1 ? browserLang : 'en';
  };

  window.setLang = function(lang){
    if(SUPPORTED.indexOf(lang) === -1) return;
    localStorage.setItem('sharpet_lang', lang);
    window.applyI18n();
    if(typeof window.onLangChange === 'function') window.onLangChange(lang);
  };

  window.toggleLangMenu = function(e){
    if(e) e.stopPropagation();
    var opts = document.getElementById('lang-options');
    var trigger = document.getElementById('lang-trigger');
    if(!opts) return;
    var open = opts.classList.toggle('open');
    if(trigger) trigger.setAttribute('aria-expanded', open ? 'true' : 'false');
  };

  document.addEventListener('click', function(e){
    var opts = document.getElementById('lang-options');
    if(!opts || !opts.classList.contains('open')) return;
    var wrap = document.getElementById('lang-switch');
    if(wrap && !wrap.contains(e.target)){
      opts.classList.remove('open');
      var trigger = document.getElementById('lang-trigger');
      if(trigger) trigger.setAttribute('aria-expanded', 'false');
    }
  });

  // t('key') or t('key', {current:1, total:10}) for strings with {placeholders}.
  // Every occurrence of a placeholder is replaced in a single pass, so a value
  // that happens to contain "{something}" is never re-scanned.
  window.t = function(key, vars){
    var lang = window.getLang();
    var table = window.STRINGS[lang] || window.STRINGS.en;
    var str = table[key];
    if(str == null) str = window.STRINGS.en[key];
    if(str == null) return key;
    if(!vars) return str;
    return str.replace(/\{(\w+)\}/g, function(match, name){
      return Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : match;
    });
  };

  window.applyI18n = function(){
    var lang = window.getLang();
    document.documentElement.lang = lang;

    document.querySelectorAll('[data-i18n]').forEach(function(el){
      el.textContent = window.t(el.getAttribute('data-i18n'));
    });
    document.querySelectorAll('[data-i18n-placeholder]').forEach(function(el){
      el.placeholder = window.t(el.getAttribute('data-i18n-placeholder'));
    });

    document.querySelectorAll('.lang-switch [data-lang]').forEach(function(btn){
      btn.classList.toggle('active', btn.getAttribute('data-lang') === lang);
    });
    document.querySelectorAll('.lang-trigger-label').forEach(function(el){
      el.textContent = lang.toUpperCase();
    });
    var opts = document.getElementById('lang-options');
    if(opts) opts.classList.remove('open');
    var trigger = document.getElementById('lang-trigger');
    if(trigger) trigger.setAttribute('aria-expanded', 'false');
  };

  // applyI18n() is deliberately NOT wired to DOMContentLoaded. Each page's
  // script calls it once during its own init, so the order is deterministic:
  // a late auto-call would overwrite text those scripts had already set.
})();
