# Quick Badminton Tournament

A responsive badminton tournament website starter with a demo mode, Supabase/PostgreSQL data layer, Razorpay order creation and signature verification, admin controls, player registration, singles/doubles leaderboards, and full-screen LED leaderboard pages.

## What is included

- Public landing page and mobile-responsive design.
- Player registration with generated Player ID.
- Singles entry minimum ₹100; doubles minimum ₹200; minimum entry is described as including two matches.
- Supabase tables for players, tournaments, tournament entries, matches, payments and admins.
- Admin sign-in through Supabase Auth.
- Admin dashboard for player directory, registration/payment stats, tournament creation and match result entry.
- Match scoring: singles winner +1 / loser -1; doubles awards +1 to each winning partner and -1 to each losing partner.
- Independent singles and doubles rankings.
- LED display URLs: `/leaderboard?type=singles` and `/leaderboard?type=doubles`; refreshes every 30 seconds.
- Razorpay server-side order creation and signature verification endpoints, plus webhook endpoint.
- Public leaderboard view excludes player phone and email fields.

## Run locally in demo mode

1. Install Node.js 18 or newer.
2. In this folder, run:

   ```bash
   npm install
   npm start
   ```

3. Open `http://localhost:3000`.

Demo mode stores test registrations in the current browser's local storage. It does not create real accounts, collect payments, or provide secure admin access. Demo admin login is intentionally disabled.

## Connect Supabase

1. Create a Supabase project.
2. Open **SQL Editor** and run the complete `sql/schema.sql` file.
3. In Supabase **Authentication → Users**, create your admin user.
4. Copy that user's UUID and run this SQL, replacing the placeholder:

   ```sql
   insert into public.admin_users(user_id)
   values ('PASTE-AUTH-USER-UUID-HERE');
   ```

5. Copy `.env.example` to `.env` and fill in:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
6. Restart the server.

**Security:** the Supabase service-role key must remain only in `.env` on the server. Never put it in browser JavaScript or commit `.env` to Git. The public leaderboard reads from a safe view that does not expose phone or email. Admin permissions are controlled through `admin_users` and Row Level Security.

## Connect Razorpay

1. Create/activate your Razorpay merchant account and start with Test Mode keys.
2. Add `RAZORPAY_KEY_ID` and `RAZORPAY_KEY_SECRET` to `.env`.
3. Set a webhook secret in Razorpay and add it as `RAZORPAY_WEBHOOK_SECRET`.
4. Configure the webhook URL as `https://YOUR-DOMAIN/api/razorpay-webhook` and subscribe to `payment.captured` and `payment.failed`.
5. Deploy over HTTPS before testing the full payment flow. Switch to Live Mode only after end-to-end testing.

The Razorpay secret and signature verification are server-side. Do not trust a browser-only payment-success message. The backend stores payment status and the webhook can reconcile captured/failed payments.

## Important setup notes before real launch

- The current registration flow creates a player profile and accepts a tournament format/fee. It does not yet bind a registration to a specific tournament record or automatically create a tournament entry. Add the tournament picker and payment-to-entry mapping before running multiple concurrent events.
- Doubles result entry requires four distinct player IDs. The current public registration flow does not yet collect/confirm a doubles partner; the admin must coordinate teams.
- The ₹100/₹200 amounts are minimums in the interface and server-side order validation. Adjust the business rules if you decide to sell add-on match credits separately.
- Admin match entry currently records a winner and loser (or two partners per team for doubles). It does not enforce a fixture schedule, court allocation, game-by-game badminton score, walkovers, or dispute workflow.
- Add CAPTCHA/rate limiting to public registration, verify phone numbers if needed, configure Supabase backups, and test restore before launch.
- For a multi-court/multi-venue product, add a venue/tenant ID to all relevant records before expanding.
- Use a paid Supabase plan when your production usage or reliability requirements exceed the free plan. Razorpay fees apply to successful payments according to your merchant pricing agreement; check current rates before launch.

## Main routes

- `/` — public website
- `/leaderboard?type=singles` — singles LED display
- `/leaderboard?type=doubles` — doubles LED display
- `/api/config` — public configuration (only Supabase URL/anon key and Razorpay public key ID are returned)

## Project structure

```text
quick-badminton-tournament/
├── public/
│   ├── index.html
│   ├── styles.css
│   └── app.js
├── sql/
│   └── schema.sql
├── .env.example
├── package.json
├── server.js
└── README.md
```


## Player portal (Player ID + mobile number)

The public homepage includes a **Player portal** login. Players enter their generated Player ID and the mobile number used at registration. The Express server checks both values against Supabase using the server-side service-role client, then returns only that player's profile statistics, match history, tournament entries, and payment history. The service-role key is never sent to the browser.

**Security note:** Player ID + phone is a basic convenience login, not strong identity verification. The endpoint applies a simple per-IP attempt limit in the running server process, but this is not a substitute for OTP or persistent rate limiting. Before making the website public, consider upgrading player access to SMS OTP and adding persistent rate limiting (for example, at the hosting/WAF layer).

To update an existing local installation, copy the updated `server.js` and the complete `public` folder into your existing project folder, replacing those files. **Keep your existing `.env` file private and do not replace it with a downloaded copy.** Restart the server with `npm start`.


## Player ID format update

New player IDs use `Firstname_Number` (for example, `Abu_1`, `Rahul_2`). The database assigns the number using a PostgreSQL sequence, so concurrent registrations cannot receive the same number. The ID is returned by Supabase after insertion.

### Existing Supabase project

1. Back up your Supabase database before changing existing IDs.
2. Open Supabase Dashboard → SQL Editor.
3. Open `sql/migrate_player_ids.sql`, copy its full contents into the SQL Editor, and run it once.
4. Confirm the existing player now has the new ID (for example, `Abu_1`) in Table Editor → `players`.
5. Replace your local project folder contents with this updated package, but keep your existing `.env` file. Do not overwrite `.env` with `.env.example`.
6. Stop the old Node server with Ctrl+C, then run `npm start` again.
7. Hard-refresh the website (Ctrl+F5) and test Player Portal using `Abu_1` plus the registered mobile number.

The migration updates player foreign-key references in matches, payments and tournament entries with `ON UPDATE CASCADE`, preserving those records. Do not manually edit IDs in Table Editor. Existing players are renumbered in original registration order; the next registration receives the next number.

For a brand-new database, use `sql/schema.sql` instead of running the migration.
