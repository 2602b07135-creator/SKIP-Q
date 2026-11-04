// Supabase Edge Function: sends Web Push when a booking is created or its status changes.
// Setup: supabase secrets set VAPID_PUBLIC=... VAPID_PRIVATE=... VAPID_SUBJECT=mailto:you@example.com
// Then Dashboard > Database > Webhooks > create a webhook on table "bookings" (Insert + Update) -> this function.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT")!, Deno.env.get("VAPID_PUBLIC")!, Deno.env.get("VAPID_PRIVATE")!);
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const MSG: Record<string, string> = {
  Confirmed: "Your booking is approved.", Rejected: "Your booking was rejected.",
  Waiting: "You’re checked in and in the queue.", "Your Turn": "It’s your turn! Please go in now.",
  "In Service": "Your service has started.", Completed: "All done. Thank you!", "No-show": "Your booking was marked as a no-show.",
};

Deno.serve(async (req) => {
  const { type, record: r, old_record: o } = await req.json();
  let userId: string | null = null, title = "Skip Q · " + r.code, body = "";
  if (type === "INSERT") { // tell the business owner a new request arrived
    const { data: b } = await db.from("businesses").select("owner_id,name").eq("id", r.business_id).single();
    userId = b?.owner_id ?? null; body = "New booking request " + r.code + " for " + r.t.slice(0, 5) + ".";
  } else if (type === "UPDATE" && r.status !== o?.status && MSG[r.status]) {
    userId = r.customer_id; body = MSG[r.status];
  }
  if (!userId || !body) return new Response("skip");
  const { data: subs } = await db.from("push_subscriptions").select("id,sub").eq("user_id", userId);
  await Promise.all((subs ?? []).map(async (s) => {
    try { await webpush.sendNotification(s.sub, JSON.stringify({ title, body, tag: r.code, icon: "icon.svg" })); }
    catch (e) { if (e.statusCode === 404 || e.statusCode === 410) await db.from("push_subscriptions").delete().eq("id", s.id); }
  }));
  return new Response("ok");
});
