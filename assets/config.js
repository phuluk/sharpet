/* Sharpet — deployment configuration.
 *
 * The anon key is a publishable key: it identifies the project, it is not a
 * secret, and it is designed to sit in a browser. What actually protects the
 * data is the Row Level Security in db/04_security.sql plus the SECURITY
 * DEFINER functions in db/05_rpc.sql — never the obscurity of this value.
 *
 * Never put a service_role key here. That one bypasses RLS entirely.
 *
 * turnstileSiteKey is also public by design — Cloudflare's Turnstile site
 * keys are meant to ship in client code, same as the Supabase anon key. The
 * matching *secret* key lives only in Supabase Vault (see db/06_hardening.sql
 * and SECURITY.md), never here.
 */
window.SHARPET_CONFIG = Object.freeze({
  supabaseUrl: 'https://phpyzytedzkitbmrefca.supabase.co',
  supabaseAnonKey: 'sb_publishable_xvMowpzAzl1Cw2CB2Dlndw_vr_Z8woi',
  turnstileSiteKey: '0x4AAAAAAECmEyMdFOnLuYbo'
});
