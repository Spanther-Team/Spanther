// Deletes the signed-in adult's account at once: the auth user goes, and the database removes the account, its
// players and their plays with it (on delete cascade, see the migration). App Store guideline 5.1.1(v).
// The phone keeps its players locally unless the person deletes them there too.
//
// A sketch for stage 2, not deployed yet: `supabase functions deploy delete-account`.
// The app calls it with the user's own token: POST /functions/v1/delete-account, Authorization: Bearer <access token>.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are given to the function by Supabase; the service role key never goes
// into the app or the repository.
//
// Before release: an account made with Sign in with Apple must also have its Apple token revoked
// (https://appleid.apple.com/auth/revoke). That needs the team's Sign in with Apple key, which is kept only as a
// function secret (`supabase secrets set`), never in the repository or in a chat.
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return new Response("sign in first", { status: 401 });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Whose token it is: only that user is deleted, never one named in the request.
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return new Response("sign in first", { status: 401 });

  const gone = await admin.auth.admin.deleteUser(data.user.id);
  if (gone.error) return new Response("could not delete the account", { status: 500 });
  return new Response(null, { status: 204 });
});
