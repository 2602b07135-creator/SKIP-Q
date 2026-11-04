# Skip Q setup
1. Supabase: create a project, run `schema.sql` (enable pg_cron first), put URL + anon key at the top of `index.html`.
2. Deploy index.html, sw.js, manifest.webmanifest, icon.svg together over HTTPS (Netlify/Vercel).
3. Push when closed: `npx web-push generate-vapid-keys`; paste the public key into `VAPID_PUBLIC` in index.html;
   `supabase secrets set VAPID_PUBLIC=... VAPID_PRIVATE=... VAPID_SUBJECT=mailto:you@example.com`;
   `supabase functions deploy send-push --no-verify-jwt`;
   Dashboard > Database > Webhooks: new webhook on `bookings` (Insert, Update) -> Edge Function `send-push`.
4. Auth > URL config: add your site URL for email verification and password-reset links.
